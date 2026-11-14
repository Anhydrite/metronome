-- Calibration: turn what the repository already says into review rules.
--
-- The reviewer reads `review-rules.md`; this module writes it. The rules come
-- from what is on disk — AGENTS.md, linter configs, the commands the project
-- actually has, its shape, its tests, its CI — plus the votes recorded in
-- `review-feedback.jsonl`. Nothing here calls a model: calibration is a
-- projection of facts, not an opinion.
--
-- Everything returns (value, err) and never raises. A missing file is normal
-- (a young repository has no feedback yet), and a torn JSONL line is normal
-- too (a killed writer leaves one), so both are data, not crashes.

local M = {}

local fs = maki.fs
local json = maki.json

-- Config files that mean "this repository has a linter". The list is fixed and
-- sorted at the end, so the output depends on the repository, not on the host.
local LINTER_FILES = {
  ".eslintrc",
  ".eslintrc.json",
  ".eslintrc.js",
  "eslint.config.js",
  "eslint.config.mjs",
  ".prettierrc",
  ".ruff.toml",
  "ruff.toml",
  "pyproject.toml",
  ".golangci.yml",
  ".golangci.yaml",
  ".rubocop.yml",
  ".stylelintrc",
  "biome.json",
  "deno.json",
  "tsconfig.json",
}

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

-- The same defaults config.lua applies to review.protected_paths. Duplicated
-- on purpose: this module must not require another one.
local DEFAULT_PROTECTED = { "review-rules.md", "AGENTS.md", ".metronome/", "deploy.md" }

local MAX_STRUCTURE = 30
local MAX_TESTS = 200
local MAX_TEST_DEPTH = 6
local MAX_RULES_DEFAULT = 20000
local MAX_COMMENTS = 3
local MAX_COMMENT_CHARS = 200

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

local function sorted_names(entries)
  local names = {}
  for _, entry in ipairs(entries or {}) do
    local name, kind = entry_name(entry), entry_kind(entry)
    if type(name) == "string" and (kind == "file" or kind == "directory") then
      names[#names + 1] = { name = name, kind = kind }
    end
  end
  table.sort(names, function(a, b)
    return a.name < b.name
  end)
  return names
end

-- Read a file relative to the repository. Returns nil when it is absent or
-- unreadable: the caller treats both the same way.
local function read_rel(repo, rel)
  local text = fs.read(fs.joinpath(repo, rel))
  if type(text) ~= "string" then
    return nil
  end
  return text
end

local function is_dir(path)
  return fs.dir(path) ~= nil
end

-- Detection ------------------------------------------------------------------

local function detect_agents_md(repo, max_rules)
  local text = read_rel(repo, "AGENTS.md")
  if not text then
    text = read_rel(repo, "CLAUDE.md")
  end
  if not text then
    return nil
  end
  if max_rules and #text > max_rules then
    text = text:sub(1, max_rules)
  end
  return text
end

local function detect_linters(repo)
  local found = {}
  for _, name in ipairs(LINTER_FILES) do
    if read_rel(repo, name) ~= nil then
      found[#found + 1] = name
    end
  end
  table.sort(found)
  return found
end

local function add_command(set, command)
  set[command] = true
end

local function detect_commands(repo)
  local set = {}

  local pkg_text = read_rel(repo, "package.json")
  if pkg_text then
    local decoded = nil
    local ok, result = pcall(json.decode, pkg_text)
    if ok then
      decoded = result
    end
    if type(decoded) == "table" and type(decoded.scripts) == "table" then
      local scripts = decoded.scripts
      if scripts.lint ~= nil then
        add_command(set, "npm run lint")
      end
      if scripts.test ~= nil then
        add_command(set, "npm test")
      end
      if scripts.typecheck ~= nil then
        add_command(set, "npm run typecheck")
      end
    end
  end

  local pyproject = read_rel(repo, "pyproject.toml") ~= nil
  local ruff = read_rel(repo, "ruff.toml") ~= nil
  if pyproject or ruff then
    add_command(set, "ruff check .")
  end
  if pyproject then
    add_command(set, "pytest")
  end

  if read_rel(repo, "go.mod") ~= nil then
    add_command(set, "go vet ./...")
    add_command(set, "go test ./...")
  end

  if read_rel(repo, "Cargo.toml") ~= nil then
    add_command(set, "cargo clippy")
    add_command(set, "cargo test")
  end

  local makefile = read_rel(repo, "Makefile")
  if makefile then
    for line in (makefile .. "\n"):gmatch("([^\n]*)\n") do
      if line:match("^lint%s*:") then
        add_command(set, "make lint")
      end
      if line:match("^test%s*:") then
        add_command(set, "make test")
      end
    end
  end

  local commands = {}
  for command in pairs(set) do
    commands[#commands + 1] = command
  end
  table.sort(commands)
  return commands
end

local function detect_structure(repo)
  local dirs = {}
  for _, entry in ipairs(sorted_names(fs.dir(repo))) do
    if entry.kind == "directory" and not SKIP_DIRS[entry.name] then
      dirs[#dirs + 1] = entry.name
      if #dirs >= MAX_STRUCTURE then
        break
      end
    end
  end
  return dirs
end

local function is_test_name(name)
  if name:find("_test%.") or name:find("%.test%.") or name:find("%.spec%.") then
    return true
  end
  if name:match("^test_.*%.py$") then
    return true
  end
  if name:match("_spec%.rb$") then
    return true
  end
  return false
end

-- Walk the repository deterministically (names sorted at every level), bounded
-- in depth and count. A file that disappears mid-walk is simply not listed.
local function detect_tests(repo)
  local found = {}

  local function walk(abs, rel, depth)
    if #found >= MAX_TESTS then
      return
    end
    local entries = sorted_names(fs.dir(abs))
    for _, entry in ipairs(entries) do
      if #found >= MAX_TESTS then
        return
      end
      local child_rel = rel == "" and entry.name or (rel .. "/" .. entry.name)
      if entry.kind == "directory" then
        if not SKIP_DIRS[entry.name] and depth < MAX_TEST_DEPTH then
          walk(fs.joinpath(abs, entry.name), child_rel, depth + 1)
        end
      elseif is_test_name(entry.name) then
        found[#found + 1] = child_rel
      end
    end
  end

  walk(repo, "", 0)
  table.sort(found)
  return found
end

local function detect_ci(repo)
  local found = {}
  local dir = fs.joinpath(repo, ".github", "workflows")
  for _, entry in ipairs(sorted_names(fs.dir(dir))) do
    if entry.kind == "file" and (entry.name:match("%.yml$") or entry.name:match("%.yaml$")) then
      found[#found + 1] = ".github/workflows/" .. entry.name
    end
  end
  table.sort(found)
  return found
end

function M.detect(repo, opts)
  opts = opts or {}
  if type(repo) ~= "string" or repo == "" or not is_dir(repo) then
    return nil, "cannot read repository: " .. tostring(repo)
  end

  local max_rules = opts.max_rules or MAX_RULES_DEFAULT

  return {
    agents_md = detect_agents_md(repo, max_rules),
    linters = detect_linters(repo),
    commands = detect_commands(repo),
    structure = detect_structure(repo),
    tests = detect_tests(repo),
    ci = detect_ci(repo),
  }, nil
end

-- Feedback -------------------------------------------------------------------

local function empty_feedback()
  return { entries = {}, by_rule = {}, skipped = 0, total = 0 }
end

-- Keep only the fields the contract names, and only when they have the right
-- type. Unknown keys are ignored: the file is written by another process and
-- may grow fields this version does not know yet.
local function valid_entry(obj)
  if type(obj) ~= "table" then
    return nil
  end
  local vote = obj.vote
  if vote ~= "up" and vote ~= "down" then
    return nil
  end

  local entry = { vote = vote }
  if type(obj.finding_id) == "string" then
    entry.finding_id = obj.finding_id
  end
  if type(obj.rule) == "string" and trim(obj.rule) ~= "" then
    entry.rule = trim(obj.rule)
  end
  if type(obj.severity) == "string" then
    entry.severity = obj.severity
  end
  if type(obj.path) == "string" then
    entry.path = obj.path
  end
  if type(obj.line) == "number" and obj.line >= 1 and obj.line == math.floor(obj.line) then
    entry.line = obj.line
  end
  if type(obj.comment) == "string" then
    entry.comment = obj.comment
  end
  if type(obj.at) == "string" then
    entry.at = obj.at
  end
  return entry
end

function M.feedback(path, opts)
  opts = opts or {}
  local result = empty_feedback()
  if type(path) ~= "string" or path == "" then
    return result, nil
  end

  local text = fs.read(path)
  if type(text) ~= "string" then
    -- No feedback yet is a normal state, not an error.
    return result, nil
  end

  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if trim(line) == "" then
      -- Blank lines carry no information: ignored, not counted as corrupt.
    else
      local decoded = nil
      local ok, value = pcall(json.decode, line)
      if ok then
        decoded = value
      end
      local entry = valid_entry(decoded)
      if not entry then
        result.skipped = result.skipped + 1
      else
        result.entries[#result.entries + 1] = entry

        local key = entry.rule or "(unruled)"
        local bucket = result.by_rule[key]
        if not bucket then
          bucket = { up = 0, down = 0, score = 0, comments = {} }
          result.by_rule[key] = bucket
        end
        if entry.vote == "up" then
          bucket.up = bucket.up + 1
        else
          bucket.down = bucket.down + 1
        end
        bucket.score = bucket.up - bucket.down
        if entry.comment then
          bucket.comments[#bucket.comments + 1] = entry.comment
        end
      end
    end
  end

  result.total = #result.entries
  return result, nil
end

-- Rendering ------------------------------------------------------------------

local function calibration_flag(score)
  if score > 0 then
    return "keep flagging"
  elseif score < 0 then
    return "de-emphasize"
  end
  return "neutral"
end

local function one_line(comment)
  local text = comment:gsub("[\r\n]+", " ")
  if #text > MAX_COMMENT_CHARS then
    text = text:sub(1, MAX_COMMENT_CHARS)
  end
  return text
end

function M.render(detected, feedback, opts)
  opts = opts or {}
  detected = type(detected) == "table" and detected or {}
  feedback = type(feedback) == "table" and feedback or {}

  local protected = opts.protected_paths
  if type(protected) ~= "table" or #protected == 0 then
    protected = DEFAULT_PROTECTED
  end

  local out = {}
  local function line(s)
    out[#out + 1] = s
  end

  local function bullets(list, empty)
    if type(list) ~= "table" or #list == 0 then
      line(empty)
      return
    end
    for _, item in ipairs(list) do
      line("- " .. tostring(item))
    end
  end

  line("# Review rules")
  line("")
  line("Generated from this repository: its own rules, linters, commands, shape, tests and CI, plus review calibration.")

  line("")
  line("## Project rules")
  line("")
  local agents = detected.agents_md
  if type(agents) == "string" and agents ~= "" then
    line(agents)
  else
    line("No AGENTS.md found.")
  end

  line("")
  line("## Linters")
  line("")
  bullets(detected.linters, "None detected.")

  line("")
  line("## Commands")
  line("")
  bullets(detected.commands, "None detected.")

  line("")
  line("## Structure")
  line("")
  bullets(detected.structure, "None detected.")

  line("")
  line("## Tests")
  line("")
  bullets(detected.tests, "None detected.")

  line("")
  line("## CI")
  line("")
  bullets(detected.ci, "None detected.")

  line("")
  line("## Protected paths")
  line("")
  line("Touching any of these paths is always blocking.")
  line("")
  bullets(protected, "None configured.")

  if (feedback.total or 0) > 0 then
    line("")
    line("## Calibration feedback")
    line("")

    local rules = {}
    for rule in pairs(feedback.by_rule or {}) do
      rules[#rules + 1] = rule
    end
    table.sort(rules, function(a, b)
      local sa = (feedback.by_rule[a] or {}).score or 0
      local sb = (feedback.by_rule[b] or {}).score or 0
      if sa ~= sb then
        return sa < sb
      end
      return a < b
    end)

    for _, rule in ipairs(rules) do
      local bucket = feedback.by_rule[rule] or {}
      local up = bucket.up or 0
      local down = bucket.down or 0
      local score = bucket.score or (up - down)
      line(string.format("- %s: up=%d down=%d — %s", rule, up, down, calibration_flag(score)))
      local comments = bucket.comments or {}
      for i = 1, math.min(#comments, MAX_COMMENTS) do
        line('  - "' .. one_line(comments[i]) .. '"')
      end
    end
  end

  return table.concat(out, "\n") .. "\n"
end

-- Generate / write / run -----------------------------------------------------

function M.generate(repo, opts)
  opts = opts or {}
  local detected, derr = M.detect(repo, opts)
  if not detected then
    return nil, derr
  end

  local feedback_path = opts.feedback_path
  if type(feedback_path) ~= "string" or feedback_path == "" then
    feedback_path = fs.joinpath(repo, "review-feedback.jsonl")
  end
  local feedback = M.feedback(feedback_path, opts)

  return {
    markdown = M.render(detected, feedback, opts),
    detected = detected,
    feedback = feedback,
  }, nil
end

local function output_path(repo, opts)
  return opts.output or fs.joinpath(repo, "review-rules.md")
end

local function write_generated(output, generated, opts)
  if opts.dry_run then
    return output, nil
  end
  local wrote, werr = fs.write(output, generated.markdown)
  if not wrote then
    return nil, "cannot write " .. tostring(output) .. ": " .. tostring(werr)
  end
  return output, nil
end

function M.write(repo, opts)
  opts = opts or {}
  local generated, gerr = M.generate(repo, opts)
  if not generated then
    return nil, gerr
  end
  return write_generated(output_path(repo, opts), generated, opts)
end

function M.run(opts)
  if type(opts) ~= "table" then
    return { ok = false, error = "calibrate.run needs an options table" }
  end
  local repo = opts.repo
  if type(repo) ~= "string" or repo == "" then
    return { ok = false, error = "calibrate.run needs a repository" }
  end

  local generated, gerr = M.generate(repo, opts)
  if not generated then
    return { ok = false, error = gerr }
  end

  local output = output_path(repo, opts)
  local path, werr = write_generated(output, generated, opts)
  if not path then
    return { ok = false, error = werr }
  end

  return {
    ok = true,
    path = path,
    markdown = generated.markdown,
    detected = generated.detected,
    feedback = generated.feedback,
    written = not opts.dry_run,
  }
end

return M
