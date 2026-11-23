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
  "review_escalated",
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

-- Per-cause classification rules, in priority order. The first match wins, so
-- the specific and benign patterns come before the broad ones.
local RULES = {
  {
    cause = "review_escalated",
    -- The review loop ran out of rounds and handed the task to a human. It is
    -- not transient in the retry sense: re-running the same attempt would
    -- escalate on its first round again. A human relaunch (metronome_retry,
    -- /metronome resume) grants a fresh review budget; no automatic retry loop
    -- is created for it.
    patterns = {
      "review escalated",
    },
    transient = false,
    remedy = "relaunch the task with metronome_retry (or /metronome resume): it resets the review round budget and keeps the last findings as feedback.",
  },
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

-- Read one context field of `opts` without ever raising, whatever the table.
local function field(opts, key)
  local ok, value = pcall(function()
    return opts[key]
  end)
  if ok then
    return value
  end
  return nil
end

-- The first non-empty text among `values`, collapsed to one line, or nil.
local function first_text(limit, ...)
  for i = 1, select("#", ...) do
    local value = select(i, ...)
    if value ~= nil then
      local ok, text = pcall(one_line, value, limit)
      if ok and type(text) == "string" and text ~= "" then
        return text
      end
    end
  end
  return nil
end

-- An empty error still happened somewhere, for a reason, at a status. Build a
-- message out of the context the caller carries, so a failure is never logged
-- without a diagnostic:
--   "task <id> failed in phase <phase>: <detail> (status <status>)"
-- where <detail> is the reason, else the latest note flagged "(see note)",
-- else a plain statement that nothing more was recorded. Without a task id the
-- head is "failure in phase <phase>"; a missing phase is "unknown phase".
local function contextual_message(opts)
  local ok, message = pcall(function()
    opts = default_opts(opts)
    local task = first_text(80, field(opts, "task_id"), field(opts, "task"))
    local phase = first_text(80, field(opts, "phase")) or "unknown phase"
    local status = first_text(40, field(opts, "status"))
    local reason = first_text(200, field(opts, "reason"))
    local note = first_text(200, field(opts, "note"))

    local detail
    local detail_names_status = false
    if reason then
      detail = reason
    elseif note then
      detail = note .. " (see note)"
    elseif status then
      detail = "status " .. status .. ", no detail recorded"
      detail_names_status = true
    else
      detail = "no detail recorded"
    end

    local head
    if task then
      head = string.format("task %s failed in phase %s", task, phase)
    else
      head = string.format("failure in phase %s", phase)
    end
    local out = head .. ": " .. detail
    if status and not detail_names_status then
      out = out .. " (status " .. status .. ")"
    end
    return one_line(out, 300)
  end)
  if ok and type(message) == "string" and message ~= "" then
    return message
  end
  return "failure in phase unknown phase: no detail recorded"
end

-- Diagnose one execution error. `opts` may carry the failure's context
-- (task_id/task, phase, status, reason, note); classification stays purely
-- textual, but an empty error is described from that context instead of the
-- useless "no error details". With a nil error the result is `unknown`, never
-- an exception.
function M.classify(err, opts)
  -- pcall returns every value of the body: keep both the matched rule and the
  -- raw text, otherwise the message is always empty (the historical bug).
  local ok, rule, raw = pcall(function()
    local text = err_text(err)
    local lower = text:lower()
    for _, candidate in ipairs(RULES) do
      if any_of(lower, candidate.patterns) then
        return candidate, text
      end
    end
    if missing_binary_fallback(lower) then
      return {
        cause = "binary_missing",
        transient = true,
        remedy = "install the missing binary (gh, no-mistakes, git) or fix PATH, then retry.",
      }, text
    end
    return UNKNOWN, text
  end)
  if not ok then
    return { cause = "unknown", message = contextual_message(opts), remedy = UNKNOWN.remedy,
      transient = false, retryable = false, remediable = false }
  end
  local transient = rule.transient == true
  local benign = rule.cause == "nothing_to_commit"
  local message = one_line(raw)
  if message == "" then
    message = benign and "nothing to commit" or contextual_message(opts)
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
-- `opts` may carry: phase, now, the failure context (task_id/task, status,
-- reason, note) and the retry bounds. The context is forwarded to classify, so
-- the message and the phase of the record are the same as classify's.
function M.record(err, prior, opts)
  opts = default_opts(opts)
  prior = type(prior) == "table" and prior or {}
  local phase = field(opts, "phase") or field(prior, "phase")
  local context = {
    task_id = field(opts, "task_id"),
    task = field(opts, "task"),
    phase = phase,
    status = field(opts, "status"),
    reason = field(opts, "reason"),
    note = field(opts, "note"),
  }
  local diagnosis = M.classify(err, context)
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
  elseif cause == "review_escalated" then
    why = "the review budget is spent: a human must relaunch the task with a fresh review round budget"
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

-- Review budget ---------------------------------------------------------------

-- Is this task's failure a review escalation? Two shapes are admitted:
--   * the typed cause `review_escalated`, written by the current pipeline;
--   * a legacy escalation, where the task carries a stored round that reached
--     its budget AND the review phase or the escalation wording proves the
--     review is what failed it. A task that simply reached its round count
--     (an in-flight round, a task parked for another reason) is not one.
function M.is_review_escalation(task)
  if type(task) ~= "table" then
    return false
  end
  local failure = type(task.failure) == "table" and task.failure or nil
  if failure and failure.cause == "review_escalated" then
    return true
  end

  local review = type(task.review) == "table" and task.review or {}
  local round = tonumber(review.round)
  local max_rounds = tonumber(review.max_rounds)
  if round == nil or max_rounds == nil or round < max_rounds then
    return false
  end
  if failure and failure.phase == "review" then
    return true
  end
  local text = tostring(
    (failure and (failure.message or failure.reason)) or task.failure_reason or task.reason or ""
  ):lower()
  return contains(text, "review escalated")
end

-- The fresh review budget a relaunch grants an escalated task: the counter
-- goes back to 0 in the same gesture as the move back to `running`, the last
-- round's findings stay as the implementer's feedback (otherwise the relaunch
-- repeats the same diff), and the reset carries the note that makes it
-- auditable. Returns nil when the task was not escalated by its review; no I/O.
function M.review_budget_reset(task)
  if not M.is_review_escalation(task) then
    return nil
  end
  local previous = type(task.review) == "table" and task.review or nil
  if previous == nil then
    return nil
  end
  local round = tonumber(previous.round)
  local max_rounds = tonumber(previous.max_rounds)
  if round == nil or max_rounds == nil or max_rounds < 1 then
    return nil
  end
  round = math.floor(round)
  max_rounds = math.floor(max_rounds)

  local review = {}
  for key, value in pairs(previous) do
    review[key] = value
  end
  review.round = 0
  review.max_rounds = max_rounds

  local note = string.format(
    "review.round %d -> 0: review budget %d granted, findings kept as implementer feedback",
    round, max_rounds
  )
  return {
    review = review,
    previous_round = round,
    max_rounds = max_rounds,
    note = note,
  }
end

return M
