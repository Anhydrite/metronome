-- Tests for maki/lua/metronome/runner.lua (REQ-20261114-16).
--
-- No token is spent: open_session is injected, so the retry policy, the run
-- directory and the cost arithmetic are exercised against fake sessions.

return function()
  local runner = load_module("runner")

  local function tmp_root(label)
    local base = maki.env.state_dir()
    local root = maki.fs.joinpath(base, "metronome-tests", label)
    local entries = maki.fs.dir(root)
    if entries then
      for _, e in ipairs(entries) do
        maki.fs.rm(maki.fs.joinpath(root, e[1]), { recursive = true })
      end
    end
    maki.fs.mkdir(root, { parents = true })
    return root
  end

  -- A fake session that replies with a scripted sequence.
  local function scripted(steps)
    local i = 0
    return function()
      i = i + 1
      local step = steps[i] or steps[#steps]
      if step == "open-fail" then
        return nil, "no such model"
      end
      return {
        id = function() return "task-" .. i end,
        close = function() end,
        prompt = function(_, _msg)
          if step == "fail" then
            return nil, "upstream 500"
          elseif step == "cancel" then
            return nil, "stopped by user"
          elseif step == "slow" then
            return { text = "late", input_tokens = 5, output_tokens = 5 }
          end
          return { text = step.text or "ok", input_tokens = step.tokens_in or 10, output_tokens = step.tokens_out or 20 }
        end,
      }
    end
  end

  -- Error classification -----------------------------------------------------

  eq(runner.classify_error(nil), "none", "no error is none")
  eq(runner.classify_error("upstream 500"), "retryable", "upstream error is retryable")
  eq(runner.classify_error("cancelled"), "fatal", "cancelled is fatal")
  eq(runner.classify_error("stopped by user"), "fatal", "user stop is fatal")
  eq(runner.classify_error("stopped by parent agent"), "fatal", "parent stop is fatal")
  eq(runner.classify_error("session closed"), "fatal", "closed session is fatal")
  eq(runner.classify_error("Cancelled"), "fatal", "classification ignores case")

  -- Run directory layout -----------------------------------------------------

  local layout = runner.run_dir("/root", "T-20261114-a3f2", "implement", 2)
  eq(layout, "/root/runs/T-20261114-a3f2/implement/2", "run dir is <root>/runs/<task>/<phase>/<n>")

  -- Happy path ---------------------------------------------------------------

  local root = tmp_root("runner-ok")
  local res = runner.run({
    role = "implementer",
    task_id = "T-20261114-a3f2",
    phase = "implement",
    prompt = "do the thing",
    state_root = root,
    open_session = scripted({ { text = "done", tokens_in = 100, tokens_out = 40 } }),
  })
  eq(res.ok, true, "successful run is ok")
  eq(res.text, "done", "text captured")
  eq(res.attempts, 1, "one attempt")
  eq(res.input_tokens, 100, "input tokens captured")
  eq(res.output_tokens, 40, "output tokens captured")
  eq(res.fatal, nil, "success is not fatal")

  local prompt_file = maki.fs.read(maki.fs.joinpath(res.run_dir, "prompt.txt"))
  eq(prompt_file, "do the thing", "prompt persisted")
  local meta = maki.fs.read(maki.fs.joinpath(res.run_dir, "meta.json"))
  eq(meta ~= nil and meta:find("done") ~= nil, true, "meta persisted")
  local result_file = maki.fs.read(maki.fs.joinpath(res.run_dir, "result.json"))
  eq(result_file ~= nil, true, "result persisted")

  -- Retry then success -------------------------------------------------------

  local root2 = tmp_root("runner-retry")
  local res2 = runner.run({
    role = "implementer",
    task_id = "T-20261114-a3f2",
    phase = "implement",
    prompt = "retry me",
    state_root = root2,
    max_attempts = 3,
    open_session = scripted({ "fail", "fail", { text = "third time", tokens_in = 7, tokens_out = 3 } }),
  })
  eq(res2.ok, true, "retry eventually succeeds")
  eq(res2.attempts, 3, "took three attempts")
  eq(res2.input_tokens, 7, "tokens accumulate only from the successful attempt's reply")
  local attempt3 = maki.fs.read(maki.fs.joinpath(root2, "runs", "T-20261114-a3f2", "implement", "3", "meta.json"))
  eq(attempt3 ~= nil, true, "each attempt gets its own directory")

  -- Exhausted retries --------------------------------------------------------

  local root3 = tmp_root("runner-exhaust")
  local res3 = runner.run({
    role = "implementer",
    task_id = "T-20261114-a3f2",
    phase = "implement",
    prompt = "never works",
    state_root = root3,
    max_attempts = 2,
    open_session = scripted({ "fail" }),
  })
  eq(res3.ok, false, "exhausted run is not ok")
  eq(res3.attempts, 2, "stopped at max_attempts")
  eq(res3.exhausted, true, "marked exhausted")
  eq(res3.error ~= nil and res3.error:find("500") ~= nil, true, "last error kept")

  -- A fatal error must not be retried ---------------------------------------

  local root4 = tmp_root("runner-fatal")
  local res4 = runner.run({
    role = "implementer",
    task_id = "T-20261114-a3f2",
    phase = "implement",
    prompt = "stop me",
    state_root = root4,
    max_attempts = 5,
    open_session = scripted({ "cancel" }),
  })
  eq(res4.ok, false, "user stop is not ok")
  eq(res4.attempts, 1, "a fatal error is not retried")
  eq(res4.fatal, true, "marked fatal")

  -- Session open failure is fatal, not retried ------------------------------

  local res5 = runner.run({
    role = "implementer",
    task_id = "T-20261114-a3f2",
    phase = "implement",
    prompt = "no model",
    max_attempts = 5,
    open_session = scripted({ "open-fail" }),
  })
  eq(res5.ok, false, "open failure is not ok")
  eq(res5.attempts, 1, "open failure is not retried")
  eq(res5.fatal, true, "open failure is fatal")

  -- Deadline ----------------------------------------------------------------

  local ticks = { 0, 0, 100, 200 }
  local ti = 0
  local fake_clock = function()
    ti = ti + 1
    return ticks[ti] or 200
  end
  local res6 = runner.run({
    role = "implementer",
    task_id = "T-20261114-a3f2",
    phase = "implement",
    prompt = "slow",
    deadline_secs = 10,
    max_attempts = 1,
    clock = fake_clock,
    open_session = scripted({ "slow" }),
  })
  eq(res6.ok, false, "a run past its deadline is not ok")
  eq(res6.timed_out, true, "marked timed out")
  eq(res6.error ~= nil and res6.error:find("timed out") ~= nil, true, "timeout explains itself")

  -- Bad input ---------------------------------------------------------------

  local res7 = runner.run({})
  eq(res7.ok, false, "missing prompt is refused")
  eq(res7.attempts, 0, "refused before any attempt")

  local res8 = runner.run("not a table")
  eq(res8.ok, false, "non-table options refused")

  -- Tool resolution ---------------------------------------------------------

  local seen_tools = nil
  local capture_session = function(_, opts)
    seen_tools = opts.tools
    return {
      id = function() return "task" end,
      close = function() end,
      prompt = function()
        return { text = "ok", input_tokens = 1, output_tokens = 1 }
      end,
    }
  end

  runner.run({
    role = "implementer",
    prompt = "write it",
    state_root = root,
    open_session = capture_session,
    resolve_tools = function(_, tools)
      return { { name = "write", schema = {} }, { name = "bash", schema = {} } }
    end,
  })
  eq(type(seen_tools), "table", "the session receives resolved tool definitions")
  eq(seen_tools and seen_tools[1] and seen_tools[1].name, "write", "the resolved tools reach the session")

  seen_tools = nil
  local defs = { { name = "read", schema = {} } }
  runner.run({
    role = "reviewer",
    prompt = "review it",
    state_root = root,
    tools = defs,
    open_session = capture_session,
    resolve_tools = function(_, tools)
      return tools
    end,
  })
  eq(seen_tools, defs, "already-resolved definitions pass through unchanged")
end
