-- Git Sync's status bar item, against a real repository the case builds, run
-- with the host's taskle-plugin-test:
--   cargo run -p taskle-plugin-test -- plugins/git-sync

local function shell(t, command)
  local full = "cd '" .. t.dir .. "' && " .. command .. " >/dev/null 2>&1"
  if not os.execute(full) then error("setup failed: " .. command, 2) end
end

local IDENTITY = "git config user.email t@example.com && git config user.name Test && git config commit.gpgsign false"

-- `work/todo.txt` committed, pushed to `remote.git`, open and linked to origin.
local function linked(t)
  t.run_for_real("git", "sh", "chmod")
  shell(t, "git init -q --bare -b main remote.git")
  shell(t, "git init -q -b main work && cd work && " .. IDENTITY)
  t.write("work/todo.txt", "a task\n")
  shell(t, "cd work && git add -A && git commit -q -m start && git remote add origin ../remote.git && git push -q -u origin main")
  t.open("work/todo.txt", "a task\n")
  t.click("Link to origin")
  t.eq(t.link("work/todo.txt").status.state, "ok", "linked")
end

local function texts(t)
  local out = {}
  for _, item in ipairs(t.status_items()) do out[#out + 1] = item.text end
  return out
end

case("with nothing linked there is no item", function(t)
  t.open("todo.txt", "a task\n")
  t.eq(texts(t), {})
end)

case("a linked document in sync shows a tick, and a click syncs it", function(t)
  linked(t)
  t.eq(texts(t), { "Git ✓" })
  t.eq({ t.click_status("status") }, { true, nil }, "nothing left standing on the status line")
  t.eq(texts(t), { "Git ✓" })
end)

case("a right-click offers Sync Now and the document window", function(t)
  linked(t)
  t.click_status("status", "right")
  t.eq(t.choice(), { prompt = "Git Sync", items = { "sync", "document" } })
  t.choose()
end)
