-- Google Drive Sync's status bar item, run with the host's taskle-plugin-test:
--   cargo run -p taskle-plugin-test -- plugins/gdrive-sync

local DRIVE = "https://www.googleapis.com/drive/v3/files"

local function authorized(t)
  t.secret("credential", '{"access_token":"T","expires":' .. (os.time() + 86400) .. ',"account_id":"P1"}')
end

local function meta(t, id, version)
  t.http {
    url = DRIVE .. "/" .. id .. "?fields=id,name,version,headRevisionId,modifiedTime,trashed",
    body = '{"id":"' .. id .. '","name":"todo.txt","version":"' .. version .. '"}',
  }
end

-- `todo.txt` linked to the Drive file F1 at version 3, both holding `content`.
local function linked(t, content)
  authorized(t)
  t.open("todo.txt", content)
  meta(t, "F1", "3")
  t.window("pasted", "F1")
  meta(t, "F1", "3")
  t.http { url = DRIVE .. "/F1?alt=media", body = content }
  t.click("Link this file")
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
  t.eq(texts(t), { "Drive ✓" })
end)

case("a right-click offers Sync Now, the document window and the settings", function(t)
  linked(t, "a task\n")
  t.click_status("status", "right")
  t.eq(t.choice(), { prompt = "Google Drive Sync", items = { "sync", "document", "settings" } })
  t.choose()
end)

case("Sync Now is refused, and greyed, while the document is not linked", function(t)
  t.open("todo.txt", "a task\n")
  local ok, why = t.command("now")
  t.ok(not ok)
  t.contains(why, "Sync Now: this document is not linked to it")
end)

-- A request that could not be made at all is said as a sentence, not as the
-- error the host raised — that goes to the log.
case("a run that cannot reach Drive says so in words", function(t)
  linked(t, "a task\n")
  t.edit("todo.txt", "a task\nmore\n")
  local url = DRIVE .. "/F1?fields=id,name,version,headRevisionId,modifiedTime,trashed"
  t.http {
    url = url,
    error = 'taskle.http.get "' .. url .. '": io: failed to lookup address information',
  }
  t.ok(t.save())
  local status = t.link().status
  t.eq(status.state, "error")
  t.eq(status.message, "Could not reach Google Drive; check the network connection. "
    .. "It will try again on the next sync")
  t.eq(texts(t), { "Drive ⚠" })
end)

case("any other failure keeps its message, without where it was raised", function(t)
  linked(t, "a task\n")
  t.edit("todo.txt", "a task\nmore\n")
  local url = DRIVE .. "/F1?fields=id,name,version,headRevisionId,modifiedTime,trashed"
  t.http { url = url, error = "something unexpected" }
  t.ok(t.save())
  local status = t.link().status
  t.eq(status.state, "error")
  t.eq(status.message, "Sync failed: something unexpected")
end)

-- A sign-in that stopped working stops every document it syncs, so the item
-- says so beside each of them, as well as each document's own error.
case("a sign-in that stopped working is said in the item's tooltip", function(t)
  linked(t, "a task\n")
  t.secret("credential", '{"access_token":"","expires":0,"account_id":"P1"}')
  t.edit("todo.txt", "a task\nmore\n")
  t.ok(t.save())
  t.eq(t.link().status.state, "error")
  t.eq(texts(t), { "Drive ⚠" })
  -- The account's line, apart from the document's error that says the same.
  t.contains(t.status_items()[1].tooltip, "open Google Drive Sync to sign in. Click to sync")
end)
