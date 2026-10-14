-- pomodoro: work in fixed intervals against one task, and keep the count.
--
-- Everything here is the automation stage — `taskle.timer`, `taskle.notify`,
-- `taskle.task.*`. No external capability, so it needs no approval prompt and
-- runs untrusted.
--
-- The count lives on the task as `_pomo:<n>`, a hidden tag: it belongs to the
-- task, survives archiving and being edited elsewhere, and syncs with the file
-- rather than with a store this plugin would otherwise have to keep.
--
-- # How the timing works, and what it cannot do
--
-- One recurring one-minute timer, registered at load, counting down a number
-- held here. Not a stopwatch: the sandbox has no clock beyond `taskle.today()`,
-- so elapsed time cannot be measured — only ticks can be counted. Two
-- consequences worth knowing:
--
--   * an interval is accurate to about a minute, not to the second;
--   * a run does not survive the app being closed, and does not continue while
--     it is closed. Reopening starts from nothing rather than from a lie about
--     how long you have been working.
--
-- # What the menu knows
--
-- `run` and `paused` below are this plugin's own state, and the menu has to
-- follow them: offering Start while a pomodoro is running, or Stop while none
-- is, is offering a row whose only outcome is a refusal. The host cannot see a
-- Lua local, and asking it to would mean running this file on every menu
-- render, so the two facts are mirrored into `taskle.flag`s and pushed with
-- `taskle.set_flag` wherever they change. `set_state` is the one place that
-- happens, so the flags cannot drift from what they describe.

local WORK_MINUTES = 25
local BREAK_MINUTES = 5
-- A longer break after this many completed intervals.
local LONG_BREAK_AFTER = 4
local LONG_BREAK_MINUTES = 15

local COUNT_TAG = "_pomo"

-- What is running, if anything. One at a time on purpose: two pomodoros at once
-- is not a thing, and the state that would allow it is state to get wrong.
local run = nil -- { task = <id>, kind = "work"|"break", left = <minutes> }
local paused = false
local completed = 0

taskle.flag { name = "running", default = false }
taskle.flag { name = "paused", default = false }

-- Set `run`/`paused` and tell the host in the same breath.
--
-- Every assignment to either goes through here. Two places that each set the
-- local and remember to mirror it is two places one of them can forget, and a
-- stale flag is a menu row that is disabled with nothing to re-enable it.
local function set_state(next_run, next_paused)
  run = next_run
  -- Nothing is paused when nothing is running, so the two cannot disagree.
  paused = run ~= nil and next_paused == true
  taskle.set_flag("running", run ~= nil)
  taskle.set_flag("paused", paused)
end

local function task_by_id(id)
  for _, t in ipairs(taskle.tasks()) do
    if t.id == id then
      return t
    end
  end
  return nil
end

local function count_of(task)
  local n = task.raw:match(COUNT_TAG .. ":(%d+)")
  return n and tonumber(n) or 0
end

-- The sentence, not the whole line: a notification reading
-- "(A) 2026-01-01 write the report +work due:2026-02-01" is unreadable.
local function label_of(task)
  local said = {}
  for _, part in ipairs(taskle.parse(task.raw).parts) do
    -- Text and the whitespace around it: the parts tile the line, so this is
    -- the sentence exactly as it was written, minus the tags filed on it.
    if part.kind == "text" or part.kind == "space" then
      said[#said + 1] = part.text
    end
  end
  local label = table.concat(said):gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
  return label ~= "" and label or task.raw
end

local function finish_work()
  completed = completed + 1
  local task = task_by_id(run.task)
  if task then
    -- Recorded on the task rather than in this plugin's state: the count is a
    -- fact about the work and should outlive the session.
    taskle.task.set_tag(task.id, COUNT_TAG, tostring(count_of(task) + 1))
  end
  local minutes = (completed % LONG_BREAK_AFTER == 0) and LONG_BREAK_MINUTES or BREAK_MINUTES
  taskle.notify {
    title = "Pomodoro finished",
    message = (task and label_of(task) or "") .. "  ·  take " .. minutes .. " minutes",
  }
  set_state({ task = run.task, kind = "break", left = minutes }, false)
end

taskle.timer {
  id = "pomodoro.tick",
  every = "1m",
  fn = function()
    if not run or paused then
      return
    end
    run.left = run.left - 1
    if run.left > 0 then
      return
    end
    if run.kind == "work" then
      finish_work()
    else
      set_state(nil, false)
      taskle.notify { title = "Break over", message = "start another when you are ready" }
    end
  end,
}

taskle.command {
  name = "pomodoro.start",
  title = "Start Pomodoro",
  -- The menu row goes grey while one is running rather than staying live to
  -- answer with the refusal below. The check stays: a key binding, `taskle.run`
  -- from another plugin and the command line all reach this without a menu.
  requires_flag = { running = false },
  fn = function()
    if run then
      return "already running — stop it first"
    end
    local focused = taskle.selection().focused
    local task = focused and task_by_id(focused)
    if not task then
      return "focus the task you are working on first"
    end
    set_state({ task = task.id, kind = "work", left = WORK_MINUTES }, false)
    return WORK_MINUTES .. " minutes on: " .. label_of(task)
  end,
}

taskle.command {
  name = "pomodoro.stop",
  title = "Stop Pomodoro",
  requires_flag = { running = true },
  fn = function()
    if not run then
      return "nothing running"
    end
    set_state(nil, false)
    return "stopped — this interval does not count"
  end,
}

-- Pause holds the countdown where it is rather than ending the interval, which
-- is the difference between answering the door and losing twenty minutes of
-- work. The tick simply stops counting; nothing is discarded.
taskle.command {
  name = "pomodoro.pause",
  title = "Pause Pomodoro",
  requires_flag = { running = true, paused = false },
  fn = function()
    if not run or paused then
      return "nothing to pause"
    end
    set_state(run, true)
    return "paused with " .. run.left .. " minutes left"
  end,
}

taskle.command {
  name = "pomodoro.resume",
  title = "Resume Pomodoro",
  requires_flag = { paused = true },
  fn = function()
    if not paused then
      return "nothing is paused"
    end
    set_state(run, false)
    return "resumed — " .. run.left .. " minutes left"
  end,
}

-- Where the countdown goes on the row: in front of the words, after the
-- priority and dates the list draws as the task's filing rather than as its
-- text. Prefixed rather than appended so the number is in one place whatever
-- the task says, and so a long line cannot push it off the end.
--
-- The first `text` part rather than the first `text`-or-`space`: the parts tile
-- the line, so a leading space is the one already separating the prefix from
-- the body, and going in front of it would leave two.
local function body_start(parts)
  for i, part in ipairs(parts) do
    if part.kind == "text" then
      return i
    end
  end
  return #parts + 1
end

-- The count on the row, so a glance says which tasks have had real time on them,
-- and the countdown on the one being worked on. Only where there is something to
-- say: a "0" against every task is noise.
taskle.on("before_render", function(ctx)
  local task = ctx.task
  local changed = false
  if run and run.task == task.id then
    local mark = paused and "⏸" or (run.kind == "work" and "⏱" or "☕")
    table.insert(task.parts, body_start(task.parts), {
      kind = "text",
      -- Minutes, because minutes are all this can honestly count: the interval
      -- is a count of one-minute ticks and there is no clock to ask for the
      -- seconds.
      text = mark .. " " .. run.left .. "m ",
      fg = paused and "#9399b2" or "#f9e2af",
    })
    changed = true
  end
  local n = count_of(task)
  if n > 0 then
    task.parts[#task.parts + 1] = {
      kind = "text",
      text = " " .. string.rep("●", math.min(n, 5)) .. (n > 5 and (" " .. n) or ""),
      fg = "#f38ba8",
    }
    changed = true
  end
  if changed then
    return { parts = task.parts }
  end
end)

taskle.menu {
  title = "Start Pomodoro",
  command = "pomodoro.start",
  menu = "Task",
  submenu = "Pomodoro",
}
taskle.menu {
  title = "Pause Pomodoro",
  command = "pomodoro.pause",
  menu = "Task",
  submenu = "Pomodoro",
}
taskle.menu {
  title = "Resume Pomodoro",
  command = "pomodoro.resume",
  menu = "Task",
  submenu = "Pomodoro",
}
taskle.menu {
  title = "Stop Pomodoro",
  command = "pomodoro.stop",
  menu = "Task",
  submenu = "Pomodoro",
}
