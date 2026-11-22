-- Tests for maki/lua/metronome/recover.lua (T-20261122-001e).
--
-- The module is the only authority that turns a run error into a typed cause
-- and a bounded retry decision. These tests pin the closed cause set, the
-- exponential backoff and its cap, the escalation bound, and the promise that
-- no input (including nil) ever raises.

return function()
  local recover = load_module("recover")

  local function cause_of(err, opts)
    local got = recover.classify(err, opts)
    return got and got.cause
  end

  -- Defaults ----------------------------------------------------------------

  eq(recover.DEFAULTS.max_attempts, 3, "default max_attempts is 3")
  eq(recover.DEFAULTS.backoff_base_secs, 30, "default backoff base is 30s")
  eq(recover.DEFAULTS.backoff_max_secs, 900, "default backoff is capped at 900s")
  eq(recover.DEFAULTS.factor, 2, "default backoff factor is 2")

  -- Every cause is recognised ----------------------------------------------

  local cases = {
    { "git_identity", "fatal: Please tell me who you are.\nRun git config --global user.email ..." },
    { "git_identity", "error: unable to auto-detect email address ('root@localhost')" },
    { "network", "fatal: unable to access 'https://github.com/x/y': Could not resolve host: github.com" },
    { "network", "dial tcp: connect: Connection refused" },
    { "network", "Connection timed out" },
    { "binary_missing", "sh: 1: gh: command not found" },
    { "binary_missing", "exec: no-mistakes: executable file not found in $PATH" },
    { "binary_missing", "spawn git: No such file or directory: git" },
    { "timeout", "turn timed out after 900s" },
    { "timeout", "context deadline exceeded" },
    { "killed", "process killed by signal 9" },
    { "killed", "exit 137" },
    { "session_dead", "session closed while the turn was running" },
    { "session_dead", "subagent open failed" },
    { "session_dead", "stopped by parent agent" },
    { "quota", "HTTP 429 Too Many Requests" },
    { "quota", "rate limit exceeded, retry later" },
    { "quota", "api_key_expired" },
    { "conflict", "CONFLICT (content): Merge conflict in maki/init.lua" },
    { "conflict", "error: could not apply 0badf00d... fix" },
    { "checks_failed", "checks failed: bash tests/run-lua.sh exited 1" },
    { "auth", "HTTP 401 Unauthorized" },
    { "auth", "remote: Permission denied (publickey)" },
    { "auth", "authentication failed for the API key" },
    { "nothing_to_commit", "nothing to commit, working tree clean" },
    { "unknown", "the model said something strange" },
  }
  for _, case in ipairs(cases) do
    eq(cause_of(case[2]), case[1], "classify " .. case[1] .. " from its message")
  end

  -- The real incident: French git output from `git commit` on a clean tree.
  local french = cause_of("exit 1: Sur la branche metronome/x\nrien à valider, l'arbre de travail est propre")
  eq(french, "nothing_to_commit", "French git commit output is benign")
  eq(cause_of("rien à valider"), "nothing_to_commit", "French 'rien à valider' is benign")
  -- A bare branch header is NOT a benign signal: a real failure often appends a
  -- `git status` dump that starts with it, and it must stay recoverable.
  eq(cause_of("Sur la branche master"), "unknown", "a bare 'Sur la branche' header is not benign")
  eq(cause_of("On branch main"), "unknown", "a bare 'On branch' header is not benign")
  eq(cause_of("Sur la branche x\nrien à valider, l'arbre de travail est propre"), "nothing_to_commit",
    "the French header plus the specific phrase is benign")

  -- Bare numeric tokens must not steal a transient failure (review feedback).
  local slow = recover.classify("turn timed out after 401s")
  eq(slow.cause, "timeout", "'timed out after 401s' is a timeout, not auth")
  eq(recover.decide(recover.record("turn timed out after 401s", nil, { now = 0 })).action, "auto_retry",
    "a timeout carrying 401 stays retryable")
  eq(cause_of("turn timed out after 429s"), "timeout", "'timed out after 429s' is a timeout, not quota")
  eq(cause_of("exit 137 after 403ms"), "killed", "'exit 137 ... 403ms' is killed, not auth")
  eq(cause_of("the tool said boom"), "unknown", "'boom' is not an OOM kill")
  eq(cause_of("no more room in the buffer"), "unknown", "'room' is not an OOM kill")
  eq(cause_of("the kernel: oom-kill:constraint=CONSTRAINT_NONE"), "killed", "'oom-kill' is killed")
  eq(cause_of("fatal: out of memory"), "killed", "'out of memory' is killed")

  -- A benign phrase does not hide a genuine failure appended after it.
  eq(cause_of("On branch main\nCONFLICT (content): Merge conflict in maki/init.lua"), "conflict",
    "a conflict dump with a branch header stays a conflict")

  -- Structural fields -------------------------------------------------------

  local id = recover.classify("fatal: Please tell me who you are")
  eq(id.transient, true, "git_identity is transient")
  eq(id.retryable, true, "git_identity is retryable")
  eq(type(id.remedy), "string", "git_identity carries a remedy")
  eq(id.remedy:find("user.email", 1, true) ~= nil, true, "the remedy names user.email")

  local benign = recover.classify("nothing to commit, working tree clean")
  eq(benign.transient, false, "nothing_to_commit is not transient")
  eq(benign.retryable, false, "nothing_to_commit is not retryable")
  eq(benign.remediable, false, "nothing_to_commit is not remediable")

  local auth = recover.classify("HTTP 401 Unauthorized")
  eq(auth.transient, false, "auth is not transient")
  eq(auth.retryable, false, "auth is not retryable")

  -- A table error is understood too, including its exit code.
  eq(cause_of({ exit_code = 137, stderr = "boom" }), "killed", "an exit_code field is classified")
  eq(cause_of({ message = "Could not resolve host: github.com" }), "network",
    "a message field is classified")
  eq(cause_of({ stderr = "sh: gh: command not found" }), "binary_missing",
    "a stderr field is classified")

  -- Nil and hostile inputs never raise --------------------------------------

  local nilc, nilerr = recover.classify(nil)
  eq(nilerr, nil, "classify(nil) returns no error")
  eq(nilc.cause, "unknown", "classify(nil) is unknown")
  eq(nilc.transient, false, "classify(nil) is not transient")

  local threw = false
  pcall(function()
    recover.classify(42)
    recover.classify(true)
    recover.classify({})
    recover.record(nil, nil, nil)
    recover.decide(nil)
    recover.describe(nil)
    recover.describe({})
  end)
  eq(threw, false, "no input makes classify/record/decide/describe raise")

  eq(recover.decide(nil).action, "none", "decide(nil) is none")
  eq(recover.decide({ cause = "nothing_to_commit" }).action, "none",
    "decide on a benign diagnostic is none")

  -- record: attempt counting, timestamps and backoff ------------------------

  local f1 = recover.record("Could not resolve host: github.com", nil, { phase = "implement", now = 1000 })
  eq(f1.cause, "network", "record keeps the cause")
  eq(f1.attempts, 1, "the first record is attempt 1")
  eq(f1.phase, "implement", "record keeps the phase")
  eq(f1.at, 1000, "record stamps at now")
  eq(f1.next_retry_at, 1030, "attempt 1 waits the 30s base")

  local f2 = recover.record("Could not resolve host: github.com", f1, { now = 1000 })
  eq(f2.attempts, 2, "the second record is attempt 2")
  eq(f2.next_retry_at, 1060, "attempt 2 waits 60s")

  local f3 = recover.record("Could not resolve host: github.com", f2, { now = 1000 })
  eq(f3.next_retry_at, 1120, "attempt 3 waits 120s")

  -- Exponential backoff is capped at backoff_max_secs.
  eq(recover.backoff_secs(1), 30, "backoff attempt 1 is 30s")
  eq(recover.backoff_secs(2), 60, "backoff attempt 2 is 60s")
  eq(recover.backoff_secs(3), 120, "backoff attempt 3 is 120s")
  eq(recover.backoff_secs(4), 240, "backoff attempt 4 is 240s")
  eq(recover.backoff_secs(5), 480, "backoff attempt 5 is 480s")
  eq(recover.backoff_secs(6), 900, "backoff is capped at 900s")
  eq(recover.backoff_secs(50), 900, "backoff stays capped for a huge attempt count")

  -- Bounds are overridable per call.
  local custom = recover.record("timeout", nil,
    { now = 0, max_attempts = 5, backoff_base_secs = 10, factor = 3, backoff_max_secs = 100 })
  eq(custom.next_retry_at, 10, "a custom base is honoured")
  local custom2 = recover.record("timeout", custom,
    { now = 0, max_attempts = 5, backoff_base_secs = 10, factor = 3, backoff_max_secs = 100 })
  eq(custom2.next_retry_at, 30, "a custom factor is honoured")
  local custom3 = recover.record("timeout", custom2,
    { now = 0, max_attempts = 5, backoff_base_secs = 10, factor = 3, backoff_max_secs = 100 })
  eq(custom3.next_retry_at, 90, "a custom factor grows exponentially")
  local custom4 = recover.record("timeout", custom3,
    { now = 0, max_attempts = 5, backoff_base_secs = 10, factor = 3, backoff_max_secs = 100 })
  eq(custom4.next_retry_at, 100, "a custom cap is honoured")
  eq(recover.decide(custom4, { max_attempts = 5 }).action, "auto_retry",
    "the custom attempt bound is honoured")
  eq(recover.decide(custom4, { max_attempts = 5 }).max_attempts, 5,
    "decide reports the overridden max_attempts")

  -- decide: auto_retry under the bound, human beyond it ---------------------

  local d1 = recover.decide(f1, { now = 1000 })
  eq(d1.action, "auto_retry", "a transient failure under the bound is auto-retried")
  eq(d1.delay_secs, 30, "the decision carries the remaining delay")
  eq(d1.max_attempts, 3, "the decision carries the attempt bound")
  eq(d1.phase, "implement", "the decision carries the phase")

  local d3 = recover.decide(f3, { now = 1000 })
  eq(d3.action, "human", "attempt 3 of 3 escalates to a human")
  eq(d3.reason:find("budget", 1, true) ~= nil, true, "the escalation reason names the budget")
  local f4 = recover.record("Could not resolve host: github.com", f3, { now = 1000 })
  eq(f4.attempts, 4, "the fourth record is attempt 4")
  eq(recover.decide(f4, { now = 1000 }).action, "human", "attempt 4 stays escalated")
  local d2 = recover.decide(f2, { now = 1000 })
  eq(d2.action, "auto_retry", "attempt 2 of 3 is still under the bound")

  -- auth and unknown escalate immediately, whatever the attempt count.
  local auth_fail = recover.record("HTTP 401 Unauthorized", nil, { now = 0 })
  eq(recover.decide(auth_fail, { now = 0 }).action, "human", "auth escalates at once")
  local unknown_fail = recover.record("something inexplicable", nil, { now = 0 })
  eq(recover.decide(unknown_fail, { now = 0 }).action, "human", "unknown escalates at once")
  local benign_fail = recover.record("nothing to commit, working tree clean", nil, { now = 0 })
  eq(recover.decide(benign_fail, { now = 0 }).action, "none", "a benign diagnostic is none")

  -- describe ---------------------------------------------------------------

  local line = recover.describe(f1)
  eq(type(line), "string", "describe returns a string")
  eq(line:find("\n", 1, true), nil, "describe stays on one line")
  eq(line:find("network", 1, true), 1, "describe starts with the cause")
  eq(line:find("check the network", 1, true) ~= nil, true, "describe includes the remedy")
  eq(line:find("retry", 1, true) ~= nil, true, "describe includes the action")
  eq(line:find("1/3", 1, true) ~= nil, true, "describe includes the attempt count")
  eq(line:find("next at", 1, true) ~= nil, true, "describe includes the next retry time")
end
