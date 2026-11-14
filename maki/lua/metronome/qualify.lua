-- The qualifier: turn an intention into task sheets.
--
-- This module reads the repository, builds the prompt that asks a model for
-- tasks and questions, and turns the answer into state the pipeline can carry.
-- It owns no session and no state module of its own: the runner function and
-- the state module are injected, because `require` cannot yield in this host
-- and because a test must be able to run the whole thing without a token.
--
-- Everything returns (value, err) and never raises: a bad answer from a model
-- is a normal outcome, not a crash.

local M = {}

local fs = maki.fs
local json = maki.json

M.MAX_QUESTIONS_DEFAULT = 15

-- Directories that are never part of the work: dependency caches, build
-- output, and the git database. Walking them wastes the budget and buries the
-- files that matter.
local SKIP_DIRS = {
  [".git"] = true,
  ["node_modules"] = true,
  ["vendor"] = true,
  ["dist"] = true,
  ["build"] = true,
  [".next"] = true,
  ["target"] = true,
  [".venv"] = true,
  ["__pycache__"] = true,
}

-- Files worth showing first: they describe the project and its commands.
local PREFERRED = {
  "README.md",
  "README",
  "package.json",
  "pyproject.toml",
  "Cargo.toml",
  "go.mod",
  "AGENTS.md",
  "CLAUDE.md",
  "Makefile",
}

local ID_PATTERN = "^T%-%d%d%d%d%d%d%d%d%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]$"

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function entry_name(entry)
  return entry.name or entry[1]
end

local function entry_kind(entry)
  return entry.kind or entry[2]
end

local function basename(path)
  return path:match("([^/]+)$") or path
end

-- Repository context ---------------------------------------------------------

-- Walk the repository and return the file list plus a few excerpts.
--
-- The walk is deterministic (names sorted at every level) and capped, so a
-- huge repository cannot blow up the prompt. Reading is best-effort: a file
-- that disappears mid-walk is simply not excerpted.
function M.repo_context(repo, opts)
  opts = opts or {}
  if type(repo) ~= "string" or repo == "" then
    return nil, "no repository path"
  end

  local max_files = opts.max_files or 400
  local max_excerpts = opts.max_excerpts or 12
  local max_bytes = opts.max_bytes or 4096
  local max_depth = opts.max_depth or 6

  if not fs.dir(repo) then
    return nil, "cannot read repository: " .. repo
  end

  local files = {}
  local truncated = false

  local function walk(abs, rel, depth)
    local entries = fs.dir(abs)
    if not entries then
      return
    end
    local sorted = {}
    for _, entry in ipairs(entries) do
      local name, kind = entry_name(entry), entry_kind(entry)
      if type(name) == "string" and (kind == "file" or kind == "directory") then
        sorted[#sorted + 1] = { name = name, kind = kind }
      end
    end
    table.sort(sorted, function(a, b)
      return a.name < b.name
    end)

    for _, entry in ipairs(sorted) do
      if truncated then
        return
      end
      local child_rel = rel == "" and entry.name or (rel .. "/" .. entry.name)
      if entry.kind == "directory" then
        if not SKIP_DIRS[entry.name] and depth < max_depth then
          walk(fs.joinpath(abs, entry.name), child_rel, depth + 1)
        end
      elseif #files < max_files then
        files[#files + 1] = child_rel
      else
        -- One more file than the cap: the list is incomplete, and saying so
        -- is more useful than silently pretending it is whole.
        truncated = true
        return
      end
    end
  end

  walk(repo, "", 0)

  -- Excerpts: key files first, then whatever else fits.
  local excerpts = {}
  local seen = {}
  local function add(path)
    if #excerpts >= max_excerpts or seen[path] then
      return
    end
    local text = fs.read(fs.joinpath(repo, path))
    if type(text) ~= "string" then
      return
    end
    if #text > max_bytes then
      text = text:sub(1, max_bytes)
    end
    seen[path] = true
    excerpts[#excerpts + 1] = { path = path, text = text }
  end

  local by_basename = {}
  for _, path in ipairs(files) do
    local base = basename(path)
    if not by_basename[base] then
      by_basename[base] = path
    end
  end
  for _, name in ipairs(PREFERRED) do
    if by_basename[name] then
      add(by_basename[name])
    end
  end
  for _, path in ipairs(files) do
    add(path)
  end

  return {
    root = repo,
    files = files,
    excerpts = excerpts,
    truncated = truncated,
  }
end

-- Prompt ---------------------------------------------------------------------

function M.build_prompt(intent, context, opts)
  opts = opts or {}
  local max_questions = opts.max_questions or M.MAX_QUESTIONS_DEFAULT
  local out = {}

  local function line(s)
    out[#out + 1] = s
  end

  line("# Qualification")
  line("")
  line("## Intention (verbatim)")
  line("")
  line(intent or "")

  if context then
    line("")
    line("## Repository")
    line("")
    line("Root: " .. tostring(context.root))
    line("")
    line("Files:")
    for _, path in ipairs(context.files or {}) do
      line("- " .. path)
    end
    if context.truncated then
      line("(the file list is truncated)")
    end
    for _, excerpt in ipairs(context.excerpts or {}) do
      line("")
      line("### " .. excerpt.path)
      line("```")
      line(excerpt.text)
      line("```")
    end
  end

  line("")
  line("## Output contract")
  line("")
  line("Return exactly one JSON object with this shape:")
  line("")
  line('{"tasks":[{"title":"...","intent":"...","files":["..."],"checks":["..."],"acceptance":["..."],"depends_on":["..."],"questions":[{"id":"q1","text":"..."}]}]}')
  line("")
  line("Every task needs at least one file and at least one check.")
  line("Questions are only for decisions the repository cannot answer.")
  line(string.format("At most %d questions in total.", max_questions))

  return table.concat(out, "\n")
end

-- JSON extraction ------------------------------------------------------------

-- Find the first balanced {...} starting at `start`, ignoring braces inside
-- strings and honouring backslash escapes.
local function balanced_object(text, start)
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
    elseif c == "{" then
      depth = depth + 1
    elseif c == "}" then
      depth = depth - 1
      if depth == 0 then
        return text:sub(start, i)
      end
    end
  end
  return nil
end

function M.extract_json(text)
  if type(text) ~= "string" then
    return nil, "no text"
  end

  local slice = text:match("```[^\n]*\n(.-)```")
  if not slice then
    slice = text:match("```(.-)```")
  end
  if not slice then
    local start = text:find("{", 1, true)
    if not start then
      return nil, "invalid JSON: no JSON object found"
    end
    slice = balanced_object(text, start)
    if not slice then
      return nil, "invalid JSON: unbalanced object"
    end
  end

  local decoded, derr = json.decode(slice)
  if decoded == nil then
    return nil, "invalid JSON: " .. tostring(derr)
  end
  return decoded
end

-- Schema validation ----------------------------------------------------------

-- The repository root, derived from this module's own source path. The module
-- is loaded with loadstring("@<path>"), so debug.getinfo gives the real file
-- and the root is what precedes /maki/lua/metronome/qualify.lua. Falling back
-- to the cwd keeps a host that hides debug working.
local function repo_root()
  local ok, info = pcall(debug.getinfo, 1, "S")
  if ok and type(info) == "table" and type(info.source) == "string" then
    local source = info.source
    if source:sub(1, 1) == "@" then
      source = source:sub(2)
    end
    local root = source:gsub("/maki/lua/metronome/qualify%.lua$", "")
    if root ~= source and root ~= "" then
      return root
    end
  end
  return nil
end

local function first_line(text)
  for line in (text or ""):gmatch("[^\n]+") do
    local trimmed = line:gsub("%s+$", "")
    if trimmed ~= "" then
      return trimmed
    end
  end
  return ""
end

-- The object task.schema.json governs: the qualifier's own fields, with
-- `acceptance` removed (the schema forbids it) and an id the schema accepts.
-- A task that has not been applied yet has no id, so a placeholder that
-- matches the pattern stands in: the validator must judge the shape, not the
-- identity.
function M.task_projection(task, opts)
  opts = opts or {}
  task = type(task) == "table" and task or {}

  local id = opts.placeholder_id or "T-19700101-0000"
  if type(task.id) == "string" and task.id:match(ID_PATTERN) then
    id = task.id
  end

  local projection = {
    id = id,
    title = task.title or "",
    intent = task.intent or "",
    status = task.status or "draft",
    files = task.files or {},
    checks = task.checks or {},
  }
  -- maki.json.encode writes an empty Lua table as `{}`, which the schema
  -- rejects where an array is required. Omit empty arrays instead: absence is
  -- legal, an object where an array belongs is not.
  if type(task.depends_on) == "table" and #task.depends_on > 0 then
    projection.depends_on = task.depends_on
  end
  if type(task.questions) == "table" and #task.questions > 0 then
    projection.questions = task.questions
  end
  return projection
end

local validate_counter = 0

-- Validate a projection against the real schema.
--
-- `opts.validator` is a test seam: when it is a function it decides, and no
-- process is spawned. Otherwise tools/validate-task.py is the authority, run
-- through the same jobstart path git.lua uses so it works from a task, a tool
-- handler, and a test alike.
function M.validate_projection(projection, opts)
  opts = opts or {}

  if type(opts.validator) == "function" then
    return opts.validator(projection)
  end

  local root = repo_root()
  local tools_dir = opts.tools_dir
  if not tools_dir then
    tools_dir = root and fs.joinpath(root, "tools") or fs.joinpath(maki.uv.cwd(), "tools")
  end

  local tmp_dir = opts.tmp_dir or fs.joinpath(maki.env.state_dir(), "metronome-validate")
  local made, mkerr = fs.mkdir(tmp_dir, { parents = true })
  if not made then
    return nil, "cannot create validator directory: " .. tostring(mkerr)
  end

  validate_counter = validate_counter + 1
  local id = type(projection) == "table" and tostring(projection.id) or "task"
  local path = fs.joinpath(tmp_dir, string.format("%s-%d.json", id:gsub("[^%w%-%.]", "_"), validate_counter))

  local ok_enc, encoded = pcall(json.encode, projection)
  if not ok_enc or type(encoded) ~= "string" then
    return nil, "cannot encode task projection: " .. tostring(encoded)
  end
  local wrote, werr = fs.write(path, encoded)
  if not wrote then
    return nil, "cannot write task projection: " .. tostring(werr)
  end

  local args = { "python3", fs.joinpath(tools_dir, "validate-task.py"), path }
  local job_opts = { tail = 200 }
  -- jobstart raises (rather than returning nil) when there is no active task
  -- to own the job, which happens at plugin top level. Retrying with a plugin
  -- scope keeps the same code usable from a tool handler and from a test.
  local ok_start, job, serr = pcall(maki.fn.jobstart, args, job_opts)
  if not ok_start then
    serr = job
    job = nil
  end
  if not job and tostring(serr):find("no active task", 1, true) then
    job_opts.scope = "plugin"
    local ok_retry, retry_job, retry_err = pcall(maki.fn.jobstart, args, job_opts)
    if ok_retry then
      job, serr = retry_job, retry_err
    else
      job, serr = nil, retry_job
    end
  end
  if not job then
    fs.rm(path)
    return nil, "task validator did not finish: " .. tostring(serr)
  end

  local result, jerr = maki.fn.jobwait(job, opts.timeout_ms or 30000)
  if not result then
    fs.rm(path)
    return nil, "task validator did not finish: " .. tostring(jerr)
  end

  fs.rm(path)

  if result.exit_code == 0 then
    return true, nil
  end

  local detail = first_line(result.stderr)
  if detail == "" then
    detail = first_line(result.stdout)
  end
  return nil, string.format("task %s violates task.schema.json: %s", id, detail)
end

function M.validate_task(task, opts)
  return M.validate_projection(M.task_projection(task, opts), opts)
end

-- Normalization --------------------------------------------------------------

local function non_empty_strings(value)
  if type(value) ~= "table" or #value == 0 then
    return nil
  end
  local out = {}
  for i, item in ipairs(value) do
    if type(item) ~= "string" or trim(item) == "" then
      return nil
    end
    out[i] = trim(item)
  end
  return out
end

local function optional_strings(value)
  if value == nil then
    return {}
  end
  if type(value) ~= "table" then
    return nil
  end
  local out = {}
  for i, item in ipairs(value) do
    if type(item) ~= "string" or trim(item) == "" then
      return nil
    end
    out[i] = trim(item)
  end
  return out
end

-- Normalize one answer into the shape state.lua stores.
--
-- The cap is applied once, over the whole answer, in task order then
-- top-level order: a model that ignores the limit must not be able to flood
-- the user with questions.
function M.normalize(parsed, opts)
  opts = opts or {}
  if type(parsed) ~= "table" then
    return nil, "no parsed tasks"
  end
  local raw_tasks = parsed.tasks
  if type(raw_tasks) ~= "table" or #raw_tasks == 0 then
    return nil, "no tasks"
  end

  local max_questions = opts.max_questions or M.MAX_QUESTIONS_DEFAULT
  local counter = 0

  -- Validation is opt-in for a pure normalize (the structural tests stay
  -- fast), and on when a validator is injected or `validate` is true.
  -- `validate = false` is the explicit opt-out, even with a validator.
  local should_validate = opts.validate == true
    or (type(opts.validator) == "function" and opts.validate ~= false)

  local function normalize_questions(list, index)
    local out = {}
    if list == nil then
      return out
    end
    if type(list) ~= "table" then
      return nil, string.format("task %d: questions must be an array", index)
    end
    for j, question in ipairs(list) do
      counter = counter + 1
      local text = type(question) == "table" and question.text or nil
      if type(text) ~= "string" or trim(text) == "" then
        return nil, string.format("task %d: question %d has no text", index, j)
      end
      local id = type(question) == "table" and question.id or nil
      if type(id) ~= "string" or trim(id) == "" then
        id = "q" .. counter
      end
      out[#out + 1] = { id = trim(id), text = trim(text) }
    end
    return out
  end

  local tasks = {}
  for i, raw in ipairs(raw_tasks) do
    if type(raw) ~= "table" then
      return nil, string.format("task %d: not an object", i)
    end

    local title = type(raw.title) == "string" and trim(raw.title) or ""
    if title == "" then
      return nil, string.format("task %d: title is empty", i)
    end
    if #title > 200 then
      return nil, string.format("task %d: title is longer than 200 chars", i)
    end

    local files = non_empty_strings(raw.files)
    if not files then
      return nil, string.format("task %d: files must be a non-empty array", i)
    end
    local checks = non_empty_strings(raw.checks)
    if not checks then
      return nil, string.format("task %d: checks must be a non-empty array", i)
    end

    local acceptance = optional_strings(raw.acceptance)
    if not acceptance then
      return nil, string.format("task %d: acceptance must be an array of non-empty strings", i)
    end
    local depends_on = optional_strings(raw.depends_on)
    if not depends_on then
      return nil, string.format("task %d: depends_on must be an array of non-empty strings", i)
    end

    local questions, qerr = normalize_questions(raw.questions, i)
    if not questions then
      return nil, qerr
    end

    local intent = raw.intent
    if type(intent) ~= "string" then
      intent = opts.intention or ""
    end

    local task = {
      title = title,
      intent = intent,
      files = files,
      checks = checks,
      acceptance = acceptance,
      depends_on = depends_on,
      questions = questions,
    }
    if type(raw.id) == "string" and raw.id:match(ID_PATTERN) then
      task.id = raw.id
    end
    tasks[i] = task

    -- A schema refusal is the same kind of outcome as broken JSON: it makes
    -- the answer unusable and triggers the repair pass in M.run.
    if should_validate then
      local valid, verr = M.validate_task(task, opts)
      if not valid then
        return nil, string.format("task %d: %s", i, tostring(verr))
      end
    end
  end

  -- Top-level questions belong to the first task: the answer is one
  -- qualification, and the user answers it in one round.
  local top_questions = {}
  if parsed.questions ~= nil then
    if type(parsed.questions) ~= "table" then
      return nil, "questions must be an array"
    end
    for j, question in ipairs(parsed.questions) do
      counter = counter + 1
      local text = type(question) == "table" and question.text or nil
      if type(text) ~= "string" or trim(text) == "" then
        return nil, string.format("top-level question %d has no text", j)
      end
      local id = type(question) == "table" and question.id or nil
      if type(id) ~= "string" or trim(id) == "" then
        id = "q" .. counter
      end
      top_questions[#top_questions + 1] = { id = trim(id), text = trim(text) }
    end
  end

  -- Cap in task order, then top-level order.
  local kept = {}
  local total = 0
  for _, task in ipairs(tasks) do
    local own = task.questions
    task.questions = {}
    for _, question in ipairs(own) do
      total = total + 1
      if #kept < max_questions then
        kept[#kept + 1] = question
        task.questions[#task.questions + 1] = question
      end
    end
  end
  for _, question in ipairs(top_questions) do
    total = total + 1
    if #kept < max_questions then
      kept[#kept + 1] = question
      tasks[1].questions[#tasks[1].questions + 1] = question
    end
  end

  return {
    tasks = tasks,
    questions = kept,
    truncated_questions = total - #kept,
  }
end

function M.parse(text, opts)
  local parsed, err = M.extract_json(text)
  if not parsed then
    return nil, err
  end
  return M.normalize(parsed, opts)
end

function M.repair_prompt(intent, raw, err)
  local previous = type(raw) == "string" and raw or tostring(raw)
  if #previous > 8000 then
    previous = previous:sub(1, 8000)
  end
  return table.concat({
    "Your previous answer could not be used.",
    "",
    "Error: " .. tostring(err),
    "",
    "Return ONLY a corrected JSON object matching the contract.",
    "",
    "## Intention (verbatim)",
    "",
    intent or "",
    "",
    "## Previous answer",
    "",
    "```",
    previous,
    "```",
  }, "\n")
end

-- Run ------------------------------------------------------------------------

-- Qualify one intention.
--
-- The runner is injected and called once per attempt. A parse failure is
-- repaired once by default: one bad answer is a model hiccup, two in a row is
-- a prompt or contract problem, and looping on it only burns money.
function M.run(opts)
  if type(opts) ~= "table" then
    return { ok = false, error = "qualify.run needs an options table", attempts = 0, cost = 0 }
  end
  local intention = opts.intention
  if type(intention) ~= "string" or trim(intention) == "" then
    return { ok = false, error = "qualify.run needs an intention", attempts = 0, cost = 0 }
  end
  if type(opts.runner) ~= "function" then
    return { ok = false, error = "qualify.run needs a runner function", attempts = 0, cost = 0 }
  end
  local session_opts = opts.session_opts
  if type(session_opts) ~= "table" then
    return { ok = false, error = "qualify.run needs session_opts", attempts = 0, cost = 0 }
  end

  local max_questions = opts.max_questions or M.MAX_QUESTIONS_DEFAULT
  local max_repairs = opts.max_repairs or 1

  local context = nil
  if type(opts.repo) == "string" and opts.repo ~= "" then
    local cerr
    context, cerr = M.repo_context(opts.repo, opts)
    if not context then
      return { ok = false, error = cerr, attempts = 0, cost = 0 }
    end
  end

  local prompt = M.build_prompt(intention, context, { max_questions = max_questions })
  local total_cost = 0
  local attempt = 0
  local repairs = 0
  local last_text = nil

  while true do
    attempt = attempt + 1
    local result = opts.runner({
      role = "qualifier",
      task_id = opts.task_id or "qualify",
      phase = "qualify",
      prompt = prompt,
      system = session_opts.system,
      model_spec = session_opts.model_spec,
      thinking = session_opts.thinking,
      tools = session_opts.tools,
      state_root = opts.state_root,
      ctx = opts.ctx,
      max_attempts = opts.max_attempts,
      deadline_secs = opts.deadline_secs,
    })
    if type(result) ~= "table" then
      result = { ok = false, error = "runner returned no result" }
    end
    total_cost = total_cost + (result.cost or 0)

    if not result.ok then
      return {
        ok = false,
        error = result.error or "runner failed",
        attempts = attempt,
        cost = total_cost,
      }
    end

    last_text = result.text
    local parsed, perr = M.parse(result.text, {
      max_questions = max_questions,
      intention = intention,
      validator = opts.validator,
      -- On by default: `opts.validate = false` is the explicit opt-out.
      validate = opts.validate ~= false,
      tools_dir = opts.tools_dir,
      tmp_dir = opts.tmp_dir,
      timeout_ms = opts.timeout_ms,
    })
    if parsed then
      return {
        ok = true,
        tasks = parsed.tasks,
        questions = parsed.questions,
        truncated_questions = parsed.truncated_questions,
        attempts = attempt,
        cost = total_cost,
        text = result.text,
      }
    end

    if repairs >= max_repairs then
      return {
        ok = false,
        error = "qualifier output invalid after repair: " .. tostring(perr),
        attempts = attempt,
        cost = total_cost,
        raw = last_text,
      }
    end
    repairs = repairs + 1
    prompt = M.repair_prompt(intention, result.text, perr)
  end
end

-- Identity -------------------------------------------------------------------

function M.next_id(state, date)
  date = date or os.date("!%Y%m%d")
  local tasks = type(state) == "table" and type(state.tasks) == "table" and state.tasks or {}
  local max = 0
  for id in pairs(tasks) do
    if type(id) == "string" then
      local day, hex = id:match("^T%-(%d%d%d%d%d%d%d%d)%-([0-9a-f][0-9a-f][0-9a-f][0-9a-f])$")
      if day == date then
        local n = tonumber(hex, 16)
        if n and n > max then
          max = n
        end
      end
    end
  end
  return string.format("T-%s-%04x", date, max + 1)
end

-- Sheets ---------------------------------------------------------------------

function M.sheet_markdown(task)
  local out = {}
  local function line(s)
    out[#out + 1] = s
  end

  line("# " .. tostring(task.title or ""))
  line("")
  line("- ID: " .. tostring(task.id or ""))
  line("- Intent: " .. tostring(task.intent or ""))
  line("- Files: " .. table.concat(task.files or {}, ", "))
  line("- Checks: " .. table.concat(task.checks or {}, ", "))
  if task.depends_on and #task.depends_on > 0 then
    line("- Depends on: " .. table.concat(task.depends_on, ", "))
  end
  line("")
  line("## Acceptance")
  for _, item in ipairs(task.acceptance or {}) do
    line("- " .. item)
  end
  line("")
  line("## Questions")
  for _, question in ipairs(task.questions or {}) do
    line("- " .. tostring(question.id) .. ": " .. tostring(question.text))
  end

  return table.concat(out, "\n") .. "\n"
end

-- Apply ----------------------------------------------------------------------

-- Write a successful qualification into the state store.
--
-- Each task is created as a draft, moved through qualifying, and then parked
-- where it belongs: awaiting answers if it asked something, ready otherwise.
-- The sheet is written last, so a task never points at a sheet that is not
-- there yet.
function M.apply(state, root, result, opts)
  opts = opts or {}
  if type(result) ~= "table" or result.ok ~= true then
    return nil, "cannot apply an unsuccessful qualification"
  end
  if type(state) ~= "table" then
    return nil, "apply needs a state module"
  end

  local tasks_dir = opts.tasks_dir or fs.joinpath(root, "tasks")
  local made, mkerr = fs.mkdir(tasks_dir, { parents = true })
  if not made then
    return nil, "cannot create tasks directory: " .. tostring(mkerr)
  end

  local created = {}
  local current = state.load(root)

  for i, task in ipairs(result.tasks or {}) do
    local id = task.id
    if not id and type(opts.id_factory) == "function" then
      id = opts.id_factory(i)
    end
    if not id then
      id = M.next_id(current, opts.date)
    end
    if type(id) ~= "string" or id == "" then
      return nil, string.format("task %d: cannot assign an id", i)
    end
    if current.tasks[id] then
      return nil, "task already exists: " .. id
    end

    local questions = task.questions or {}
    -- maki.json.encode writes an empty Lua table as `{}`, which the task
    -- schema rejects where an array is required. Omit empty arrays instead:
    -- absence is legal, an object where an array belongs is not.
    local record = {
      id = id,
      title = task.title,
      intent = task.intent or "",
      files = task.files,
      checks = task.checks,
      status = "draft",
    }
    if #(task.depends_on or {}) > 0 then
      record.depends_on = task.depends_on
    end
    if #questions > 0 then
      record.questions = questions
    end
    local created_task, cerr = state.create(root, record)
    if not created_task then
      return nil, cerr
    end

    local moved, terr = state.transition(root, id, "qualifying", { phase = "qualify" })
    if not moved then
      return nil, terr
    end

    local target = #questions > 0 and "awaiting_answers" or "ready"
    local settled, serr = state.transition(root, id, target, { phase = "qualify" })
    if not settled then
      return nil, serr
    end

    local sheet = M.sheet_markdown({
      id = id,
      title = task.title,
      intent = task.intent or "",
      files = task.files,
      checks = task.checks,
      depends_on = task.depends_on or {},
      acceptance = task.acceptance or {},
      questions = questions,
    })
    local wrote, werr = fs.write(fs.joinpath(tasks_dir, id .. ".md"), sheet)
    if not wrote then
      return nil, "cannot write sheet for " .. id .. ": " .. tostring(werr)
    end

    created[#created + 1] = settled
    current = state.load(root)
  end

  return {
    tasks = created,
    questions = result.questions or {},
    truncated_questions = result.truncated_questions or 0,
  }
end

return M
