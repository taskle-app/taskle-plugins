-- Google Drive synchronization for canonical local todo.txt files.
--
-- Sync is opt-in per document: a document syncs once it is linked to a Drive
-- file in this plugin's window, and the host keeps that link. Every run ends
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
  client_id = taskle.state.get("client_id") or "",
  client_secret = "",
  status = "",
  user_code = taskle.state.get("user_code") or "",
  -- The Drive files offered by "Link existing file", once listed.
  files = nil,
  -- What was typed into the "paste a file id or link" field.
  pasted = "",
  -- What the last action on this document said.
  document_status = "",
}

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

-- A usable access token, refreshed when needed, or nil and why not.
local function access_token()
  local access = taskle.secrets.get("access_token")
  local expires = tonumber(taskle.state.get("access_expires") or "0") or 0
  if access and access ~= "" and expires > taskle.now() + 60 then return access end
  local refresh = taskle.secrets.get("refresh_token")
  if not refresh or refresh == "" or ui.client_id == "" then
    return nil, "Not authorized"
  end
  local values = { client_id = ui.client_id, refresh_token = refresh, grant_type = "refresh_token" }
  local secret = taskle.secrets.get("client_secret")
  if secret and secret ~= "" then values.client_secret = secret end
  local response = token_request(values)
  local body = json(response)
  if response.status ~= 200 or not body or not body.access_token then
    return nil, "Authorization must be renewed"
  end
  taskle.secrets.set("access_token", body.access_token)
  taskle.state.set("access_expires", tostring(taskle.now() + (body.expires_in or 3600)))
  return body.access_token
end

local function headers(token, content_type)
  return { Authorization = "Bearer " .. token, ["Content-Type"] = content_type or "application/json" }
end

local function metadata(token, file_id)
  local response = taskle.http.get {
    url = DRIVE .. "/" .. file_id .. "?fields=id,name,version,modifiedTime,trashed",
    headers = headers(token),
  }
  return response, json(response)
end

local function download(token, file_id)
  return taskle.http.get { url = DRIVE .. "/" .. file_id .. "?alt=media", headers = headers(token) }
end

-- ----- one run of a linked document -----
--
-- Every function below returns the status the run ends with: a state and a
-- message saying what to do. `run` reports it, so no path can end silently.

local state = taskle.links.state

local function ok(message) return "ok", message or "" end
local function failed(message) return "error", message end

local function remember(version, content)
  state.set("version", tostring(version))
  state.set("base", hash(content))
  state.delete("pending_version")
  state.delete("pending_hash")
end

-- Hand Drive's copy to the host: as a replacement when only Drive changed, as
-- a conflict that keeps both when both did.
local function stage(snapshot, remote, version, diverged)
  state.set("pending_version", tostring(version))
  state.set("pending_hash", hash(remote))
  local operation = diverged and taskle.document.conflict or taskle.document.replace
  operation {
    document_id = snapshot.document_id,
    token = snapshot.token,
    content = remote,
    reason = "gdrive-sync",
  }
end

local function both_kept(why)
  return "conflict", why .. "; both versions were kept. Choose which to keep, then save."
end

-- Write the snapshot over the Drive file, if Drive still holds `expected`.
local function upload(snapshot, token, file_id, expected)
  local before_response, before = metadata(token, file_id)
  if before_response.status ~= 200 or not before or tostring(before.version) ~= tostring(expected) then
    local remote = download(token, file_id)
    if remote.status == 200 and before and before.version then
      stage(snapshot, remote.body, before.version, true)
      return both_kept("Drive changed before the upload")
    end
    return failed("Could not check the Drive file before uploading (HTTP "
      .. tostring(before_response.status) .. "); the local changes are not on Drive yet")
  end
  local response = taskle.http.patch {
    url = UPLOAD .. "/" .. file_id .. "?uploadType=media&fields=id,version",
    headers = headers(token, "text/plain; charset=utf-8"),
    body = snapshot.saved_content,
  }
  local written = json(response)
  if response.status ~= 200 or not written or not written.version then
    return failed("Upload failed (HTTP " .. tostring(response.status) .. "); the local changes are not on Drive yet")
  end
  local after_response, after = metadata(token, file_id)
  if after_response.status ~= 200 or not after or tostring(after.version) ~= tostring(written.version) then
    local remote = download(token, file_id)
    if remote.status == 200 and after and after.version then
      stage(snapshot, remote.body, after.version, true)
      notify("Drive changed during upload; both versions were kept.", "critical")
      return both_kept("Drive changed during the upload")
    end
    return failed("Could not confirm the upload (HTTP " .. tostring(after_response.status) .. ")")
  end
  remember(written.version, snapshot.saved_content)
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
    -- Drive's copy was handed over. Once the document holds it, Drive and
    -- the document agree; until then the user is choosing, and only their
    -- save says which version they kept.
    if local_hash == pending_hash then
      remember(pending_version, snapshot.saved_content)
      taskle.links.synced { token = snapshot.token }
      return ok()
    elseif event == "after_save" then
      return upload(snapshot, token, file_id, pending_version)
    end
    return both_kept("This document and Drive both changed")
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
    remember(remote_meta.version, snapshot.saved_content)
    taskle.links.synced { token = snapshot.token }
    return ok()
  end
  if not known_version then
    -- A first comparison: neither copy can be shown to come from the other,
    -- so neither is adopted.
    stage(snapshot, remote.body, remote_meta.version, true)
    return both_kept("This document and the Drive file differ")
  end
  local local_changed = base ~= nil and local_hash ~= base
  local remote_changed = tostring(remote_meta.version) ~= known_version
  if local_changed and remote_changed then
    stage(snapshot, remote.body, remote_meta.version, true)
    return both_kept("This document and Drive both changed")
  elseif remote_changed then
    stage(snapshot, remote.body, remote_meta.version, false)
    return ok("Updated from Drive")
  end
  -- Saved local content Drive has not got, with Drive unchanged since the
  -- last sync. Every snapshot is saved content, so any event may send it.
  return upload(snapshot, token, file_id, remote_meta.version)
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
      local updated, why = taskle.links.update { expect = link.id, remote = id, label = "Drive: " .. meta.name }
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
    url = UPLOAD .. "?uploadType=multipart&fields=id,name,version",
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
  local updated, why = taskle.links.update { expect = link.id, remote = created.id, label = "Drive: " .. (created.name or name) }
  if not updated then return failed("Could not finish the link: " .. tostring(why)) end
  state.delete("creating_id")
  remember(created.version, snapshot.saved_content)
  taskle.links.synced { token = snapshot.token }
  return ok()
end

-- The status the last run reported, for a poll that skips Drive this time.
local function last_status(link_id)
  for _, link in ipairs(taskle.links.list()) do
    if link.id == link_id and link.state then return link.state, link.message or "" end
  end
end

local function run(snapshot, event)
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
  local result, message
  local token, why = access_token()
  if not token then
    result, message = failed(why .. ": open " .. NAME .. " to sign in; "
      .. file_name(snapshot.path) .. " is not syncing")
  elseif snapshot.link.remote == "" then
    result, message = create(snapshot, token)
  else
    result, message = compare(snapshot, token, snapshot.link.remote, event)
  end
  taskle.links.status { state = result, message = message }
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
  if ui.client_id == "" then ui.status = "Enter a limited-input OAuth client ID first."; return end
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
  local secret = taskle.secrets.get("client_secret")
  if secret and secret ~= "" then values.client_secret = secret end
  local response = token_request(values)
  local body = json(response)
  if response.status == 200 and body and body.access_token then
    taskle.secrets.set("access_token", body.access_token)
    if body.refresh_token then taskle.secrets.set("refresh_token", body.refresh_token) end
    taskle.state.set("access_expires", tostring(taskle.now() + (body.expires_in or 3600)))
    taskle.secrets.delete("device_code")
    taskle.state.delete("user_code")
    taskle.state.delete("auth_poll_interval")
    taskle.state.delete("auth_poll_at")
    ui.user_code, ui.status = "", "Google Drive connected."
  elseif body and body.error == "slow_down" then
    interval = interval + 5
    taskle.state.set("auth_poll_interval", tostring(interval))
    taskle.state.set("auth_poll_at", tostring(taskle.now() + interval))
  elseif body and body.error ~= "authorization_pending" then
    taskle.secrets.delete("device_code")
    taskle.state.delete("user_code")
    taskle.state.delete("auth_poll_interval")
    taskle.state.delete("auth_poll_at")
    ui.status = "Authorization failed: " .. tostring(body.error)
  end
end

taskle.timer { id = "gdrive-auth", every = "1s", missed = "skip", fn = poll_auth }

-- ----- this document -----

-- Link the document in front to the Drive file `id` named `name`.
local function link_to(id, name)
  local made, why = taskle.links.set { remote = id, label = "Drive: " .. name }
  if made then
    ui.files = nil
    ui.pasted = ""
    ui.document_status = "Linked to Drive: " .. name .. ". Comparing the two copies…"
  else
    ui.document_status = why
  end
end

local function create_linked()
  if not access_token() then ui.document_status = "Authorize Google Drive first."; return end
  local document, refused = taskle.links.document()
  if not document then ui.document_status = refused; return end
  local made, why = taskle.links.set { remote = "", label = "Drive: creating " .. document.name }
  ui.document_status = made and "Creating the Drive file…" or why
end

local function list_files()
  local token = access_token()
  if not token then ui.document_status = "Authorize Google Drive first."; return end
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
    ui.document_status = "Could not list Drive files (HTTP " .. tostring(response.status) .. ")."
    return
  end
  ui.files = body.files or {}
  ui.document_status = #ui.files == 0
      and "Drive shows no text files this app may open. Paste the file's id or link below."
    or ""
end

-- A Drive file id, from a bare id or from a link that carries one.
local function pasted_id(text)
  text = (text or ""):match("^%s*(.-)%s*$")
  return text:match("/d/([%w_-]+)") or text:match("[?&]id=([%w_-]+)") or text:match("^([%w_-]+)$")
end

local function link_pasted()
  local id = pasted_id(ui.pasted)
  if not id or id == "" then ui.document_status = "That is not a Drive file id or link."; return end
  local token = access_token()
  if not token then ui.document_status = "Authorize Google Drive first."; return end
  local response, meta = metadata(token, id)
  if response.status == 404 or response.status == 403 then
    ui.document_status = "Drive has no file " .. id .. " this app may open. A file another app "
      .. "created, or one in another account, cannot be linked here."
  elseif response.status ~= 200 or not meta then
    ui.document_status = "Could not reach Drive (HTTP " .. tostring(response.status) .. ")."
  elseif meta.trashed then
    ui.document_status = meta.name .. " is in the Drive trash."
  else
    link_to(id, meta.name)
  end
end

-- ----- the window -----

local function described(link)
  local status = link.state and (link.state .. (link.message ~= "" and (": " .. link.message) or "")) or "not synced yet"
  if link.pending and link.state ~= "error" and link.state ~= "conflict" and link.state ~= "held" then
    status = "changes not yet on Drive"
  end
  return link.label .. " ← " .. file_name(link.path)
    .. (link.exists and "" or " (missing: the local file was moved or deleted)")
    .. " — " .. status
end

local function view()
  local children = {
    taskle.ui.text { "Account", tone = "heading" },
    taskle.ui.text { "Uses drive.file and a user-supplied limited-input OAuth client.", tone = "dim" },
    taskle.ui.text_input { id = "client", placeholder = "OAuth client ID", value = ui.client_id, on_input = "client" },
    taskle.ui.text_input { id = "secret", placeholder = "OAuth client secret (if issued)", value = ui.client_secret, on_input = "secret" },
    taskle.ui.button { "Authorize", on_press = "authorize", style = "primary" },
    taskle.ui.text { ui.user_code ~= "" and ("Authorization code: " .. ui.user_code) or "", tone = "accent" },
    taskle.ui.text { ui.status, tone = "accent" },
    taskle.ui.separator {},
    taskle.ui.text { "This document", tone = "heading" },
  }
  local function add(node) children[#children + 1] = node end
  local link = taskle.links.get()
  if link then
    add(taskle.ui.text(link.remote == "" and (link.label .. "…") or ("Linked to " .. link.label)))
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
    for i, file in ipairs(ui.files or {}) do
      add(taskle.ui.button { file.name .. " — modified " .. (file.modifiedTime or "?"), on_press = "pick:" .. i })
    end
    add(taskle.ui.text_input { id = "pasted", placeholder = "Or paste a Drive file id or link", value = ui.pasted, on_input = "pasted" })
    add(taskle.ui.button { "Link this file", on_press = ui.pasted ~= "" and "link-pasted" or nil })
  end
  add(taskle.ui.text { ui.document_status, tone = "accent" })
  add(taskle.ui.separator {})
  add(taskle.ui.text { "Linked documents", tone = "heading" })
  local links = taskle.links.list()
  if #links == 0 then
    add(taskle.ui.text { "No documents are linked; nothing is syncing.", tone = "danger" })
  end
  for _, each in ipairs(links) do add(taskle.ui.text(described(each))) end
  add(taskle.ui.text { "Drive has no conditional media update; a detected post-write race becomes a conflict.", tone = "dim" })
  children.spacing = 6
  return taskle.ui.column(children)
end

local function update(_, message, value)
  if message == "client" then ui.client_id = value or ""; taskle.state.set("client_id", ui.client_id)
  elseif message == "secret" then ui.client_secret = value or ""
  elseif message == "authorize" then
    if ui.client_secret ~= "" then taskle.secrets.set("client_secret", ui.client_secret); ui.client_secret = "" end
    begin_auth()
  elseif message == "create" then create_linked()
  elseif message == "list" then list_files()
  elseif message == "pasted" then ui.pasted = value or ""
  elseif message == "link-pasted" then link_pasted()
  elseif message:match("^pick:") then
    local file = (ui.files or {})[tonumber(message:match("^pick:(%d+)"))]
    if file then link_to(file.id, file.name) end
  elseif message == "sync" then
    local queued, why = taskle.links.sync()
    ui.document_status = queued and "Syncing…" or why
  elseif message == "unlink" then
    taskle.links.clear()
    ui.document_status = "Unlinked: this document no longer syncs. The Drive file is kept."
    check_unlinked()
  end
end

taskle.window { id = "gdrive-sync", title = NAME, command = "gdrive-sync.configure", settings = true, view = view, update = update }
