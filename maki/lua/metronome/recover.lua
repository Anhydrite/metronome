-- Typed failure diagnosis and bounded retry policy.
--
-- A failed task or a stopped workflow is the worst outcome: every execution
-- error must be turned into a typed cause, an actionable remedy and a bounded
-- retry decision, so the scheduler can start the task again from its last
-- stable state instead of giving up. This module is the only authority that
-- makes that call.
--
-- It does no I/O, never raises and every function returns `(value, err)`. The
-- causes are a closed set, plus `unknown` as the last resort.
--
-- Contract consumed by the other tasks:
--   recover.classify(err, opts)   -> { cause, message, remedy, transient, retryable }
--   recover.record(err, prior, opts) -> failure = { cause, message, remedy,
--                                       transient, attempts, at, next_retry_at, phase }
--   recover.decide(failure, opts) -> { action, delay_secs, max_attempts, phase, reason }
--   recover.describe(failure)     -> one short human line

local M = {}

-- Default retry bounds. Every field can be overridden per call through `opts`
-- (max_attempts, backoff_base_secs, backoff_max_secs, factor).
M.DEFAULTS = {
  max_attempts = 3,
  backoff_base_secs = 30,
  backoff_max_secs = 900,
  factor = 2,
}

-- The closed set of causes. `nothing_to_commit` is benign: it is not a
-- failure at all, just a tree that was already at the requested state.
M.CAUSES = {
  "nothing_to_commit",
  "git_identity",
  "network",
  "binary_missing",
  "timeout",
  "killed",
  "session_dead",
  "quota",
  "conflict",
  "checks_failed",
  "auth",
  "unknown",
}

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Collapse any whitespace run to a single space, so a description stays on one
-- line whatever the tool printed.
local function one_line(s, limit)
  local out = trim(s):gsub("%s+", " ")
  limit = tonumber(limit) or 300
  if limit > 0 and #out > limit then
    out = out:sub(1, limit) .. "..."
  end
  return out
end

local function default_opts(opts)
  return type(opts) == "table" and opts or {}
end

local function number(value, fallback)
  local n = tonumber(value)
  if n == nil then
    return fallback
  end
  return n
end

-- The bounds for one call: per-call opts first, then M.DEFAULTS.
local function bounds(opts)
  opts = default_opts(opts)
  local d = M.DEFAULTS
  return {
    max_attempts = math.max(1, number(opts.max_attempts, d.max_attempts)),
    backoff_base_secs = math.max(0, number(opts.backoff_base_secs, d.backoff_base_secs)),
    backoff_max_secs = math.max(0, number(opts.backoff_max_secs, d.backoff_max_secs)),
    factor = math.max(1, number(opts.factor, d.factor)),
  }
end

-- Gather every piece of text an error can carry. A bare string is used as is;
-- a table is read for its usual fields (message, error, stderr, stdout, output,
-- command) and its exit code, so `exit 137` and `429` are visible to matching.
local function err_text(err, depth)
  local t = type(err)
  if err == nil then
    return ""
  end
  if t == "string" then
    return err
  end
  if t == "number" or t == "boolean" then
    return tostring(err)
  end
  if t ~= "table" then
    return tostring(err)
  end
  depth = depth or 0
  if depth > 3 then
    return ""
  end
  local parts = {}
  for _, key in ipairs({ "message", "msg", "error", "err", "stderr", "stdout", "output", "command" }) do
    local v = err[key]
    if type(v) == "string" and v ~= "" then
      parts[#parts + 1] = v
    elseif type(v) == "table" then
      parts[#parts + 1] = err_text(v, depth + 1)
    end
  end
  for _, key in ipairs({ "exit_code", "code", "status" }) do
    local v = err[key]
    if type(v) == "number" then
      parts[#parts + 1] = "exit " .. tostring(v)
    end
  end
  return table.concat(parts, "\n")
end

local function contains(haystack, needle)
  return haystack:find(needle, 1, true) ~= nil
end

local function any_of(haystack, needles)
  for _, needle in ipairs(needles) do
    if contains(haystack, needle) then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Structured conflicts.
--
-- A merge or rebase failure does not always come with text: the runtime and
-- `merge.run` report it as fields (`conflict = true` or the file table,
-- `conflict_files`, `conflict_file_list`, `base`, `base_sha`,
-- `rebase_command`). Reading only message/error/stderr left such a failure as
-- "conflict: no error details", which a human cannot act on. These helpers
-- gather those facts from the error and its sub-tables (bounded depth, cycles
-- broken) so `classify` can name the files, the base and the command.
-- ---------------------------------------------------------------------------

local function non_empty_string(value)
  return type(value) == "string" and trim(value) ~= ""
end

-- Collect file names from any shape: a comma/newline separated string, an
-- array of names, or an array of `{ file = ... }` hunk-like tables.
local function add_conflict_files(files, seen, value)
  if type(value) == "string" then
    for piece in value:gmatch("[^\n,]+") do
      local name = trim(piece)
      if name ~= "" and not seen[name] then
        seen[name] = true
        files[#files + 1] = name
      end
    end
  elseif type(value) == "table" then
    for _, item in ipairs(value) do
      if type(item) == "table" then
        add_conflict_files(files, seen, item.file or item.path or item.name)
      else
        add_conflict_files(files, seen, item)
      end
    end
  end
end

local CONFLICT_FIELDS = { "error", "err", "message", "msg", "details", "result", "output", "stderr", "stdout" }
local CONFLICT_HUNK_FIELDS = { "conflict_hunks", "hunks" }

-- Walk the error graph for conflict facts. Returns nil when no conflict marker
-- is present, so a purely textual error keeps its existing classification.
local function conflict_facts(err)
  if type(err) ~= "table" then
    return nil
  end
  local files, seen_files = {}, {}
  local facts = {}
  local visited = {}
  local function scan(node, depth)
    if type(node) ~= "table" or depth > 3 or visited[node] then
      return
    end
    visited[node] = true
    local marked = false
    local conflict = node.conflict
    if conflict == true then
      marked = true
    elseif type(conflict) == "table" then
      marked = true
      add_conflict_files(files, seen_files, conflict)
    elseif non_empty_string(conflict) then
      marked = true
      add_conflict_files(files, seen_files, conflict)
    end
    for _, key in ipairs({ "conflict_files", "conflict_file_list" }) do
      local value = node[key]
      if non_empty_string(value) then
        marked = true
        add_conflict_files(files, seen_files, value)
      elseif type(value) == "table" then
        marked = true
        add_conflict_files(files, seen_files, value)
      end
    end
    for _, key in ipairs(CONFLICT_HUNK_FIELDS) do
      if type(node[key]) == "table" then
        add_conflict_files(files, seen_files, node[key])
      end
    end
    if marked then
      facts.found = true
    end
    if facts.base == nil and non_empty_string(node.base) then
      facts.base = node.base
    end
    if facts.base_sha == nil and non_empty_string(node.base_sha) then
      facts.base_sha = node.base_sha
    end
    if facts.command == nil and non_empty_string(node.rebase_command) then
      facts.command = node.rebase_command
    end
    if facts.command == nil and non_empty_string(node.command) then
      facts.command = node.command
    end
    if facts.commit == nil and non_empty_string(node.conflict_commit) then
      facts.commit = node.conflict_commit
    end
    if facts.commit == nil and non_empty_string(node.commit) then
      facts.commit = node.commit
    end
    for _, key in ipairs(CONFLICT_FIELDS) do
      scan(node[key], depth + 1)
    end
  end
  scan(err, 0)
  if not facts.found then
    return nil
  end
  facts.files = files
  return facts
end

-- The actionable one-line message for a structured conflict: the files, the
-- base (with its SHA), the exact command and the commit git could not replay.
-- It is never empty, so a detailed conflict can never degrade to the dead-end
-- "no error details".
local function conflict_message(facts)
  local files = #facts.files > 0 and table.concat(facts.files, ", ") or "unknown"
  local parts = { "merge/rebase conflict, files: " .. files }
  local base = facts.base or facts.base_sha
  if base ~= nil and facts.base and facts.base_sha and facts.base_sha ~= facts.base then
    base = string.format("%s (%s)", facts.base, facts.base_sha)
  end
  if base ~= nil then
    parts[#parts + 1] = "base: " .. base
  end
  if facts.command ~= nil then
    parts[#parts + 1] = "command: `" .. facts.command .. "`"
  end
  if facts.commit ~= nil then
    parts[#parts + 1] = "commit: " .. facts.commit
  end
  return table.concat(parts, "; ")
end

-- Per-cause classification rules, in priority order. The first match wins, so
-- the specific and benign patterns come before the broad ones.
local RULES = {
  {
    cause = "nothing_to_commit",
    -- A commit that found nothing to do is not a failure. The French forms are
    -- the real incident: `git commit` exits 1 with "Sur la branche ... / rien a
    -- valider" when the machine runs in a French locale, and the tree was in
    -- fact clean.
    -- Only the specific phrases count. A bare branch header ("Sur la branche",
    -- "On branch") must never match: a real failure (hook rejection, conflict)
    -- often carries a `git status` dump that starts with it, and dropping that
    -- failure as benign would leave it unrecovered.
    patterns = {
      "nothing to commit",
      "working tree clean",
      "no changes added to commit",
      "rien a valider",
      "rien à valider",
      "arbre de travail est propre",
      "arbre de travail propre",
    },
    transient = false,
    remedy = "none: the tree already holds the requested state; carry on.",
  },
  {
    cause = "quota",
    -- The numeric status is only a quota signal in an HTTP context: a bare
    -- "429" would swallow a genuine message such as "timed out after 429s".
    patterns = {
      "http 429",
      "status 429",
      "status code 429",
      "error: 429",
      "429 too many",
      "rate limit",
      "ratelimit",
      "rate_limit",
      "too many requests",
      "quota",
      "api_key_expired",
      "insufficient_quota",
    },
    transient = true,
    remedy = "wait for the quota window to reset, then retry with the slower backoff.",
  },
  {
    cause = "auth",
    -- Same rule for auth: "401"/"403" are only credentials signals when they
    -- carry an HTTP-status context ("timed out after 401s" is a timeout).
    patterns = {
      "http 401",
      "http 403",
      "status 401",
      "status 403",
      "status code 401",
      "status code 403",
      "error: 401",
      "error: 403",
      "401 unauthorized",
      "403 forbidden",
      "permission denied",
      "authentication",
      "unauthorized",
      "not authorized",
      "bad credentials",
      "invalid api key",
      "invalid token",
      "could not read username",
    },
    transient = false,
    remedy = "refresh the credentials (gh auth login, API key) before retrying.",
  },
  {
    cause = "git_identity",
    patterns = {
      "please tell me who you are",
      "user.email",
      "user.name",
      "unable to auto-detect email",
      "author identity unknown",
      "empty ident",
    },
    transient = true,
    remedy = "set git user.email and user.name (git config --global user.email/user.name), then retry.",
  },
  {
    cause = "network",
    patterns = {
      "could not resolve host",
      "unable to access",
      "connection refused",
      "connection timed out",
      "connection reset",
      "network is unreachable",
      "could not connect",
      "temporary failure in name resolution",
      "econnreset",
      "etimedout",
      "ssl connect error",
    },
    transient = true,
    remedy = "check the network or the remote, then retry once it answers.",
  },
  {
    cause = "binary_missing",
    patterns = {
      "command not found",
      "executable file not found",
      "not found in path",
      "no such file or directory: gh",
      "no such file or directory: no-mistakes",
      "no such file or directory: git",
    },
    transient = true,
    remedy = "install the missing binary (gh, no-mistakes, git) or fix PATH, then retry.",
  },
  {
    cause = "session_dead",
    patterns = {
      "session closed",
      "session is closed",
      "session ended",
      "open failed",
      "stopped by parent agent",
      "no such session",
      "subagent session",
    },
    transient = true,
    remedy = "reopen the session; the worktree, branch and transcript are still there.",
  },
  {
    cause = "timeout",
    patterns = {
      "timed out after",
      "timed out",
      "deadline exceeded",
      "deadline",
      "timeout",
    },
    transient = true,
    remedy = "retry; if it keeps timing out, raise the timeout or shrink the step.",
  },
  {
    cause = "killed",
    patterns = {
      "exit 137",
      "exit 143",
      "killed",
      "sigkill",
      "sigterm",
      "signal",
      -- `oom` must be bounded: "boom", "room", "zoom" are not OOM kills.
      "oom-kill",
      "oom kill",
      "out of memory",
      "out-of-memory",
      "killed process",
    },
    transient = true,
    remedy = "retry; the process was killed by a signal or the OOM killer.",
  },
  {
    cause = "conflict",
    patterns = {
      "merge conflict",
      "rebase conflict",
      "automatic merge failed",
      "fix conflicts",
      "could not apply",
      "conflict (content)",
      "conflicts:",
    },
    transient = false,
    remedy = "resolve the merge/rebase conflict in the worktree, then retry.",
  },
  {
    cause = "checks_failed",
    patterns = {
      "checks failed",
      "check failed",
      "checks are red",
      "red check",
      "check(s) failed",
    },
    transient = false,
    remedy = "read the checks report and fix the code; the last checkpoint is still available.",
  },
}

-- A binary may be missing while the text only says "No such file or directory".
-- That phrase alone is ambiguous, so it counts as binary_missing only when a
-- known tool is named next to it.
local function missing_binary_fallback(lower)
  if not contains(lower, "no such file or directory") and not contains(lower, "enoent") then
    return false
  end
  return any_of(lower, { "gh", "no-mistakes", "git", "command" })
end

local UNKNOWN = {
  cause = "unknown",
  transient = false,
  remedy = "inspect the transcript and the worktree, then retry or fix by hand.",
}

-- The conflict rule, reused for a structured conflict so its cause, remedy and
-- transience stay identical to the textual one.
local CONFLICT_RULE
for _, rule in ipairs(RULES) do
  if rule.cause == "conflict" then
    CONFLICT_RULE = rule
    break
  end
end

-- Diagnose one execution error. `opts` is accepted for symmetry (a caller may
-- pass the phase or extra hints). Classification reads the text and, for a
-- conflict, the structured fields the merge/rebase carries. With a nil error
-- the result is `unknown`, never an exception.
function M.classify(err, opts)
  local ok, rule, raw, synthesized = pcall(function()
    local raw = err_text(err)
    local lower = raw:lower()
    -- A structured conflict wins over any text: it is unambiguous, and the
    -- message must name its files, base and command rather than the text.
    local facts = conflict_facts(err)
    if facts then
      return CONFLICT_RULE, raw, conflict_message(facts)
    end
    for _, rule in ipairs(RULES) do
      if any_of(lower, rule.patterns) then
        return rule, raw
      end
    end
    if missing_binary_fallback(lower) then
      return {
        cause = "binary_missing",
        transient = true,
        remedy = "install the missing binary (gh, no-mistakes, git) or fix PATH, then retry.",
      }, raw
    end
    return UNKNOWN, raw
  end)
  if not ok then
    return { cause = "unknown", message = "", remedy = UNKNOWN.remedy,
      transient = false, retryable = false, remediable = false }
  end
  local transient = rule.transient == true
  local benign = rule.cause == "nothing_to_commit"
  local message
  if synthesized ~= nil then
    -- Keep any raw text, but always append the facts. Never fall back to the
    -- dead-end message for a conflict carrying details.
    local rawline = one_line(raw, 0)
    if rawline == "" or rawline == "no error details" then
      message = synthesized
    else
      message = rawline .. " — " .. synthesized
    end
  else
    message = one_line(raw)
    if message == "" then
      message = benign and "nothing to commit" or "no error details"
    end
  end
  return {
    cause = rule.cause,
    message = message,
    remedy = rule.remedy,
    transient = transient,
    retryable = transient,
    -- Benign is explicitly not something to remedy; everything else is.
    remediable = not benign,
  }
end

-- The backoff for a given attempt number, capped by backoff_max_secs:
-- min(base * factor^(attempts-1), max). Attempt 1 waits the base delay.
function M.backoff_secs(attempts, opts)
  local b = bounds(opts)
  attempts = math.max(1, number(attempts, 1))
  local delay = b.backoff_base_secs * (b.factor ^ (attempts - 1))
  if delay > b.backoff_max_secs then
    delay = b.backoff_max_secs
  end
  return math.floor(delay)
end

-- Turn an error plus the prior attempt record into a failure record.
-- `opts` may carry: phase, now, and the retry bounds.
function M.record(err, prior, opts)
  opts = default_opts(opts)
  prior = type(prior) == "table" and prior or {}
  local diagnosis = M.classify(err, opts)
  local b = bounds(opts)
  local attempts = number(prior.attempts, 0) + 1
  local now = number(opts.now, number(prior.at, nil))
  if now == nil then
    now = os.time()
  end
  local delay = M.backoff_secs(attempts, opts)
  local next_retry_at
  if diagnosis.transient then
    next_retry_at = now + delay
  else
    -- Nothing to schedule: a benign cause or an unrecoverable one.
    next_retry_at = now
  end
  return {
    cause = diagnosis.cause,
    message = diagnosis.message,
    remedy = diagnosis.remedy,
    transient = diagnosis.transient,
    retryable = diagnosis.retryable,
    remediable = diagnosis.remediable,
    attempts = attempts,
    at = now,
    next_retry_at = next_retry_at,
    phase = opts.phase or prior.phase,
  }
end

-- Decide what to do with a failure record.
--   auto_retry: transient and under the attempt bound;
--   human:      retrying can no longer help (auth, unknown, conflict,
--               checks_failed, or the budget is exhausted);
--   none:       not a failure at all (benign), or no failure given.
function M.decide(failure, opts)
  opts = default_opts(opts)
  local b = bounds(opts)
  local max_attempts = b.max_attempts
  local now = number(opts.now, nil)

  if type(failure) ~= "table" then
    return {
      action = "none",
      delay_secs = 0,
      max_attempts = max_attempts,
      phase = opts.phase,
      reason = "no failure to recover from",
    }
  end

  local phase = failure.phase or opts.phase
  local attempts = number(failure.attempts, 1)
  local cause = failure.cause or "unknown"

  if cause == "nothing_to_commit" then
    return {
      action = "none",
      delay_secs = 0,
      max_attempts = max_attempts,
      phase = phase,
      reason = "benign: nothing to commit, this is not a failure",
    }
  end

  if failure.transient then
    if attempts < max_attempts then
      local delay
      if now ~= nil and type(failure.next_retry_at) == "number" then
        delay = failure.next_retry_at - now
      else
        delay = M.backoff_secs(attempts, opts)
      end
      if delay < 0 then
        delay = 0
      end
      return {
        action = "auto_retry",
        delay_secs = math.floor(delay),
        max_attempts = max_attempts,
        phase = phase,
        reason = string.format("transient %s, attempt %d/%d", cause, attempts, max_attempts),
      }
    end
    return {
      action = "human",
      delay_secs = 0,
      max_attempts = max_attempts,
      phase = phase,
      reason = string.format("attempt budget exhausted (%d/%d)", attempts, max_attempts),
    }
  end

  local why
  if cause == "auth" then
    why = "authentication must be fixed before any retry can succeed"
  elseif cause == "unknown" then
    why = "unknown cause: a human must inspect the transcript"
  elseif cause == "conflict" then
    why = "the conflict must be resolved in the worktree"
  elseif cause == "checks_failed" then
    why = "the checks are red: the code must be fixed"
  else
    why = "this failure is not transient"
  end
  return {
    action = "human",
    delay_secs = 0,
    max_attempts = max_attempts,
    phase = phase,
    reason = why,
  }
end

-- One short line for the status panel and the logs:
-- "cause: message — remedy — action (attempt n/max, next at ...)".
function M.describe(failure)
  if type(failure) ~= "table" then
    return "unknown: no failure details"
  end
  local cause = failure.cause or "unknown"
  local message = one_line(failure.message or "", 160)
  if message == "" then
    message = "(no message)"
  end
  local remedy = one_line(failure.remedy or "", 160)
  if remedy == "" then
    remedy = "inspect the transcript"
  end
  local decision = M.decide(failure)
  local attempts = number(failure.attempts, 0)
  local action
  if decision.action == "auto_retry" then
    action = string.format("retry in %ds", decision.delay_secs)
  elseif decision.action == "human" then
    action = "human intervention"
  else
    action = "no action"
  end
  local parts = {
    cause .. ": " .. message,
    remedy,
    action,
  }
  local line = table.concat(parts, " — ")
  local suffix = string.format(" (attempt %d/%d", attempts, decision.max_attempts)
  if decision.action == "auto_retry" and type(failure.next_retry_at) == "number" then
    suffix = suffix .. string.format(", next at %d", failure.next_retry_at)
  end
  suffix = suffix .. ")"
  return line .. suffix
end

return M
