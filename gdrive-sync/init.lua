-- Google Drive synchronization for canonical local todo.txt files.
--
-- Sync is opt-in per document: a document syncs once it is linked to a Drive
-- file in this plugin's document window, and the host keeps that link. Every run ends
-- with a status the host shows on the document's tab, so a document that
-- stopped syncing never looks synced.
--
-- Drive v3 has no documented conditional media update. Uploads therefore use
-- detect-after-write and preserve a surprising result as an explicit conflict.

local NAME = "Google Drive Sync"
local DEVICE = "https://oauth2.googleapis.com/device/code"
local TOKEN = "https://oauth2.googleapis.com/token"
local DRIVE = "https://www.googleapis.com/drive/v3/files"
local UPLOAD = "https://www.googleapis.com/upload/drive/v3/files"
local SCOPE = "https://www.googleapis.com/auth/drive.file"
-- A poll fires about every 30 seconds; Drive is asked at most this often.
local POLL_SECONDS = 300

local ui = {
  -- The OAuth client this plugin is registered as: the same app whichever
  -- project is in front, so it is kept once, globally. The sign-in it grants
  -- stays per project.
  client_id = taskle.state.global.get("client_id") or "",
  client_secret = "",
  -- What the last action in the settings window said.
  settings_status = "",
  status = "",
  user_code = taskle.state.get("user_code") or "",
}

-- What the document window holds for the document it is open on; each
-- document has its own, so a file listed or pasted for one is never offered
-- for another.
local function new_document_ui()
  return {
    -- The Drive files offered by "Link existing file", once listed.
    files = nil,
    -- The account those files were listed under, which a pick links under.
    listed_by = nil,
    -- What was typed into the "paste a file id or link" field.
    pasted = "",
    -- What the last action on this document said.
    document_status = "",
  }
end

local function form(values)
  local encoded = {}
  for key, value in pairs(values) do encoded[#encoded + 1] = { key, value } end
  table.sort(encoded, function(a, b) return a[1] < b[1] end)
  return taskle.codec.form_encode(encoded)
end

local function json(response)
  local ok, value = pcall(taskle.codec.json_decode, response.body or "")
  return ok and value or nil
end

local function hash(value)
  return taskle.codec.base64url_encode(taskle.codec.sha256(value))
end

local function file_name(path)
  return (path or ""):match("([^/\\]+)$") or "todo.txt"
end

local function notify(message, urgency)
  taskle.notify { title = NAME, message = message, urgency = urgency or "normal" }
end

local function token_request(values)
  return taskle.http.post {
    url = TOKEN,
    headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
    body = form(values),
  }
end

-- ----- the credential -----
--
-- One secret holds everything a sign-in produced: both tokens, when the access
-- token expires, and which account they are for. It is written whole, so a
-- sign-in or refresh that stops part way leaves the old record or the new
-- one, never one account's tokens under another account's id, and a refresh
-- token never outlives the sign-in that issued it.

local function credential()
  local text = taskle.secrets.get("credential")
  if not text or text == "" then return nil end
  local ok, record = pcall(taskle.codec.json_decode, text)
  if not ok or type(record) ~= "table" or not record.account_id or record.account_id == "" then return nil end
  return record
end

local function store(record)
  taskle.secrets.set("credential", taskle.codec.json_encode(record))
end

-- A usable access token from `record`, refreshed when needed, or nil and why
-- not. A run reads the credential once and passes that record to everything
-- it checks and uses, so the account it checked is the account it acts as.
local function access_token(record)
  if not record then return nil, "Not authorized" end
  if record.access_token and (tonumber(record.expires) or 0) > taskle.now() + 60 then return record.access_token end
  if not record.refresh_token or record.refresh_token == "" or ui.client_id == "" then return nil, "Not authorized" end
  local values = { client_id = ui.client_id, refresh_token = record.refresh_token, grant_type = "refresh_token" }
  local secret = taskle.secrets.global.get("client_secret")
  if secret and secret ~= "" then values.client_secret = secret end
  local response = token_request(values)
  local body = json(response)
  if response.status ~= 200 or not body or not body.access_token then
    return nil, "Authorization must be renewed"
  end
  record.access_token = body.access_token
  record.expires = taskle.now() + (body.expires_in or 3600)
  store(record)
  return record.access_token
end

local function headers(token, content_type)
  return { Authorization = "Bearer " .. token, ["Content-Type"] = content_type or "application/json" }
end

local function metadata(token, file_id)
  local response = taskle.http.get {
    url = DRIVE .. "/" .. file_id .. "?fields=id,name,version,headRevisionId,modifiedTime,trashed",
    headers = headers(token),
  }
  return response, json(response)
end

local function download(token, file_id)
  return taskle.http.get { url = DRIVE .. "/" .. file_id .. "?alt=media", headers = headers(token) }
end

local function download_revision(token, file_id, revision)
  return taskle.http.get {
    url = DRIVE .. "/" .. file_id .. "/revisions/" .. revision .. "?alt=media",
    headers = headers(token),
  }
end

-- ----- one run of a linked document -----
--
-- Every function below returns the status the run ends with: a state and a
-- message saying what to do. `run` reports it, so no path can end silently.

local state = taskle.links.state

local function ok(message) return "ok", message or "" end
local function failed(message) return "error", message end

local function forget_staged()
  state.delete("pending_version")
  state.delete("pending_revision")
  state.delete("pending_hash")
end

-- Record that the document and Drive agree on `content`, Drive's file being
-- at `meta`: its version, and the revision that holds the content.
local function remember(meta, content)
  state.set("version", tostring(meta.version))
  state.set("base", hash(content))
  if meta.headRevisionId then
    state.set("base_revision", meta.headRevisionId)
  else
    state.delete("base_revision")
  end
  forget_staged()
  state.delete("postponed")
end

local function postponed()
  return "held", "You postponed choosing between this document and Drive; press Sync Now to choose"
end

-- ----- the account -----
--
-- The credentials belong to the plugin, not to a link, and signing in again may
-- switch accounts, where a link's file id names a file this app cannot open
-- or none. So each link records the account it was made under, and a run under
-- any other account holds instead of reading or writing there.

-- The account `record` (by default the stored credential) is for.
local function signed_in(record)
  record = record or credential()
  if not record then return nil end
  return { id = record.account_id, name = record.account_name or record.account_id }
end

-- Record `account` on the link of the document the call is bound to.
local function pin(account)
  state.set("account", account.id)
  state.set("account_name", account.name)
end

-- Nothing when the run may go ahead under `record`'s account; otherwise the
-- status to stop with.
local function other_account(record)
  local pinned = state.get("account")
  if not pinned then
    return "held", "This link does not record which Google account it belongs to; unlink and link it again"
  end
  local current = signed_in(record)
  if not current then
    return failed("Sign in to Google Drive again in " .. NAME .. "; which account it is for was not recorded")
  end
  if current.id ~= pinned then
    return "held", "Linked under " .. (state.get("account_name") or pinned) .. ", but " .. NAME
      .. " is signed in as " .. current.name .. "; sign in to that account, or unlink and link again"
  end
end

-- The text the document and Drive last agreed on, for a merge to measure the
-- two versions against: the Drive revision recorded at that sync, provided it
-- still hashes to what was recorded. Drive prunes old revisions, and a base
-- that is not the one both sides shared would make the merge propose wrong
-- changes, so anything short of a match is no base at all.
local function shared_base(token, file_id)
  local revision, base = state.get("base_revision"), state.get("base")
  if not (revision and base and taskle.supports("document.conflict_base")) then return nil end
  local response = download_revision(token, file_id, revision)
  if response.status == 200 and hash(response.body) == base then return response.body end
end

-- Hand Drive's copy, at `meta`, to the host: as a replacement when only Drive
-- changed, as a conflict that keeps both when both did.
local function stage(snapshot, remote, meta, diverged, token, file_id)
  state.set("pending_version", tostring(meta.version))
  if meta.headRevisionId then
    state.set("pending_revision", meta.headRevisionId)
  else
    state.delete("pending_revision")
  end
  state.set("pending_hash", hash(remote))
  if diverged then
    taskle.document.conflict {
      document_id = snapshot.document_id,
      token = snapshot.token,
      content = remote,
      reason = "gdrive-sync",
      base = shared_base(token, file_id),
    }
  else
    taskle.document.replace {
      document_id = snapshot.document_id,
      token = snapshot.token,
      content = remote,
      reason = "gdrive-sync",
    }
  end
end

local function both_kept(why)
  return "conflict", why .. "; both versions were kept. Choose which to keep in the conflict dialog."
end

-- Drive's `version` counts every change to the file on the server, including
-- ones that leave the content alone, and it can move again shortly after an
-- upload. A version that differs is therefore only a reason to look: the
-- content decides whether Drive really holds something else. Returns whether
-- Drive's content hashes to `expected_hash`, and what Drive holds when that
-- could be read.
local function holds(token, file_id, expected_hash)
  local remote = download(token, file_id)
  if remote.status ~= 200 then return false end
  return hash(remote.body) == expected_hash, remote.body
end

-- Write the snapshot over the Drive file, if Drive still holds the content
-- hashing to `expected_hash`, last seen at version `expected`.
local function upload(snapshot, token, file_id, expected, expected_hash)
  local before_response, before = metadata(token, file_id)
  if before_response.status ~= 200 or not before or not before.version then
    return failed("Could not check the Drive file before uploading (HTTP "
      .. tostring(before_response.status) .. "); the local changes are not on Drive yet")
  end
  if tostring(before.version) ~= tostring(expected) then
    local same, remote = holds(token, file_id, expected_hash)
    if not same then
      if remote then
        stage(snapshot, remote, before, true, token, file_id)
        return both_kept("Drive changed before the upload")
      end
      return failed("Could not check the Drive file before uploading; the local changes are not on Drive yet")
    end
  end
  local response = taskle.http.patch {
    url = UPLOAD .. "/" .. file_id .. "?uploadType=media&fields=id,version,headRevisionId",
    headers = headers(token, "text/plain; charset=utf-8"),
    body = snapshot.saved_content,
  }
  local written = json(response)
  if response.status ~= 200 or not written or not written.version then
    return failed("Upload failed (HTTP " .. tostring(response.status) .. "); the local changes are not on Drive yet")
  end
  local after_response, after = metadata(token, file_id)
  if after_response.status ~= 200 or not after or not after.version then
    return failed("Could not confirm the upload (HTTP " .. tostring(after_response.status) .. ")")
  end
  if tostring(after.version) ~= tostring(written.version) then
    local same, remote = holds(token, file_id, hash(snapshot.saved_content))
    if not same then
      if remote then
        stage(snapshot, remote, after, true, token, file_id)
        notify("Drive changed during upload; both versions were kept.", "critical")
        return both_kept("Drive changed during the upload")
      end
      return failed("Could not confirm the upload; Drive could not be read back")
    end
  end
  remember(after, snapshot.saved_content)
  taskle.links.synced { token = snapshot.token }
  return ok()
end

-- Compare the document with the Drive file it is linked to, and bring them
-- together where one side alone changed.
local function compare(snapshot, token, file_id, event)
  local local_hash = hash(snapshot.saved_content)
  local pending_version = state.get("pending_version")
  local pending_hash = state.get("pending_hash")
  if pending_version and pending_hash then
    -- Drive's copy was handed over. The marker records only that: the
    -- replacement may never have been applied (a crash, a closed document, an
    -- expired token), and a conflict may never have been answered, so the
    -- user may not have seen that copy at all. Only the document holding it,
    -- or the user's answer, settles it.
    if snapshot.conflict then return both_kept("This document and Drive both changed") end
    local answer = snapshot.conflict_answer
    if answer == "cancel" then
      forget_staged()
      state.set("postponed", "1")
      return postponed()
    end
    if local_hash == pending_hash then
      remember({ version = pending_version, headRevisionId = state.get("pending_revision") }, snapshot.saved_content)
      taskle.links.synced { token = snapshot.token }
      return ok()
    end
    if answer == "mine" or answer == "theirs" or answer == "merged" then
      -- The user chose, and the document holds the outcome (or what they
      -- saved since): it replaces the version they were shown.
      return upload(snapshot, token, file_id, pending_version, pending_hash)
    end
    -- Neither: compare again from the last agreed base, as if nothing had
    -- been handed over.
    forget_staged()
  end
  if state.get("postponed") then
    if event ~= "sync" then return postponed() end
    state.delete("postponed")
  end
  local response, remote_meta = metadata(token, file_id)
  if response.status == 404 or (remote_meta and remote_meta.trashed) then
    return failed("The Drive file was deleted or moved to the trash; unlink this document and link it again to sync it")
  end
  if response.status ~= 200 or not remote_meta then
    return failed("Drive is unavailable (HTTP " .. tostring(response.status) .. "); will retry")
  end
  local remote = download(token, file_id)
  if remote.status ~= 200 then
    return failed("Download failed (HTTP " .. tostring(remote.status) .. "); will retry")
  end
  local base = state.get("base")
  local known_version = state.get("version")
  local remote_hash = hash(remote.body)
  if local_hash == remote_hash then
    remember(remote_meta, snapshot.saved_content)
    taskle.links.synced { token = snapshot.token }
    return ok()
  end
  if not known_version then
    -- A first comparison: neither copy can be shown to come from the other,
    -- so neither is adopted.
    stage(snapshot, remote.body, remote_meta, true, token, file_id)
    return both_kept("This document and the Drive file differ")
  end
  local local_changed = base ~= nil and local_hash ~= base
  -- By content where the last synced content is known: see `holds`.
  local remote_changed
  if base then
    remote_changed = remote_hash ~= base
  else
    remote_changed = tostring(remote_meta.version) ~= known_version
  end
  if local_changed and remote_changed then
    stage(snapshot, remote.body, remote_meta, true, token, file_id)
    return both_kept("This document and Drive both changed")
  elseif remote_changed then
    stage(snapshot, remote.body, remote_meta, false)
    return ok("Updated from Drive")
  end
  -- Saved local content Drive has not got, with Drive unchanged since the
  -- last sync. Every snapshot is saved content, so any event may send it.
  return upload(snapshot, token, file_id, remote_meta.version, remote_hash)
end

local function multipart(boundary, meta, content)
  return "--" .. boundary .. "\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n"
    .. taskle.codec.json_encode(meta)
    .. "\r\n--" .. boundary .. "\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n"
    .. content .. "\r\n--" .. boundary .. "--\r\n"
end

-- Finish a link made with no remote yet: create the Drive file under an id
-- chosen first, so a create whose answer was lost is found again rather than
-- made twice.
local function create(snapshot, token)
  local link = snapshot.link
  local name = file_name(snapshot.path)
  local id = state.get("creating_id")
  if id then
    local response, meta = metadata(token, id)
    if response.status == 200 and meta and not meta.trashed then
      -- The earlier create landed. Adopt it, and compare as a first link.
      local updated, why = taskle.links.update { expect = link.id, remote = id, label = "Google Drive: " .. meta.name }
      if not updated then return failed("Could not finish the link: " .. tostring(why)) end
      state.delete("creating_id")
      return compare(snapshot, token, id, "link")
    elseif response.status ~= 404 then
      return failed("Drive is unavailable (HTTP " .. tostring(response.status) .. "); the Drive file is not created yet")
    end
    -- Not there: create it again under the same id.
  else
    local response = taskle.http.get {
      url = DRIVE .. "/generateIds?count=1&space=drive&type=files",
      headers = headers(token),
    }
    local body = json(response)
    id = response.status == 200 and body and body.ids and body.ids[1]
    if not id then
      return failed("Could not reserve a Drive file id (HTTP " .. tostring(response.status) .. "); will retry")
    end
    state.set("creating_id", id)
  end
  local boundary = "taskle-" .. taskle.codec.base64url_encode(taskle.codec.random_bytes(18))
  local response = taskle.http.post {
    url = UPLOAD .. "?uploadType=multipart&fields=id,name,version,headRevisionId",
    headers = headers(token, "multipart/related; boundary=" .. boundary),
    body = multipart(boundary, { id = id, name = name, mimeType = "text/plain" }, snapshot.saved_content),
  }
  local created = json(response)
  if response.status == 409 then
    -- The id is taken: an earlier attempt landed after all. The next run
    -- finds it under `creating_id` and adopts it.
    return failed("Drive already has the file being created; it is adopted on the next sync")
  end
  if response.status ~= 200 or not created or not created.id then
    return failed("Could not create the Drive file (HTTP " .. tostring(response.status) .. "); will retry")
  end
  local updated, why = taskle.links.update { expect = link.id, remote = created.id, label = "Google Drive: " .. (created.name or name) }
  if not updated then return failed("Could not finish the link: " .. tostring(why)) end
  state.delete("creating_id")
  remember(created, snapshot.saved_content)
  taskle.links.synced { token = snapshot.token }
  return ok()
end

-- ----- the status bar -----
--
-- The item beside a document this plugin syncs. The host draws how that
-- document's link stands after the label, and says so in the tooltip, from the
-- link file and its own record of runs asked for and under way, so trouble with
-- another document never shows beside this one.

local status_item = nil -- registered at the end of the file, after what it runs

local HINT = "Click to sync, right-click for more."

-- What the item says about the account, beside every document it syncs: a
-- sign-in that stopped working stops them all, and is said as that, not only
-- as each document's error.
local function show_account(trouble)
  if status_item then
    status_item:set { tooltip = trouble and (trouble .. ". " .. HINT) or HINT }
  end
end

-- The status the last run reported, for a poll that skips Drive this time.
local function last_status(link_id)
  for _, link in ipairs(taskle.links.list()) do
    if link.id == link_id and link.state then return link.state, link.message or "" end
  end
end

local function run_once(snapshot, event)
  if event == "poll" then
    local checked = tonumber(state.get("checked") or "0") or 0
    if checked > taskle.now() - POLL_SECONDS then
      local kept, message = last_status(snapshot.link.id)
      if kept then
        taskle.links.status { state = kept, message = message }
        return
      end
    end
  end
  state.set("checked", tostring(taskle.now()))
  -- The account first: refreshing a token is already a request, and none is
  -- made under another account.
  local record = credential()
  local result, message = other_account(record)
  if not result then
    local token, why = access_token(record)
    show_account(not token and (why .. ": open " .. NAME .. " to sign in") or nil)
    if not token then
      result, message = failed(why .. ": open " .. NAME .. " to sign in; "
        .. file_name(snapshot.path) .. " is not syncing")
    elseif snapshot.link.remote == "" then
      result, message = create(snapshot, token)
    else
      result, message = compare(snapshot, token, snapshot.link.remote, event)
    end
  end
  taskle.links.status { state = result, message = message }
end

-- A run that raised. Most often a request that could not be made at all —
-- no network, a name that does not resolve, a connection refused or timed
-- out — which the host raises rather than answers. Said as a sentence the user
-- can act on; the whole error goes to the log, for whoever needs the detail.
local function trouble(err)
  local text = tostring(err)
  taskle.log.warn(NAME .. ": " .. text)
  local message = text:match("[^\n]*"):gsub('^%[string "[^"]*"%]:%d+: ', "")
  if message:find(": io: ", 1, true) or message:find("timed out", 1, true) then
    return "Could not reach Google Drive; check the network connection. It will try again on the next sync"
  end
  return "Sync failed: " .. message
end

local function run(snapshot, event)
  local ran, err = pcall(run_once, snapshot, event)
  if not ran then
    local message = trouble(err)
    taskle.links.status { state = "error", message = message }
  end
end

for _, event in ipairs { "file_loaded", "after_save", "external_change", "poll", "link", "sync" } do
  local observed = event
  taskle.observe_document {
    event = observed,
    linked = true,
    fn = function(snapshot) run(snapshot, observed) end,
  }
end

-- ----- nothing linked -----

-- Say once that nothing syncs while no document is linked, and again only
-- after the last link has gone.
local function check_unlinked()
  if #taskle.links.list() > 0 then
    taskle.state.delete("told_unlinked")
  elseif taskle.state.get("told_unlinked") ~= "1" then
    taskle.state.set("told_unlinked", "1")
    notify(NAME .. " is enabled but no document is linked; nothing is syncing.")
  end
end

taskle.timer { id = "gdrive-unlinked", every = "60s", missed = "skip", fn = check_unlinked }

-- ----- authorization -----

local function begin_auth()
  if ui.client_id == "" then ui.status = "Set the OAuth client in Settings first."; return end
  local response = taskle.http.post {
    url = DEVICE,
    headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
    body = form { client_id = ui.client_id, scope = SCOPE },
  }
  local body = json(response)
  if response.status ~= 200 or not body or not body.device_code then
    ui.status = "Could not start authorization (HTTP " .. tostring(response.status) .. ")."
    return
  end
  taskle.secrets.set("device_code", body.device_code)
  taskle.state.set("user_code", body.user_code)
  local interval = math.max(tonumber(body.interval) or 5, 1)
  taskle.state.set("auth_poll_interval", tostring(interval))
  taskle.state.set("auth_poll_at", tostring(taskle.now() + interval))
  ui.user_code = body.user_code
  ui.status = "Enter code " .. body.user_code .. " in the browser."
  taskle.open_url(body.verification_url or body.verification_uri)
end

-- Which Google account `token` is for: Drive's permission id for the user,
-- which `drive.file` may read, and the email to name it by. Nil and the HTTP
-- status when Drive will not say.
local function account_of(token)
  local response = taskle.http.get {
    url = "https://www.googleapis.com/drive/v3/about?fields=user%28permissionId%2CemailAddress%29",
    headers = headers(token),
  }
  local body = response.status == 200 and json(response)
  local user = body and body.user
  if not user or not user.permissionId or user.permissionId == "" then return nil, response.status end
  return { id = user.permissionId, name = user.emailAddress or user.permissionId }
end

local function forget_device()
  taskle.secrets.delete("device_code")
  taskle.state.delete("user_code")
  taskle.state.delete("auth_poll_interval")
  taskle.state.delete("auth_poll_at")
end

local function poll_auth()
  local device = taskle.secrets.get("device_code")
  if not device or device == "" or ui.client_id == "" then return end
  local interval = tonumber(taskle.state.get("auth_poll_interval") or "5") or 5
  local next_poll = tonumber(taskle.state.get("auth_poll_at") or "0") or 0
  if taskle.now() < next_poll then return end
  taskle.state.set("auth_poll_at", tostring(taskle.now() + interval))
  local values = {
    client_id = ui.client_id,
    device_code = device,
    grant_type = "urn:ietf:params:oauth:grant-type:device_code",
  }
  local secret = taskle.secrets.global.get("client_secret")
  if secret and secret ~= "" then values.client_secret = secret end
  local response = token_request(values)
  local body = json(response)
  if response.status == 200 and body and body.access_token then
    forget_device()
    local account, status = account_of(body.access_token)
    if not account then
      ui.user_code = ""
      ui.status = "Authorization failed: could not read which Google account this is (HTTP " .. tostring(status) .. ")."
      return
    end
    store {
      access_token = body.access_token,
      refresh_token = body.refresh_token,
      expires = taskle.now() + (body.expires_in or 3600),
      account_id = account.id,
      account_name = account.name,
    }
    ui.user_code, ui.status = "", "Google Drive connected as " .. account.name .. "."
  elseif body and body.error == "slow_down" then
    interval = interval + 5
    taskle.state.set("auth_poll_interval", tostring(interval))
    taskle.state.set("auth_poll_at", tostring(taskle.now() + interval))
  elseif body and body.error == "expired_token" then
    -- The code Google showed has run out: polling on would never succeed, and
    -- a sign-in that silently stops is one the user waits on forever.
    forget_device()
    ui.user_code = ""
    ui.status = "Sign-in timed out: start it again from Google Drive Sync."
    notify(ui.status)
  elseif body and body.error ~= "authorization_pending" then
    forget_device()
    ui.status = "Authorization failed: " .. tostring(body.error)
  end
end

-- Per project: the device code and the poll's pace are kept in the project the
-- sign-in was started in, so each open project polls for its own, and one
-- brought to the front meanwhile does not interrupt another's.
taskle.timer { id = "gdrive-auth", every = "1s", missed = "skip", scope = "project", fn = poll_auth }

-- ----- this document -----

-- Link the document in front to the Drive file `id` named `name`, under
-- `account`: the one the file was found under.
local function link_to(doc, id, name, account)
  if not account then
    doc.document_status = "Authorize Google Drive again: which account it is for was not recorded."
    return
  end
  local made, why = taskle.links.set { remote = id, label = "Google Drive: " .. name }
  if made then
    pin(account)
    doc.files = nil
    doc.pasted = ""
    doc.document_status = "Linked to Drive: " .. name .. ". Comparing the two copies…"
  else
    doc.document_status = why
  end
end

local function create_linked(doc)
  local record = credential()
  if not access_token(record) then doc.document_status = "Authorize Google Drive first."; return end
  local account = signed_in(record)
  if not account then
    doc.document_status = "Authorize Google Drive again: which account it is for was not recorded."
    return
  end
  local document, refused = taskle.links.document()
  if not document then doc.document_status = refused; return end
  local made, why = taskle.links.set { remote = "", label = "Google Drive: creating " .. document.name }
  if made then pin(account) end
  doc.document_status = made and "Creating the Drive file…" or why
end

local function list_files(doc)
  local record = credential()
  doc.listed_by = signed_in(record)
  local token = access_token(record)
  if not token then doc.document_status = "Authorize Google Drive first."; return end
  local response = taskle.http.get {
    url = DRIVE .. "?" .. form {
      q = "trashed = false and mimeType = 'text/plain'",
      fields = "files(id,name,modifiedTime)",
      orderBy = "modifiedTime desc",
      pageSize = "50",
    },
    headers = headers(token),
  }
  local body = json(response)
  if response.status ~= 200 or not body then
    doc.document_status = "Could not list Drive files (HTTP " .. tostring(response.status) .. ")."
    return
  end
  doc.files = body.files or {}
  doc.document_status = #doc.files == 0
      and "Drive shows no text files this app may open. Paste the file's id or link below."
    or ""
end

-- A Drive file id, from a bare id or from a link that carries one.
local function pasted_id(text)
  text = (text or ""):match("^%s*(.-)%s*$")
  return text:match("/d/([%w_-]+)") or text:match("[?&]id=([%w_-]+)") or text:match("^([%w_-]+)$")
end

local function link_pasted(doc)
  local id = pasted_id(doc.pasted)
  if not id or id == "" then doc.document_status = "That is not a Drive file id or link."; return end
  local record = credential()
  local token = access_token(record)
  if not token then doc.document_status = "Authorize Google Drive first."; return end
  local response, meta = metadata(token, id)
  if response.status == 404 or response.status == 403 then
    doc.document_status = "Drive has no file " .. id .. " this app may open. A file another app "
      .. "created, or one in another account, cannot be linked here."
  elseif response.status ~= 200 or not meta then
    doc.document_status = "Could not reach Drive (HTTP " .. tostring(response.status) .. ")."
  elseif meta.trashed then
    doc.document_status = meta.name .. " is in the Drive trash."
  else
    link_to(doc, id, meta.name, signed_in(record))
  end
end

-- ----- the window -----


-- The settings window: the OAuth client, which is the same app for every
-- project. Detached, because nothing in it is about the document in front.
local function settings_view()
  return taskle.ui.column {
    taskle.ui.text { "OAuth client", tone = "heading" },
    taskle.ui.text { "Uses drive.file and a user-supplied limited-input OAuth client, kept for every project.", tone = "dim" },
    taskle.ui.text_input { id = "client", placeholder = "OAuth client ID", value = ui.client_id, on_input = "client" },
    taskle.ui.text_input { id = "secret", placeholder = "OAuth client secret (if issued)", value = ui.client_secret, on_input = "secret" },
    taskle.ui.text { (taskle.secrets.global.get("client_secret") or "") ~= ""
      and "A client secret is stored; enter one only to replace it."
      or "No client secret stored.", tone = "dim" },
    taskle.ui.button { "Save secret", on_press = ui.client_secret ~= "" and "save-secret" or nil, style = "primary" },
    taskle.ui.text { ui.settings_status, tone = "accent" },
    spacing = 6,
  }
end

local function settings_update(_, message, value)
  if message == "client" then
    ui.client_id = value or ""
    taskle.state.global.set("client_id", ui.client_id)
  elseif message == "secret" then ui.client_secret = value or ""
  elseif message == "save-secret" and ui.client_secret ~= "" then
    taskle.secrets.global.set("client_secret", ui.client_secret)
    ui.client_secret = ""
    ui.settings_status = "Client secret saved."
  end
end

-- The document window: the sign-in for the document's project and the
-- document's own link. A panel over the document, which holds it in front
-- until the window closes.
local function view(doc)
  -- What the last action said is about the document it was taken for: a
  -- sign-in is kept for that document's project, so it says nothing about
  -- another document's.
  local here = (taskle.links.document() or {}).path
  if ui.status_for ~= here then ui.status, ui.status_for = "", here end
  local children = {
    taskle.ui.text { "Account", tone = "heading" },
    taskle.ui.text { signed_in() and ("Signed in for this project as " .. signed_in().name .. ".")
      or "Not signed in for this document's project. Sign-ins are kept per project.", tone = "dim" },
  }
  local function add(node) children[#children + 1] = node end
  if ui.client_id == "" then
    add(taskle.ui.text { "Set the OAuth client in Settings to sign in.", tone = "dim" })
    add(taskle.ui.button { "Settings…", on_press = "settings" })
  else
    add(taskle.ui.button { "Authorize", on_press = "authorize", style = "primary" })
  end
  add(taskle.ui.text { ui.user_code ~= "" and ("Authorization code: " .. ui.user_code) or "", tone = "accent" })
  add(taskle.ui.text { ui.status, tone = "accent" })
  add(taskle.ui.separator {})
  add(taskle.ui.text { "This document", tone = "heading" })
  local link = taskle.links.get()
  if link then
    local pinned = state.get("account_name") or state.get("account")
    add(taskle.ui.text((link.remote == "" and (link.label .. "…") or ("Linked to " .. link.label))
      .. (pinned and (" in " .. pinned) or "")))
    add(taskle.ui.row {
      taskle.ui.button { "Sync Now", on_press = "sync" },
      taskle.ui.button { "Unlink", on_press = "unlink", style = "danger" },
    })
  else
    add(taskle.ui.text { "Not linked: this document does not sync.", tone = "dim" })
    add(taskle.ui.row {
      taskle.ui.button { "Create Drive file", on_press = "create", style = "primary" },
      taskle.ui.button { "Link existing file", on_press = "list" },
    })
    for i, file in ipairs(doc.files or {}) do
      add(taskle.ui.button { file.name .. " — modified " .. (file.modifiedTime or "?"), on_press = "pick:" .. i })
    end
    add(taskle.ui.text_input { id = "pasted", placeholder = "Or paste a Drive file id or link", value = doc.pasted, on_input = "pasted" })
    add(taskle.ui.button { "Link this file", on_press = doc.pasted ~= "" and "link-pasted" or nil })
  end
  add(taskle.ui.text { doc.document_status, tone = "accent" })
  add(taskle.ui.text { "Drive has no conditional media update; a detected post-write race becomes a conflict.", tone = "dim" })
  children.spacing = 6
  return taskle.ui.column(children)
end

local function update(doc, message, value)
  if message == "authorize" then begin_auth()
  elseif message == "settings" then taskle.run("gdrive-sync.configure")
  elseif message == "create" then create_linked(doc)
  elseif message == "list" then list_files(doc)
  elseif message == "pasted" then doc.pasted = value or ""
  elseif message == "link-pasted" then link_pasted(doc)
  elseif message:match("^pick:") then
    local file = (doc.files or {})[tonumber(message:match("^pick:(%d+)"))]
    if file then link_to(doc, file.id, file.name, doc.listed_by) end
  elseif message == "sync" then
    local queued, why = taskle.links.sync()
    doc.document_status = queued and "Syncing…" or why
  elseif message == "unlink" then
    taskle.links.clear()
    doc.document_status = "Unlinked: this document no longer syncs. The Drive file is kept."
    check_unlinked()
  end
end

-- A file id pasted and not linked yet, or a client secret typed and not
-- saved, is asked about before the window closes, the app quits, or the
-- plugins reload.
local function before_close(doc)
  if doc.pasted ~= "" and not taskle.links.get() then
    return { confirm = "The file id you pasted is not linked yet.", save = "link-pasted" }
  end
end

local function settings_before_close()
  if ui.client_secret ~= "" then
    return { confirm = "The client secret you typed is not saved.", save = "save-secret" }
  end
end

taskle.window {
  id = "gdrive-sync",
  title = NAME,
  command = "gdrive-sync.document",
  scope = "document",
  state = new_document_ui,
  view = view,
  update = update,
  before_close = before_close,
}
taskle.window {
  id = "settings",
  title = NAME .. " Settings",
  command = "gdrive-sync.configure",
  settings = true,
  detached = true,
  view = settings_view,
  update = settings_update,
  before_close = settings_before_close,
}

-- Sync Now asks for a run of the document in front and nothing else; all the
-- Drive work happens in the run.
local function sync_front()
  local queued, why = taskle.links.sync()
  if not queued then return "Link this document in " .. NAME .. " first (" .. tostring(why) .. ")" end
end

taskle.command { name = "gdrive-sync.now", title = "Sync Now", requires = { "linked" }, fn = sync_front }
taskle.menu { title = "Sync Now", command = "gdrive-sync.now", menu = "File", submenu = NAME }
taskle.menu { title = "This Document…", command = "gdrive-sync.document", menu = "File", submenu = NAME }

-- The item: a click syncs the document in front when it is linked here, and
-- opens the document window to link it when it is not; a right-click offers
-- those and the settings.
-- Each is a command too, for a key, the palette and a terminal, which cannot
-- click.
if taskle.supports("status_item") then
  status_item = taskle.status_item {
    id = "status",
    -- Drawn only beside a document this plugin syncs, with how that
    -- document's link stands after the label.
    linked = true,
    text = "Drive",
    tooltip = HINT,
    on_click = function(ctx)
      local linked = taskle.links.get() ~= nil
      if ctx.button == "right" then
        local items = {}
        if linked then
          items[#items + 1] = { id = "sync", label = "Sync Now", detail = "the document in front" }
        end
        items[#items + 1] = { id = "document", label = "This Document…" }
        items[#items + 1] = { id = "settings", label = "Settings…" }
        local choice = taskle.choose { prompt = NAME, items = items }
        if choice == "sync" then return sync_front() end
        if choice == "document" then taskle.run("gdrive-sync.document") end
        if choice == "settings" then taskle.run("gdrive-sync.configure") end
        return
      end
      if linked then return sync_front() end
      taskle.run("gdrive-sync.document")
    end,
  }
end
