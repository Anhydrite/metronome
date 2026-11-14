-- The analyzer: check the task sheets against each other before `ready`.
--
-- Qualification produces one sheet at a time; this module is what looks at
-- the set. It finds the contradictions, duplicates and gaps a human would
-- catch by reading every sheet side by side: two tasks with the same title,
-- two tasks that would edit the same file without an ordering, a dependency
-- that names nothing, a cycle, a task with no files or no checks.
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
-- owns them, and reporting them twice would double the noise.
local function find_cycles(ids, dep_map, id_set)
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
      if dep ~= node and id_set[dep] then
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
  end

  -- duplicate_title: two sheets a human would read as the same task.
  for i = 1, #ids do
    for j = i + 1, #ids do
      if titles[i] ~= "" and titles[i] == titles[j] then
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

  -- duplicate_files: two sheets that would change exactly the same files.
  for i = 1, #ids do
    for j = i + 1, #ids do
      if keys[i] ~= "" and keys[i] == keys[j] then
        findings[#findings + 1] = {
          severity = "blocking",
          rule = "duplicate_files",
          message = string.format(
            "tasks %s and %s declare the same files: %s", ids[i], ids[j], keys[i]
          ),
          tasks = { ids[i], ids[j] },
        }
      end
    end
  end

  -- file_overlap: two sheets that touch a shared file with no ordering
  -- between them. An explicit dependency either way is the ordering, so the
  -- scheduler can run them in sequence and the overlap is not a finding.
  local reaches = make_reacher(dep_map)
  for i = 1, #ids do
    for j = i + 1, #ids do
      if keys[i] ~= "" and keys[j] ~= "" and keys[i] ~= keys[j] then
        local shared = intersection(filesets[i], filesets[j])
        if #shared > 0
          and not reaches(ids[i], ids[j])
          and not reaches(ids[j], ids[i]) then
          findings[#findings + 1] = {
            severity = "blocking",
            rule = "file_overlap",
            message = string.format(
              "tasks %s and %s both touch %s and neither depends on the other",
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
              "task %s depends on unknown task %s", ids[i], dep
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

  -- dependency_cycle: a loop among two or more tasks.
  for _, cycle in ipairs(find_cycles(ids, dep_map, id_set)) do
    local path = table.concat(cycle, " -> ") .. " -> " .. cycle[1]
    findings[#findings + 1] = {
      severity = "blocking",
      rule = "dependency_cycle",
      message = "dependency cycle: " .. path,
      tasks = cycle,
    }
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
  if type(opts.repo) == "string" and opts.repo ~= "" then
    for i = 1, #ids do
      for _, file in ipairs(filesets[i]) do
        if not exists_under(opts.repo, file) then
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

-- Gate -----------------------------------------------------------------------

-- The `qualifying -> ready` gate.
--
-- Select the sheets that are waiting (or the ones the caller names), analyze
-- them, write the report, and only then move the ones still qualifying to
-- ready. A blocking finding moves nothing: the whole batch stays where it is
-- so the user can fix the sheets and re-run.
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

  local selected = {}
  if type(opts.tasks) == "table" then
    for i, task in ipairs(opts.tasks) do
      selected[i] = task
    end
  else
    local ids = {}
    for id, task in pairs(all) do
      if type(task) == "table" and task.status == "qualifying" then
        ids[#ids + 1] = id
      end
    end
    table.sort(ids)
    for i, id in ipairs(ids) do
      selected[i] = all[id]
    end
  end

  if #selected == 0 then
    return { ok = true, verdict = "ok", findings = {}, tasks = {} }
  end

  local known_ids = {}
  for id in pairs(all) do
    known_ids[id] = true
  end

  local result = M.run({
    tasks = selected,
    intention = opts.intention,
    known_ids = known_ids,
    repo = opts.repo,
    runner = opts.runner,
    session_opts = opts.session_opts,
    semantic = opts.semantic,
    tasks_dir = opts.tasks_dir or fs.joinpath(root, "tasks"),
    state_root = opts.state_root,
    ctx = opts.ctx,
    now = opts.now,
  })

  local _, report_err = M.write_report(root, result, opts)
  if report_err then
    return nil, report_err
  end

  local moved = {}
  if result.ok then
    local fresh = state.load(root)
    local current_tasks = type(fresh) == "table" and type(fresh.tasks) == "table" and fresh.tasks or {}
    for _, task in ipairs(selected) do
      local id = task_id(task, 1)
      local current = current_tasks[id]
      if type(current) == "table" and current.status == "qualifying" then
        local moved_ok, transitioned, transition_err = pcall(
          state.transition, root, id, "ready", { phase = "analyze" }
        )
        if not moved_ok then
          return nil, "cannot move " .. id .. " to ready: " .. tostring(transitioned)
        end
        if not transitioned then
          return nil, transition_err
        end
        moved[#moved + 1] = id
      end
    end
  end

  return {
    ok = result.ok,
    verdict = result.verdict,
    findings = result.findings,
    tasks = moved,
  }
end

return M
