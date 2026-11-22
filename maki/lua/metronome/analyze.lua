-- The analyzer: check the task sheets against each other before `ready`.
--
-- Qualification produces one sheet at a time; this module is what looks at
-- the set. It finds the contradictions, duplicates and gaps a human would
-- catch by reading every sheet side by side: two tasks with the same title, a
-- dependency that names nothing, a cycle, a task with no files or no checks.
-- Two tasks touching the same file is not a contradiction: each task works in
-- its own worktree, and any conflict is resolved when the branches merge.
--
-- Inter-task rules only compare tasks that share a base_ref: two tasks cut
-- from different base branches are never concurrent, so overlap, duplicates
-- and cycles across them are meaningless.
--
-- Two halves, deliberately separate:
--   * the structural half is pure Lua over the task tables — no state, no
--     runner, no token. It is what the gate always runs.
--   * the semantic half asks the analyst to read the sheets. The runner is
--     injected, so a test (and a dry run) can script it without a model.
--
-- Every function returns (value, err) and never raises. The state module is
-- injected for the same reason it is in questions.lua: `require` cannot yield
-- in this host, and a test must be able to run the gate without a journal.

local M = {}

local fs = maki.fs
local json = maki.json

M.MAX_FILES_DEFAULT = 15

local SEVERITIES = {
  blocking = true,
  major = true,
  minor = true,
  nit = true,
}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_non_empty(s)
  return type(s) == "string" and trim(s) ~= ""
end

local function now_iso()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

-- The id a finding names. A task that has not been applied yet has no id, so
-- a stable placeholder keeps the message readable instead of printing "nil".
local function task_id(task, index)
  if type(task) == "table" and is_non_empty(task.id) then
    return trim(task.id)
  end
  return "task#" .. tostring(index)
end

-- A list of non-empty strings, trimmed. Anything else is dropped: the checks
-- below judge what the sheet actually declares, not what a model meant.
local function string_list(value)
  local out = {}
  if type(value) ~= "table" then
    return out
  end
  for _, item in ipairs(value) do
    if is_non_empty(item) then
      out[#out + 1] = trim(item)
    end
  end
  return out
end

local function dedupe_sorted(list)
  local seen = {}
  local out = {}
  for _, item in ipairs(list) do
    if not seen[item] then
      seen[item] = true
      out[#out + 1] = item
    end
  end
  table.sort(out)
  return out
end

local function intersection(a, b)
  local set = {}
  for _, item in ipairs(a) do
    set[item] = true
  end
  local out = {}
  for _, item in ipairs(b) do
    if set[item] then
      out[#out + 1] = item
    end
  end
  table.sort(out)
  return out
end

-- The file paths a check command mentions. A check such as `node check.js`
-- runs a file that another task may own; that is an implicit dependency the
-- declared `depends_on` graph does not show. We only need tokens that are
-- exactly a declared path (an optional leading `./` is stripped), so quotes,
-- flags and shell operators do not matter.
local function command_tokens(command)
  local tokens = {}
  for token in tostring(command or ""):gmatch("[^%s;|&<>()]+") do
    token = token:gsub("^['\"]", ""):gsub("['\"]$", "")
    token = token:gsub("^%./", "")
    if token ~= "" then
      tokens[#tokens + 1] = token
    end
  end
  return tokens
end

-- Normalization --------------------------------------------------------------

-- Two titles are the same title when they read the same once case, whitespace
-- and trailing punctuation are normalised away. "Add AUTH page." and
-- "  add   auth page  " must collide, or the duplicate check is blind to the
-- most common way a model restates itself.
function M.normalize_title(title)
  if type(title) ~= "string" then
    return ""
  end
  local out = title:lower():gsub("%s+", " ")
  out = out:gsub("^%s+", ""):gsub("%s+$", "")
  out = out:gsub("[%p%s]+$", "")
  out = out:gsub("%s+$", "")
  return out
end

-- The set identity of a task's files. Sorted and deduped, so two sheets that
-- list the same files in a different order compare equal.
function M.file_key(files)
  local list = dedupe_sorted(string_list(files))
  return table.concat(list, ",")
end

-- Dependency graph -----------------------------------------------------------

-- `reaches(a, b)` is true when a depends on b, directly or transitively. The
-- cache is per-analyze: the graph does not change while the checks run.
local function make_reacher(dep_map)
  local cache = {}
  local function reaches(from, to)
    if from == to then
      return true
    end
    local key = from .. "\0" .. to
    local cached = cache[key]
    if cached ~= nil then
      return cached
    end
    local seen = {}
    local stack = { from }
    while #stack > 0 do
      local node = stack[#stack]
      stack[#stack] = nil
      if not seen[node] then
        seen[node] = true
        for _, dep in ipairs(dep_map[node] or {}) do
          if dep == to then
            cache[key] = true
            return true
          end
          if not seen[dep] then
            stack[#stack + 1] = dep
          end
        end
      end
    end
    cache[key] = false
    return false
  end
  return reaches
end

-- Rotate a cycle so the smallest id comes first. Two traversals that found
-- the same cycle from different entry points then collapse into one finding.
local function canonical_cycle(cycle)
  if #cycle == 0 then
    return cycle
  end
  local min_index = 1
  for i = 2, #cycle do
    if cycle[i] < cycle[min_index] then
      min_index = i
    end
  end
  local out = {}
  for k = 0, #cycle - 1 do
    out[#out + 1] = cycle[(min_index - 1 + k) % #cycle + 1]
  end
  return out
end

-- Depth-first search with the usual white/gray/black colours. A back edge to
-- a gray node is a cycle; its nodes are the gray tail of the stack. Each
-- canonical cycle is reported once. Self-loops are skipped: self_dependency
-- owns them, and reporting them twice would double the noise. `allowed` is
-- the group being searched: an edge that leaves it is ignored, so a cycle
-- spanning two base branches is never reported.
local function find_cycles(ids, dep_map, id_set, allowed)
  local color = {}
  local stack = {}
  local position = {}
  local seen = {}
  local cycles = {}

  local function visit(node)
    color[node] = 1
    stack[#stack + 1] = node
    position[node] = #stack
    for _, dep in ipairs(dep_map[node] or {}) do
      if dep ~= node and id_set[dep] and (not allowed or allowed[dep]) then
        local state = color[dep] or 0
        if state == 0 then
          visit(dep)
        elseif state == 1 then
          local start = position[dep]
          if start then
            local cycle = {}
            for k = start, #stack do
              cycle[#cycle + 1] = stack[k]
            end
            local canonical = canonical_cycle(cycle)
            local key = table.concat(canonical, "\0")
            if not seen[key] then
              seen[key] = true
              cycles[#cycles + 1] = canonical
            end
          end
        end
      end
    end
    stack[#stack] = nil
    position[node] = nil
    color[node] = 2
  end

  for _, id in ipairs(ids) do
    if (color[id] or 0) == 0 then
      visit(id)
    end
  end
  return cycles
end

-- Repository existence -------------------------------------------------------

-- Does `rel` exist under `repo`? Listing the parent directory keeps this a
-- metadata question: reading the file would fail on binary content and would
-- pull a whole source file into memory for a one-bit answer.
local function exists_under(repo, rel)
  local parent, name = rel:match("^(.*)/([^/]+)$")
  if not parent then
    parent, name = "", rel
  end
  if not name or name == "" then
    return false
  end
  local dir = parent == "" and repo or fs.joinpath(repo, parent)
  local entries = fs.dir(dir)
  if not entries then
    return false
  end
  for _, entry in ipairs(entries) do
    local entry_name = entry.name or entry[1]
    if entry_name == name then
      return true
    end
  end
  return false
end

-- Structural analysis --------------------------------------------------------

-- Analyze a set of tasks. Pure: the same tables always give the same
-- findings, in the same order. `opts.known_ids` is a map or an array of every
-- id the pipeline knows about; when it is absent the dependency-existence
-- check is skipped, because there is nothing to check against.
function M.analyze(tasks, opts)
  opts = type(opts) == "table" and opts or {}
  local list = type(tasks) == "table" and tasks or {}
  local max_files = opts.max_files_per_task or M.MAX_FILES_DEFAULT
  local findings = {}

  local ids = {}
  local titles = {}
  local filesets = {}
  local checksets = {}
  local keys = {}
  local dep_map = {}
  local id_set = {}
  local groups = {}

  for i, raw in ipairs(list) do
    local task = type(raw) == "table" and raw or {}
    local id = task_id(task, i)
    ids[i] = id
    id_set[id] = true
    titles[i] = M.normalize_title(task.title)
    filesets[i] = dedupe_sorted(string_list(task.files))
    checksets[i] = string_list(task.checks)
    keys[i] = table.concat(filesets[i], ",")
    dep_map[id] = string_list(task.depends_on)
    -- The group a task belongs to: its base_ref, else the batch base_ref,
    -- else the default group. Inter-task rules never cross groups: two tasks
    -- cut from different base branches are never concurrent.
    local group_key = ""
    if is_non_empty(task.base_ref) then
      group_key = trim(task.base_ref)
    elseif is_non_empty(opts.base_ref) then
      -- Trim it like the per-task base_ref, or a padded batch base_ref would
      -- split a group that should be one.
      group_key = trim(opts.base_ref)
    end
    groups[i] = group_key
  end

  local group_indexes = {}
  local group_order = {}
  for i = 1, #ids do
    local key = groups[i]
    if not group_indexes[key] then
      group_indexes[key] = {}
      -- Remember the key the first time it appears so the groups can be
      -- walked in task-index order: `pairs` order is not reproducible and the
      -- findings must land in a stable order in the report.
      group_order[#group_order + 1] = key
    end
    local group = group_indexes[key]
    group[#group + 1] = i
  end

  local function same_group(i, j)
    return groups[i] == groups[j]
  end

  -- duplicate_title: two sheets a human would read as the same task.
  for i = 1, #ids do
    for j = i + 1, #ids do
      if same_group(i, j) and titles[i] ~= "" and titles[i] == titles[j] then
        findings[#findings + 1] = {
          severity = "blocking",
          rule = "duplicate_title",
          message = string.format(
            "tasks %s and %s share the title %q", ids[i], ids[j], titles[i]
          ),
          tasks = { ids[i], ids[j] },
        }
      end
    end
  end

  -- duplicate_files: two sheets declaring exactly the same files. Like
  -- file_overlap, this is not a conflict — each task works in its own
  -- worktree and the branches merge independently — so it only advises.
  for i = 1, #ids do
    for j = i + 1, #ids do
      if same_group(i, j) and keys[i] ~= "" and keys[i] == keys[j] then
        findings[#findings + 1] = {
          severity = "minor",
          rule = "duplicate_files",
          message = string.format(
            "tasks %s and %s declare the same files: %s; both merge independently, so make sure their changes compose",
            ids[i], ids[j], keys[i]
          ),
          tasks = { ids[i], ids[j] },
        }
      end
    end
  end

  -- file_overlap: two sheets touching a shared file. Overlap is the point of
  -- worktrees, not a conflict: the two branches merge independently and any
  -- textual conflict is resolved at merge time. The finding is kept as minor
  -- advice so a human can still spot an accidental split.
  local reaches = make_reacher(dep_map)
  for i = 1, #ids do
    for j = i + 1, #ids do
      if same_group(i, j) and keys[i] ~= "" and keys[j] ~= "" and keys[i] ~= keys[j] then
        local shared = intersection(filesets[i], filesets[j])
        if #shared > 0
          and not reaches(ids[i], ids[j])
          and not reaches(ids[j], ids[i]) then
          findings[#findings + 1] = {
            severity = "minor",
            rule = "file_overlap",
            message = string.format(
              "tasks %s and %s both touch %s; they merge independently and any conflict resolves at merge",
              ids[i], ids[j], table.concat(shared, ", ")
            ),
            tasks = { ids[i], ids[j] },
          }
        end
      end
    end
  end

  -- known_ids accepts a map { [id] = true } or an array { id, ... }. Both
  -- become one set, so the caller does not have to remember which it has.
  local known = nil
  if type(opts.known_ids) == "table" then
    known = {}
    for key, value in pairs(opts.known_ids) do
      if type(key) == "number" then
        if type(value) == "string" then
          known[value] = true
        end
      else
        known[key] = true
      end
    end
  end

  -- missing_dependency: an edge that points at nothing the pipeline knows.
  if known then
    for i = 1, #ids do
      for _, dep in ipairs(dep_map[ids[i]] or {}) do
        if not known[dep] then
          findings[#findings + 1] = {
            severity = "blocking",
            rule = "missing_dependency",
            message = string.format(
              "task %s depends on %s, which is neither a task id, a 'T<n>' batch position, a 1-based batch index nor a task title",
              ids[i], dep
            ),
            tasks = { ids[i] },
          }
        end
      end
    end
  end

  -- self_dependency: a task that can never start.
  for i = 1, #ids do
    local depends_on_self = false
    for _, dep in ipairs(dep_map[ids[i]] or {}) do
      if dep == ids[i] then
        depends_on_self = true
        break
      end
    end
    if depends_on_self then
      findings[#findings + 1] = {
        severity = "blocking",
        rule = "self_dependency",
        message = string.format("task %s depends on itself", ids[i]),
        tasks = { ids[i] },
      }
    end
  end

  -- dependency_cycle: a loop among two or more tasks of the same base
  -- branch. A cycle across groups would be an artifact: those tasks are
  -- never scheduled together.
  for _, group_key in ipairs(group_order) do
    local indexes = group_indexes[group_key]
    local group_ids = {}
    local group_set = {}
    for k, i in ipairs(indexes) do
      group_ids[k] = ids[i]
      group_set[ids[i]] = true
    end
    for _, cycle in ipairs(find_cycles(group_ids, dep_map, id_set, group_set)) do
      local path = table.concat(cycle, " -> ") .. " -> " .. cycle[1]
      findings[#findings + 1] = {
        severity = "blocking",
        rule = "dependency_cycle",
        message = "dependency cycle: " .. path,
        tasks = cycle,
      }
    end
  end

  -- gate_cycle / undeclared_gate_dependency: a check that runs a file another
  -- task owns is an implicit dependency on that task. The check sees the file
  -- as the owner will leave it, not as the base has it. If the owner waits on
  -- this task, neither can go green: this task is red until the owner lands,
  -- and the owner cannot start until this task merges. The declared graph
  -- cannot show this, so the analyst must.
  local owners = {}
  local file_sets = {}
  local id_group = {}
  for i = 1, #ids do
    id_group[ids[i]] = groups[i]
    file_sets[ids[i]] = {}
    for _, file in ipairs(filesets[i]) do
      file_sets[ids[i]][file] = true
      owners[file] = owners[file] or {}
      owners[file][ids[i]] = true
    end
  end
  local gate_reported = {}
  for i = 1, #ids do
    local me = ids[i]
    for _, command in ipairs(checksets[i]) do
      for _, token in ipairs(command_tokens(command)) do
        local file_owners = owners[token]
        if file_owners and not file_sets[me][token] then
          for owner in pairs(file_owners) do
            -- Tasks of another base branch never run concurrently with this
            -- one, so owning the same gate file is not a coupling.
            if id_group[owner] == id_group[me] then
              local key = me .. "\0" .. owner .. "\0" .. token
              if not gate_reported[key] then
              gate_reported[key] = true
              if reaches(owner, me) then
                findings[#findings + 1] = {
                  severity = "blocking",
                  rule = "gate_cycle",
                  message = string.format(
                    "task %s runs %s in its checks, but %s owns that file and depends on %s; neither can go green — merge them, update the gate in %s, or make %s independent and merge it first",
                    me, token, owner, me, me, owner
                  ),
                  tasks = { me, owner },
                }
              elseif not reaches(me, owner) then
                findings[#findings + 1] = {
                  severity = "major",
                  rule = "undeclared_gate_dependency",
                  message = string.format(
                    "task %s runs %s in its checks, which %s owns; %s should depend on %s, or the gate update belongs in %s",
                    me, token, owner, me, owner, me
                  ),
                  tasks = { me, owner },
                }
              end
              end
            end
          end
        end
      end
    end
  end

  -- empty_files: a sheet that says nothing about what it touches.
  for i = 1, #ids do
    if #filesets[i] == 0 then
      findings[#findings + 1] = {
        severity = "blocking",
        rule = "empty_files",
        message = string.format("task %s declares no files", ids[i]),
        tasks = { ids[i] },
      }
    end
  end

  -- empty_checks: a sheet with no way to prove it is done.
  for i = 1, #ids do
    if #checksets[i] == 0 then
      findings[#findings + 1] = {
        severity = "blocking",
        rule = "empty_checks",
        message = string.format("task %s declares no checks", ids[i]),
        tasks = { ids[i] },
      }
    end
  end

  -- unknown_file: a declared file that is not in the repository. A new file
  -- is legitimate, so this is a warning: the analyst may still be right that
  -- the sheet is describing something that should not exist.
  --
  -- With `opts.ref` the check reads the tree the worktree will be cut from
  -- (`origin/<base>`), not the local checkout: a diverged checkout would
  -- otherwise flag a file that exists on the base, or accept one that only
  -- exists locally.
  local ref_files = nil
  if type(opts.ref) == "string" and opts.ref ~= ""
    and type(opts.git) == "table" and type(opts.git.ls_tree) == "function"
    and type(opts.repo) == "string" and opts.repo ~= "" then
    local listed = opts.git.ls_tree(opts.repo, opts.ref)
    if type(listed) == "table" then
      ref_files = {}
      for _, path in ipairs(listed) do
        ref_files[path] = true
      end
    end
  end
  if type(opts.repo) == "string" and opts.repo ~= "" then
    for i = 1, #ids do
      for _, file in ipairs(filesets[i]) do
        local known
        if ref_files then
          known = ref_files[file] == true
        else
          known = exists_under(opts.repo, file)
        end
        if not known then
          findings[#findings + 1] = {
            severity = "minor",
            rule = "unknown_file",
            message = string.format(
              "task %s declares a file that does not exist under the repo: %s",
              ids[i], file
            ),
            tasks = { ids[i] },
          }
        end
      end
    end
  end

  -- undeclared_file_dependency: a sheet whose checks or acceptance name a
  -- file another sheet produces, without declaring that sheet as a dependency.
  -- The qualifier split one ask into tasks that must run in order; a missing
  -- edge makes the scheduler run them together and the reviewer catch it too
  -- late.
  local texts = {}
  for i = 1, #ids do
    local parts = {}
    for _, c in ipairs(checksets[i]) do
      parts[#parts + 1] = c
    end
    for _, a in ipairs(string_list(list[i] and list[i].acceptance)) do
      parts[#parts + 1] = a
    end
    texts[i] = table.concat(parts, "\n")
  end
  local function depends_on(id, target, seen)
    seen = seen or {}
    if seen[id] then
      return false
    end
    seen[id] = true
    for _, dep in ipairs(dep_map[id] or {}) do
      if dep == target or depends_on(dep, target, seen) then
        return true
      end
    end
    return false
  end
  for i = 1, #ids do
    local mine = {}
    for _, f in ipairs(filesets[i]) do
      mine[f] = true
    end
    for j = 1, #ids do
      if i ~= j and same_group(i, j) and not depends_on(ids[i], ids[j]) then
        for _, file in ipairs(filesets[j]) do
          if not mine[file] then
            local base = file:match("([^/]+)$") or file
            local named = texts[i]:find(file, 1, true) ~= nil
              or (base ~= file and texts[i]:find(base, 1, true) ~= nil)
            if named then
              findings[#findings + 1] = {
                severity = "major",
                rule = "undeclared_file_dependency",
                message = string.format(
                  "task %s names %s, produced by %s, without depending on it",
                  ids[i], file, ids[j]
                ),
                tasks = { ids[i], ids[j] },
              }
              break
            end
          end
        end
      end
    end
  end

  -- oversized: a sheet too large to review as one pull request.
  for i = 1, #ids do
    if #filesets[i] > max_files then
      findings[#findings + 1] = {
        severity = "major",
        rule = "oversized",
        message = string.format(
          "task %s declares %d files, more than the %d allowed",
          ids[i], #filesets[i], max_files
        ),
        tasks = { ids[i] },
      }
    end
  end

  local ok = true
  for _, finding in ipairs(findings) do
    if finding.severity == "blocking" then
      ok = false
      break
    end
  end

  return {
    findings = findings,
    ok = ok,
    verdict = ok and "ok" or "blocked",
  }
end

-- Semantic prompt ------------------------------------------------------------

local function concat_list(value)
  return table.concat(string_list(value), ", ")
end

-- The prompt the analyst reads. The intention is verbatim; each task is
-- rendered with the fields that matter for cross-sheet reasoning, and the
-- sheet itself is included when it exists on disk.
function M.semantic_prompt(intention, tasks, opts)
  opts = type(opts) == "table" and opts or {}
  local out = {}
  local function line(s)
    out[#out + 1] = s
  end

  line("# Analysis")
  line("")
  line("## Intention (verbatim)")
  line("")
  line(tostring(intention or ""))

  line("")
  line("## Task sheets")
  for i, raw in ipairs(type(tasks) == "table" and tasks or {}) do
    local task = type(raw) == "table" and raw or {}
    local id = task_id(task, i)
    line("")
    line("### " .. id)
    line("")
    line("- id: " .. id)
    line("- title: " .. tostring(task.title or ""))
    line("- files: " .. concat_list(task.files))
    line("- checks: " .. concat_list(task.checks))
    line("- depends_on: " .. concat_list(task.depends_on))

    if type(opts.tasks_dir) == "string" and opts.tasks_dir ~= "" then
      local sheet = fs.read(fs.joinpath(opts.tasks_dir, id .. ".md"))
      if type(sheet) == "string" then
        line("")
        line("#### Sheet")
        line("")
        line(sheet)
      end
    end
  end

  line("")
  line("## Output contract")
  line("")
  line("Return exactly one JSON object with this shape:")
  line("")
  line('{"findings":[{"severity":"blocking|major|minor|nit","rule":"contradiction|duplicate|gap|ordering|scope","message":"...","tasks":["T-..."]}]}')
  line("")
  line("Use blocking only for a real contradiction, duplicate or gap that makes the plan unexecutable.")
  line("Otherwise use major, minor or nit.")
  line('If the sheets are coherent, return {"findings":[]}.')

  return table.concat(out, "\n")
end

-- JSON extraction ------------------------------------------------------------

-- The first balanced {...} or [...] starting at `start`, ignoring brackets
-- inside strings and honouring backslash escapes.
local function balanced(text, start, open, close)
  local depth = 0
  local in_string = false
  local escaped = false
  for i = start, #text do
    local c = text:sub(i, i)
    if in_string then
      if escaped then
        escaped = false
      elseif c == "\\" then
        escaped = true
      elseif c == '"' then
        in_string = false
      end
    elseif c == '"' then
      in_string = true
    elseif c == open then
      depth = depth + 1
    elseif c == close then
      depth = depth - 1
      if depth == 0 then
        return text:sub(start, i)
      end
    end
  end
  return nil
end

-- Prefer whichever bracket opens first, so a bare array is not mistaken for
-- the first object inside it. If that candidate is unbalanced, the other one
-- still gets a chance.
local function extract_candidate(text)
  local object_start = text:find("{", 1, true)
  local array_start = text:find("[", 1, true)
  local candidates = {}
  if object_start then
    candidates[#candidates + 1] = { start = object_start, open = "{", close = "}" }
  end
  if array_start then
    candidates[#candidates + 1] = { start = array_start, open = "[", close = "]" }
  end
  table.sort(candidates, function(a, b)
    return a.start < b.start
  end)
  for _, candidate in ipairs(candidates) do
    local slice = balanced(text, candidate.start, candidate.open, candidate.close)
    if slice then
      return slice
    end
  end
  return nil
end

-- Validate one semantic finding. The shape is the one the analyst contract
-- promises; a finding that does not fit it is an error, not a silent drop.
local function normalize_finding(raw, index)
  if type(raw) ~= "table" then
    return nil, string.format("finding %d: not an object", index)
  end

  local severity = raw.severity
  if type(severity) ~= "string" or not SEVERITIES[severity] then
    return nil, string.format(
      "finding %d: severity must be one of blocking, major, minor, nit", index
    )
  end

  local message = raw.message
  if not is_non_empty(message) then
    return nil, string.format("finding %d: message must be a non-empty string", index)
  end

  local rule = raw.rule
  if rule == nil then
    rule = "semantic"
  elseif type(rule) ~= "string" then
    return nil, string.format("finding %d: rule must be a string", index)
  end

  local tasks = {}
  if raw.tasks ~= nil then
    if type(raw.tasks) ~= "table" then
      return nil, string.format(
        "finding %d: tasks must be an array of non-empty strings", index
      )
    end
    for j, id in ipairs(raw.tasks) do
      if not is_non_empty(id) then
        return nil, string.format(
          "finding %d: tasks[%d] must be a non-empty string", index, j
        )
      end
      tasks[j] = trim(id)
    end
  end

  return {
    severity = severity,
    rule = rule,
    message = message,
    tasks = tasks,
  }
end

-- Parse the analyst's answer. Accepts `{findings:[...]}` or a bare array,
-- fenced or surrounded by prose. Returns (findings, err).
function M.parse_findings(text)
  if type(text) ~= "string" then
    return nil, "no text"
  end

  local slice = extract_candidate(text)
  if not slice then
    return nil, "invalid JSON: no JSON object found"
  end

  local ok, decoded, decode_err = pcall(json.decode, slice)
  if not ok then
    return nil, "invalid JSON: " .. tostring(decoded)
  end
  if decoded == nil then
    return nil, "invalid JSON: " .. tostring(decode_err)
  end
  if type(decoded) ~= "table" then
    return nil, "invalid JSON: expected an object or an array"
  end

  -- The decoded table cannot tell an empty array from an empty object, so the
  -- slice's first character decides. That is what makes `[]` a valid answer.
  local first = slice:match("^%s*(.)")
  local list
  if first == "[" then
    list = decoded
  elseif type(decoded.findings) == "table" then
    list = decoded.findings
  else
    return nil, "invalid JSON: expected a findings array"
  end

  local findings = {}
  for i, raw in ipairs(list) do
    local finding, err = normalize_finding(raw, i)
    if not finding then
      return nil, err
    end
    findings[i] = finding
  end
  return findings
end

-- Run ------------------------------------------------------------------------

-- Analyze the structural half, then optionally the semantic half.
--
-- A failed or unparseable analyst is a blocking `semantic_failed` finding:
-- the gate cannot claim the sheets are coherent when the check that reads
-- them did not run. `semantic = false` is the explicit dry run.
function M.run(opts)
  opts = type(opts) == "table" and opts or {}
  local tasks = type(opts.tasks) == "table" and opts.tasks or {}

  local structural = M.analyze(tasks, opts)
  local findings = {}
  for i, finding in ipairs(structural.findings) do
    findings[i] = finding
  end

  if opts.semantic == false or type(opts.runner) ~= "function" then
    return {
      ok = structural.ok,
      verdict = structural.verdict,
      findings = findings,
      structural = structural,
      semantic = { ok = true, skipped = true },
    }
  end

  local session_opts = type(opts.session_opts) == "table" and opts.session_opts or {}
  local prompt = M.semantic_prompt(opts.intention, tasks, opts)

  local called, result = pcall(opts.runner, {
    role = "analyst",
    task_id = opts.task_id or "analyze",
    phase = "analyze",
    prompt = prompt,
    system = session_opts.system,
    model_spec = session_opts.model_spec,
    thinking = session_opts.thinking,
    tools = session_opts.tools,
    state_root = opts.state_root,
    ctx = opts.ctx,
  })
  if not called then
    result = { ok = false, error = tostring(result) }
  end
  if type(result) ~= "table" then
    result = { ok = false, error = "runner returned no result" }
  end

  local parsed, parse_err = nil, nil
  if result.ok then
    parsed, parse_err = M.parse_findings(result.text)
  end

  local semantic
  if not result.ok or not parsed then
    local message = result.ok and tostring(parse_err) or tostring(result.error or "runner failed")
    local ids = {}
    for i, task in ipairs(tasks) do
      ids[i] = task_id(task, i)
    end
    findings[#findings + 1] = {
      severity = "blocking",
      rule = "semantic_failed",
      message = "analyst failed: " .. message,
      tasks = ids,
    }
    semantic = { ok = false, error = message }
  else
    for _, finding in ipairs(parsed) do
      findings[#findings + 1] = finding
    end
    semantic = { ok = true, findings = parsed }
  end

  local ok = true
  for _, finding in ipairs(findings) do
    if finding.severity == "blocking" then
      ok = false
      break
    end
  end

  return {
    ok = ok,
    verdict = ok and "ok" or "blocked",
    findings = findings,
    structural = structural,
    semantic = semantic,
  }
end

-- Report ---------------------------------------------------------------------

-- Write the evidence for one gate decision. `analysis.json` is what a human
-- reads after the fact, so it carries the intention and the timestamp as well
-- as the findings.
function M.write_report(root, result, opts)
  opts = type(opts) == "table" and opts or {}
  if type(root) ~= "string" or root == "" then
    return nil, "state root is required"
  end

  local made, mkdir_err = fs.mkdir(root, { parents = true })
  if not made then
    return nil, "cannot create state root: " .. tostring(mkdir_err)
  end

  local payload = {
    at = opts.now or now_iso(),
    intention = opts.intention,
    verdict = type(result) == "table" and result.verdict or "blocked",
    findings = type(result) == "table" and result.findings or {},
  }

  local encoded_ok, encoded = pcall(json.encode, payload)
  if not encoded_ok or type(encoded) ~= "string" then
    return nil, "cannot encode analysis report: " .. tostring(encoded)
  end

  local path = fs.joinpath(root, "analysis.json")
  local wrote, write_err = fs.write(path, encoded)
  if not wrote then
    return nil, "cannot write analysis report: " .. tostring(write_err)
  end
  return path, nil
end

-- Fingerprint cache ----------------------------------------------------------

-- Two polynomial hashes with distinct bases, concatenated. A single 32-bit hash
-- has a collision rate low enough to be unlikely but not low enough to bet a
-- cache hit on; two bases make an accidental match negligible without pulling a
-- crypto library into the module. Both multipliers stay small enough that each
-- step (h * base + byte) stays below 2^53, so the modulo is exact in double
-- arithmetic and no low bits are lost.
local function digest(text)
  local h1, h2 = 5381, 2166136261
  for i = 1, #text do
    local byte = text:byte(i)
    h1 = (h1 * 33 + byte) % 4294967296
    h2 = (h2 * 65599 + byte) % 4294967296
  end
  return string.format("%.0f-%.0f", h1, h2)
end

-- The findings a cache hit reuses, rendered so that any change to a severity,
-- a rule, a message or an attributed task changes the signature. A cache whose
-- stored signature no longer matches its own findings is stale: someone edited
-- the report, or a previous run wrote it half-way.
local function findings_signature(findings)
  local parts = {}
  for i, finding in ipairs(type(findings) == "table" and findings or {}) do
    parts[i] = table.concat({
      tostring(finding.severity or ""),
      tostring(finding.rule or ""),
      tostring(finding.message or ""),
      table.concat(string_list(finding.tasks), ","),
    }, "\31")
  end
  return digest(table.concat(parts, "\30"))
end

-- The analysis input: the selected ids, each sheet's structural fields, the
-- dependency edges and the sheet text itself. Sorted by id, so the order the
-- caller happened to pass the tasks in never invalidates the cache.
--
-- `extra` folds in everything the findings depend on that is not part of the
-- selected sheets: the ids the pipeline already knows (a `missing_dependency`
-- clears as soon as the referenced task is created), whether each declared file
-- exists in the tree the worktree is cut from (an `unknown_file` clears when the
-- file lands), and the intention, repo and ref handed to the semantic prompt.
local function input_fingerprint(tasks, tasks_dir, extra)
  local ids = {}
  for i, task in ipairs(tasks) do
    ids[i] = task_id(task, i)
  end
  local order = {}
  for i = 1, #tasks do
    order[i] = i
  end
  table.sort(order, function(a, b)
    return ids[a] < ids[b]
  end)

  local rows = {}
  for _, i in ipairs(order) do
    local task = tasks[i]
    local sheet = ""
    if type(tasks_dir) == "string" and tasks_dir ~= "" then
      local text = fs.read(fs.joinpath(tasks_dir, ids[i] .. ".md"))
      if type(text) == "string" then
        sheet = text
      end
    end
    rows[#rows + 1] = table.concat({
      ids[i],
      tostring(task.title or ""),
      tostring(task.base_ref or ""),
      table.concat(dedupe_sorted(string_list(task.files)), ","),
      table.concat(string_list(task.checks), "\1"),
      table.concat(string_list(task.acceptance), "\1"),
      table.concat(dedupe_sorted(string_list(task.depends_on)), ","),
      sheet,
    }, "\2")
  end
  return digest(table.concat(rows, "\3") .. "\4" .. tostring(extra or ""))
end

local CACHE_FILE = "analysis-cache.json"

local function read_cache(root)
  local text = fs.read(fs.joinpath(root, CACHE_FILE))
  if type(text) ~= "string" then
    return nil
  end
  local ok, decoded = pcall(json.decode, text)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

local function write_cache(root, fingerprint, findings)
  local payload = {
    fingerprint = fingerprint,
    findings = findings,
    findings_signature = findings_signature(findings),
    at = now_iso(),
  }
  local ok, encoded = pcall(json.encode, payload)
  if not ok or type(encoded) ~= "string" then
    return nil
  end
  return fs.write(fs.joinpath(root, CACHE_FILE), encoded)
end

-- Gate -----------------------------------------------------------------------

-- The first `depends_on` entry of `task` that names no task of `known_ids`, or
-- nil when every dependency resolves. A ready task with one of these can never
-- be dispatched, so the gate has to pull it back into qualification.
local function unresolved_dependency(task, known_ids)
  for _, dep in ipairs(string_list(type(task) == "table" and task.depends_on or nil)) do
    if not known_ids[dep] then
      return dep
    end
  end
  return nil
end

-- The `qualifying -> ready` gate, decided per task.
--
-- The structural and semantic halves produce one findings list for the batch;
-- the gate then attributes every blocking finding to the task ids it names. A
-- task that carries one stays in `qualifying` with a `quarantine` marker, and
-- every other task moves to `ready`. One broken sheet therefore never freezes
-- the tasks that are fine.
--
-- A blocking finding that names no selected task (an empty tasks list, or a
-- batch-level rule) cannot be pinned on one sheet: it quarantines the whole
-- analysed batch and moves none. That is still a completed analysis, so the
-- gate returns ok=true and the caller dispatches whatever else is ready.
--
-- A fingerprint of the analysis input (ids, sheets, dependencies) and of the
-- findings keys a persistent cache under the state root. When nothing changed,
-- the gate reuses the cached findings and never calls the semantic runner; a
-- change to a sheet, an edge or a finding misses the cache. A re-analysis that
-- finds a quarantined task clean clears its quarantine and moves it to ready
-- without waiting for a new submit.
--
-- A ready task with an unresolved dependency is pulled back to `qualifying`
-- first, so it cannot stay ready-but-never-dispatchable.
--
function M.gate(state, root, opts)
  opts = type(opts) == "table" and opts or {}
  if type(state) ~= "table" or type(state.load) ~= "function" then
    return nil, "state module is required"
  end
  if type(root) ~= "string" or root == "" then
    return nil, "state root is required"
  end

  local loaded_ok, loaded = pcall(state.load, root)
  if not loaded_ok or type(loaded) ~= "table" then
    return nil, "cannot load state"
  end
  local all = type(loaded.tasks) == "table" and loaded.tasks or {}

  local known_ids = {}
  for id in pairs(all) do
    known_ids[id] = true
  end

  local selected = {}
  if type(opts.tasks) == "table" then
    for i, task in ipairs(opts.tasks) do
      selected[i] = task
    end
  else
    local ids = {}
    for id, task in pairs(all) do
      if type(task) == "table" then
        local eligible = task.status == "qualifying"
          or (task.status == "ready" and unresolved_dependency(task, known_ids) ~= nil)
        if eligible then
          ids[#ids + 1] = id
        end
      end
    end
    table.sort(ids)
    for i, id in ipairs(ids) do
      selected[i] = all[id]
    end
  end

  if #selected == 0 then
    return { ok = true, verdict = "ok", findings = {}, tasks = {}, quarantined = {},
      blocked = {}, demoted = {} }
  end

  local selected_by_id = {}
  local selected_ids = {}
  for i, task in ipairs(selected) do
    local id = task_id(task, i)
    selected_ids[i] = id
    selected_by_id[id] = task
  end
  table.sort(selected_ids)
  end

  -- Everything outside the sheets that can change a finding: the known ids, the
  -- declared files' existence, and the semantic prompt's intention/repo/ref.
  local function input_signature()
    local known_sorted = {}
    for id in pairs(known_ids) do
      known_sorted[#known_sorted + 1] = tostring(id)
    end
    table.sort(known_sorted)

    local ref_files = nil
    if type(opts.ref) == "string" and opts.ref ~= ""
      and type(opts.git) == "table" and type(opts.git.ls_tree) == "function"
      and type(opts.repo) == "string" and opts.repo ~= "" then
      local listed = opts.git.ls_tree(opts.repo, opts.ref)
      if type(listed) == "table" then
        ref_files = {}
        for _, path in ipairs(listed) do
          ref_files[path] = true
        end
      end
    end

    local repo = type(opts.repo) == "string" and opts.repo or ""
    local file_bits = {}
    if repo ~= "" then
      for _, id in ipairs(selected_ids) do
        local task = selected_by_id[id]
        for _, file in ipairs(dedupe_sorted(string_list(task.files))) do
          local exists
          if type(ref_files) == "table" then
            exists = ref_files[file] == true
          else
            exists = exists_under(repo, file)
          end
          file_bits[#file_bits + 1] = tostring(file) .. (exists and "=1" or "=0")
        end
      end
    end

    return table.concat({
      table.concat(known_sorted, ","),
      tostring(opts.intention or ""),
      repo,
      tostring(opts.ref or ""),
      table.concat(file_bits, ","),
    }, "\5")
  end

  local tasks_dir = opts.tasks_dir or fs.joinpath(root, "tasks")
  -- Only a run that actually consulted the semantic half is worth caching: a
  -- structural-only dry run must never hide the analyst from the next gate.
  local cacheable = type(opts.runner) == "function" and opts.semantic ~= false
  local cache_hit = false
  local result = nil
  local fingerprint = nil

  if cacheable then
    -- Only a cacheable run pays for the fingerprint: hashing the sheets, listing
    -- the declared files and running `git ls_tree` is wasted work when no runner
    -- will ever read or write the cache.
    fingerprint = input_fingerprint(selected, tasks_dir, input_signature())
    local cache = read_cache(root)
    if type(cache) == "table"
      and cache.fingerprint == fingerprint
      and type(cache.findings) == "table" then
      -- A hand-edited or half-written cache can hold a findings array whose
      -- entries are not tables. `findings_signature` indexes each entry, so a
      -- malformed entry would raise; treat any such failure as a cache miss
      -- instead of breaking the module's "never raises" contract.
      local sig_ok, sig = pcall(findings_signature, cache.findings)
      if sig_ok and cache.findings_signature == sig then
        -- A cache hit replays findings, not a verdict: recompute the verdict
        -- from the cached findings exactly as a fresh run does, so
        -- `analysis.json` never says ok next to a blocking finding.
        local cached_ok = true
        for _, finding in ipairs(cache.findings) do
          if finding.severity == "blocking" then
            cached_ok = false
            break
          end
        end
        result = {
          ok = cached_ok,
          verdict = cached_ok and "ok" or "blocked",
          findings = cache.findings,
          semantic = { ok = true, cached = true },
        }
        cache_hit = true
      end
    end
  end

  if not result then
    result = M.run({
      tasks = selected,
      intention = opts.intention,
      known_ids = known_ids,
      repo = opts.repo,
      ref = opts.ref,
      git = opts.git,
      runner = opts.runner,
      session_opts = opts.session_opts,
      semantic = opts.semantic,
      tasks_dir = tasks_dir,
      state_root = opts.state_root,
      ctx = opts.ctx,
      now = opts.now,
    })
    local ok = true
    for _, finding in ipairs(result.findings or {}) do
      if finding.severity == "blocking" then
        ok = false
        break
      end
    end
    result.ok = ok
    result.verdict = ok and "ok" or "blocked"
    -- Never cache a run whose semantic half failed: `M.run` synthesises a
    -- blocking `semantic_failed` finding then, and reusing it would pin the
    -- batch in quarantine forever instead of retrying the analyst next pass.
    local semantic_failed = type(result.semantic) == "table" and result.semantic.ok == false
    if cacheable and not semantic_failed then
      write_cache(root, fingerprint, result.findings)
    end
  end

  local _, report_err = M.write_report(root, result, opts)
  if report_err then
    return nil, report_err
  end

  local ready = {}
  local quarantined = {}
  local blocked = {}
  local demoted = {}

  for _, id in ipairs(selected_ids) do
    local current = current_tasks[id]
    if type(current) == "table" then
      local own = per_task[id]
      local list = nil
      if #unattributable > 0 then
        list = {}
        for _, finding in ipairs(own or {}) do
          list[#list + 1] = finding
        end
        for _, finding in ipairs(unattributable) do
          list[#list + 1] = finding
        end
      elseif own and #own > 0 then
        list = own
      end

      -- A ready task whose dependency names no task can never be dispatched:
      -- pull it back into qualification whatever the verdict, so a repaired
      -- depends_on gives it another chance.
      local unresolved
      if current.status == "ready" then
        unresolved = unresolved_dependency(current, known_ids)
      end
      if current.status == "ready" and unresolved then
        local demoted_ok, transitioned, transition_err = pcall(
          state.transition, root, id, "qualifying", {
            phase = "analyze",
            reason = "unresolved dependency: " .. unresolved,
          }
        )
        if not demoted_ok then
          return nil, "cannot move " .. id .. " back to qualifying: " .. tostring(transitioned)
        end
        if not transitioned then
          return nil, transition_err
        end
        demoted[#demoted + 1] = id
      elseif list and current.status == "qualifying" then
        local payload = quarantine_payload(list, current.quarantine)
        local wrote_ok, wrote, write_err = pcall(
          state.set_fields, root, id, { quarantine = payload }
        )
        if not wrote_ok then
          return nil, "cannot quarantine " .. id .. ": " .. tostring(wrote)
        end
        if not wrote then
          return nil, write_err
        end
        quarantined[#quarantined + 1] = id
        blocked[id] = {
          reason = payload.reason,
          rules = payload.rules,
          findings = payload.findings,
        }
      elseif result.ok and current.status == "qualifying" then
        local moved_ok, transitioned, transition_err = pcall(
          state.transition, root, id, "ready", { phase = "analyze" }
        )
        if not moved_ok then
          return nil, "cannot move " .. id .. " to ready: " .. tostring(transitioned)
        end
        if not transitioned then
          return nil, transition_err
        end
        ready[#ready + 1] = id
        -- Clear only after the move succeeded: a failed transition must not
        -- lose the marker that still explains why the task is blocked.
        if current.quarantine ~= nil then
          local cleared_ok, cleared, clear_err = pcall(state.clear_quarantine, root, id)
          if not cleared_ok then
            return nil, "cannot clear the quarantine of " .. id .. ": " .. tostring(cleared)
          end
          if not cleared then
            return nil, clear_err
          end
        end
      elseif current.quarantine ~= nil then
        -- A clean re-analysis of a task that is no longer qualifying still
        -- lifts a stale marker, without touching its status. A failure to clear
        -- is reported rather than swallowed: a stale quarantine must not
        -- survive silently.
        local cleared_ok, cleared, clear_err = pcall(state.clear_quarantine, root, id)
        if not cleared_ok then
          return nil, "cannot clear the quarantine of " .. id .. ": " .. tostring(cleared)
        end
        if not cleared then
          return nil, clear_err
        end
      end
    end
  end

  return {
    ok = true,
    verdict = result.verdict,
    findings = result.findings,
    tasks = ready,
    quarantined = quarantined,
    blocked = blocked,
    demoted = demoted,
    cached = cache_hit,
  }
end

return M
