-- Kanban: the open document as a board.
--
-- Built on the Lua API as it stands — columns are `taskle.ui.column`s inside a
-- `taskle.ui.row`, cards are buttons, and a card moves with the ◀ / ▶ buttons on
-- it. There is no drag and drop, because the widget vocabulary is a description
-- of a tree rather than a surface with pointer events, and inventing a drag
-- protocol for one plugin would be the wrong place to start.
--
-- The board takes a window of its own (`detached`), because it is the thing this
-- plugin does rather than a form to answer: its columns sit side by side, and a
-- panel's width puts most of them behind a scrollbar before a single card is
-- drawn. The strip scrolls sideways and each column has a floor, so a narrow
-- window slides the board instead of squeezing every card down to one word a
-- line.
--
-- # Where a card's column is written
--
-- On the task line, in todo.txt:
--
--   * The **last** stage is `x` — the real completion state, not a column that
--     shadows it. A board whose Done pile disagreed with what the app calls done
--     would be a second source of truth for the one fact the format already has.
--   * The **first** stage is the absence of a tag, so a task nobody has touched
--     needs no tag to appear on the board, and a document that has never met
--     this plugin still opens as a full board rather than an empty one.
--   * Every stage between them is `_kanban:<slug>`. The leading underscore is
--     what keeps it out of the task list's own display: this is the plugin's
--     bookkeeping, and a user reading their todo.txt in the app should not have
--     to look at it.
--
-- So the cost of the board is one tag on the tasks actually in flight.
--
-- # Stages
--
-- Configurable, because "To Do / Doing / Done" is one team's vocabulary and the
-- board is worth no more than its columns. The list lives in `taskle.state`,
-- which is this plugin's own namespace and survives a reload.
--
-- A stage's tag is a slug of its name rather than its position: reordering the
-- stages must not silently move every task, which is exactly what an index
-- would do. The trade is that **renaming** a stage strands the tasks tagged with
-- the old slug; they come back in the first column, where they are visible and
-- can be moved again, rather than disappearing.

local TAG = "_kanban"
local STAGES_KEY = "stages"
local DEFAULT_STAGES = { "To Do", "Doing", "Done" }

-- How many cards a column draws before it stops and says how many are left.
-- A board is for seeing the shape of the work; a thousand-card column is a
-- list, and the app already has a very good one of those.
local MAX_CARDS = 50

-- How narrow a column may draw. Below about this a card's text wraps to one
-- word a line, which is a column that costs more to read than the list it came
-- from.
local MIN_COLUMN = 220

local state = { status = "" }
-- The stage-name draft the configure window is editing, or nil when it is
-- showing what is saved. Held apart from the saved list so a half-typed line is
-- never what the board reads.
local draft = nil

-- The tag value for a stage name: lowercase, and everything that is not a
-- letter or a digit becomes a dash. Two stages that slug the same are the
-- user's own doing and share a column; nothing here can guess which they meant.
local function slug(name)
  local out = name:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  return out
end

local function stages()
  local saved = taskle.state.get(STAGES_KEY)
  if not saved or saved == "" then
    return DEFAULT_STAGES
  end
  local ok, decoded = pcall(taskle.codec.json_decode, saved)
  -- Corrupt state is not silently overwritten; the board falls back to the
  -- defaults and says so where the stages are edited.
  if not ok or type(decoded) ~= "table" or #decoded < 2 then
    return DEFAULT_STAGES
  end
  return decoded
end

local function tag_of(task, key)
  local parsed = taskle.parse(task.raw)
  for _, part in ipairs(parsed.parts or {}) do
    if part.kind == "tag" and part.key == key then
      return part.value
    end
  end
  return nil
end

-- Which column a task is in, as an index into `list`.
--
-- A tag naming a stage that no longer exists lands in the first column rather
-- than nowhere: an unreadable tag is a task that needs moving, not a task to
-- hide.
local function column_of(task, list)
  if task.completed then
    return #list
  end
  local value = tag_of(task, TAG)
  if value then
    for i = 2, #list - 1 do
      if slug(list[i]) == value then
        return i
      end
    end
  end
  return 1
end

-- The words of a task, without the metadata the card does not need. The board
-- shows what the work *is*; priority, dates and tags are the list's job, and a
-- card repeating them is a card nobody can scan.
local function card_text(task)
  local parsed = taskle.parse(task.raw)
  local out = {}
  for _, part in ipairs(parsed.parts or {}) do
    if part.kind == "text" or part.kind == "space" then
      out[#out + 1] = part.text or ""
    elseif part.kind == "project" then
      out[#out + 1] = "+" .. (part.value or "")
    elseif part.kind == "context" then
      out[#out + 1] = "@" .. (part.value or "")
    end
    -- Tags are dropped: `_kanban:doing` is this plugin's own bookkeeping, and
    -- showing it on the card it moved would be showing the user the machinery.
  end
  local text = table.concat(out):match("^%s*(.-)%s*$")
  return text ~= "" and text or task.raw
end

-- Put `task` in `column`, saying it the way todo.txt says it.
local function move_to(task, column, list)
  if column == #list then
    taskle.task.remove_tag(task.id, TAG)
    taskle.task.complete(task.id)
    return
  end
  if task.completed then
    taskle.task.reopen(task.id)
  end
  if column == 1 then
    taskle.task.remove_tag(task.id, TAG)
  else
    taskle.task.set_tag(task.id, TAG, slug(list[column]))
  end
end

local function board(list)
  local columns = {}
  for i = 1, #list do
    columns[i] = {}
  end
  for _, task in ipairs(taskle.tasks()) do
    if not task.hidden then
      local column = column_of(task, list)
      columns[column][#columns[column] + 1] = task
    end
  end
  return columns
end

local function card(task, column, last)
  -- A card is the text plus the two ways it can go. The buttons are `nil` at
  -- the ends of the board, which the host draws disabled — so the card keeps
  -- its shape in every column rather than reflowing as it moves.
  return taskle.ui.column {
    spacing = 2,
    taskle.ui.text { card_text(task) },
    taskle.ui.row {
      spacing = 4,
      taskle.ui.button {
        "◀",
        on_press = column > 1 and ("move:" .. task.id .. ":" .. (column - 1)) or nil,
      },
      taskle.ui.button {
        "▶",
        on_press = column < last and ("move:" .. task.id .. ":" .. (column + 1)) or nil,
      },
    },
  }
end

local function column_view(title, index, tasks, last)
  local rows = {
    taskle.ui.text { title .. "  (" .. #tasks .. ")", tone = "heading" },
    taskle.ui.separator {},
  }
  if #tasks == 0 then
    rows[#rows + 1] = taskle.ui.text { "Nothing here.", tone = "dim" }
  end
  for i, task in ipairs(tasks) do
    if i > MAX_CARDS then
      rows[#rows + 1] = taskle.ui.text {
        "and " .. (#tasks - MAX_CARDS) .. " more",
        tone = "dim",
      }
      break
    end
    rows[#rows + 1] = card(task, index, last)
  end
  rows.spacing = 6
  rows.min_width = MIN_COLUMN
  -- Each column scrolls on its own, so one long pile does not set the height
  -- of the board.
  return taskle.ui.scrollable { height = 460, taskle.ui.column(rows) }
end

local function view()
  local list = stages()
  local columns = board(list)
  local strip = { spacing = 16 }
  for i, title in ipairs(list) do
    strip[#strip + 1] = column_view(title, i, columns[i], #list)
  end
  local rows = {
    -- The strip slides rather than the columns squeezing: each has a floor, and
    -- a board narrower than the sum of them is a board you scroll.
    taskle.ui.scrollable {
      direction = "horizontal",
      taskle.ui.row(strip),
    },
  }
  if state.status ~= "" then
    rows[#rows + 1] = taskle.ui.text { state.status, tone = "dim" }
  end
  return taskle.ui.column(rows)
end

local function update(_, message)
  local id, column = message:match("^move:(%-?%d+):(%d+)$")
  if not id then
    return
  end
  id, column = tonumber(id), tonumber(column)
  local list = stages()
  -- Re-read the task rather than trusting the id the button was built with:
  -- the document may have been edited since this frame was drawn, and a task
  -- id is document-local and does not survive a reload.
  for _, task in ipairs(taskle.tasks()) do
    if task.id == id then
      move_to(task, column, list)
      state.status = card_text(task) .. " moved to " .. (list[column] or "?")
      return
    end
  end
  state.status = "That task is no longer here."
end

taskle.window {
  id = "kanban",
  title = "Kanban",
  command = "kanban.open",
  detached = true,
  view = view,
  update = update,
}

-- ===== configuring the stages =====

-- One stage a line, which is the shortest thing to type and the easiest to
-- reorder. A grid of add/remove/move buttons would be more controls than the
-- list has entries.
local function draft_text()
  if draft then
    return draft
  end
  return table.concat(stages(), "\n")
end

local function parse_draft(text)
  local list = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local name = line:match("^%s*(.-)%s*$")
    if name ~= "" then
      list[#list + 1] = name
    end
  end
  return list
end

local config_state = { message = "" }

local function config_view()
  local list = stages()
  local rows = {
    taskle.ui.text { "Stages", tone = "heading" },
    taskle.ui.text {
      "One per line, left to right. The first is where untagged tasks sit; "
        .. "the last is the done pile and is the document's own completion.",
      tone = "dim",
    },
    taskle.ui.text_area {
      id = "stages",
      value = draft_text(),
      placeholder = table.concat(DEFAULT_STAGES, "\n"),
      on_input = "stages",
      height = 200,
    },
    taskle.ui.row {
      spacing = 6,
      taskle.ui.button { "Save", on_press = "save", style = "primary" },
      taskle.ui.button { "Restore defaults", on_press = "reset" },
    },
    -- Said where the renaming happens, because this is the one edit here that
    -- can leave tasks behind.
    taskle.ui.text {
      "Renaming a stage leaves the tasks already in it in the first column: a "
        .. "task's stage is written on it by name, so that reordering the "
        .. "stages does not move every task at once.",
      tone = "dim",
    },
  }
  if config_state.message ~= "" then
    rows[#rows + 1] = taskle.ui.text { config_state.message, tone = "accent" }
  end
  rows[#rows + 1] = taskle.ui.text {
    "In use: " .. table.concat(list, " · "),
    tone = "dim",
  }
  return taskle.ui.column(rows)
end

local function config_update(_, message, value)
  if message == "stages" then
    draft = value
    return
  end
  if message == "reset" then
    taskle.state.delete(STAGES_KEY)
    draft = nil
    config_state.message = "Back to " .. table.concat(DEFAULT_STAGES, " · ") .. "."
    return
  end
  if message ~= "save" then
    return
  end
  local list = parse_draft(draft_text())
  -- Two is the floor, not three: a board with one column is a list, and the
  -- first and last stages have meanings the middle ones do not.
  if #list < 2 then
    config_state.message = "A board needs at least two stages."
    return
  end
  taskle.state.set(STAGES_KEY, taskle.codec.json_encode(list))
  draft = nil
  config_state.message = "Saved."
end

taskle.window {
  id = "kanban.configure",
  title = "Kanban",
  settings = true,
  view = config_view,
  update = config_update,
}
