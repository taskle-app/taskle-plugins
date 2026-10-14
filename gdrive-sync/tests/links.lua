-- Google Drive Sync on host links, run with the host's taskle-plugin-test:
--   cargo run -p taskle-plugin-test -- plugins/gdrive-sync

local DRIVE = "https://www.googleapis.com/drive/v3/files"
local UPLOAD = "https://www.googleapis.com/upload/drive/v3/files"
local IDS = DRIVE .. "/generateIds?count=1&space=drive&type=files"
local CREATE = UPLOAD .. "?uploadType=multipart&fields=id,name,version,headRevisionId"
local LIST = DRIVE .. "?fields=files%28id%2Cname%2CmodifiedTime%29&orderBy=modifiedTime+desc"
  .. "&pageSize=50&q=trashed+%3D+false+and+mimeType+%3D+%27text%2Fplain%27"

-- Signed in to `account` (an id, named `<id>@example.com`), with an access
-- token good until `expires` and no refresh token.
local function authorized(t, account, expires)
  account = account or "P1"
  t.secret("credential", '{"access_token":"T","expires":' .. (expires or os.time() + 86400)
    .. ',"account_id":"' .. account .. '","account_name":"' .. account .. '@example.com"}')
end

local function meta(t, id, version, extra)
  t.http {
    url = DRIVE .. "/" .. id .. "?fields=id,name,version,headRevisionId,modifiedTime,trashed",
    body = '{"id":"' .. id .. '","name":"todo.txt","version":"' .. version .. '"' .. (extra or "") .. "}",
  }
end

local function body(t, id, content)
  t.http { url = DRIVE .. "/" .. id .. "?alt=media", body = content }
end

local function upload(t, id, status, version)
  t.http {
    method = "PATCH",
    url = UPLOAD .. "/" .. id .. "?uploadType=media&fields=id,version,headRevisionId",
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
  t.eq(link.label, "Google Drive: todo.txt")
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

  t.http { url = DRIVE .. "/F1?fields=id,name,version,headRevisionId,modifiedTime,trashed", status = 404 }
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
  t.contains(t.view(), "Not linked: this document does not sync.")
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
  authorized(t, "P1", 0)
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
  t.eq(t.link().label, "Google Drive: work.txt")
  t.eq(t.link().status.state, "ok")
end)

case("a pasted id Drive will not open is refused, and nothing is linked", function(t)
  authorized(t)
  t.open("todo.txt", "a task\n")
  t.http { url = DRIVE .. "/F9?fields=id,name,version,headRevisionId,modifiedTime,trashed", status = 404 }
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

case("a Drive version that moved without the content uploads, not conflicts", function(t)
  linked(t, "a task\n")
  t.edit("todo.txt", "a task\nmore\n")
  meta(t, "F1", "7")
  body(t, "F1", "a task\n")
  meta(t, "F1", "7")
  upload(t, "F1", 200, "8")
  meta(t, "F1", "8")
  t.ok(t.save())
  t.eq(t.link().status.state, "ok")
  t.eq(t.link().pending, false)
  t.eq(t.link().state.version, "8")
end)

case("Drive bumping its version right after the upload is not a race", function(t)
  linked(t, "a task\n")
  t.edit("todo.txt", "a task\nmore\n")
  meta(t, "F1", "3")
  body(t, "F1", "a task\n")
  meta(t, "F1", "3")
  upload(t, "F1", 200, "4")
  meta(t, "F1", "5")
  body(t, "F1", "a task\nmore\n")
  t.ok(t.save())
  t.eq(t.link().status.state, "ok")
  t.eq(t.link().state.version, "5")
  t.eq(t.conflict(), nil)
end)

case("a change landing during the upload keeps both", function(t)
  linked(t, "a task\n")
  t.edit("todo.txt", "a task\nmore\n")
  meta(t, "F1", "3")
  body(t, "F1", "a task\n")
  meta(t, "F1", "3")
  upload(t, "F1", 200, "4")
  meta(t, "F1", "5")
  body(t, "F1", "a task\nfrom elsewhere\n")
  t.ok(t.save())
  t.eq(t.link().status.state, "conflict")
  t.eq(t.conflict(), "a task\nfrom elsewhere\n")
end)

case("a merge answered after Drive's version moved uploads", function(t)
  linked(t, "a task\n")
  t.edit("todo.txt", "a task\nmine\n")
  meta(t, "F1", "5")
  body(t, "F1", "a task\ntheirs\n")
  t.ok(t.save())
  t.eq(t.link().status.state, "conflict")

  -- The user keeps both; Drive's content is unchanged but its version has
  -- moved on.
  meta(t, "F1", "6")
  body(t, "F1", "a task\ntheirs\n")
  upload(t, "F1", 200, "7")
  meta(t, "F1", "7")
  -- The merge's save runs the plugin once more.
  meta(t, "F1", "7")
  body(t, "F1", "a task\nmine\ntheirs\n")
  t.eq({ t.merge({ "both" }) }, { true, "two_way" })
  t.eq(t.read("todo.txt"), "a task\nmine\ntheirs\n")
  t.eq(t.link().status.state, "ok")
  t.eq(t.link().state.version, "7")
end)

-- What a run that handed Drive's copy over leaves behind when the document
-- never took it: a crash, a document closed first, or a conflict nobody
-- answered.
local function handed_over_and_lost(t)
  t.link_state("pending_version", "5")
  t.link_state("pending_hash", "not what the document holds")
end

case("a lost handover never makes a save upload over what the user has not seen", function(t)
  linked(t, "a task\n")
  handed_over_and_lost(t)
  t.edit("todo.txt", "a task\nmine\n")
  meta(t, "F1", "5")
  body(t, "F1", "a task\nfrom elsewhere\n")
  t.ok(t.save())
  t.eq(count(t, UPLOAD), 0)
  t.eq(t.link().status.state, "conflict")
  t.eq(t.conflict(), "a task\nfrom elsewhere\n")
  t.eq(t.read("todo.txt"), "a task\nmine\n")
end)

case("a lost handover is handed over again when only Drive changed", function(t)
  linked(t, "a task\n")
  handed_over_and_lost(t)
  meta(t, "F1", "5")
  body(t, "F1", "a task\nfrom elsewhere\n")
  t.fire("file_loaded", "todo.txt")
  t.eq(t.content(), "a task\nfrom elsewhere\n")
  t.eq(count(t, UPLOAD), 0)
end)

case("a save while the question is open is not an answer", function(t)
  linked(t, "a task\n")
  t.edit("todo.txt", "a task\nmine\n")
  meta(t, "F1", "5")
  body(t, "F1", "a task\ntheirs\n")
  t.ok(t.save())
  t.eq(t.link().status.state, "conflict")
  t.ok(t.save())
  t.eq(count(t, UPLOAD), 0)
  t.eq(t.link().status.state, "conflict")
end)

case("Overwrite uploads over the version the user was shown", function(t)
  linked(t, "a task\n")
  t.edit("todo.txt", "a task\nmine\n")
  meta(t, "F1", "5")
  body(t, "F1", "a task\ntheirs\n")
  t.ok(t.save())
  t.eq(t.link().status.state, "conflict")

  meta(t, "F1", "5")
  upload(t, "F1", 200, "6")
  meta(t, "F1", "6")
  -- The save Overwrite makes runs the plugin once more.
  meta(t, "F1", "6")
  body(t, "F1", "a task\nmine\n")
  t.ok(t.answer("mine"))
  t.eq(t.link().status.state, "ok")
  t.eq(t.link().state.version, "6")
  t.eq(t.read("todo.txt"), "a task\nmine\n")
end)

case("Cancel holds until Sync Now asks again", function(t)
  linked(t, "a task\n")
  t.edit("todo.txt", "a task\nmine\n")
  meta(t, "F1", "5")
  body(t, "F1", "a task\ntheirs\n")
  t.ok(t.save())
  t.ok(t.answer("cancel"))
  t.eq(t.link().status.state, "held")
  t.contains(t.link().status.message, "press Sync Now")

  local before = #t.requests()
  t.edit("todo.txt", "a task\nmine\nmore\n")
  t.ok(t.save())
  t.eq(#t.requests(), before, "a save neither uploads nor asks again")
  t.eq(t.link().status.state, "held")

  meta(t, "F1", "5")
  body(t, "F1", "a task\ntheirs\n")
  t.click("Sync Now")
  t.eq(t.link().status.state, "conflict")
  t.eq(t.conflict(), "a task\ntheirs\n")
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

-- `todo.txt` linked to F1 at version 3, revision R3, both holding `content`.
local function linked_at_revision(t, content)
  authorized(t)
  t.open("todo.txt", content)
  meta(t, "F1", "3", ',"headRevisionId":"R3"')
  t.window("pasted", "F1")
  meta(t, "F1", "3", ',"headRevisionId":"R3"')
  body(t, "F1", content)
  t.click("Link this file")
  t.eq(t.link().state.base_revision, "R3")
end

local function revision(t, id, rev, content, status)
  t.http { url = DRIVE .. "/" .. id .. "/revisions/" .. rev .. "?alt=media", status = status, body = content }
end

case("a conflict carries the revision both last shared, and merges three-way", function(t)
  linked_at_revision(t, "a\nb\nc\n")
  t.edit("todo.txt", "a\nB\nc\nmine\n")
  meta(t, "F1", "5", ',"headRevisionId":"R5"')
  body(t, "F1", "a\nb\nc\ntheirs\n")
  revision(t, "F1", "R3", "a\nb\nc\n")
  t.ok(t.save())
  t.eq(t.link().status.state, "conflict")
  -- The edit to b is proposed; only the two additions at the end ask.
  meta(t, "F1", "5", ',"headRevisionId":"R5"')
  upload(t, "F1", 200, "6")
  meta(t, "F1", "6", ',"headRevisionId":"R6"')
  -- The run the answer queues finds Drive holding the merge.
  meta(t, "F1", "6", ',"headRevisionId":"R6"')
  body(t, "F1", "a\nB\nc\nmine\ntheirs\n")
  t.eq({ t.merge({ "both" }) }, { true, "three_way" })
  t.eq(t.link().status.state, "ok", "the merged text went up")
  t.eq(t.link().state.base_revision, "R6")
  t.eq(t.read("todo.txt"), "a\nB\nc\nmine\ntheirs\n")
end)

case("a revision Drive pruned leaves the merge two-way", function(t)
  linked_at_revision(t, "a\nb\n")
  t.edit("todo.txt", "a\nmine\n")
  meta(t, "F1", "5", ',"headRevisionId":"R5"')
  body(t, "F1", "a\ntheirs\n")
  revision(t, "F1", "R3", "", 404)
  t.ok(t.save())
  t.eq(t.link().status.state, "conflict")
  meta(t, "F1", "5", ',"headRevisionId":"R5"')
  upload(t, "F1", 200, "6")
  meta(t, "F1", "6", ',"headRevisionId":"R6"')
  -- The run the answer queues finds Drive holding the merge.
  meta(t, "F1", "6", ',"headRevisionId":"R6"')
  body(t, "F1", "a\nmine\ntheirs\n")
  t.eq({ t.merge({ "both" }) }, { true, "two_way" })
  t.eq(t.link().status.state, "ok", "the merged text went up")
  t.eq(t.link().state.base_revision, "R6")
end)

case("a revision that does not hash to the recorded base is not offered", function(t)
  linked_at_revision(t, "a\nb\n")
  t.edit("todo.txt", "a\nmine\n")
  meta(t, "F1", "5", ',"headRevisionId":"R5"')
  body(t, "F1", "a\ntheirs\n")
  revision(t, "F1", "R3", "something else\n")
  t.ok(t.save())
  meta(t, "F1", "5", ',"headRevisionId":"R5"')
  upload(t, "F1", 200, "6")
  meta(t, "F1", "6", ',"headRevisionId":"R6"')
  -- The run the answer queues finds Drive holding the merge.
  meta(t, "F1", "6", ',"headRevisionId":"R6"')
  body(t, "F1", "a\nmine\ntheirs\n")
  t.eq({ t.merge({ "both" }) }, { true, "two_way" })
  t.eq(t.link().status.state, "ok", "the merged text went up")
  t.eq(t.link().state.base_revision, "R6")
end)

case("a host that ignores a base is not asked for one", function(t)
  t.withhold("document.conflict_base")
  linked_at_revision(t, "a\nb\n")
  t.edit("todo.txt", "a\nmine\n")
  meta(t, "F1", "5", ',"headRevisionId":"R5"')
  body(t, "F1", "a\ntheirs\n")
  t.ok(t.save())
  t.eq(t.link().status.state, "conflict")
  t.eq(count(t, "/revisions/"), 0)
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
  t.http { url = DRIVE .. "/F1?fields=id,name,version,headRevisionId,modifiedTime,trashed", status = 503 }
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

-- ----- the account -----

case("a link records the account it was made under", function(t)
  linked(t, "a task\n")
  t.eq(t.link().state.account, "P1")
  t.contains(t.view(), "Linked to Google Drive: todo.txt in P1@example.com")
end)

case("Create records the account too", function(t)
  authorized(t)
  t.open("todo.txt", "a task\n")
  t.http { url = IDS, body = '{"ids":["F1"]}' }
  t.http { method = "POST", url = CREATE, body = '{"id":"F1","name":"todo.txt","version":"3"}' }
  t.click("Create Drive file")
  t.eq(t.link().state.account, "P1")
  t.eq(t.link().status.state, "ok")
end)

case("signed in to another account, a link holds and asks nothing of Drive", function(t)
  linked(t, "a task\n")
  authorized(t, "P2")
  local before = #t.requests()
  t.edit("todo.txt", "a task\nmore\n")
  t.ok(t.save())
  t.eq(#t.requests(), before)
  t.eq(t.link().status.state, "held")
  t.contains(t.link().status.message, "Linked under P1@example.com, but Google Drive Sync is signed in as P2@example.com")
end)

case("a link that records no account holds until it is linked again", function(t)
  linked(t, "a task\n")
  t.link_state("account", "")
  t.click("Sync Now")
  t.eq(t.link().status.state, "held")
end)

case("credentials that do not say whose they are count as no sign-in", function(t)
  t.secret("credential", '{"access_token":"T","expires":' .. (os.time() + 86400) .. '}')
  t.open("todo.txt", "a task\n")
  t.click("Create Drive file")
  t.eq(t.link(), nil)
  t.contains(t.view(), "Authorize Google Drive first.")
  t.contains(t.view(), "Not signed in for this document's project")
end)

case("a run under another account makes no request, not even a refresh", function(t)
  linked(t, "a task\n")
  t.secret("credential", '{"access_token":"T","expires":0,"refresh_token":"R","account_id":"P2"}')
  t.window("client", "app", "settings")
  local before = #t.requests()
  t.click("Sync Now")
  t.eq(#t.requests(), before)
  t.eq(t.link().status.state, "held")
end)

case("the OAuth client is set in the settings window, for every project", function(t)
  t.open("todo.txt", "a task\n")
  t.contains(t.view(), "Set the OAuth client in Settings to sign in.")
  t.window("client", "app", "settings")
  t.window("secret", "shh", "settings")
  t.click("Save secret", "settings")
  t.contains(t.view("settings"), "A client secret is stored; enter one only to replace it.")
  t.contains(t.view(), "[Authorize]")
end)
