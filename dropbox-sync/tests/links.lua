-- Dropbox Sync on host links, run with the host's taskle-plugin-test:
--   cargo run -p taskle-plugin-test -- plugins/dropbox-sync

local META = "https://api.dropboxapi.com/2/files/get_metadata"
local DOWNLOAD = "https://content.dropboxapi.com/2/files/download"
local UPLOAD = "https://content.dropboxapi.com/2/files/upload"

local TOKEN = "https://api.dropboxapi.com/oauth2/token"
local ACCOUNT = "https://api.dropboxapi.com/2/users/get_current_account"

-- Signed in to `account` (an id, named `<id>@example.com`), with an access
-- token good until `expires` and no refresh token.
local function authorized(t, account, expires)
  account = account or "dbid:A"
  t.secret("credential", '{"access_token":"T","expires":' .. (expires or os.time() + 86400)
    .. ',"account_id":"' .. account .. '","account_name":"' .. account .. '@example.com"}')
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
  -- The revision both last shared, for the merge.
  remote(t, "r1", "a task\n")
  t.ok(t.save())
  t.eq(t.link().status.state, "conflict")
  t.eq(t.conflict(), "a task\ntheirs\n")
  t.eq(t.link().pending, true)

  uploaded(t, "r3")
  -- The run the answer queues finds Dropbox holding the merge.
  meta(t, "r3")
  remote(t, "r3", "a task\nmine\ntheirs\n")
  t.eq({ t.merge({ "both" }) }, { true, "three_way" })
  t.eq(t.read("todo.txt"), "a task\nmine\ntheirs\n")
  t.eq(t.link().status.state, "ok")
end)

-- Both sides changed, and the revision they last shared comes back as
-- `answer` says.
local function diverged_with_base(t, answer)
  linked(t, "a task\n")
  t.edit("todo.txt", "a task\nmine\n")
  meta(t, "r1")
  remote(t, "r1", "a task\n")
  t.http { method = "POST", url = UPLOAD, status = 409, body = '{"error_summary":"path/conflict/file/"}' }
  remote(t, "r2", "a task\ntheirs\n")
  t.http { method = "POST", url = DOWNLOAD, status = answer.status, body = answer.body,
           headers = { ["Dropbox-API-Result"] = '{"rev":"r1"}' } }
  t.ok(t.save())
  t.eq(t.link().status.state, "conflict")
  uploaded(t, "r3")
  meta(t, "r3")
  remote(t, "r3", "a task\nmine\ntheirs\n")
end

case("a revision Dropbox no longer has leaves the merge two-way", function(t)
  diverged_with_base(t, { status = 409, body = '{"error_summary":"path/not_found/"}' })
  t.eq({ t.merge({ "both" }) }, { true, "two_way" })
end)

case("a revision that does not hash to the recorded base is not offered", function(t)
  diverged_with_base(t, { body = "edited\n" })
  t.eq({ t.merge({ "both" }) }, { true, "two_way" })
end)

-- What a run that handed Dropbox's copy over leaves behind when the document
-- never took it: a crash, a document closed first, or a conflict nobody
-- answered.
local function handed_over_and_lost(t)
  t.link_state("pending_rev", "r2")
  t.link_state("pending_hash", "not what the document holds")
end

case("a lost handover never makes a save upload over what the user has not seen", function(t)
  linked(t, "a task\n")
  handed_over_and_lost(t)
  t.edit("todo.txt", "a task\nmine\n")
  meta(t, "r2")
  remote(t, "r2", "a task\nfrom elsewhere\n")
  remote(t, "r1", "a task\n")
  t.ok(t.save())
  t.eq(#uploads(t), 0)
  t.eq(t.link().status.state, "conflict")
  t.eq(t.conflict(), "a task\nfrom elsewhere\n")
  t.eq(t.read("todo.txt"), "a task\nmine\n")
end)

case("a lost handover is handed over again when only Dropbox changed", function(t)
  linked(t, "a task\n")
  handed_over_and_lost(t)
  meta(t, "r2")
  remote(t, "r2", "a task\nfrom elsewhere\n")
  t.fire("file_loaded", "todo.txt")
  t.eq(t.content(), "a task\nfrom elsewhere\n")
  t.eq(#uploads(t), 0)
end)

-- Both sides changed since r1: the document holds `mine`, Dropbox r2 `theirs`.
local function conflicted(t)
  linked(t, "a task\n")
  t.edit("todo.txt", "a task\nmine\n")
  meta(t, "r2")
  remote(t, "r2", "a task\ntheirs\n")
  remote(t, "r1", "a task\n")
  t.ok(t.save())
  t.eq(t.link().status.state, "conflict")
end

case("a save while the question is open is not an answer", function(t)
  conflicted(t)
  t.ok(t.save())
  t.eq(#uploads(t), 0)
  t.eq(t.link().status.state, "conflict")
end)

case("Overwrite uploads over the revision the user was shown", function(t)
  conflicted(t)
  uploaded(t, "r3")
  -- The save Overwrite makes runs the plugin once more.
  meta(t, "r3")
  remote(t, "r3", "a task\nmine\n")
  t.ok(t.answer("mine"))
  t.eq(t.link().status.state, "ok")
  t.eq(t.link().state.rev, "r3")
  local sent = uploads(t)[1]
  t.eq(sent.body, "a task\nmine\n")
end)

case("Cancel holds until Sync Now asks again", function(t)
  conflicted(t)
  t.ok(t.answer("cancel"))
  t.eq(t.link().status.state, "held")
  t.contains(t.link().status.message, "press Sync Now")

  local before = #t.requests()
  t.edit("todo.txt", "a task\nmine\nmore\n")
  t.ok(t.save())
  t.eq(#t.requests(), before, "a save neither uploads nor asks again")
  t.eq(t.link().status.state, "held")

  meta(t, "r2")
  remote(t, "r2", "a task\ntheirs\n")
  remote(t, "r1", "a task\n")
  t.click("Sync Now")
  t.eq(t.link().status.state, "conflict")
  t.eq(t.conflict(), "a task\ntheirs\n")
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
  authorized(t, "dbid:A", 0)
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
  t.contains(t.view(), "Not linked: this document does not sync.")
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

-- ----- the account -----

case("a link records the account it was made under", function(t)
  linked(t, "a task\n")
  t.eq(t.link().state.account, "dbid:A")
  t.eq(t.link().state.account_name, "dbid:A@example.com")
  t.contains(t.view(), "Linked to /Taskle/todo.txt in dbid:A@example.com")
end)

case("signed in to another account, a link holds and asks nothing of Dropbox", function(t)
  linked(t, "a task\n")
  authorized(t, "dbid:B")
  local before = #t.requests()
  t.edit("todo.txt", "a task\nmore\n")
  t.ok(t.save())
  t.eq(#t.requests(), before)
  t.eq(t.link().status.state, "held")
  t.contains(t.link().status.message, "Linked under dbid:A@example.com, but Dropbox Sync is signed in as dbid:B@example.com")
end)

case("signing back in to the link's account resumes it", function(t)
  linked(t, "a task\n")
  authorized(t, "dbid:B")
  t.click("Sync Now")
  t.eq(t.link().status.state, "held")
  authorized(t, "dbid:A")
  meta(t, "r1")
  remote(t, "r1", "a task\n")
  t.click("Sync Now")
  t.eq(t.link().status.state, "ok")
end)

case("a link that records no account holds until it is linked again", function(t)
  linked(t, "a task\n")
  t.link_state("account", "")
  t.click("Sync Now")
  t.eq(t.link().status.state, "held")
end)

-- Authorization started, with app key `app` and the code `c` pasted.
local function finishing(t)
  t.state("pkce_verifier", "v")
  t.window("client", "app", "settings")
  t.window("code", "c")
end

case("authorizing records which account the credentials are for", function(t)
  finishing(t)
  t.http { method = "POST", url = TOKEN,
           body = '{"access_token":"T","refresh_token":"R","expires_in":14400,"account_id":"dbid:A"}' }
  t.http { method = "POST", url = ACCOUNT, body = '{"account_id":"dbid:A","email":"a@example.com"}' }
  t.click("Finish authorization")
  t.contains(t.view(), "Dropbox connected as a@example.com.")
  t.contains(t.view(), "Signed in for this project as a@example.com.")
end)

case("an account Dropbox will not describe is named by its id", function(t)
  finishing(t)
  t.http { method = "POST", url = TOKEN,
           body = '{"access_token":"T","refresh_token":"R","expires_in":14400,"account_id":"dbid:A"}' }
  t.http { method = "POST", url = ACCOUNT, status = 401, body = '{"error_summary":"missing_scope/"}' }
  t.click("Finish authorization")
  t.contains(t.view(), "Dropbox connected as dbid:A.")
end)

case("credentials that do not say whose they are are not kept", function(t)
  finishing(t)
  t.http { method = "POST", url = TOKEN, body = '{"access_token":"T","refresh_token":"R","expires_in":14400}' }
  t.click("Finish authorization")
  t.contains(t.view(), "Authorization failed: Dropbox did not say which account it is for.")
  t.contains(t.view(), "Not signed in for this document's project")
end)

case("signing in to another account never keeps the old account's refresh token", function(t)
  t.secret("credential", '{"access_token":"T","expires":0,"refresh_token":"R","account_id":"dbid:A"}')
  finishing(t)
  -- Account B's sign-in issues no refresh token, and its access token is
  -- already expired.
  t.http { method = "POST", url = TOKEN, body = '{"access_token":"TB","expires_in":0,"account_id":"dbid:B"}' }
  t.http { method = "POST", url = ACCOUNT, body = '{"account_id":"dbid:B","email":"b@example.com"}' }
  t.click("Finish authorization")
  t.contains(t.view(), "Signed in for this project as b@example.com.")
  -- Linking needs a usable token: B has none, and A's refresh token is gone,
  -- so nothing is asked of Dropbox.
  local before = #t.requests()
  t.open("todo.txt", "a task\n")
  t.click("Link")
  t.eq(#t.requests(), before)
  t.eq(t.link(), nil)
  t.contains(t.view(), "Authorize Dropbox first.")
end)

case("a run under another account makes no request, not even a refresh", function(t)
  linked(t, "a task\n")
  t.secret("credential", '{"access_token":"T","expires":0,"refresh_token":"R","account_id":"dbid:B"}')
  t.window("client", "app", "settings")
  local before = #t.requests()
  t.click("Sync Now")
  t.eq(#t.requests(), before)
  t.eq(t.link().status.state, "held")
end)

case("an email lookup that cannot reach Dropbox names the account by its id", function(t)
  finishing(t)
  t.http { method = "POST", url = TOKEN,
           body = '{"access_token":"T","refresh_token":"R","expires_in":14400,"account_id":"dbid:A"}' }
  t.http { method = "POST", url = ACCOUNT, error = "timed out" }
  t.click("Finish authorization")
  t.contains(t.view(), "Dropbox connected as dbid:A.")
end)

case("a sign-in kept for one scope says nothing about a document in another project", function(t)
  t.write("project-b/.taskle/keep", "")
  -- Signed in with no document in front: kept for documents in no project.
  finishing(t)
  t.http { method = "POST", url = TOKEN,
           body = '{"access_token":"T","refresh_token":"R","expires_in":14400,"account_id":"dbid:A"}' }
  t.http { method = "POST", url = ACCOUNT, body = '{"account_id":"dbid:A","email":"a@example.com"}' }
  t.click("Finish authorization")
  t.contains(t.view(), "Dropbox connected as a@example.com.")
  t.contains(t.view(), "Signed in for this project as a@example.com.")

  t.open("project-b/todo.txt", "b task\n")
  for _, line in ipairs(t.view()) do
    t.ok(not line:find("connected as", 1, true), "project A's sign-in message is not shown here")
  end
  t.contains(t.view(), "Not signed in for this document's project. Sign-ins are kept per project.")
end)

case("the app key is set in the settings window, for every project", function(t)
  t.open("todo.txt", "a task\n")
  t.contains(t.view(), "Set the Dropbox app key in Settings to sign in.")
  t.window("client", "app", "settings")
  t.contains(t.view(), "[Authorize]")
end)
