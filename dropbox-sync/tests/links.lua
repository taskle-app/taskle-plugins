-- Dropbox Sync on host links, run with the host's taskle-plugin-test:
--   cargo run -p taskle-plugin-test -- plugins/dropbox-sync

local META = "https://api.dropboxapi.com/2/files/get_metadata"
local DOWNLOAD = "https://content.dropboxapi.com/2/files/download"
local UPLOAD = "https://content.dropboxapi.com/2/files/upload"

local function authorized(t)
  t.secret("access_token", "T")
  t.state("access_expires", tostring(os.time() + 86400))
end

local function meta(t, rev)
  t.http { method = "POST", url = META, body = '{"name":"todo.txt","rev":"' .. rev .. '"}' }
end

local function missing(t)
  t.http { method = "POST", url = META, status = 409,
           body = '{"error_summary":"path/not_found/","error":{".tag":"path"}}' }
end

local function remote(t, rev, content)
  t.http { method = "POST", url = DOWNLOAD, body = content,
           headers = { ["Dropbox-API-Result"] = '{"rev":"' .. rev .. '"}' } }
end

local function uploaded(t, rev)
  t.http { method = "POST", url = UPLOAD, body = '{"rev":"' .. rev .. '"}' }
end

local function uploads(t)
  local found = {}
  for _, request in ipairs(t.requests()) do
    if request.url == UPLOAD then found[#found + 1] = request end
  end
  return found
end

-- `todo.txt` linked to /Taskle/todo.txt at revision r1, both holding `content`.
local function linked(t, content)
  authorized(t)
  t.open("todo.txt", content)
  meta(t, "r1")
  remote(t, "r1", content)
  t.click("Link")
  t.eq(t.link().status.state, "ok", "linked and compared")
end

case("the path is suggested from the document's name", function(t)
  t.open("work.txt", "a task\n")
  t.contains(t.view(), "/Taskle/work.txt")
end)

case("linking to a path with nothing there uploads the document as a new file", function(t)
  authorized(t)
  t.open("todo.txt", "a task\n")
  missing(t)
  uploaded(t, "r1")
  t.click("Link")
  local link = t.link()
  t.eq(link.remote, "/Taskle/todo.txt")
  t.eq(link.label, "Dropbox: /Taskle/todo.txt")
  t.eq(link.status.state, "ok")
  t.eq(link.pending, false)
  t.eq(link.state.rev, "r1")
  local sent = uploads(t)[1]
  t.eq(sent.body, "a task\n")
end)

case("a file that appears before the first upload is kept, not overwritten", function(t)
  authorized(t)
  t.open("todo.txt", "mine\n")
  missing(t)
  t.http { method = "POST", url = UPLOAD, status = 409, body = '{"error_summary":"path/conflict/file/"}' }
  remote(t, "r1", "theirs\n")
  t.click("Link")
  t.eq(t.link().status.state, "conflict")
  t.eq(t.conflict(), "theirs\n")
  t.eq(t.read("todo.txt"), "mine\n")
end)

case("linking an equal file records the base", function(t)
  linked(t, "a task\n")
  t.eq(t.link().state.rev, "r1")
  t.eq(t.link().pending, false)
  t.eq(#uploads(t), 0)
end)

case("linking a different file keeps both and adopts neither", function(t)
  authorized(t)
  t.open("todo.txt", "mine\n")
  meta(t, "r1")
  remote(t, "r1", "theirs\n")
  t.click("Link")
  t.eq(t.link().status.state, "conflict")
  t.eq(t.conflict(), "theirs\n")
  t.eq(t.content(), "mine\n")
end)

case("a path another document holds is refused by name, in any case", function(t)
  linked(t, "a task\n")
  t.open("other.txt", "b task\n")
  t.window("path", "/taskle/TODO.txt")
  t.click("Link")
  t.eq(t.link("other.txt"), nil)
  t.contains(t.view(), "that remote is already linked to")
end)

case("a typed path is normalized", function(t)
  authorized(t)
  t.open("todo.txt", "a task\n")
  t.window("path", "  Lists//todo.txt/ ")
  meta(t, "r1")
  remote(t, "r1", "a task\n")
  t.click("Link")
  t.eq(t.link().remote, "/Lists/todo.txt")
end)

case("a saved change uploads over the revision it replaces", function(t)
  linked(t, "a task\n")
  t.edit("todo.txt", "a task\nmore\n")
  meta(t, "r1")
  remote(t, "r1", "a task\n")
  uploaded(t, "r2")
  t.ok(t.save())
  local link = t.link()
  t.eq(link.status.state, "ok")
  t.eq(link.pending, false)
  t.eq(link.state.rev, "r2")
  local sent = uploads(t)[1]
  t.contains(sent.body, "more")
end)

case("an upload Dropbox refuses as stale keeps both", function(t)
  linked(t, "a task\n")
  t.edit("todo.txt", "a task\nmine\n")
  meta(t, "r1")
  remote(t, "r1", "a task\n")
  t.http { method = "POST", url = UPLOAD, status = 409, body = '{"error_summary":"path/conflict/file/"}' }
  remote(t, "r2", "a task\ntheirs\n")
  t.ok(t.save())
  t.eq(t.link().status.state, "conflict")
  t.eq(t.conflict(), "a task\ntheirs\n")
  t.eq(t.link().pending, true)
end)

case("a failed upload stays pending, and the next run of any event sends it", function(t)
  linked(t, "a task\n")
  t.edit("todo.txt", "a task\nmore\n")
  meta(t, "r1")
  remote(t, "r1", "a task\n")
  t.http { method = "POST", url = UPLOAD, status = 500 }
  t.ok(t.save())
  t.eq(t.link().status.state, "error")
  t.eq(t.link().pending, true)

  meta(t, "r1")
  remote(t, "r1", "a task\n")
  uploaded(t, "r2")
  t.fire("file_loaded", "todo.txt")
  t.eq(t.link().status.state, "ok")
  t.eq(t.link().pending, false)
end)

case("a change on Dropbox alone replaces the document", function(t)
  linked(t, "a task\n")
  meta(t, "r2")
  remote(t, "r2", "a task\nfrom elsewhere\n")
  t.click("Sync Now")
  t.eq(t.content(), "a task\nfrom elsewhere\n")
  t.eq(t.link().status.state, "ok")
end)

case("a linked file deleted on Dropbox is an error, never re-created", function(t)
  linked(t, "a task\n")
  missing(t)
  t.click("Sync Now")
  t.eq(t.link().status.state, "error")
  t.contains(t.link().status.message, "deleted or moved")
  t.eq(#uploads(t), 0)
end)

case("losing authorization is an error, not a skip", function(t)
  linked(t, "a task\n")
  t.state("access_expires", "0")
  t.click("Sync Now")
  t.eq(t.link().status.state, "error")
  t.contains(t.link().status.message, "Not authorized: open Dropbox Sync to sign in; todo.txt is not syncing")
end)

case("an unlinked document asks nothing of Dropbox", function(t)
  authorized(t)
  t.open("todo.txt", "a task\n")
  t.edit("todo.txt", "a task\nmore\n")
  t.ok(t.save())
  t.fire("poll")
  t.eq(#t.requests(), 0)
  t.contains(t.view(), "No documents are linked; nothing is syncing.")
end)

case("Unlink stops syncing and keeps the Dropbox file", function(t)
  linked(t, "a task\n")
  local before = #t.requests()
  t.click("Unlink")
  t.eq(t.link(), nil)
  t.edit("todo.txt", "a task\nmore\n")
  t.ok(t.save())
  t.eq(#t.requests(), before)
end)

case("a poll soon after a run asks nothing and keeps the status", function(t)
  linked(t, "a task\n")
  local before = #t.requests()
  t.fire("poll")
  t.eq(#t.requests(), before)
  t.eq(t.link().status.state, "ok")
end)
