-- The pomodoro's status bar item, run with the host's taskle-plugin-test:
--   cargo run -p taskle-plugin-test -- plugins/pomodoro

local function item(t)
  local items = t.status_items()
  t.eq(#items, 1, "one item")
  return items[1]
end

case("with nothing running the item offers to start one", function(t)
  t.open("todo.txt", "write the report\n")
  t.eq(item(t).text, "🍅")
end)

case("a click starts one on the focused task and the item counts down", function(t)
  t.open("todo.txt", "write the report\n")
  t.focus(1)
  t.eq({ t.click_status("clock") }, { true, "25 minutes on: write the report" })
  t.eq(item(t).text, "🍅 25m")
end)

case("a click with nothing focused says so and starts nothing", function(t)
  t.open("todo.txt", "write the report\n")
  t.eq({ t.click_status("clock") }, { true, "focus the task you are working on first" })
  t.eq(item(t).text, "🍅")
end)

case("a click pauses the one running, and another resumes it", function(t)
  t.open("todo.txt", "write the report\n")
  t.focus(1)
  t.click_status("clock")
  t.eq({ t.click_status("clock") }, { true, "paused with 25 minutes left" })
  t.eq(item(t).text, "⏸ 25m")
  t.eq({ t.click_status("clock") }, { true, "resumed — 25 minutes left" })
  t.eq(item(t).text, "🍅 25m")
end)

case("a right-click offers pause and stop, and stop ends the interval", function(t)
  t.open("todo.txt", "write the report\n")
  t.focus(1)
  t.click_status("clock")
  t.click_status("clock", "right")
  t.eq(t.choice(), { prompt = "Pomodoro", items = { "pause", "stop" } })
  t.eq({ t.choose("stop") }, { true, "stopped — this interval does not count" })
  t.eq(item(t).text, "🍅")
end)

case("a right-click with nothing running starts nothing and asks nothing", function(t)
  t.open("todo.txt", "write the report\n")
  t.focus(1)
  t.click_status("clock", "right")
  t.eq(t.choice(), nil)
  t.eq(item(t).text, "🍅")
end)

case("the commands move the item too", function(t)
  t.open("todo.txt", "write the report\n")
  t.focus(1)
  t.command("pomodoro.start")
  t.eq(item(t).text, "🍅 25m")
  t.command("pomodoro.stop")
  t.eq(item(t).text, "🍅")
end)
