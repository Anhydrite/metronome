-- Tests for maki/lua/metronome/state.lua (REQ-20261114-12).
--
-- Run inside maki's Lua host by the harness; each case uses a fresh temp root.

return function()
  local state = load_module("state")

  local function tmp_root(label)
    local base = maki.env.state_dir()
    local root = maki.fs.joinpath(base, "metronome-tests", label)
    -- Start clean so a rerun is not polluted by the previous one.
    local entries = maki.fs.dir(root)
    if entries then
      for _, e in ipairs(entries) do
        maki.fs.rm(maki.fs.joinpath(root, e[1]), { recursive = true })
      end
    end
    maki.fs.mkdir(root, { parents = true })
    return root
  end

  -- Transitions -------------------------------------------------------------

  eq(state.can_transition("draft", "qualifying"), true, "draft -> qualifying allowed")
  eq(state.can_transition("ready", "running"), true, "ready -> running allowed")
  eq(state.can_transition("running", "verifying"), true, "running -> verifying allowed")
  eq(state.can_transition("reviewing", "pr_open"), true, "reviewing -> pr_open allowed")
  eq(state.can_transition("merged", "deploying"), true, "merged -> deploying allowed")
  eq(state.can_transition("draft", "merged"), false, "draft -> merged refused")
  eq(state.can_transition("deployed", "running"), false, "deployed -> running refused")
  eq(state.can_transition("abandoned", "draft"), false, "abandoned -> draft refused")
  eq(state.can_transition("abandoned", "running"), true, "abandoned -> running allowed for retry")
  eq(state.can_transition("abandoned", "failed"), true, "abandoned -> failed allowed for escalation")
  eq(state.can_transition("running", "running"), true, "same status is a no-op")

  eq(state.is_terminal("merged"), true, "merged is terminal")
  eq(state.is_terminal("deployed"), true, "deployed is terminal")
  eq(state.is_terminal("running"), false, "running is not terminal")

  -- The refusal must be actionable: a caller that hit an illegal transition
  -- needs to know what it could have asked for instead.
  local allowed = state.allowed_from("qualifying")
  eq(type(allowed), "table", "allowed_from returns a list")
  local set = {}
  for _, v in ipairs(allowed) do set[v] = true end
  eq(set.ready, true, "allowed_from includes ready")
  eq(set.awaiting_answers, true, "allowed_from includes awaiting_answers")
  eq(set.merged, nil, "allowed_from excludes merged")

  local none = state.allowed_from("deployed")
  eq(#none, 0, "a terminal status allows nothing")

  local unknown_status = state.allowed_from("nonsense")
  eq(#unknown_status, 0, "an unknown status allows nothing")

  -- Journal parsing ---------------------------------------------------------

  eq(state.parse_line(""), nil, "blank line ignored")
  eq(state.parse_line("   "), nil, "whitespace line ignored")
  eq(state.parse_line("{not json"), nil, "corrupt line ignored")
  eq(state.parse_line('{"no_kind":true}'), nil, "event without kind ignored")

  local event = state.parse_line('{"kind":"status","task_id":"T-20261114-a3f2","status":"ready"}')
  eq(type(event), "table", "valid line parsed")
  eq(event and event.status, "ready", "status field read")

  -- Replay ------------------------------------------------------------------

  local journal = table.concat({
    '{"kind":"task_created","task_id":"T-20261114-a3f2","task":{"id":"T-20261114-a3f2","title":"one","status":"draft"}}',
    '{"kind":"status","task_id":"T-20261114-a3f2","status":"qualifying"}',
    '{"kind":"field","task_id":"T-20261114-a3f2","fields":{"branch":"metronome/T-20261114-a3f2"}}',
    '{"kind":"note","task_id":"T-20261114-a3f2","text":"hello"}',
    '{"kind":"status","task_id":"T-20261114-a3f2","status":"ready"}',
    'this line is torn',
  }, "\n")

  local replayed = state.replay(journal)
  eq(replayed.events, 5, "five valid events replayed")
  eq(replayed.tasks["T-20261114-a3f2"].status, "ready", "last status wins")
  eq(replayed.tasks["T-20261114-a3f2"].branch, "metronome/T-20261114-a3f2", "field event applied")
  eq(replayed.tasks["T-20261114-a3f2"].notes[1], "hello", "note appended")
  eq(replayed.tasks["T-20261114-a3f2"].title, "one", "created fields kept")

  -- A torn last line must not destroy the replay.
  local torn = state.replay(journal .. '\n{"kind":"status","task_id":"T-20261114-a3f2","sta')
  eq(torn.tasks["T-20261114-a3f2"].status, "ready", "torn tail ignored, state intact")

  -- Create / transition / field round trip --------------------------------

  local root = tmp_root("roundtrip")
  local created, cerr = state.create(root, { id = "T-20261114-a3f2", title = "first" })
  eq(cerr, nil, "create has no error")
  eq(created and created.status, "draft", "created task is draft")

  local dup, derr = state.create(root, { id = "T-20261114-a3f2", title = "again" })
  eq(dup, nil, "duplicate create returns nil")
  eq(derr ~= nil, true, "duplicate create explains itself")

  -- delete hides a task on replay -------------------------------------------
  state.create(root, { id = "T-20261114-dead", title = "to delete" })
  local dead_task = state.load(root).tasks["T-20261114-dead"]
  local archive_path = state.archive(root, dead_task, { sheet = "# to delete\n" })
  eq(type(archive_path), "string", "archive writes a snapshot")
  local archived = state.archived(root)
  eq(#archived, 1, "archived lists the snapshot")
  eq(archived[1].id, "T-20261114-dead", "archived names the task")
  eq(archived[1].title, "to delete", "archived keeps the title")
  local snapshot = maki.json.decode(maki.fs.read(archive_path))
  eq(snapshot and snapshot.sheet, "# to delete\n", "archive keeps the sheet text")
  eq(state.delete(root, "T-20261114-dead"), true, "delete removes a task")
  eq(state.load(root).tasks["T-20261114-dead"], nil, "deleted task is gone from load")
  eq(state.load(root).ids["T-20261114-dead"], true, "a deleted id stays reserved")
  eq(#state.archived(root), 1, "the archive survives the delete")
  eq(state.delete(root, "T-20261114-dead"), nil, "deleting an unknown task fails")

  local moved, merr = state.transition(root, "T-20261114-a3f2", "qualifying")
  eq(merr, nil, "legal transition has no error")
  eq(moved and moved.status, "qualifying", "status moved")

  -- A failure keeps its reason: the journal, the projection and the panel all
  -- read it, instead of a bare "task failed".
  state.create(root, { id = "T-20261114-b001", title = "will fail" })
  state.transition(root, "T-20261114-b001", "qualifying")
  local failed = state.transition(root, "T-20261114-b001", "failed", { reason = "checks exited 1" })
  eq(failed and failed.status, "failed", "task moved to failed")
  eq(failed and failed.failure_reason, "checks exited 1", "failure reason persisted")
  local reloaded = state.load(root)
  eq(reloaded.tasks["T-20261114-b001"].failure_reason, "checks exited 1",
    "failure reason survives a replay")

  local bad, berr = state.transition(root, "T-20261114-a3f2", "merged")
  eq(bad, nil, "illegal transition returns nil")
  eq(berr and berr:find("illegal transition") ~= nil, true, "illegal transition explains itself")
  eq(berr and berr:find("qualifying") ~= nil, true, "refusal names the current status")
  eq(berr and berr:find("merged") ~= nil, true, "refusal names the refused status")
  eq(berr and berr:find("ready") ~= nil, true, "refusal lists an allowed alternative")
  eq(berr and berr:find("T-20261114-a3f2", 1, true) ~= nil, true, "refusal names the task")

  local unknown, uerr = state.transition(root, "nope", "ready")
  eq(unknown, nil, "unknown task returns nil")
  eq(uerr and uerr:find("unknown task") ~= nil, true, "unknown task explains itself")

  local fielded = state.set_fields(root, "T-20261114-a3f2", { branch = "metronome/T-20261114-a3f2", files = { "a.lua" } })
  eq(fielded and fielded.branch, "metronome/T-20261114-a3f2", "field set")
  eq(fielded and fielded.files[1], "a.lua", "array field set")

  -- The projection must match a replay of the journal.
  local loaded = state.load(root)
  eq(loaded.tasks["T-20261114-a3f2"].status, "qualifying", "projection has the status")
  eq(loaded.tasks["T-20261114-a3f2"].branch, "metronome/T-20261114-a3f2", "projection has the field")

  local paths = state.paths(root)
  local journal_text = maki.fs.read(paths.journal)
  eq(journal_text ~= nil, true, "journal exists")
  local replayed_again = state.replay(journal_text)
  eq(replayed_again.tasks["T-20261114-a3f2"].status, loaded.tasks["T-20261114-a3f2"].status, "projection matches replay")

  -- Losing the projection must not lose the state: it is rebuilt from the
  -- journal, which is the whole point of an append-only log.
  maki.fs.rm(paths.projection)
  local rebuilt = state.load(root)
  eq(rebuilt.tasks["T-20261114-a3f2"].status, "qualifying", "state rebuilt without the projection")
  eq(rebuilt.tasks["T-20261114-a3f2"].branch, "metronome/T-20261114-a3f2", "fields rebuilt without the projection")

  -- Crash window: the journal is appended first and the projection written
  -- after, so a kill in between leaves a projection that is behind. Loading
  -- must notice and replay instead of serving stale state.
  local crash_root = tmp_root("crash-window")
  local crash_paths = state.paths(crash_root)
  maki.fs.mkdir(crash_root, { parents = true })
  maki.fs.write(crash_paths.journal, table.concat({
    '{"kind":"task_created","task_id":"T-20261114-a3f2","task":{"id":"T-20261114-a3f2","title":"crash","status":"draft"}}',
    '{"kind":"status","task_id":"T-20261114-a3f2","status":"qualifying"}',
    '{"kind":"status","task_id":"T-20261114-a3f2","status":"ready"}',
  }, "\n") .. "\n")
  -- A projection written after only the first event.
  maki.fs.write(crash_paths.projection, maki.json.encode({
    events = 1,
    tasks = { ["T-20261114-a3f2"] = { id = "T-20261114-a3f2", title = "crash", status = "draft" } },
  }))

  local recovered = state.load(crash_root)
  eq(recovered.events, 3, "stale projection is detected and replayed")
  eq(recovered.tasks["T-20261114-a3f2"].status, "ready", "recovered state has the latest status")

  -- A torn tail on top of that must still recover.
  maki.fs.append(crash_paths.journal, '{"kind":"status","task_id":"T-20261114-a3f2","sta')
  local after_torn = state.load(crash_root)
  eq(after_torn.events, 3, "torn tail does not add an event")
  eq(after_torn.tasks["T-20261114-a3f2"].status, "ready", "torn tail does not lose state")

  -- Deploy pending flag and single-flight lock -------------------------------

  local deploy_root = tmp_root("deploy-pending")

  local bad_base, bad_base_err = state.set_deploy_pending(deploy_root, "")
  eq(bad_base, nil, "deploy pending without a base is refused")
  eq(bad_base_err ~= nil, true, "empty base explains itself")

  local pending, perr = state.set_deploy_pending(deploy_root, "cafebabe")
  eq(perr, nil, "set_deploy_pending has no error")
  eq(pending and pending.base, "cafebabe", "pending records the base")
  eq(state.deploy_pending(deploy_root).base, "cafebabe", "pending is readable")

  -- The flag is journal-backed: losing the projection must not lose it.
  maki.fs.rm(state.paths(deploy_root).projection)
  eq(state.deploy_pending(deploy_root).base, "cafebabe", "pending replays without the projection")

  -- A second merge overwrites the base: there is only one thing to deploy.
  state.set_deploy_pending(deploy_root, "deadbeef")
  eq(state.deploy_pending(deploy_root).base, "deadbeef", "a newer base overwrites the pending one")

  -- Single-flight: one deployer at a time.
  local l1, l1err = state.acquire_deploy(deploy_root, "deployer-a")
  eq(l1err, nil, "first acquire succeeds")
  eq(l1 and l1.owner, "deployer-a", "lock names its owner")
  eq(state.deploy_lock(deploy_root).owner, "deployer-a", "lock is readable")

  local l2, l2err = state.acquire_deploy(deploy_root, "deployer-b")
  eq(l2, nil, "a second deployer is refused")
  eq(l2err and l2err:find("deployer-a", 1, true) ~= nil, true, "refusal names the holder")

  local reentrant = state.acquire_deploy(deploy_root, "deployer-a")
  eq(reentrant and reentrant.owner, "deployer-a", "the holder may re-acquire")

  local wrong_release = state.release_deploy(deploy_root, "deployer-b")
  eq(wrong_release, nil, "a non-holder cannot release")
  eq(state.deploy_lock(deploy_root).owner, "deployer-a", "failed release leaves the lock intact")

  eq(state.release_deploy(deploy_root, "deployer-a"), true, "the holder releases")
  eq(state.deploy_lock(deploy_root), nil, "released lock is gone")
  eq(state.release_deploy(deploy_root, "deployer-a"), nil, "releasing again fails")

  -- One deployer at a time: a refused acquire is inert. It must write no
  -- journal event and leave both the holder and the pending flag untouched, or
  -- a second deployer could silently disturb a drain that is already running.
  local flight_root = tmp_root("deploy-single-flight")
  state.set_deploy_pending(flight_root, "cafed00d")
  local first, first_err = state.acquire_deploy(flight_root, "deployer-first")
  eq(first_err, nil, "the first deployer takes the lock: " .. tostring(first_err))
  local events_before = state.load(flight_root).events

  local second, second_err = state.acquire_deploy(flight_root, "deployer-second")
  eq(second, nil, "a concurrent deployer is refused while the lock is held")
  has(second_err, "deploy lock held by deployer-first", "the refusal names the holder")
  eq(state.load(flight_root).events, events_before, "a refused acquire writes no journal event")
  eq(state.deploy_lock(flight_root).owner, "deployer-first", "the refused deployer does not take the lock")
  eq(state.deploy_pending(flight_root).base, "cafed00d", "the refused deployer leaves the pending flag alone")

  eq(state.release_deploy(flight_root, "deployer-first"), true, "the holder releases after the refusal")
  eq(state.deploy_lock(flight_root), nil, "the lock is free again")
  local next_lock, next_err = state.acquire_deploy(flight_root, "deployer-second")
  eq(next_lock and next_lock.owner, "deployer-second", "the lock is free once released: " .. tostring(next_err))
  state.release_deploy(flight_root, "deployer-second")

  -- A lock left by a crashed deployer can be taken over explicitly.
  state.acquire_deploy(deploy_root, "deployer-crashed")
  local stole = state.acquire_deploy(deploy_root, "deployer-next", { force = true })
  eq(stole and stole.owner, "deployer-next", "force takes over a stale lock")
  state.release_deploy(deploy_root, "deployer-next")

  eq(state.clear_deploy_pending(deploy_root), true, "clear_deploy_pending drops the marker")
  eq(state.deploy_pending(deploy_root), nil, "cleared pending is nil")
  eq(state.clear_deploy_pending(deploy_root), nil, "clearing twice fails")

  -- Crash/torn-write replay: the marker and the lock are rebuilt from the
  -- journal alone, with a half-written tail dropped.
  local deploy_crash = tmp_root("deploy-crash")
  local deploy_crash_paths = state.paths(deploy_crash)
  maki.fs.mkdir(deploy_crash, { parents = true })
  maki.fs.write(deploy_crash_paths.journal, table.concat({
    '{"kind":"deploy_pending","base":"0badf00d","at":"2026-11-14T10:00:00Z"}',
    '{"kind":"deploy_lock_acquired","owner":"deployer-a","at":"2026-11-14T10:01:00Z"}',
  }, "\n") .. "\n")
  maki.fs.append(deploy_crash_paths.journal, '{"kind":"deploy_pending_cleared"')

  local deploy_recovered = state.load(deploy_crash)
  eq(deploy_recovered.deploy.pending and deploy_recovered.deploy.pending.base, "0badf00d", "pending survives a torn write")
  eq(deploy_recovered.deploy.lock and deploy_recovered.deploy.lock.owner, "deployer-a", "lock survives a torn write")
  eq(deploy_recovered.events, 2, "torn deploy tail is not counted")

  -- Round trip through the real append path, on the root the schema check
  -- validates: the deploy events must be legal journal events too.
  state.set_deploy_pending(root, "feedface")
  state.acquire_deploy(root, "deployer-roundtrip")
  state.release_deploy(root, "deployer-roundtrip")
  eq(state.deploy_pending(root).base, "feedface", "roundtrip root has a pending base")

  -- An empty root is not an error.
  local empty_root = tmp_root("empty")
  local empty = state.load(empty_root)
  eq(type(empty.tasks), "table", "empty root loads")
  eq(empty.events, 0, "empty root has no events")
end
