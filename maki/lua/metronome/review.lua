-- Review: one exact commit, structured findings, a bounded loop.
--
-- The reviewer is the gate before the PR. It never reviews "the branch": it
-- reviews one commit SHA, and a branch that moved while the model was thinking
-- invalidates the answer. That is why the SHA is read before the turn, stored
-- with the findings, and checked again afterwards.
--
-- Three rules shape the module:
--   * Protected paths are checked before the model is called. A change to the
--     rules is a finding no model gets to waive, and spending a turn on it
--     would only invite the model to argue.
--   * The loop is bounded. At `max_rounds` the task escalates to a human
--     instead of spinning, and the escalation leaves a note in the journal.
--   * Nothing here opens the PR. A clean review returns `approved`; the
--     pipeline owns the move to `pr_open`.
--
-- Every function returns `(value, err)` and never raises. git, state, runner
-- and the session options are injected, so the module is pure Lua and the whole
-- turn is testable against a throwaway repository.
--
-- Restated: this module never opens the PR; a clean `approved` is the pipeline's cue to move to `pr_open`.

local M = {}

local fs = maki.fs

local SEVERITIES = {
  blocking = true,
  major = true,
  minor = true,
  nit = true,
}

-- The paths a task may never touch without a human. Kept in sync with
-- config.lua's review.protected_paths default; the caller can override it.
local DEFAULT_PROTECTED = { "review-rules.md", "AGENTS.md", ".metronome/", "deploy.md" }

local DEFAULT_MAX_ROUNDS = 3
local DEFAULT_MAX_DIFF = 120000

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_non_empty(s)
  return type(s) == "string" and trim(s) ~= ""
end

local function is_integer(value)
  return type(value) == "number" and value == math.floor(value)
end

-- JSON extraction -------------------------------------------------------------

-- The first balanced {...} or [...] starting at `start`, ignoring brackets
-- inside strings and honouring backslash escapes. A diff or a message may
-- contain braces, so counting characters would cut the answer short.
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

-- Normalise one finding to the five keys schemas/task.schema.json knows about.
-- Unknown keys are dropped rather than refused: a model that adds a helpful
-- `file` or `suggestion` is not wrong, it is just verbose. A wrong value in a
-- known key is an error, because silently coercing it would store a lie.
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

  local finding = { severity = severity, message = message }

  if raw.path ~= nil then
    if type(raw.path) ~= "string" then
      return nil, string.format("finding %d: path must be a string", index)
    end
    finding.path = raw.path
  end

  if raw.line ~= nil then
    if not is_integer(raw.line) or raw.line < 1 then
      return nil, string.format("finding %d: line must be an integer >= 1", index)
    end
    finding.line = raw.line
  end

  if raw.rule ~= nil then
    if type(raw.rule) ~= "string" then
      return nil, string.format("finding %d: rule must be a string", index)
    end
    finding.rule = raw.rule
  end

  return finding
end

-- Parse the reviewer's answer. Accepts `{findings:[...]}` or a bare array,
-- fenced or surrounded by prose. Returns (findings, err).
function M.parse_findings(text)
  if type(text) ~= "string" then
    return nil, "no text"
  end

  local slice = extract_candidate(text)
  if not slice then
    return nil, "invalid JSON: no JSON object found"
  end

  local ok, decoded, decode_err = pcall(maki.json.decode, slice)
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
  -- slice's first character decides. For an object answer, the character after
  -- `"findings":` must be `[` for the same reason: `{"findings":{}}` is not a
  -- findings array, and treating it as an empty one would approve a malformed
  -- answer.
  local first = slice:match("^%s*(.)")
  local list
  if first == "[" then
    list = decoded
  else
    local opener = slice:match('"findings"%s*:%s*(%S)')
    if opener ~= "[" then
      return nil, "invalid JSON: expected a findings array"
    end
    list = decoded.findings
    if type(list) ~= "table" then
      return nil, "invalid JSON: expected a findings array"
    end
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

-- Protected paths -------------------------------------------------------------

-- A protected entry matches a changed path three ways: the same file, a path
-- under it (`entry/...`), or a directory entry with a trailing slash. The
-- trailing-slash form is what makes `.metronome/` mean "the whole directory"
-- rather than a file with an odd name.
local function matches_protected(path, entry)
  if path == entry then
    return true
  end
  if entry:sub(-1) == "/" then
    return path:sub(1, #entry) == entry
  end
  return path:sub(1, #entry + 1) == entry .. "/"
end

-- Findings for the changed files that touch a protected path. Always blocking:
-- the caller uses `#protected > 0` as the signal to skip the model entirely.
function M.protected_findings(changed_files, protected_paths)
  local findings = {}
  local seen = {}
  local changed = type(changed_files) == "table" and changed_files or {}
  local protected = type(protected_paths) == "table" and protected_paths or {}

  for _, raw_path in ipairs(changed) do
    local path = trim(raw_path)
    if path ~= "" then
      for _, raw_entry in ipairs(protected) do
        local entry = trim(raw_entry)
        if entry ~= "" and matches_protected(path, entry) then
          local key = entry .. "\0" .. path
          if not seen[key] then
            seen[key] = true
            findings[#findings + 1] = {
              severity = "blocking",
              rule = "protected_path",
              message = "protected path " .. entry .. " was modified",
              path = path,
            }
          end
        end
      end
    end
  end

  return findings
end

-- Diff ------------------------------------------------------------------------

-- The diff of exactly the commit under review, against the merge base of the
-- base ref. A long diff is truncated with a marker rather than dropped: the
-- reviewer must know it saw only the head of the change.
function M.diff(worktree, base, sha, opts)
  opts = type(opts) == "table" and opts or {}
  local git = opts.git
  if type(git) ~= "table" or type(git.run) ~= "function" then
    return nil, "git module is missing run"
  end
  if not is_non_empty(worktree) then
    return nil, "diff needs a worktree"
  end
  if not is_non_empty(sha) then
    return nil, "diff needs a commit sha"
  end

  local range = tostring(base or "HEAD") .. "..." .. sha
  local called, result, rerr = pcall(git.run, { "git", "-C", worktree, "diff", range })
  if not called then
    return nil, tostring(result)
  end
  if not result then
    return nil, rerr or ("cannot run git diff " .. range)
  end
  if not result.ok then
    local detail = trim(result.stderr or "")
    if detail == "" then
      detail = trim(result.stdout or "")
    end
    return nil, string.format("git diff %s failed (exit %s): %s",
      range, tostring(result.code), detail)
  end

  local text = result.stdout or ""
  local max_diff = tonumber(opts.max_diff) or DEFAULT_MAX_DIFF
  if max_diff < 1 then
    max_diff = DEFAULT_MAX_DIFF
  end
  if #text > max_diff then
    text = text:sub(1, max_diff) .. "\n[truncated]"
  end
  return text
end

-- Evidence --------------------------------------------------------------------

-- The checks report the verification step wrote, or a placeholder. A missing
-- report is not an error here: the reviewer can still read the diff, and the
-- pipeline decides whether a missing report is acceptable.
function M.checks_report(root, task_id, opts)
  opts = type(opts) == "table" and opts or {}
  if not is_non_empty(root) or not is_non_empty(task_id) then
    return "(no checks report)"
  end
  local text = fs.read(fs.joinpath(root, "checks", tostring(task_id) .. ".json"))
  if type(text) ~= "string" or trim(text) == "" then
    return "(no checks report)"
  end
  return text
end

-- The repository's review rules, read from `rules_path` or the repo root.
function M.rules(opts)
  opts = type(opts) == "table" and opts or {}
  local path = opts.rules_path
  if not is_non_empty(path) then
    if not is_non_empty(opts.repo) then
      return "(no review rules)"
    end
    path = fs.joinpath(opts.repo, "review-rules.md")
  end
  local text = fs.read(path)
  if type(text) ~= "string" or trim(text) == "" then
    return "(no review rules)"
  end
  return text
end

-- Prompt ----------------------------------------------------------------------

-- The prompt is built around the exact SHA. The contract is stated once, in
-- the shape the parser accepts, so a model that follows it cannot produce an
-- answer this module refuses.
function M.prompt(task, sheet, sha, diff, checks, rules, opts)
  opts = type(opts) == "table" and opts or {}
  task = type(task) == "table" and task or {}
  sha = tostring(sha or "")

  local out = {}
  local function line(s)
    out[#out + 1] = s
  end

  local id = tostring(task.id or "")
  local title = trim(task.title)
  local fence = type(opts.fence) == "table" and opts.fence or nil

  line("# Review")
  line("")
  line("- Task: " .. id .. (title ~= "" and (" — " .. title) or ""))
  line("- Commit: " .. sha)
  line("")
  line("## Task sheet")
  line("")
  line(tostring(sheet or ""))
  line("")
  line("## Commit under review")
  line("")
  line(sha)
  line("")
  line("Review this exact commit. If the branch moved, this review no longer applies.")
  line("")
  line("## Diff")
  line("")
  local diff_text = tostring(diff or "")
  if trim(diff_text) == "" then
    diff_text = "(no diff)"
  end
  if fence then
    line(fence.wrap_diff("```diff\n" .. diff_text .. "\n```", { label = id }))
  else
    line("```diff")
    line(diff_text)
    line("```")
  end
  line("")
  line("## Checks")
  line("")
  local checks_text = tostring(checks or "(no checks report)")
  if fence then
    line(fence.wrap_checks(checks_text, { label = id }))
  else
    line(checks_text)
  end
  line("")
  line("## Review rules")
  line("")
  line(tostring(rules or "(no review rules)"))
  line("")
  line("## Output contract")
  line("")
  line("Return ONE JSON object and nothing else:")
  line("")
  line('{"findings":[{"severity":"blocking|major|minor|nit","message":"...","path":"...","line":1,"rule":"..."}]}')
  line("")
  line('- If the commit is clean, return {"findings":[]}.')
  line("- Review THIS commit (" .. sha .. "), not the branch: a branch that moved is a different change.")
  line("- `path` and `line` are optional; `line` is 1-based.")
  line("- Protected paths are always blocking.")
  line("- You do not edit code. Report what you found and stop.")

  return table.concat(out, "\n") .. "\n"
end

-- Store -----------------------------------------------------------------------

-- Validate a review before it reaches the journal. schemas/task.schema.json
-- forbids extra keys and requires a hex commit_sha, so a malformed review is
-- refused here rather than written and caught later by the validator.
local function validate_review(review)
  if type(review) ~= "table" then
    return nil, "review must be a table"
  end

  if not is_integer(review.round) or review.round < 0 then
    return nil, "review.round must be an integer >= 0"
  end
  if not is_integer(review.max_rounds) or review.max_rounds < 1 then
    return nil, "review.max_rounds must be an integer >= 1"
  end

  local sha = review.commit_sha
  if type(sha) ~= "string" or not sha:match("^[0-9a-f]+$") or #sha < 7 or #sha > 40 then
    return nil, "review.commit_sha must be a 7-40 character lowercase hex sha"
  end

  local findings = {}
  if review.findings ~= nil then
    if type(review.findings) ~= "table" then
      return nil, "review.findings must be an array"
    end
    for i, raw in ipairs(review.findings) do
      local finding, err = normalize_finding(raw, i)
      if not finding then
        return nil, err
      end
      findings[i] = finding
    end
  end

  return {
    round = review.round,
    max_rounds = review.max_rounds,
    commit_sha = sha,
    findings = findings,
  }
end

-- Store the review on the task. An empty findings array is omitted: maki
-- encodes an empty table as `{}`, which the schema rejects as an array, so the
-- only schema-safe way to say "no findings" is to leave the key out.
function M.store(state, root, task_id, review)
  if type(state) ~= "table" or type(state.set_fields) ~= "function" then
    return nil, "state module is missing set_fields"
  end
  if not is_non_empty(root) then
    return nil, "store needs a root"
  end
  if not is_non_empty(task_id) then
    return nil, "store needs a task_id"
  end

  local normalized, err = validate_review(review)
  if not normalized then
    return nil, err
  end

  local payload = {
    round = normalized.round,
    max_rounds = normalized.max_rounds,
    commit_sha = normalized.commit_sha,
  }
  if #normalized.findings > 0 then
    payload.findings = normalized.findings
  end

  local called, task, serr = pcall(state.set_fields, root, task_id, { review = payload })
  if not called then
    return nil, tostring(task)
  end
  if not task then
    return nil, serr or "cannot store the review"
  end
  return task
end

-- Escalate --------------------------------------------------------------------

-- Hand the task to a human. The note is written first: if the transition is
-- refused, the reason for the escalation still survives in the journal.
function M.escalate(state, root, task_id, opts)
  opts = type(opts) == "table" and opts or {}
  if type(state) ~= "table" or type(state.append) ~= "function" then
    return nil, "state module is missing append"
  end
  if not is_non_empty(root) then
    return nil, "escalate needs a root"
  end
  if not is_non_empty(task_id) then
    return nil, "escalate needs a task_id"
  end

  local round = tonumber(opts.round)
  local loaded = type(state.load) == "function" and state.load(root) or nil
  local task = type(loaded) == "table" and type(loaded.tasks) == "table"
    and loaded.tasks[task_id] or nil
  if not round then
    round = task and type(task.review) == "table" and tonumber(task.review.round)
      or tonumber(opts.max_rounds) or 0
  end
  round = math.floor(round)

  local appended, aerr = state.append(root, {
    kind = "note",
    task_id = task_id,
    text = string.format("review escalated after %d rounds: human review required", round),
  })
  if not appended then
    return nil, aerr or "cannot append the escalation note"
  end

  if type(task) ~= "table" then
    return nil, "unknown task: " .. tostring(task_id)
  end
  if not state.can_transition(task.status, "failed") then
    return nil, string.format(
      "cannot escalate %s from %s: failed is not a legal transition",
      tostring(task_id), tostring(task.status)
    )
  end

  local moved, merr = state.transition(root, task_id, "failed", { phase = "review" })
  if not moved then
    return nil, merr
  end
  return true
end

-- Review ----------------------------------------------------------------------

local function check_module(name, module, functions)
  if type(module) ~= "table" then
    return nil, name .. " module is required"
  end
  for _, fn in ipairs(functions) do
    if type(module[fn]) ~= "function" then
      return nil, string.format("%s module is missing %s", name, fn)
    end
  end
  return true
end

-- A caller may pass the task table it already holds, or only an id. An id is
-- loaded from state so the round counter is always the journal's, never a
-- stale copy in the caller.
local function resolve_task(opts)
  local task = opts.task
  if type(task) == "table" and is_non_empty(task.id) then
    return task, task.id
  end

  local task_id = type(task) == "string" and task or opts.task_id
  if not is_non_empty(task_id) then
    return nil, nil, "review needs a task or a task_id"
  end

  local state = opts.state
  if type(state) ~= "table" or type(state.load) ~= "function" then
    return nil, task_id, "state module is missing load"
  end
  if not is_non_empty(opts.root) then
    return nil, task_id, "review needs a state root"
  end

  local loaded = state.load(opts.root)
  local found = type(loaded) == "table" and type(loaded.tasks) == "table"
    and loaded.tasks[task_id] or nil
  if type(found) ~= "table" then
    return nil, task_id, "unknown task: " .. tostring(task_id)
  end
  return found, task_id
end

-- The sheet is what qualification wrote. A caller may pass it directly; when
-- it does not, it is read from tasks_dir (or root/tasks), and a missing sheet
-- degrades to a minimal one rather than a crash.
local function read_sheet(task, root, opts)
  if type(opts.sheet) == "string" then
    return opts.sheet
  end
  local dir = opts.tasks_dir
  if not is_non_empty(dir) then
    dir = fs.joinpath(root, "tasks")
  end
  local id = tostring(task.id or "")
  if is_non_empty(dir) and id ~= "" then
    local text = fs.read(fs.joinpath(dir, id .. ".md"))
    if type(text) == "string" then
      return text
    end
  end
  return "# Task " .. id .. "\n\n- Title: " .. tostring(task.title or "") .. "\n"
end

local function review_impl(opts)
  local ok, err = check_module("git", opts.git, { "head_sha", "changed_files", "run" })
  if not ok then
    return { ok = false, error = err }
  end
  ok, err = check_module("state", opts.state, {
    "load", "set_fields", "transition", "can_transition", "append",
  })
  if not ok then
    return { ok = false, error = err }
  end

  local task, task_id, terr = resolve_task(opts)
  if not task then
    return { ok = false, error = terr }
  end

  local worktree = opts.worktree
  if not is_non_empty(worktree) then
    return { ok = false, error = "review needs a worktree" }
  end
  local root = opts.root
  if not is_non_empty(root) then
    return { ok = false, error = "review needs a state root" }
  end

  -- The SHA is read once, before anything else. Everything below is about
  -- this commit, and the final check refuses to store a review of a commit
  -- that is no longer the head.
  local sha, sherr = opts.git.head_sha(worktree)
  if not sha then
    return { ok = false, error = sherr or "cannot read HEAD" }
  end

  local previous = type(task.review) == "table" and task.review or {}
  local round = (tonumber(previous.round) or 0) + 1
  local max_rounds = tonumber(opts.max_rounds) or tonumber(previous.max_rounds) or DEFAULT_MAX_ROUNDS
  if max_rounds < 1 then
    max_rounds = DEFAULT_MAX_ROUNDS
  end
  max_rounds = math.floor(max_rounds)

  local base = opts.base or task.base_ref or "main"
  local changed, cerr = opts.git.changed_files(worktree, base, { three_dot = true })
  if not changed then
    return { ok = false, error = cerr or "cannot list changed files", round = round, sha = sha }
  end

  local protected_paths = opts.protected_paths
  if type(protected_paths) ~= "table" then
    protected_paths = DEFAULT_PROTECTED
  end
  local protected = M.protected_findings(changed, protected_paths)

  -- A protected change is decided here, without a model turn. The review is
  -- still stored, so the evidence survives the escalation.
  if #protected > 0 then
    local stored, serr = M.store(opts.state, root, task_id, {
      round = round,
      max_rounds = max_rounds,
      commit_sha = sha,
      findings = protected,
    })
    if not stored then
      return {
        ok = false, error = serr, findings = protected,
        round = round, sha = sha, protected = true,
      }
    end

    if round >= max_rounds then
      local escalated, eerr = M.escalate(opts.state, root, task_id, {
        round = round, max_rounds = max_rounds,
      })
      if not escalated then
        return {
          ok = false, error = eerr, findings = protected,
          round = round, sha = sha, protected = true,
        }
      end
      return {
        ok = false, findings = protected, round = round, sha = sha,
        protected = true, escalated = true,
      }
    end

    local moved, merr = opts.state.transition(root, task_id, "changes_requested", { phase = "review" })
    if not moved then
      return {
        ok = false, error = merr, findings = protected,
        round = round, sha = sha, protected = true,
      }
    end
    return {
      ok = false, findings = protected, round = round, sha = sha,
      protected = true, escalated = false,
    }
  end

  -- Past the bound there is nothing left to review: escalate rather than
  -- review a fourth time.
  if round > max_rounds then
    local escalated, eerr = M.escalate(opts.state, root, task_id, {
      round = round, max_rounds = max_rounds,
    })
    if not escalated then
      return { ok = false, error = eerr, round = round, sha = sha }
    end
    return { ok = false, escalated = true, round = round, sha = sha }
  end

  local sheet = read_sheet(task, root, opts)
  local diff_text, derr = M.diff(worktree, base, sha, opts)
  if not diff_text then
    return { ok = false, error = derr, round = round, sha = sha }
  end

  local checks = M.checks_report(root, task_id, opts)
  local rules = M.rules(opts)
  local prompt = M.prompt(task, sheet, sha, diff_text, checks, rules, opts)

  if type(opts.runner) ~= "function" then
    return { ok = false, error = "review needs a runner function", round = round, sha = sha }
  end

  local session_opts = type(opts.session_opts) == "table" and opts.session_opts or {}
  local called, run = pcall(opts.runner, {
    role = "reviewer",
    task_id = task_id,
    phase = "review",
    prompt = prompt,
    system = session_opts.system,
    model_spec = session_opts.model_spec,
    thinking = session_opts.thinking,
    tools = session_opts.tools,
    state_root = opts.state_root,
    ctx = opts.ctx,
  })
  if not called then
    run = { ok = false, error = tostring(run) }
  elseif type(run) ~= "table" then
    run = { ok = false, error = "runner returned no result" }
  end

  if not run.ok then
    return {
      ok = false, error = run.error or "runner failed",
      round = round, sha = sha, run = run,
    }
  end

  local findings, perr = M.parse_findings(run.text)
  if not findings then
    return {
      ok = false, error = "review output invalid: " .. tostring(perr),
      round = round, sha = sha, run = run,
    }
  end

  -- The branch may have moved while the model was reading. A review of a
  -- commit that is no longer the head is evidence of nothing, so it is not
  -- stored.
  local after_sha, aerr = opts.git.head_sha(worktree)
  if not after_sha then
    return {
      ok = false, error = aerr or "cannot re-read HEAD",
      round = round, sha = sha, run = run,
    }
  end
  if after_sha ~= sha then
    return {
      ok = false,
      error = string.format("branch moved during review: %s -> %s", sha, after_sha),
      round = round, sha = sha, run = run,
    }
  end

  local stored, serr = M.store(opts.state, root, task_id, {
    round = round,
    max_rounds = max_rounds,
    commit_sha = sha,
    findings = findings,
  })
  if not stored then
    return {
      ok = false, error = serr, findings = findings,
      round = round, sha = sha, run = run,
    }
  end

  local unresolved = {}
  for _, finding in ipairs(findings) do
    if finding.severity == "blocking" or finding.severity == "major" then
      unresolved[#unresolved + 1] = finding
    end
  end

  if #unresolved == 0 then
    -- Approved, but the status is untouched: the pipeline opens the PR.
    return {
      ok = true, approved = true, findings = findings,
      round = round, sha = sha, run = run,
    }
  end

  if round >= max_rounds then
    local escalated, eerr = M.escalate(opts.state, root, task_id, {
      round = round, max_rounds = max_rounds,
    })
    if not escalated then
      return {
        ok = false, error = eerr, findings = findings,
        round = round, sha = sha, run = run,
      }
    end
    return {
      ok = false, escalated = true, findings = findings,
      round = round, sha = sha, run = run,
    }
  end

  local moved, merr = opts.state.transition(root, task_id, "changes_requested", { phase = "review" })
  if not moved then
    return {
      ok = false, error = merr, findings = findings,
      round = round, sha = sha, run = run,
    }
  end
  return {
    ok = false, changes_requested = true, findings = findings,
    round = round, sha = sha, run = run,
  }
end

-- One round, never raises: a reviewer that dies cannot report why.
function M.review(opts)
  opts = type(opts) == "table" and opts or {}
  local called, result = pcall(review_impl, opts)
  if not called then
    return { ok = false, error = tostring(result) }
  end
  return result
end

-- Loop ------------------------------------------------------------------------

local function loop_impl(opts)
  local max_iter = tonumber(opts.max_rounds) or DEFAULT_MAX_ROUNDS
  if max_iter < 1 then
    max_iter = 1
  end
  max_iter = math.floor(max_iter)

  local last = nil
  for _ = 1, max_iter do
    -- Re-read the task from state each round when we have an id: the round
    -- counter lives in the journal, and a stale table would review round 1
    -- forever.
    local call_opts = opts
    local id = type(opts.task) == "table" and opts.task.id or opts.task
    if is_non_empty(id) and opts.state and is_non_empty(opts.root) then
      call_opts = {}
      for key, value in pairs(opts) do
        call_opts[key] = value
      end
      call_opts.task = id
    end

    local result = M.review(call_opts)
    last = result

    if result.ok or result.escalated or result.error then
      return result
    end
    if not result.changes_requested then
      return result
    end
    if type(opts.fix) ~= "function" then
      return result
    end

    local called, fixed = pcall(opts.fix, result)
    if not called then
      return {
        ok = false, error = tostring(fixed),
        round = result.round, sha = result.sha, findings = result.findings,
      }
    end
    if fixed == false or fixed == nil then
      local message = "fix failed"
      if type(fixed) == "table" and is_non_empty(fixed.error) then
        message = fixed.error
      end
      return {
        ok = false, error = message,
        round = result.round, sha = result.sha, findings = result.findings,
      }
    end
  end

  -- The bound ran out without a verdict. Escalate once so the caller never has
  -- to interpret an exhausted loop.
  local id = type(opts.task) == "table" and opts.task.id or opts.task
  if is_non_empty(id) and opts.state and is_non_empty(opts.root) then
    local escalated, eerr = M.escalate(opts.state, opts.root, id, {
      round = last and last.round,
      max_rounds = max_iter,
    })
    if not escalated then
      return {
        ok = false, error = eerr,
        round = last and last.round, sha = last and last.sha,
      }
    end
  end
  return {
    ok = false, escalated = true,
    round = last and last.round,
    sha = last and last.sha,
    findings = last and last.findings,
  }
end

-- A bounded loop of review rounds, with an optional fix callback between them.
-- Stops at the first verdict, error, or escalation.
function M.loop(opts)
  opts = type(opts) == "table" and opts or {}
  local called, result = pcall(loop_impl, opts)
  if not called then
    return { ok = false, error = tostring(result) }
  end
  return result
end

return M
