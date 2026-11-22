-- Tests for per-task XDG_STATE_HOME isolation in checks.lua (T-20261122-0032).
--
-- A declared check is often a third-party command (a shop, an application
-- script) that keeps state under XDG_STATE_HOME. Two tasks running at the same
-- time used to share the inherited directory, reset each other's state and
-- produce false failures. Each execution now owns an XDG_STATE_HOME, created
-- on disk, that the other cannot see; an explicit value wins verbatim, a
-- command that sets the variable itself is never rewritten, and an unscoped
-- run (a unit test, a tool) keeps the inherited environment untouched.

return function()
  local checks = load_module("checks")
  local fs = maki.fs

  local base = test_base("checks-xdg")
  local work = fs.joinpath(base, "work")
  fs.mkdir(work, { parents = true })

  local root_a = fs.joinpath(base, "root-a")
  local root_b = fs.joinpath(base, "root-b")
  fs.mkdir(root_a, { parents = true })
  fs.mkdir(root_b, { parents = true })

  local function run(command, opts)
    opts = opts or {}
    local request = { worktree = work, root = opts.root, task_id = opts.task_id }
    if opts.xdg_state_home ~= nil then
      request.xdg_state_home = opts.xdg_state_home
    end
    local result, err = checks.run({ command }, request)
    eq(err, nil, "check run has no error: " .. tostring(err))
    eq(result ~= nil, true, "check run returns a result")
    local entry = result and result.results[1] or {}
    return result, entry
  end

  -- Two tasks, two roots: two distinct directories, both on disk, and what one
  -- writes the other never sees.
  local first, first_entry = run(
    [[printf '%s' "$XDG_STATE_HOME"; : > "$XDG_STATE_HOME/from-A"]],
    { root = root_a, task_id = "T-A" })
  local state_a = fs.joinpath(root_a, "checks", "T-A", "state")
  eq(first and first.ok, true, "task A check is green")
  eq(first_entry.stdout, state_a, "task A child sees its own state directory")
  eq(first_entry.xdg_state_home, state_a, "task A result records the injected value")
  eq(fs.dir(state_a) ~= nil, true, "task A state directory exists on disk")
  eq(fs.read(fs.joinpath(state_a, "from-A")) ~= nil, true, "task A wrote its marker")

  local second, second_entry = run([[
test ! -e "$XDG_STATE_HOME/from-A" || { echo "saw task A state"; exit 1; }
printf '%s' "$XDG_STATE_HOME"
: > "$XDG_STATE_HOME/from-B"
]], { root = root_b, task_id = "T-B" })
  local state_b = fs.joinpath(root_b, "checks", "T-B", "state")
  eq(second and second.ok, true, "task B check is green: " .. tostring(second_entry.stdout))
  eq(second_entry.stdout, state_b, "task B child sees its own state directory")
  eq(second_entry.xdg_state_home, state_b, "task B result records the injected value")
  eq(state_a ~= state_b, true, "the two tasks see two different XDG_STATE_HOME")
  eq(fs.read(fs.joinpath(state_b, "from-A")) == nil, true, "task B cannot see task A's file")

  -- The isolation holds the other way round too.
  local again, again_entry = run(
    [[test ! -e "$XDG_STATE_HOME/from-B"]],
    { root = root_a, task_id = "T-A" })
  eq(again and again.ok, true, "task A cannot see task B's file")
  eq(again_entry.xdg_state_home, state_a, "task A keeps the same directory across runs")

  -- An unscoped run (unit test, tool) injects nothing: the inherited value
  -- survives, whatever it is.
  local inherited = maki.uv.os_getenv("XDG_STATE_HOME") or ""
  local _, loose_entry = run([[printf '%s' "${XDG_STATE_HOME:-}"]], {})
  eq(loose_entry.xdg_state_home, nil, "unscoped run records no injected value")
  eq(loose_entry.stdout, inherited, "unscoped run keeps the inherited XDG_STATE_HOME")

  -- An explicit value wins verbatim over the per-task directory.
  local explicit = fs.joinpath(base, "explicit-state")
  fs.mkdir(explicit, { parents = true })
  local _, explicit_entry = run([[printf '%s' "$XDG_STATE_HOME"]],
    { root = root_a, task_id = "T-C", xdg_state_home = explicit })
  eq(explicit_entry.stdout, explicit, "explicit xdg_state_home wins verbatim")
  eq(explicit_entry.xdg_state_home, explicit, "the explicit value is the one recorded")
  eq(fs.dir(fs.joinpath(root_a, "checks", "T-C", "state")) == nil, true,
    "no per-task directory is created when the value is explicit")

  -- A command that pins XDG_STATE_HOME itself is never rewritten, even when
  -- the call is scoped.
  local own = fs.joinpath(base, "own-state")
  fs.mkdir(own, { parents = true })
  local _, own_entry = run(
    string.format([[XDG_STATE_HOME='%s' sh -c 'printf "%%s" "$XDG_STATE_HOME"']], own),
    { root = root_a, task_id = "T-D" })
  eq(own_entry.stdout, own, "a command's own XDG_STATE_HOME is left intact")
  eq(own_entry.xdg_state_home, nil, "nothing is injected when the command sets the variable")
  eq(fs.dir(fs.joinpath(root_a, "checks", "T-D", "state")) == nil, true,
    "no per-task directory is created when the command sets the variable")
end
