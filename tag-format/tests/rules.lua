-- Tag Format's rules, saved through its configure window and checked against
-- the rows the list draws, run with the host's taskle-plugin-test:
--   cargo run -p taskle-plugin-test -- plugins/tag-format
--
-- Every case asserts what a row draws, not only what the window says: a parser
-- change that still accepts a line can change what that line means.
--
-- A row is drawn under the default preferences, whose compact fields put `-`
-- where a task with no priority would show one.

-- Save `text` as the rules and return the window's status line.
local function save(t, text)
  t.window("edit", text)
  t.click("Save")
  local view = t.view()
  return view[#view]
end

-- The drawn part of row `n` whose kind is `kind`.
local function part(t, n, kind)
  for _, p in ipairs(t.row_parts(n)) do
    if p.kind == kind then
      return p
    end
  end
  t.fail("row " .. n .. " draws no " .. kind .. " part")
end

case("with no rules saved, rows draw as written", function(t)
  t.open("todo.txt", "call mom +home note:x _state:on\n")
  t.eq(t.rows(), { "- call mom +home note:x" })
end)

-- ----- bare labels -----

case("a bare label rewrites the tag and fills in its placeholders", function(t)
  t.open("todo.txt", "call mom +home note:x\n")
  t.eq(save(t, "note = [{key}={value}] fg:#a6e3a1\n+home = 🏠{value}\n"), "2 rules saved.")
  t.eq(t.rows(), { "- call mom 🏠home [note=x]" })
  t.eq(part(t, 1, "tag").fg, "#a6e3a1")
end)

case("a bare label drops its option words wherever they stand", function(t)
  t.open("todo.txt", "call mom note:x\n")
  t.eq(save(t, "note = a   show b fg:#a6e3a1\n"), "1 rule saved.")
  t.eq(t.rows(), { "- call mom a b" })
end)

case("a quote inside a bare label is drawn as text", function(t)
  t.open("todo.txt", "call mom note:x\n")
  t.eq(save(t, 'note = say "hi" fg:#a6e3a1\n'), "1 rule saved.")
  t.eq(t.rows(), { '- call mom say "hi"' })
end)

case("an empty bare label keeps the text and applies the colours", function(t)
  t.open("todo.txt", "call mom +home\n")
  t.eq(save(t, "+home = fg:#a6e3a1 bg:#45475a\n"), "1 rule saved.")
  t.eq(t.rows(), { "- call mom +home" })
  t.eq(part(t, 1, "project"), { kind = "project", text = "+home", fg = "#a6e3a1", bg = "#45475a" })
end)

-- ----- quoted labels -----

case("a quoted label may be a word that reads as an option", function(t)
  t.open("todo.txt", "call mom _state:on\n")
  t.eq(save(t, '_state = "show" fg:#a6e3a1\n'), "1 rule saved.")
  -- `show` is the label, not the option, so the hidden tag stays hidden.
  t.eq(t.rows(), { "- call mom" })
  t.eq(save(t, '_state = "hide" show\n'), "1 rule saved.")
  t.eq(t.rows(), { "- call mom hide" })
end)

case("a quoted label keeps its spaces", function(t)
  t.open("todo.txt", "call mom +home\n")
  t.eq(save(t, '+home = " {value}  here " bg:#45475a\n'), "1 rule saved.")
  t.eq(part(t, 1, "project").text, " home  here ")
end)

case("a quoted label's escapes are a quote and a backslash", function(t)
  t.open("todo.txt", "call mom note:x\n")
  t.eq(save(t, 'note = "say \\"hi\\" \\\\o/ \\n"\n'), "1 rule saved.")
  -- Any other backslash is kept as written.
  t.eq(t.rows(), { '- call mom say "hi" \\o/ \\n' })
end)

case("a label that starts with a quote is a quoted label", function(t)
  -- Before quoting existed this drew `"hi"`, quotes and all; it now draws the
  -- label inside them. Pinned so the next change to it is a decision.
  t.open("todo.txt", "call mom note:x\n")
  t.eq(save(t, 'note = "hi"\n'), "1 rule saved.")
  t.eq(t.rows(), { "- call mom hi" })
end)

case("an empty quoted label keeps the text", function(t)
  t.open("todo.txt", "call mom note:x\n")
  t.eq(save(t, 'note = "" fg:#a6e3a1\n'), "1 rule saved.")
  t.eq(t.rows(), { "- call mom note:x" })
  t.eq(part(t, 1, "tag").fg, "#a6e3a1")
end)

-- ----- refused lines -----

case("a quoted label with no closing quote is refused by line", function(t)
  t.open("todo.txt", "call mom note:x +home\n")
  t.eq(
    save(t, "+home = 🏠\nnote = \"show fg:#a6e3a1\n"),
    "1 saved, 1 skipped — line 2: no closing quote on the label"
  )
  t.eq(t.rows(), { "- call mom note:x 🏠" })
end)

case("only options may follow a quoted label", function(t)
  -- Before quoting existed this drew `"hi" x`; the line is now refused.
  t.open("todo.txt", "call mom note:x\n")
  t.eq(
    save(t, 'note = "hi" {value}\n'),
    "0 saved, 1 skipped — line 1: not an option after the quoted label: {value}"
  )
  t.eq(t.rows(), { "- call mom note:x" })
end)

case("a bad colour after a quoted label is still caught", function(t)
  t.open("todo.txt", "call mom note:x\n")
  t.eq(save(t, 'note = "on" fg:#zz\n'), "0 saved, 1 skipped — line 1: not a colour: #zz")
  t.eq(t.rows(), { "- call mom note:x" })
end)
