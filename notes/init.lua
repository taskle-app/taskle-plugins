-- Notes: a long-form note attached to a task.
--
-- The first customer of `taskle.ui.text_area`, and written to prove the node is
-- enough for a real editor rather than a demo — see
-- `docs/ideas/plan-text-area-node.md`.
--
-- Where a note lives. `<workspace>/.taskle/notes/<id>.md`, so a note travels
-- with the tasks it annotates: copy the project, or commit it, and the notes
-- come too. Not in the app's data directory, which would strand every note the
-- moment the todo file moved.
--
-- At the workspace root rather than beside each todo file: a project with
-- several lists in subdirectories would otherwise grow a `.taskle` in every one
-- of them, and a note is about the project's work, not about which file the
-- task happens to be listed in. Ids are minted per note, so several documents
-- sharing one `notes/` cannot collide. A document in no workspace falls back to
-- its own directory — there is nowhere else to put it, and prompting to create
-- a project just to write a note would be the wrong moment to ask.
--
-- What ties the two together is a `note:<id>` tag on the task line. That is
-- todo.txt, so it survives being edited in another program, sorted, archived,
-- or synced — none of which a side table of task ids would survive, since task
-- ids are document-local and change on reload. The id is minted on first save,
-- not on first open: opening the editor and changing nothing must not write a
-- tag onto the user's task line.

-- Hidden, like every tag a plugin keeps for its own bookkeeping: a leading `_`
-- is what the app reads as "this is not part of the sentence", and it keeps
-- `_note:` off the line the user is looking at.
local NOTE_TAG = "_note"

local NOTES_DIR = ".taskle/notes"

-- The alphabet an id is spelled in, and how many characters of it.
--
-- Lowercase letters only, because the id *is* a filename: macOS and Windows
-- compare filenames case-insensitively, so two ids differing only in case are
-- one file, and a note would silently overwrite another. Ten letters is ~47
-- bits, in the same range as the eight base64url characters this replaces.
-- `mint_id` checks for a collision anyway, because "will not happen" and
-- "cannot happen" are different and only one of them needs no recovery path.
--
-- Ids already written stay as they are. They name files that exist, and the
-- tag is what finds them; only newly minted ones are spelled this way.
local ID_ALPHABET = "abcdefghijklmnopqrstuvwxyz"
local ID_LENGTH = 10

local state = {
  -- The task this note belongs to, and the id under which it is filed. `id` is
  -- nil for a task with no note yet.
  task = nil,
  id = nil,
  -- The editor's contents, and what was last read from or written to disk.
  -- Their difference is what "unsaved" means; a flag would be a second answer
  -- able to disagree with the text.
  body = "",
  saved = "",
  status = "",
  error = nil,
}

-- The directory holding the open document, which is what a note sits beside.
--
-- `taskle.open_documents` rather than a remembered path: the app is long-lived
-- and the user switches files, so the answer is a property of what is in front
-- right now.
local function document_dir()
  for _, doc in ipairs(taskle.open_documents()) do
    if doc.active and doc.path and doc.path ~= "" then
      return doc.path:match("^(.*)[/\\][^/\\]*$")
    end
  end
  return nil
end

-- The directory the `.taskle/notes/` folder hangs off: the project the open
-- document belongs to, or the document's own directory when it is in none.
--
-- `taskle.workspace.path` is fixed for the life of this load — the host
-- resolves the workspace when it loads the sources, and the same answer decides
-- which directories this plugin may write to at all. So it is the load's
-- project, not necessarily the front tab's: opening a document from a different
-- project and writing a note there is refused by confinement until the sources
-- reload, which is the safe way for that to fail.
local function notes_root()
  return taskle.workspace.path or document_dir()
end

local function note_path(id)
  local dir = notes_root()
  if not dir then
    return nil
  end
  return dir .. "/" .. NOTES_DIR .. "/" .. id .. ".md"
end

-- The focused task, or nil. A note is about one task; with several selected
-- there is no single answer, so the focused row is the one that counts.
local function focused_task()
  local focused = taskle.selection().focused
  if not focused then
    return nil
  end
  for _, task in ipairs(taskle.tasks()) do
    if task.id == focused then
      return task
    end
  end
  return nil
end

-- A task's note id, if it has one. `taskle.parse` rather than a pattern over
-- the raw line: `_note:` inside a word, or a URL with a colon in it, is not a
-- tag, and the parser is the one thing that already knows the difference.
local function note_id_of(task)
  local parsed = taskle.parse(task.raw)
  for _, part in ipairs(parsed.parts or {}) do
    if part.kind == "tag" and part.key == NOTE_TAG then
      return part.value
    end
  end
  return nil
end

local function file_exists(path)
  local ok = pcall(taskle.fs.read, path)
  return ok
end

-- A random id, spelled in `ID_ALPHABET`.
--
-- Drawn by rejection: 256 is not a multiple of 26, so taking every byte modulo
-- the alphabet would make its first six letters likelier than the rest. Drawing
-- again for the few values that would skew it costs a fraction of a draw.
local function random_id()
  local limit = 256 - (256 % #ID_ALPHABET)
  local out = {}
  while #out < ID_LENGTH do
    local bytes = taskle.codec.random_bytes(ID_LENGTH)
    for i = 1, #bytes do
      local b = string.byte(bytes, i)
      if b < limit and #out < ID_LENGTH then
        local at = b % #ID_ALPHABET + 1
        out[#out + 1] = ID_ALPHABET:sub(at, at)
      end
    end
  end
  return table.concat(out)
end

-- An id no note is already filed under.
local function mint_id()
  for _ = 1, 8 do
    local id = random_id()
    local path = note_path(id)
    if path and not file_exists(path) then
      return id
    end
  end
  return nil
end

-- Bring the editor onto whatever task is focused now.
--
-- Called from `view`, which runs on every keystroke, so it must do nothing at
-- all in the ordinary case. The guard is the task id: while the user types, the
-- focus has not moved and the file is not re-read out from under them.
local function load_for_focused()
  local task = focused_task()
  local id = task and task.id or nil
  if id == state.task then
    return
  end
  state.task = id
  state.status = ""
  state.error = nil
  state.id = task and note_id_of(task) or nil
  state.body = ""
  state.saved = ""
  if not state.id then
    return
  end
  local path = note_path(state.id)
  if not path then
    state.error = "This document has no folder to keep notes in — save it first."
    return
  end
  local ok, body = pcall(taskle.fs.read, path)
  -- A tag pointing at a file that is not there is not an error to shout about:
  -- the note was deleted, or the folder was not copied along with the todo
  -- file. Opening an empty editor over it lets the user simply write it again.
  state.body = ok and body or ""
  state.saved = state.body
end

local function save()
  if not state.task then
    state.error = "Select a task first."
    return
  end
  local id = state.id
  if not id then
    id = mint_id()
    if not id then
      state.error = "Could not find an unused note id."
      return
    end
  end
  local path = note_path(id)
  if not path then
    state.error = "This document has no folder to keep notes in — save it first."
    return
  end
  local ok, err = pcall(taskle.fs.write, path, state.body)
  if not ok then
    state.error = "Could not save: " .. tostring(err)
    return
  end
  -- The tag goes on only once the file it points at exists, so a task never
  -- carries a `_note:` for a note that was never written.
  if not state.id then
    taskle.task.set_tag(state.task, NOTE_TAG, id)
    state.id = id
  end
  state.saved = state.body
  state.error = nil
  state.status = "Saved."
end

local function open_externally()
  if not state.id then
    return
  end
  local path = note_path(state.id)
  if not path then
    return
  end
  -- Save first: handing the file to another editor while this one holds newer
  -- text is how the two end up disagreeing, and the user asked for *this* note.
  if state.body ~= state.saved then
    save()
  end
  local result = taskle.open_path(path)
  if result and result.opened then
    state.status = "Opened."
  else
    state.error = "Could not open: " .. tostring(result and result.error or "unknown")
  end
end

-- Detach the focused task's note and delete the file it pointed at.
--
-- Both halves or neither: a tag left behind names a note that is gone, and a
-- file left behind is one nothing will ever open again. The file goes first, so
-- a refused delete leaves the task still pointing at a note that is still there.
local function clear()
  local task = focused_task()
  if not task then
    return "focus a task first"
  end
  local id = note_id_of(task)
  if not id then
    return "this task has no note"
  end
  local path = note_path(id)
  if path then
    local ok, err = pcall(taskle.fs.remove, path)
    if not ok then
      return "could not delete the note: " .. tostring(err)
    end
  end
  taskle.task.remove_tag(task.id, NOTE_TAG)
  -- The editor is showing what was just deleted. Forgetting the task is what
  -- makes `load_for_focused` read the cleared state back on the next frame,
  -- rather than leaving the old body on screen over a task that has no note.
  state.task = nil
  return "note cleared"
end

local function view()
  load_for_focused()

  -- No heading of its own: the window is titled "Notes" by the host, and a
  -- window that says its own name twice has said nothing the second time.
  if not state.task then
    return taskle.ui.column {
      taskle.ui.text { "Select a task to write a note about it.", tone = "dim" },
    }
  end

  local dirty = state.body ~= state.saved
  local rows = {
    taskle.ui.text {
      state.id and ("Filed as " .. state.id .. ".md") or "Not saved yet",
      tone = "dim",
    },
    taskle.ui.text_area {
      id = "body",
      value = state.body,
      placeholder = "Write a note about this task…",
      on_input = "body",
      height = 320,
    },
    taskle.ui.row {
      taskle.ui.button {
        dirty and "Save" or "Saved",
        -- No message is how a control says "nothing to do now": the host draws
        -- it disabled and the window does not reflow around it appearing.
        on_press = dirty and "save" or nil,
        style = "primary",
      },
      -- Only once there is a file to hand over.
      taskle.ui.button { "Open externally", on_press = state.id and "open" or nil },
      -- Deleting is the same action the menu offers, routed through the same
      -- command so the host asks about it once, in one place, rather than this
      -- window growing a confirmation of its own that could word it differently.
      taskle.ui.button {
        "Delete",
        on_press = state.id and "delete" or nil,
        style = "danger",
      },
      taskle.ui.space {},
      taskle.ui.text { dirty and "Unsaved changes" or "", tone = "dim" },
    },
  }
  if state.error then
    rows[#rows + 1] = taskle.ui.text { state.error, tone = "danger" }
  elseif state.status ~= "" then
    rows[#rows + 1] = taskle.ui.text { state.status, tone = "dim" }
  end
  return taskle.ui.column(rows)
end

local function update(_, message, value)
  if message == "body" then
    -- Per-edit: the whole contents arrive on every keystroke, so this table is
    -- always what the user is looking at. Measured before the node was built —
    -- 0.03 ms at a 128 KB note.
    state.body = value or ""
    state.status = ""
  elseif message == "save" then
    save()
  elseif message == "open" then
    open_externally()
  elseif message == "delete" then
    -- Through the command, not by calling `clear` here: the command is what
    -- carries `needs_confirm`, and calling past it would delete the note with
    -- no question asked.
    taskle.run("notes.clear")
  end
end

taskle.window {
  id = "notes",
  title = "Notes",
  command = "notes.open",
  view = view,
  update = update,
}

taskle.command {
  name = "notes.clear",
  title = "Clear Note",
  -- The note is prose the user wrote and the only copy of it. Deleting is one
  -- menu click from the task it belongs to, and there is no undo for a file.
  needs_confirm = true,
  fn = clear,
}

-- Under Task, beside the other things done to the task in front of you. Writing
-- and clearing sit together because they are the two halves of one thing: the
-- window is where a note is made, and this is where it is unmade.
taskle.menu { title = "Note…", command = "notes.open", menu = "Task", submenu = "Note" }
taskle.menu { title = "Clear Note", command = "notes.clear", menu = "Task", submenu = "Note" }

-- And on the row's own menu, which is where a task is acted on by pointer.
taskle.menu { context = "task", title = "Note…", command = "notes.open" }
taskle.menu { context = "task", title = "Clear Note", command = "notes.clear" }

-- `gn` — the `g` prefix the app uses for "go to", and the note is where this
-- goes. A `keys.toml` binding overrides it like any built-in.
taskle.bind { keys = "gn", command = "notes.open" }
