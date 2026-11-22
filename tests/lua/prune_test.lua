-- Tests for runtime.prune: it reconciles GitHub with the journal without ever
-- destroying a retryable task.
--
-- Regression: a failed task was treated as dead, so prune closed its PR and
-- deleted its remote branch. A failed task is retryable by construction: its
-- branch, PR, checkpoints and worktree are exactly what `metronome_retry`
-- resumes from. Only an explicitly abandoned task, or a branch/PR whose task
-- is gone from the journal, may be cleaned, and the report must say why.

return function()
  local runtime = load_module("runtime")

  local function make_runtime(tasks, prs, branches, hooks)
    hooks = hooks or {}
    local deps = {
      config = {
        load = function()
          return {
            project = { repo = "/tmp/repo", base_ref = "main" },
            git = { branch_prefix = "metronome/" },
          }
        end,
      },
      roles = {
        session_opts = function()
          return { system = "", model_spec = "m", thinking = "low", tools = {} }
        end,
      },
      state = {
        load = function() return { tasks = tasks } end,
      },
      git = {
        list_open_prs = function()
          return prs
        end,
        list_branches = function()
          return branches
        end,
        pr_close = function(ref)
          if hooks.pr_close then hooks.pr_close(ref) end
          return { closed = true }
        end,
        delete_branch = function(_, branch)
          if hooks.delete_branch then hooks.delete_branch(branch) end
          return { ok = true }
        end,
      },
      paths = function()
        return { root = "/tmp/root", config = "/tmp/config.toml", repo = "/tmp/repo" }
      end,
      spawn = function(fn) fn() end,
      wait_turn_end = false,
      runner = {}, qualify = {}, questions = {}, analyze = {}, implement = {},
      checks = {}, converge = {}, review = {}, merge = {}, deploy = {},
      pipeline = {}, calibrate = {}, fence = {}, mode = {},
    }
    return runtime.new(deps)
  end

  local function find_kept(result, task_id)
    for _, entry in ipairs(result.kept or {}) do
      if entry.task == task_id then return entry end
    end
    return nil
  end

  local function find_deleted(result, branch)
    for _, entry in ipairs(result.deleted or {}) do
      if entry.branch == branch then return entry end
    end
    return nil
  end

  local function find_closed(result, number)
    for _, entry in ipairs(result.closed or {}) do
      if entry.number == number then return entry end
    end
    return nil
  end

  local function summary_has(result, needle)
    for _, line in ipairs(result.summary or {}) do
      if tostring(line):find(needle, 1, true) then return true end
    end
    return false
  end

  -- A failed task with a branch and an open PR is never touched ------------
  local pr_closed, branch_deleted = {}, {}
  local failed_rt = make_runtime({
    FAILED = { id = "FAILED", status = "failed", branch = "metronome/failed" },
    LIVE = { id = "LIVE", status = "running", branch = "metronome/live" },
  }, {
    { number = 54, head = "metronome/failed", url = "u" },
    { number = 55, head = "metronome/live", url = "u" },
  }, {
    "metronome/failed",
    "metronome/live",
  }, {
    pr_close = function(ref) pr_closed[#pr_closed + 1] = ref end,
    delete_branch = function(branch) branch_deleted[#branch_deleted + 1] = branch end,
  })
  local result = failed_rt.prune({})
  eq(result.ok, true, "prune succeeds on a failed task")

  local kept_failed = find_kept(result, "FAILED")
  eq(type(kept_failed), "table", "the failed task is returned in the kept set")
  eq(kept_failed and kept_failed.reason, "failed (retryable)",
    "the failed task's reason says it is retryable")
  eq(kept_failed and kept_failed.branch, "metronome/failed", "the kept entry names the branch")
  eq(kept_failed and kept_failed.number, 54, "the kept entry carries the open PR number")
  eq(find_closed(result, 54), nil, "the failed task's PR is not closed")
  eq(find_deleted(result, "metronome/failed"), nil, "the failed task's branch is not deleted")
  local touched_failed = false
  for _, ref in ipairs(pr_closed) do
    if ref == 54 then touched_failed = true end
  end
  for _, branch in ipairs(branch_deleted) do
    if branch == "metronome/failed" then touched_failed = true end
  end
  eq(touched_failed, false, "prune makes zero cleanup calls for the failed task")

  local kept_live = find_kept(result, "LIVE")
  eq(type(kept_live), "table", "the live task is kept")
  eq(kept_live and kept_live.reason, "in progress", "a live task is kept as in progress")
  eq(summary_has(result, "kept (failed, retryable): FAILED branch metronome/failed"), true,
    "the summary names the failed task and why it was kept")

  -- A stalled task is retryable like failed ---------------------------------
  local stalled_rt = make_runtime({
    STALLED = { id = "STALLED", status = "stalled", branch = "metronome/stalled" },
  }, {}, { "metronome/stalled" })
  local stalled = stalled_rt.prune({})
  local kept_stalled = find_kept(stalled, "STALLED")
  eq(type(kept_stalled), "table", "a stalled task is kept")
  eq(kept_stalled and kept_stalled.reason, "stalled (retryable)",
    "a stalled task is kept as retryable")
  eq(find_deleted(stalled, "metronome/stalled"), nil, "a stalled task's branch is kept")

  -- A terminal task is merge-owned: prune does not clean its leftovers ------
  local terminal_rt = make_runtime({
    MERGED = { id = "MERGED", status = "merged", branch = "metronome/merged" },
  }, {}, { "metronome/merged" })
  local terminal = terminal_rt.prune({})
  local kept_terminal = find_kept(terminal, "MERGED")
  eq(type(kept_terminal), "table", "a terminal task is kept")
  eq(kept_terminal and kept_terminal.reason, "terminal, merge owns cleanup",
    "a terminal task's leftover is left to merge cleanup")
  eq(find_deleted(terminal, "metronome/merged"), nil,
    "prune does not delete a terminal task's branch")

  -- An explicitly abandoned task is cleaned ---------------------------------
  local ab_closed, ab_deleted = {}, {}
  local abandoned_rt = make_runtime({
    ABANDONED = { id = "ABANDONED", status = "abandoned", branch = "metronome/abandoned" },
  }, {
    { number = 60, head = "metronome/abandoned", url = "u" },
  }, {
    "metronome/abandoned",
  }, {
    pr_close = function(ref) ab_closed[#ab_closed + 1] = ref end,
    delete_branch = function(branch) ab_deleted[#ab_deleted + 1] = branch end,
  })
  local abandoned = abandoned_rt.prune({})
  eq(abandoned.ok, true, "prune succeeds with an abandoned task")
  local closed_ab = find_closed(abandoned, 60)
  eq(type(closed_ab), "table", "the abandoned task's PR is closed")
  eq(closed_ab and closed_ab.task, "ABANDONED", "the closed PR entry carries the task id")
  eq(closed_ab and closed_ab.reason, "abandoned", "the closed PR reason is abandoned")
  local deleted_ab = find_deleted(abandoned, "metronome/abandoned")
  eq(type(deleted_ab), "table", "the abandoned task's branch is deleted")
  eq(deleted_ab and deleted_ab.task, "ABANDONED", "the deleted entry carries the task id")
  eq(deleted_ab and deleted_ab.reason, "abandoned", "the deleted reason is abandoned")
  eq(ab_closed[1], 60, "the abandoned PR was actually closed")
  eq(ab_deleted[1], "metronome/abandoned", "the abandoned branch was actually deleted")
  eq(summary_has(abandoned, "deleted (abandoned): ABANDONED branch metronome/abandoned"), true,
    "the summary names the abandoned deletion")
  eq(summary_has(abandoned, "closed (abandoned): ABANDONED #60 branch metronome/abandoned"), true,
    "the summary names the abandoned PR close and its number")

  -- A branch/PR whose task is absent from the journal is gone --------------
  local gone_closed, gone_deleted = {}, {}
  local gone_rt = make_runtime({
    LIVE = { id = "LIVE", status = "running", branch = "metronome/live" },
  }, {
    { number = 70, head = "metronome/gone", url = "u" },
  }, {
    "metronome/live",
    "metronome/gone",
    "metronome/orphan",
  }, {
    pr_close = function(ref) gone_closed[#gone_closed + 1] = ref end,
    delete_branch = function(branch) gone_deleted[#gone_deleted + 1] = branch end,
  })
  local gone = gone_rt.prune({})
  local closed_gone = find_closed(gone, 70)
  eq(type(closed_gone), "table", "the gone task's PR is closed")
  eq(closed_gone and closed_gone.reason, "gone", "the closed PR reason is gone")
  local deleted_gone = find_deleted(gone, "metronome/gone")
  eq(type(deleted_gone), "table", "the gone task's branch is deleted")
  eq(deleted_gone and deleted_gone.reason, "gone", "the gone branch reason is gone")
  local deleted_orphan = find_deleted(gone, "metronome/orphan")
  eq(type(deleted_orphan), "table", "a branch with no task is deleted")
  eq(deleted_orphan and deleted_orphan.reason, "gone", "an orphan branch reason is gone")
  eq(find_deleted(gone, "metronome/live"), nil, "a live task's branch survives")
  eq(summary_has(gone, "deleted (gone): branch metronome/orphan"), true,
    "the summary names a gone branch")
  eq(summary_has(gone, "closed (gone): #70 branch metronome/gone"), true,
    "the summary names the gone PR close and its number")
end
