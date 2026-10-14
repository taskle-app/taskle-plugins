-- Kanban's windows, run with the host's taskle-plugin-test:
--   cargo run -p taskle-plugin-test -- plugins/kanban

local function said(view, needle)
  for _, line in ipairs(view) do
    if line:find(needle, 1, true) then return true end
  end
  return false
end

case("each document's board says what was done on it alone", function(t)
  t.open("a.txt", "first\n")
  local id = 0
  t.ok(t.window("move:" .. id .. ":2"))
  t.ok(said(t.view(), "moved to"), "A's board reports the move")

  t.open("b.txt", "second\n")
  t.ok(not said(t.view(), "moved to"), "B's board is its own")

  t.front("a.txt")
  t.ok(said(t.view(), "moved to"), "and A's still says it")
end)

case("the stage list is edited once per project", function(t)
  t.open("a.txt", "first\n")
  t.ok(t.window("stages", "todo\nnext\ndone", "kanban.configure"))
  t.open("b.txt", "second\n")
  -- Both documents are in no project, so they share the unscoped instance.
  t.contains(t.view("kanban.configure"), "todo\nnext\ndone")
end)
