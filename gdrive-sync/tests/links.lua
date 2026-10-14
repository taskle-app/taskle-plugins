-- Google Drive Sync on host links, run with the host's taskle-plugin-test:
--   cargo run -p taskle-plugin-test -- plugins/gdrive-sync

local DRIVE = "https://www.googleapis.com/drive/v3/files"
local UPLOAD = "https://www.googleapis.com/upload/drive/v3/files"
local IDS = DRIVE .. "/generateIds?count=1&space=drive&type=files"
local CREATE = UPLOAD .. "?uploadType=multipart&fields=id,name,version"
local LIST = DRIVE .. "?fields=files%28id%2Cname%2CmodifiedTime%29&orderBy=modifiedTime+desc"
  .. "&pageSize=50&q=trashed+%3D+false+and+mimeType+%3D+%27text%2Fplain%27"

local function authorized(t)
  t.secret("access_token", "T")
  t.state("access_expires", tostring(os.time() + 86400))
end

local function meta(t, id, version, extra)
  t.http {
    url = DRIVE .. "/" .. id .. "?fields=id,name,version,modifiedTime,trashed",
    body = '{"id":"' .. id .. '","name":"todo.txt","version":"' .. version .. '"' .. (extra or "") .. "}",
  }
end

local function body(t, id, content)
  t.http { url = DRIVE .. "/" .. id .. "?alt=media", body = content }
end

local function upload(t, id, status, version)
  t.http {
    method = "PATCH",
    url = UPLOAD .. "/" .. id .. "?uploadType=media&fields=id,version",
    status = status,
    body = version and ('{"id":"' .. id .. '","version":"' .. version .. '"}') or "",
  }
end

-- `todo.txt` linked to the Drive file F1 at version 3, both holding `content`.
local function linked(t, content)
  authorized(t)
  t.open("todo.txt", content)
  meta(t, "F1", "3")
  t.window("pasted", "F1")
  meta(t, "F1", "3")
  body(t, "F1", content)
  t.click("Link this file")
  t.eq(t.link().status.state, "ok", "linked and compared")
end

local function count(t, what)
  local n = 0
  for _, request in ipairs(t.requests()) do
    if request.url and request.url:find(what, 1, true) then n = n + 1 end
  end
  return n
end

case("Create makes the Drive file under a reserved id and links it", function(t)
  authorized(t)
  t.open("todo.txt", "a task\n")
  t.http { url = IDS, body = '{"ids":["F1"]}' }
  t.http { method = "POST", url = CREATE, body = '{"id":"F1","name":"todo.txt","version":"3"}' }
  t.click("Create Drive file")

  local link = t.link()
  t.eq(link.remote, "F1")
  t.eq(link.label, "Drive: todo.txt")
  t.eq(link.status.state, "ok")
  t.eq(link.pending, false, "the run confirmed what it uploaded")
  t.eq(link.state.creating_id, nil)
  t.eq(link.state.version, "3")
  local created = t.requests()[2].body
  t.contains(created, '"id":"F1"')
  t.contains(created, "a task\n")
end)

case("a create whose answer was lost is adopted, not made twice", function(t)
  authorized(t)
  t.open("todo.txt", "a task\n")
  t.http { url = IDS, body = '{"ids":["F1"]}' }
  t.http { method = "POST", url = CREATE, error = "timed out" }
  t.click("Create Drive file")
  t.eq(t.link().status.state, "error")
  t.eq(t.link().state.creating_id, "F1")
  t.eq(t.link().remote, "")

  -- It had landed. The next run finds it under the reserved id.
  meta(t, "F1", "3")
  meta(t, "F1", "3")
  body(t, "F1", "a task\n")
  t.click("Sync Now")
  local link = t.link()
  t.eq(link.remote, "F1")
  t.eq(link.status.state, "ok")
  t.eq(link.state.creating_id, nil)
  t.eq(count(t, "generateIds"), 1)
  t.eq(count(t, "uploadType=multipart"), 1, "never created twice")
end)

case("a create that never landed is retried under the same id", function(t)
  authorized(t)
  t.open("todo.txt", "a task\n")
  t.http { url = IDS, body = '{"ids":["F1"]}' }
  t.http { method = "POST", url = CREATE, error = "timed out" }
  t.click("Create Drive file")

  t.http { url = DRIVE .. "/F1?fields=id,name,version,modifiedTime,trashed", status = 404 }
  t.http { method = "POST", url = CREATE, body = '{"id":"F1","name":"todo.txt","version":"1"}' }
  t.click("Sync Now")
  t.eq(t.link().remote, "F1")
  t.eq(t.link().status.state, "ok")
  t.eq(count(t, "generateIds"), 1, "the reserved id is reused")
  local creates = {}
  for _, request in ipairs(t.requests()) do
    if request.method == "POST" then creates[#creates + 1] = request.body end
  end
  t.eq(#creates, 2)
  t.contains(creates[2], '"id":"F1"')
end)

case("unlinking before the create finished stops it", function(t)
  authorized(t)
  t.open("todo.txt", "a task\n")
  t.http { url = IDS, body = '{"ids":["F1"]}' }
  t.http { method = "POST", url = CREATE, error = "timed out" }
  t.click("Create Drive file")
  local before = #t.requests()

  t.click("Unlink")
  t.eq(t.link(), nil)
  t.fire("after_save", "todo.txt")
  t.fire("poll")
  t.eq(#t.requests(), before, "nothing more is asked of Drive")
  t.contains(t.view(), "No documents are linked; nothing is syncing.")
end)

case("an unlinked document asks nothing of Drive", function(t)
  authorized(t)
  t.open("todo.txt", "a task\n")
  t.edit("todo.txt", "a task\nmore\n")
  t.ok(t.save())
  t.fire("poll")
  t.eq(#t.requests(), 0)
  t.contains(t.view(), "Not linked: this document does not sync.")
end)

case("Create without authorization links nothing", function(t)
  t.open("todo.txt", "a task\n")
  t.click("Create Drive file")
  t.eq(t.link(), nil)
  t.contains(t.view(), "Authorize Google Drive first.")
end)

case("losing authorization is an error, not a skip", function(t)
  linked(t, "a task\n")
  t.state("access_expires", "0")
  t.click("Sync Now")
  local status = t.link().status
  t.eq(status.state, "error")
  t.contains(status.message, "Not authorized: open Google Drive Sync to sign in; todo.txt is not syncing")
end)

case("linking an equal file records the base", function(t)
  linked(t, "a task\n")
  t.eq(t.link().state.version, "3")
  t.eq(t.link().pending, false)
end)

case("linking a different file keeps both and adopts neither", function(t)
  authorized(t)
  t.open("todo.txt", "mine\n")
  meta(t, "F1", "3")
  t.window("pasted", "https://drive.google.com/file/d/F1/view")
  meta(t, "F1", "3")
  body(t, "F1", "theirs\n")
  t.click("Link this file")
  t.eq(t.link().status.state, "conflict")
  t.eq(t.conflict(), "theirs\n")
  t.eq(t.content(), "mine\n")
  t.eq(t.read("todo.txt"), "mine\n")
  t.eq(t.link().pending, true)
end)

case("Link existing file lists Drive's text files to pick from", function(t)
  authorized(t)
  t.open("todo.txt", "a task\n")
  t.http {
    url = LIST,
    body = '{"files":[{"id":"F7","name":"work.txt","modifiedTime":"2026-10-01T09:00:00Z"}]}',
  }
  t.click("Link existing file")
  t.contains(t.view(), "[work.txt — modified 2026-10-01T09:00:00Z]")
  meta(t, "F7", "2")
  body(t, "F7", "a task\n")
  t.click("work.txt — modified 2026-10-01T09:00:00Z")
  t.eq(t.link().remote, "F7")
  t.eq(t.link().label, "Drive: work.txt")
  t.eq(t.link().status.state, "ok")
end)

case("a pasted id Drive will not open is refused, and nothing is linked", function(t)
  authorized(t)
  t.open("todo.txt", "a task\n")
  t.http { url = DRIVE .. "/F9?fields=id,name,version,modifiedTime,trashed", status = 404 }
  t.window("pasted", "F9")
  t.click("Link this file")
  t.eq(t.link(), nil)
  t.contains(t.view(), "Drive has no file F9 this app may open")
end)

case("a saved change uploads", function(t)
  linked(t, "a task\n")
  t.edit("todo.txt", "a task\nmore\n")
  meta(t, "F1", "3")
  body(t, "F1", "a task\n")
  meta(t, "F1", "3")
  upload(t, "F1", 200, "4")
  meta(t, "F1", "4")
  t.ok(t.save())
  local link = t.link()
  t.eq(link.status.state, "ok")
  t.eq(link.pending, false)
  t.eq(link.state.version, "4")
end)

case("a failed upload stays pending, and the next run of any event sends it", function(t)
  linked(t, "a task\n")
  t.edit("todo.txt", "a task\nmore\n")
  meta(t, "F1", "3")
  body(t, "F1", "a task\n")
  meta(t, "F1", "3")
  upload(t, "F1", 500)
  t.ok(t.save())
  t.eq(t.link().status.state, "error")
  t.eq(t.link().pending, true, "the remote never got it")

  -- As when the document is opened again later.
  meta(t, "F1", "3")
  body(t, "F1", "a task\n")
  meta(t, "F1", "3")
  upload(t, "F1", 200, "4")
  meta(t, "F1", "4")
  t.fire("file_loaded", "todo.txt")
  t.eq(t.link().status.state, "ok")
  t.eq(t.link().pending, false)
end)

case("a change on Drive alone replaces the document", function(t)
  linked(t, "a task\n")
  meta(t, "F1", "5")
  body(t, "F1", "a task\nfrom elsewhere\n")
  t.click("Sync Now")
  t.eq(t.content(), "a task\nfrom elsewhere\n")
  t.eq(t.link().status.state, "ok")
end)

case("changes on both sides keep both", function(t)
  linked(t, "a task\n")
  t.edit("todo.txt", "a task\nmine\n")
  meta(t, "F1", "5")
  body(t, "F1", "a task\ntheirs\n")
  t.ok(t.save())
  t.eq(t.link().status.state, "conflict")
  t.eq(t.conflict(), "a task\ntheirs\n")
  t.eq(t.read("todo.txt"), "a task\nmine\n")
end)

case("a Drive file moved to the trash is an error", function(t)
  linked(t, "a task\n")
  meta(t, "F1", "3", ',"trashed":true')
  t.click("Sync Now")
  t.eq(t.link().status.state, "error")
  t.contains(t.link().status.message, "moved to the trash")
end)

case("Drive being unreachable is an error that keeps the link", function(t)
  linked(t, "a task\n")
  t.http { url = DRIVE .. "/F1?fields=id,name,version,modifiedTime,trashed", status = 503 }
  t.click("Sync Now")
  t.eq(t.link().status.state, "error")
  t.eq(t.link().remote, "F1")
end)

case("a poll soon after a run asks nothing and keeps the status", function(t)
  linked(t, "a task\n")
  local before = #t.requests()
  t.fire("poll")
  t.eq(#t.requests(), before)
  t.eq(t.link().status.state, "ok")
end)
