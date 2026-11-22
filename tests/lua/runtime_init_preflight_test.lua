-- Tests for the preflight gate in runtime.init and runtime.config.
--
-- A project bound with a missing checker, no git identity or no origin branch
-- only fails on the first task, far from `/metronome init`. The runtime must
-- therefore run the preflight on the prospective answers *before* it writes a
-- config, and refuse with the preflight text instead of a silent success.

return function()
  local runtime = load_module("runtime")

  local function make_root(tag)
    local root = mktmpdir("metronome-init-preflight-" .. tag)
    local paths = {
      repo = "/tmp/repo",
      root = root,
      tasks = maki.fs.joinpath(root, "tasks"),
      worktrees = maki.fs.joinpath(root, "worktrees"),
      runs = maki.fs.joinpath(root, "runs"),
      prompts = maki.fs.joinpath(root, "prompts"),
      config = maki.fs.joinpath(root, "config.toml"),
    }
    return paths
  end

  -- A refusing verdict shaped like metronome.preflight.run's failures.
  local refusing_failure = {
    id = "checks-executable",
    command = "npm test",
    detail = "npm not found in PATH",
    remedy = "install node/npm or declare a check that exists",
  }

  local function refusing_preflight(calls)
    return {
      run = function(opts)
        if calls then
          calls.n = calls.n + 1
          calls.opts = opts
        end
        return {
          ok = false,
          checks = {},
          failures = { refusing_failure },
          message = "preflight failed",
        }
      end,
      format = function(result)
        local line = result.failures[1]
        return string.format("[%s] %s -- %s (remedy: %s)",
          line.id, line.command, line.detail, line.remedy)
      end,
    }
  end

  local function green_preflight(calls)
    return {
      run = function(opts)
        if calls then
          calls.n = calls.n + 1
          calls.opts = opts
        end
        return { ok = true, checks = {}, failures = {} }
      end,
      format = function() return "" end,
    }
  end

  local function make_deps(paths, preflight)
    return {
      config = {
        load = function()
          if not maki.fs.read(paths.config) then
            return nil, { "no config" }
          end
          return {
            project = { repo = "/tmp/repo", base_ref = "main", max_parallel = 1 },
            checks = { default = { "npm test" } },
            merge = { auto_merge = false },
            deploy = { auto_deploy = false, confirm = true },
            roles = {},
          }
        end,
      },
      roles = {
        session_opts = function()
          return { system = "", model_spec = "test/model", thinking = "low", tools = {} }
        end,
      },
      paths = function()
        return paths
      end,
      preflight = preflight,
      spawn = function(fn) fn() end,
      wait_turn_end = false,
      state = { load = function() return { tasks = {} } end },
      runner = {}, git = {}, qualify = {}, questions = {}, analyze = {},
      implement = {}, checks = {}, converge = {}, review = {}, merge = {},
      deploy = {}, calibrate = {}, pipeline = {}, fence = {}, mode = {},
    }
  end

  -- (a) A refusing preflight blocks init and leaves no config ----------------

  local paths = make_root("refuse")
  local calls = { n = 0 }
  local rt = runtime.new(make_deps(paths, refusing_preflight(calls)))
  eq(type(rt), "table", "runtime wires with a refusing preflight")

  local refused = rt.init({ defaults = true })
  eq(type(refused), "table", "init returns a result table")
  eq(refused and refused.ok, false, "a refusing preflight blocks init")
  eq(calls.n, 1, "init runs the preflight once")
  eq(type(refused and refused.preflight), "table", "the refusal carries the preflight verdict")
  has(tostring(refused and refused.error), "checks-executable", "the error names the failing check id")
  has(tostring(refused and refused.error), "npm test", "the error names the declared command")
  has(tostring(refused and refused.error), "install node/npm", "the error carries the remedy")
  eq(maki.fs.read(paths.config), nil, "a refused init writes no config")
  eq(maki.fs.read(maki.fs.joinpath(paths.prompts, "implementer.md")), nil,
    "a refused init writes no prompts")

  -- The prospective answers, not the current config, feed the preflight.
  eq(type(calls.opts), "table", "preflight receives the prospective answers")
  eq(calls.opts and calls.opts.repo, "/tmp/repo", "preflight receives the repo")
  eq(calls.opts and calls.opts.base_ref, "main", "preflight receives the base branch")
  eq(type(calls.opts and calls.opts.checks), "table", "preflight receives the checks")

  -- The pure question-asking path writes nothing and does not preflight.
  calls = { n = 0 }
  local ask_paths = make_root("ask")
  local rt_ask = runtime.new(make_deps(ask_paths, refusing_preflight(calls)))
  local asked = rt_ask.init({})
  eq(type(asked and asked.questions), "table", "init without answers returns the questions")
  eq(calls.n, 0, "the question path does not run the preflight")
  eq(maki.fs.read(ask_paths.config), nil, "the question path writes nothing")

  -- (b) A green preflight lets init write the config -------------------------

  local green_paths = make_root("green")
  local green_calls = { n = 0 }
  local rt_green = runtime.new(make_deps(green_paths, green_preflight(green_calls)))
  local bound = rt_green.init({ defaults = true })
  eq(bound and bound.ok, true, "a green preflight lets init succeed")
  eq(green_calls.n, 1, "the green init ran the preflight")
  has(tostring(bound and bound.message), "Metronome bound to", "init keeps its previous message shape")
  eq(type(maki.fs.read(green_paths.config)), "string", "the green init writes config.toml")
  eq(type(maki.fs.read(maki.fs.joinpath(green_paths.prompts, "reviewer.md"))), "string",
    "the green init copies the prompts")

  -- (c) A refusing preflight blocks a config update, byte for byte -----------

  local upd_paths = make_root("update")
  maki.fs.mkdir(upd_paths.root, { parents = true })
  local original = "[project]\nrepo = \"/tmp/repo\"\nbase_ref = \"main\"\n"
  maki.fs.write(upd_paths.config, original)

  local upd_calls = { n = 0 }
  local rt_upd = runtime.new(make_deps(upd_paths, refusing_preflight(upd_calls)))
  local unchanged = rt_upd.config({ answers = { base_ref = "develop" } })
  eq(unchanged and unchanged.ok, false, "a refusing preflight blocks a config update")
  eq(upd_calls.n, 1, "the config update ran the preflight")
  has(tostring(unchanged and unchanged.error), "checks-executable", "the update error names the check id")
  eq(maki.fs.read(upd_paths.config), original, "a refused update leaves the config byte-identical")

  -- (d) No preflight dependency is a refusal, never a silent success --------

  local bare_paths = make_root("bare")
  local rt_bare = runtime.new(make_deps(bare_paths, nil))
  local bare_init = rt_bare.init({ defaults = true })
  eq(bare_init and bare_init.ok, false, "init without deps.preflight refuses")
  has(tostring(bare_init and bare_init.error), "preflight is not wired",
    "the refusal says preflight is not wired")
  eq(maki.fs.read(bare_paths.config), nil, "the preflight-less init writes no config")

  maki.fs.mkdir(bare_paths.root, { parents = true })
  maki.fs.write(bare_paths.config, original)
  local bare_cfg = rt_bare.config({ answers = { base_ref = "develop" } })
  eq(bare_cfg and bare_cfg.ok, false, "config without deps.preflight refuses")
  has(tostring(bare_cfg and bare_cfg.error), "preflight is not wired",
    "the config refusal says preflight is not wired")
  eq(maki.fs.read(bare_paths.config), original, "the preflight-less config update writes nothing")
end
