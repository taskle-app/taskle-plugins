-- Dropbox Sync's status bar item, run with the host's taskle-plugin-test:
--   cargo run -p taskle-plugin-test -- plugins/dropbox-sync

local META = "https://api.dropboxapi.com/2/files/get_metadata"
local DOWNLOAD = "https://content.dropboxapi.com/2/files/download"
local UPLOAD = "https://content.dropboxapi.com/2/files/upload"

local function authorized(t)
  t.secret("credential", '{"access_token":"T","expires":' .. (os.time() + 86400) .. ',"account_id":"dbid:A"}')
end

local function meta(t, rev)
  t.http { method = "POST", url = META, body = '{"name":"todo.txt","rev":"' .. rev .. '"}' }
end

local function remote(t, rev, content)
  t.http { method = "POST", url = DOWNLOAD, body = content,
           headers = { ["Dropbox-API-Result"] = '{"rev":"' .. rev .. '"}' } }
end

-- `todo.txt` linked to /Taskle/todo.txt at revision r1, both holding `content`.
local function linked(t, content)
  authorized(t)
  t.open("todo.txt", content)
  t.http { method = "POST", url = META, body = '{"name":"todo.txt","rev":"r1"}' }
  t.http { method = "POST", url = DOWNLOAD, body = content,
           headers = { ["Dropbox-API-Result"] = '{"rev":"r1"}' } }
  t.click("Link")
  t.eq(t.link().status.state, "ok", "linked and compared")
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

case("a linked document in sync shows a tick", function(t)
  linked(t, "a task\n")
  t.eq(texts(t), { "Dropbox ✓" })
  t.contains(t.status_items()[1].tooltip, "Synced to Dropbox: /Taskle/todo.txt")
end)

case("a run that ends in a conflict shows a warning, with why in the tooltip", function(t)
  linked(t, "a task\n")
  t.edit("todo.txt", "a task\nmine\n")
  meta(t, "r1")
  remote(t, "r1", "a task\n")
  t.http { method = "POST", url = UPLOAD, status = 409, body = '{"error_summary":"path/conflict/file/"}' }
  remote(t, "r2", "a task\ntheirs\n")
  remote(t, "r1", "a task\n")
  t.ok(t.save())
  t.eq(t.link().status.state, "conflict")
  t.eq(texts(t), { "Dropbox ⚠" })
  t.contains(t.status_items()[1].tooltip, "Dropbox: /Taskle/todo.txt")
end)

case("a click syncs the linked document in front", function(t)
  linked(t, "a task\n")
  meta(t, "r1")
  remote(t, "r1", "a task\n")
  t.eq({ t.click_status("status") }, { true, nil }, "nothing left standing on the status line")
  t.eq(t.link().status.state, "ok", "the run it asked for happened")
  t.eq(texts(t), { "Dropbox ✓" }, "and the item shows how it ended")
end)

case("a right-click offers Sync Now, the document window and the settings", function(t)
  linked(t, "a task\n")
  t.click_status("status", "right")
  t.eq(t.choice(), { prompt = "Dropbox Sync", items = { "sync", "document", "settings" } })
  t.eq({ t.choose() }, { true, nil }, "cancelled, nothing done")
end)

case("Sync Now is refused, and greyed, while the document is not linked", function(t)
  t.open("todo.txt", "a task\n")
  local ok, why = t.command("now")
  t.ok(not ok)
  t.contains(why, "Sync Now: this document is not linked to it")
end)

case("the item shows only beside a linked document", function(t)
  linked(t, "a task\n")
  t.eq(#t.status_items(), 1)
  t.open("other.txt", "not synced\n")
  t.eq(#t.status_items(), 0, "nothing beside a document it does not sync")
  t.front("todo.txt")
  t.eq(#t.status_items(), 1, "and back beside the linked one")
end)

-- A sign-in that stopped working stops every document it syncs, so the item
-- says so beside each of them, as well as each document's own error.
case("a sign-in that stopped working is said in the item's tooltip", function(t)
  linked(t, "a task\n")
  t.secret("credential", '{"access_token":"","expires":0,"account_id":"dbid:A"}')
  t.edit("todo.txt", "a task\nmore\n")
  t.ok(t.save())
  t.eq(t.link().status.state, "error")
  t.eq(texts(t), { "Dropbox ⚠" })
  -- The account's line, apart from the document's error that says the same.
  t.contains(t.status_items()[1].tooltip, "open Dropbox Sync to sign in. Click to sync")
end)
