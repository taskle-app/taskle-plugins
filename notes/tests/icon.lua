-- The icon a row with a note draws, run with the host's taskle-plugin-test:
--   cargo run -p taskle-plugin-test -- plugins/notes
--
-- A row is drawn under the default preferences, whose compact fields put `-`
-- where a task with no priority would show one.

case("a task with a note draws the icon where its tag stands", function(t)
  t.open("todo.txt", "call mom _note:abcdefghij +home\n")
  t.eq(t.rows(), { "- call mom 📝 +home" })
end)

case("a task with no note draws as written", function(t)
  t.open("todo.txt", "call mom +home _state:on\n")
  t.eq(t.rows(), { "- call mom +home" })
end)

case("a tag that only begins like the note tag is left alone", function(t)
  t.open("todo.txt", "call mom _notes:x\n")
  t.eq(t.rows(), { "- call mom" })
end)
