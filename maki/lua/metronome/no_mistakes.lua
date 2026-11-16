-- no-mistakes: the reviewer's cleaning gate.
--
-- `no-mistakes` (https://github.com/kunchenguid/no-mistakes) is a local git
-- gate: it rebases, reviews, tests, documents and lints a branch, pushes it,
-- opens the PR and watches CI, applying safe fixes along the way. Metronome
-- uses it as the review engine so a task does not bounce between review and
-- implementation: the gate either cleans the branch and opens a mergeable PR,
-- or reports why it could not, and the task fails instead of looping.
--
-- The command surface is `no-mistakes axi run`, the non-interactive agent
-- interface. It prints TOON to stdout and progress to stderr; the exit code is
-- the verdict. A missing binary is reported, never guessed around: the feature
-- needs `no-mistakes init` to have configured the gate for the repository.
--
-- Every function returns `(value, err)` and never raises.

local M = {}

local function run(args, opts)
  opts = opts or {}
  local job_opts = {
    cwd = opts.cwd,
    tail = opts.tail or 400,
  }
  local ok_start, job, err = pcall(maki.fn.jobstart, args, job_opts)
  if not ok_start then
    err = job
    job = nil
  end
  if not job and tostring(err):find("no active task", 1, true) then
    job_opts.scope = "plugin"
    local ok_retry, retry_job, retry_err = pcall(maki.fn.jobstart, args, job_opts)
    if ok_retry then
      job, err = retry_job, retry_err
    else
      job, err = nil, retry_job
    end
  end
  if not job then
    return nil, "cannot start no-mistakes: " .. tostring(err)
  end
  local result, werr = maki.fn.jobwait(job, opts.timeout_ms or 1800000)
  if not result then
    return nil, "no-mistakes did not finish: " .. tostring(werr)
  end
  return {
    code = result.exit_code,
    stdout = result.stdout or "",
    stderr = result.stderr or "",
    command = table.concat(args, " "),
    ok = result.exit_code == 0,
  }
end

M.run_cmd = run

-- True when the binary answers its version probe. The pipeline refuses early
-- with a named reason instead of spending an implementation turn first.
function M.available(opts)
  opts = type(opts) == "table" and opts or {}
  local result = run({ opts.bin or "no-mistakes", "--version" }, {
    cwd = opts.cwd,
    timeout_ms = opts.timeout_ms or 10000,
  })
  return result ~= nil and result.code == 0
end

-- Run the gate on the task branch. `opts.intent` is the user's goal, not a
-- description of the diff; `opts.base` is the integration branch. Returns
-- `{ ok, approved, code, output }` on success and `(nil, err)` when the gate
-- could not run at all. A gate that ran and failed is a verdict, not an error:
-- `ok = false` with the output, so the caller can report it without looping.
function M.run(opts)
  opts = type(opts) == "table" and opts or {}
  local intent = tostring(opts.intent or "")
  if intent:gsub("%s", "") == "" then
    return nil, "no-mistakes needs an intent"
  end
  local bin = opts.bin or "no-mistakes"
  local args = { bin, "axi", "run", "--intent", intent }
  if opts.yes ~= false then
    args[#args + 1] = "--yes"
  end
  if type(opts.base) == "string" and opts.base ~= "" then
    args[#args + 1] = "--base-branch"
    args[#args + 1] = opts.base
  end
  -- `axi run` holds the caller for 8 minutes by default, then returns while the
  -- run is still working. That return is not a verdict: treating it as one
  -- failed a task whose gate was mid-fix. Hold for the task's own timeout.
  if type(opts.wait) == "string" and opts.wait ~= "" then
    args[#args + 1] = "--wait"
    args[#args + 1] = opts.wait
  end
  if type(opts.skip) == "string" and opts.skip ~= "" then
    args[#args + 1] = "--skip"
    args[#args + 1] = opts.skip
  end
  local result, err = run(args, {
    cwd = opts.worktree,
    timeout_ms = opts.timeout_ms or 1800000,
    tail = opts.tail or 400,
  })
  if not result then
    return nil, err
  end
  local output = tostring(result.stdout or "") .. tostring(result.stderr or "")
  if result.code == 0 then
    return { ok = true, approved = true, code = 0, output = output }
  end
  return {
    ok = false,
    approved = false,
    code = result.code,
    output = output,
    error = string.format("no-mistakes did not pass (exit %s)", tostring(result.code)),
  }
end

return M
