-- subtasks: a parent/child task hierarchy, built entirely on the public plugin
-- API. The app has no sub-task feature and no notion of a parent — the relation
-- below is this script's, declared once and applied by the host's composition
-- pipeline.
--
-- Convention: a parent carries `_id:<n>` and each child carries `_parent:<n>`
-- naming it, e.g.
--
--   (A) ship the release +work _id:1
--   write the changelog +work _parent:1
--   tag the commit +work _parent:1
--
-- The id lives in the line rather than being the app's own task id, which is a
-- position in the loaded document: archiving one task renumbers the rest, and
-- every child would then point at the wrong parent.
--
-- The `_parent:` tag begins with `_`, so Taskle hides it from the row by default
-- (enable "Show hidden tags" in Preferences to see it). This plugin then:
--
--   * declares the parent relation as a `taskle.nest` slot, which is what
--     indents child rows, keeps a family contiguous under every sort, and shows
--     a filtered-out ancestor as an inert context row — all host-side, from the
--     one declaration;
--   * decides where a family sits when the sort is about urgency (`rollup`);
--   * flags a duplicate `_id`, which makes every `_parent:` naming it ambiguous
--     (`before_render`);
--   * offers `subtasks.new` / `make-child-of` / `outdent` under Task ▸ Sub-tasks,
--     and `indent` on `>>` (`taskle.task.draft` / `set_tag` / `remove_tag`,
--     `taskle.pick_task` to ask which task is the parent), and a "roots" filter.
--
-- Because it only reads typed tags and edits them through the task API, never
-- raw text, it can never corrupt a task.

-- The stable `_id:<n>` this plugin assigns a task that has children, or nil.
--
-- Deliberately not the app's own `task.id`, which is a position in the loaded
-- document: archiving a task renumbers everything after it, and every child in
-- the file would then point at the wrong parent. `_id` is written into the line,
-- so it survives archiving, sorting, and being edited in another program.
local function id_of(task)
  local id = task.raw:match("_id:(%d+)")
  return id and tonumber(id) or nil
end

-- The `_parent:<id>` of a task, or nil for a top-level task.
local function parent_of(task)
  local id = task.raw:match("_parent:(%d+)")
  return id and tonumber(id) or nil
end

-- One past the largest `_id` in the document. Deterministic, and it never reuses
-- a number a child might still be pointing at.
local function next_id()
  local max = 0
  for _, t in ipairs(taskle.tasks()) do
    local id = id_of(t)
    if id and id > max then
      max = id
    end
  end
  return max + 1
end

-- The `_id`s claimed by more than one task. Two tasks answering to one id makes
-- every `_parent:` pointing at it ambiguous, so the rows are flagged rather than
-- silently picking one.
local function duplicate_ids()
  local seen, dupes = {}, {}
  for _, t in ipairs(taskle.tasks()) do
    local id = id_of(t)
    if id then
      if seen[id] then
        dupes[id] = true
      end
      seen[id] = true
    end
  end
  return dupes
end

-- The sorts a family's position aggregates under. Urgency rolls up; identity
-- does not: under project, context, alphabetical, and the document-order
-- fallback a family floated to its earliest-sorting child would defeat looking
-- for the parent by its own name, so each node stays at its own key there.
local AGGREGATED = {
  ["priority"] = true,
  ["due-date"] = true,
  ["threshold-date"] = true,
  ["creation-date"] = true,
  ["completion-date"] = true,
}

-- The hierarchy itself. `parents` is the whole relation: one claim per
-- candidate, answered in a single call per recompose. Depth and indentation, the
-- inert context ancestor of a matching row, the cycle break, the depth cap, and
-- keeping a family contiguous under the user's sort are all consequences the
-- host derives from it — none of them is this plugin's code any more.
taskle.nest {
  name = "subtasks",
  title = "Sub-tasks",
  -- No `requires`, deliberately: a source spanning the open documents hands a
  -- nester tasks from documents other than the focused one, which needs
  -- `read_documents`, and asking for that would put this whole plugin — the
  -- completion cascade included — behind an approval prompt. So under such a
  -- source the host switches this nester off and says so, and nesting stays a
  -- within-a-document affair.
  parents = function(ctx)
    -- Built by the host on first call and cached for the recompose, over the
    -- candidates rather than the file: a plugin-built index is what made the
    -- old hierarchy code able to walk past what the user was looking at. A
    -- repeated `_id` resolves first-wins here; `before_render` is what says
    -- the document is broken.
    local ids = ctx.index("_id")
    local out = {}
    for i, t in ipairs(ctx.candidates) do
      local parent = t.tags._parent
      out[i] = parent and ids[parent] or nil
    end
    return out
  end,
  -- One call per level of the host's bottom-up fold, answering with the rank
  -- that represents each node's subtree when the node is compared against its
  -- siblings.
  rollup = function(ctx)
    if not AGGREGATED[ctx.sort] then
      -- No entries: the host reads a nil per node as "self", which is exactly
      -- the four remaining sorts. Nothing to hand-roll.
      return {}
    end
    local out = {}
    for i, node in ipairs(ctx.nodes) do
      -- A rank is a position under the active comparator, so the earliest is
      -- the smallest whatever the sort is — one loop covers all five, where a
      -- field-by-field aggregate needed one branch each.
      --
      -- The node's own rank is folded in explicitly, and each child is taken as
      -- given: the host has already folded the subtree bottom-up, so
      -- `child.rep` stands for that whole family and descending would only find
      -- members it deliberately did not hand over.
      local rep = node.rank
      for _, child in ipairs(node.children) do
        if child.rep < rep then
          rep = child.rep
        end
      end
      out[i] = rep
    end
    return out
  end,
  -- An ancestor the user's filter rejected still explains why its matching
  -- child is on screen, so it renders as an inert context row.
  filtered_parent = "context",
  -- A `_parent:` naming a task that is not in the list — archived, or a hand
  -- edit — leaves the child as a top-level task rather than hiding work.
  missing_parent = "promote",
}

taskle.on("before_render", function(ctx)
  local task = ctx.task
  -- Another source may show a task from a different open document. Duplicate
  -- `_id`s are a property of one file, so a task this document does not hold
  -- cannot be judged against its ids.
  if ctx.document_active == false then return end
  -- Two tasks with one `_id` is a broken document, not a styling choice: the
  -- row says so in the theme's error role rather than a colour chosen here.
  local my_id = id_of(task)
  if my_id and duplicate_ids()[my_id] then
    return { parts = task.parts, tone = "error" }
  end
end)

-- Completing a parent while a child is still open would leave the list claiming
-- work is finished that isn't. The plugin cannot ask a question from inside a
-- hook — a hook is a synchronous call — so it returns `{ confirm = … }`: the app
-- puts that to the user, and a yes re-runs the hook with `confirmed` set. That
-- second pass is where the children actually get completed. A no drops the
-- parent's completion too, which is the point of asking.
-- A hook receives the event context; the task it concerns is `ctx.task`, and the
-- retry flag is `ctx.confirmed` — a fact about the conversation, not the task.
taskle.on("before_complete", function(ctx)
  local task = ctx.task
  if not task or task.completed then
    return
  end
  local mine = id_of(task)
  local open = {}
  if mine then
    for _, t in ipairs(taskle.tasks()) do
      if parent_of(t) == mine and not t.completed then
        open[#open + 1] = t
      end
    end
  end
  if #open == 0 then
    return
  end
  if not ctx.confirmed then
    return {
      confirm = ("This task has %d unfinished sub-task%s. Complete them too?")
        :format(#open, #open == 1 and "" or "s"),
    }
  end
  for _, t in ipairs(open) do
    taskle.task.complete(t.id)
  end
end)

-- Every task under `task`, depth-first: its children, their children, and so on.
-- Bounded because a hand-edited file can point two tasks at each other, and a
-- command must not hang the app over it. (Composition needs no such guard: the
-- host caps depth and breaks cycles for the nester above.)
local function descendants(task)
  local mine = id_of(task)
  if not mine then
    return {}
  end
  local all = taskle.tasks()
  local out, frontier, depth = {}, { mine }, 0
  while #frontier > 0 and depth < 32 do
    local next_frontier = {}
    for _, pid in ipairs(frontier) do
      for _, t in ipairs(all) do
        if parent_of(t) == pid then
          out[#out + 1] = t
          local own = id_of(t)
          if own then
            next_frontier[#next_frontier + 1] = own
          end
        end
      end
    end
    frontier, depth = next_frontier, depth + 1
  end
  return out
end

-- Deleting a parent would leave its children pointing at an id no task carries:
-- they would stop being indented, stop sorting with the family, and read as
-- unrelated top-level tasks. Asked rather than vetoed — the user may well mean
-- "get rid of this whole branch" — and the yes deletes the branch, so the file
-- is never left holding orphans.
taskle.on("before_delete", function(ctx)
  local task = ctx.task
  if not task then
    return
  end
  local kids = descendants(task)
  if #kids == 0 then
    return
  end
  if not ctx.confirmed then
    return {
      confirm = ("This task has %d sub-task%s. Delete them too?")
        :format(#kids, #kids == 1 and "" or "s"),
    }
  end
  for _, t in ipairs(kids) do
    taskle.task.delete(t.id)
  end
end)

-- Add a child of the focused task. The one action that creates a sub-task
-- outright; the two below turn an existing task into one and back.
taskle.command {
  name = "subtasks.new",
  title = "New Sub-task",
  fn = function()
    local focused = taskle.selection().focused
    if not focused then
      return "focus the task the sub-task belongs to first"
    end
    -- The parent needs a stable id before anything can point at it. Assigned
    -- once and left alone afterwards, so re-parenting never renumbers.
    local parent
    for _, t in ipairs(taskle.tasks()) do
      if t.id == focused then
        parent = t
      end
    end
    if not parent then
      return "focus the task the sub-task belongs to first"
    end
    local pid = id_of(parent)
    if not pid then
      pid = next_id()
      taskle.task.set_tag(parent.id, "_id", tostring(pid))
    end
    -- A child is an ordinary task carrying `_parent:<id>`; nothing about it is
    -- special to the app, which is the point of the convention. The app applies
    -- its own new-task rules (the creation-date preference, relative dates) and
    -- focuses what it created, so this does not reimplement any of that.
    --
    -- Drafted rather than created: the request is what opens the app's editor,
    -- and the `set_tag` above rides along as a prerequisite. Neither reaches
    -- the document unless the user saves, so abandoning the sheet cannot leave
    -- the parent carrying an `_id:` nothing references.
    taskle.task.draft("_parent:" .. tostring(pid))
  end,
}

-- Make the focused task a child of the one above it / promote it back to top
-- level. Indent has no menu row of its own — "Make Sub-task of…" is the one
-- that asks which task — but keeps its `>>` key, the quick case of it.
taskle.command {
  name = "subtasks.indent",
  title = "Make Sub-task of Previous",
  fn = function()
    local focused = taskle.selection().focused
    local ts = taskle.tasks()
    for i, t in ipairs(ts) do
      if t.id == focused and i > 1 then
        local above = ts[i - 1]
        local pid = id_of(above)
        if not pid then
          pid = next_id()
          taskle.task.set_tag(above.id, "_id", tostring(pid))
        end
        taskle.task.set_tag(t.id, "_parent", tostring(pid))
        return "sub-task of: " .. above.raw
      end
    end
    return "focus a task that has a task above it first"
  end,
}

-- Make the selected tasks children of one the user points at. The parent is
-- chosen after the command starts, in the list itself: the app holds the call
-- while the user moves to a task and confirms it (`taskle.pick_task`), and
-- answers nil when they cancel.
taskle.command {
  name = "subtasks.make-child-of",
  title = "Make Sub-task of…",
  description = "Choose a task in the list to be the parent of the selected tasks",
  requires = { "selection", "no_visual_range" },
  fn = function()
    if not taskle.supports("pick_task") then
      return "this version of Taskle cannot ask for a task"
    end
    local sel = taskle.selection()
    local children = {}
    for _, id in ipairs(sel.selected) do
      children[id] = true
    end
    if next(children) == nil and sel.focused then
      children[sel.focused] = true
    end
    if next(children) == nil then
      return "select the tasks to move first"
    end
    -- What each child said when the command started, so a change made while
    -- the user was choosing is noticed rather than written over.
    local before = {}
    for _, t in ipairs(taskle.tasks()) do
      if children[t.id] then
        before[t.id] = t.raw
      end
    end

    local picked = taskle.pick_task { prompt = "Make sub-task of" }
    if picked == nil then
      return "no task was changed"
    end

    local tasks = taskle.tasks()
    local by_id, by_uid = {}, {}
    for _, t in ipairs(tasks) do
      by_id[t.id] = t
      local uid = id_of(t)
      -- First wins, as the nesting resolves a repeated `_id`; a repeat met on
      -- the walk below is refused before this choice could matter.
      if uid and not by_uid[uid] then
        by_uid[uid] = t
      end
    end
    for id, raw in pairs(before) do
      if not by_id[id] or by_id[id].raw ~= raw then
        return "a selected task changed while you were choosing; nothing was moved"
      end
    end
    local parent = by_id[picked.id]
    if not parent then
      return "the chosen task is no longer in the list"
    end
    if children[parent.id] then
      return "a task cannot be its own parent"
    end
    local dupes = duplicate_ids()
    local pid = id_of(parent)
    if pid and dupes[pid] then
      return "the chosen task's _id:" .. pid .. " is used by more than one task; fix that first"
    end
    -- Walk up from the chosen parent: reaching one of the children means it
    -- would become its own ancestor. An ancestor named by a repeated `_id` is
    -- refused rather than guessed at: whichever task the walk picked, the
    -- other could be the one that closes a cycle.
    local seen, at = {}, parent
    while at do
      if children[at.id] then
        return "a task cannot be a sub-task of its own sub-task"
      end
      local up = parent_of(at)
      if not up or seen[up] then
        break
      end
      if dupes[up] then
        return "an ancestor of the chosen task has _id:" .. up
          .. ", which more than one task uses; fix that first"
      end
      seen[up] = true
      at = by_uid[up]
    end

    if not pid then
      pid = next_id()
      taskle.task.set_tag(parent.id, "_id", tostring(pid))
    end
    local moved = 0
    for id in pairs(children) do
      taskle.task.set_tag(id, "_parent", tostring(pid))
      moved = moved + 1
    end
    if moved == 1 then
      return "sub-task of: " .. parent.raw
    end
    return moved .. " sub-tasks of: " .. parent.raw
  end,
}

taskle.command {
  name = "subtasks.outdent",
  title = "Promote Sub-task",
  fn = function()
    local focused = taskle.selection().focused
    for _, t in ipairs(taskle.tasks()) do
      if t.id == focused and parent_of(t) then
        taskle.task.remove_tag(t.id, "_parent")
        return "promoted to a top-level task"
      end
    end
  end,
}

-- The three actions, grouped under Task so a sub-task is something you can find
-- rather than something you have to know about. Every one of them is an
-- ordinary command, so `keys.toml` can rebind it like any built-in:
--
--   [[bind]]
--   keys = "<D-S-n>"
--   command = "subtasks.new"
taskle.menu { title = "New Sub-task", command = "subtasks.new", menu = "Task", submenu = "Sub-tasks" }
taskle.menu {
  title = "Make Sub-task of…",
  command = "subtasks.make-child-of",
  menu = "Task",
  submenu = "Sub-tasks",
}
taskle.menu {
  title = "Promote Sub-task",
  command = "subtasks.outdent",
  menu = "Task",
  submenu = "Sub-tasks",
}

-- Default keys, chosen to sit beside the app's own: ⇧⌘N next to New Task, and
-- Vim's shift-indent pair. A `keys.toml` binding overrides any of them.
-- ⇧N, beside the bare `n` that adds an ordinary task.
taskle.bind { keys = "N", command = "subtasks.new" }
taskle.bind { keys = ">>", command = "subtasks.indent" }
-- `<` opens a bracketed chord in the key syntax, so a literal one is `<lt>`.
taskle.bind { keys = "<lt><lt>", command = "subtasks.outdent" }

-- Show only top-level tasks (children hidden). Pick it from Define Filters, or
-- bind a key to it.
-- A modifier, not an alternative list: it drops the children from whatever the
-- user is already looking at, so it narrows rather than standing in for a
-- preset, and it belongs with the Filter menu's other "Hide … Tasks" toggles.
-- Batched like every composition slot: one call per recompose over the whole
-- candidate array, answering with one boolean per candidate.
taskle.filter {
  name = "roots",
  description = "Hide Sub Tasks",
  menu = "Filter",
  fn = function(ctx)
    local out = {}
    for i = 1, #ctx.candidates do
      out[i] = parent_of(ctx.candidates[i]) == nil
    end
    return out
  end,
}
