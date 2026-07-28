-- Google Drive synchronization for canonical local todo.txt files.
-- Drive v3 has no documented conditional media update. Uploads therefore use
-- detect-after-write and preserve a surprising result as an explicit conflict.

local DEVICE = "https://oauth2.googleapis.com/device/code"
local TOKEN = "https://oauth2.googleapis.com/token"
local DRIVE = "https://www.googleapis.com/drive/v3/files/"
local UPLOAD = "https://www.googleapis.com/upload/drive/v3/files/"
local SCOPE = "https://www.googleapis.com/auth/drive.file"

local ui = {
  client_id = taskle.state.get("client_id") or "",
  client_secret = "",
  status = "",
  user_code = taskle.state.get("user_code") or "",
  path = nil,
  content = nil,
  document_id = nil,
}

local function form(values)
  local encoded = {}
  for key, value in pairs(values) do encoded[#encoded + 1] = { key, value } end
  return taskle.codec.form_encode(encoded)
end

local function json(response)
  local ok, value = pcall(taskle.codec.json_decode, response.body or "")
  return ok and value or nil
end

local function hash(value)
  return taskle.codec.base64url_encode(taskle.codec.sha256(value))
end

local function key(path, name)
  return name .. ":" .. hash(path or "untitled")
end

local function notify(message, urgency)
  taskle.notify { title = "Google Drive Sync", message = message, urgency = urgency or "normal" }
end

local function token_request(values)
  return taskle.http.post {
    url = TOKEN,
    headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
    body = form(values),
  }
end

local function access_token()
  local access = taskle.secrets.get("access_token")
  local expires = tonumber(taskle.state.get("access_expires") or "0") or 0
  if access and access ~= "" and expires > taskle.now() + 60 then return access end
  local refresh = taskle.secrets.get("refresh_token")
  if not refresh or refresh == "" or ui.client_id == "" then return nil end
  local values = { client_id = ui.client_id, refresh_token = refresh, grant_type = "refresh_token" }
  local secret = taskle.secrets.get("client_secret")
  if secret and secret ~= "" then values.client_secret = secret end
  local response = token_request(values)
  local body = json(response)
  if response.status ~= 200 or not body or not body.access_token then
    notify("Authorization must be renewed.", "critical")
    return nil
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
    url = DRIVE .. file_id .. "?fields=id,name,version,headRevisionId,modifiedTime,trashed",
    headers = headers(token),
  }
  return response, json(response)
end

local function download(token, file_id)
  return taskle.http.get { url = DRIVE .. file_id .. "?alt=media", headers = headers(token) }
end

local function remember(path, version, content)
  taskle.state.set(key(path, "version"), tostring(version))
  taskle.state.set(key(path, "base"), hash(content))
  taskle.state.delete(key(path, "pending_version"))
  taskle.state.delete(key(path, "pending_hash"))
end

local function stage(snapshot, remote, version, diverged)
  taskle.state.set(key(snapshot.path, "pending_version"), tostring(version))
  taskle.state.set(key(snapshot.path, "pending_hash"), hash(remote))
  local operation = diverged and taskle.document.conflict or taskle.document.replace
  operation {
    document_id = snapshot.document_id,
    token = snapshot.token,
    content = remote,
    reason = "gdrive-sync",
  }
end

local function upload(snapshot, token, file_id, expected_version)
  local before_response, before = metadata(token, file_id)
  if before_response.status ~= 200 or not before or tostring(before.version) ~= tostring(expected_version) then
    local remote = download(token, file_id)
    if remote.status == 200 and before and before.version then
      stage(snapshot, remote.body, before.version, true)
    end
    return false
  end
  local response = taskle.http.patch {
    url = UPLOAD .. file_id .. "?uploadType=media&fields=id,version,headRevisionId,modifiedTime",
    headers = headers(token, "text/plain; charset=utf-8"),
    body = snapshot.saved_content,
  }
  local written = json(response)
  if response.status ~= 200 or not written or not written.version then
    notify("Upload failed (HTTP " .. tostring(response.status) .. ").", "critical")
    return false
  end
  local after_response, after = metadata(token, file_id)
  if after_response.status ~= 200 or not after or tostring(after.version) ~= tostring(written.version) then
    local remote = download(token, file_id)
    if remote.status == 200 and after and after.version then
      stage(snapshot, remote.body, after.version, true)
    end
    notify("Drive changed during upload; both versions were preserved.", "critical")
    return false
  end
  remember(snapshot.path, written.version, snapshot.saved_content)
  return true
end

local function sync(snapshot, after_save)
  ui.path, ui.content, ui.document_id = snapshot.path, snapshot.saved_content, snapshot.document_id
  local file_id = taskle.state.get(key(snapshot.path, "file"))
  if not file_id or file_id == "" then return end
  local token = access_token()
  if not token then return end
  local local_hash = hash(snapshot.saved_content)
  local pending_version = taskle.state.get(key(snapshot.path, "pending_version"))
  local pending_hash = taskle.state.get(key(snapshot.path, "pending_hash"))
  if pending_version and pending_hash then
    if local_hash == pending_hash then
      remember(snapshot.path, pending_version, snapshot.saved_content)
    elseif after_save then
      upload(snapshot, token, file_id, pending_version)
    end
    return
  end
  local response, remote_meta = metadata(token, file_id)
  if response.status == 404 or (remote_meta and remote_meta.trashed) then
    notify("The paired Drive file was deleted or moved to trash.", "critical")
    return
  end
  if response.status ~= 200 or not remote_meta then
    notify("Drive is unavailable (HTTP " .. tostring(response.status) .. ").")
    return
  end
  local remote = download(token, file_id)
  if remote.status ~= 200 then
    notify("Download failed (HTTP " .. tostring(remote.status) .. ").", "critical")
    return
  end
  local base = taskle.state.get(key(snapshot.path, "base"))
  local known_version = taskle.state.get(key(snapshot.path, "version"))
  local remote_hash = hash(remote.body)
  local local_changed = base and local_hash ~= base
  local remote_changed = not known_version or tostring(remote_meta.version) ~= known_version
  if not known_version and local_hash ~= remote_hash then
    -- Nothing is known about this pairing, so neither copy can be shown to be
    -- derived from the other. Plugin state is a hint, and losing it must not
    -- make the remote copy authoritative by accident.
    stage(snapshot, remote.body, remote_meta.version, true)
  elseif local_changed and remote_changed and local_hash ~= remote_hash then
    stage(snapshot, remote.body, remote_meta.version, true)
  elseif remote_changed and local_hash ~= remote_hash then
    stage(snapshot, remote.body, remote_meta.version, false)
  elseif local_hash ~= remote_hash then
    -- Local content Drive has not got. A save is what makes local content
    -- canonical, so only that uploads; any other event leaves `base` alone so
    -- the divergence is still on record. Recording this as synchronized would
    -- lose the local edits twice over: they would never upload, and the next
    -- remote change would read as a one-sided remote edit and replace them.
    if after_save then
      upload(snapshot, token, file_id, remote_meta.version)
    end
  else
    remember(snapshot.path, remote_meta.version, snapshot.saved_content)
  end
end

for _, event in ipairs { "file_loaded", "after_save", "external_change", "poll" } do
  local observed = event
  taskle.observe_document {
    event = observed,
    fn = function(snapshot)
      if observed == "poll" then
        local checked = tonumber(taskle.state.get(key(snapshot.path, "checked")) or "0") or 0
        if checked > taskle.now() - 300 then return end
        taskle.state.set(key(snapshot.path, "checked"), tostring(taskle.now()))
      end
      sync(snapshot, observed == "after_save")
    end,
  }
end

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

local function create_remote()
  if not ui.path or not ui.content then ui.status = "Open the local document first."; return end
  local token = access_token()
  if not token then ui.status = "Authorize Google Drive first."; return end
  local boundary = "taskle-" .. taskle.codec.base64url_encode(taskle.codec.random_bytes(18))
  local name = ui.path:match("([^/\\]+)$") or "todo.txt"
  local body = "--" .. boundary .. "\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n"
    .. taskle.codec.json_encode { name = name, mimeType = "text/plain" }
    .. "\r\n--" .. boundary .. "\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n"
    .. ui.content .. "\r\n--" .. boundary .. "--\r\n"
  local response = taskle.http.post {
    url = "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,version",
    headers = headers(token, "multipart/related; boundary=" .. boundary),
    body = body,
  }
  local created = json(response)
  if response.status == 200 and created and created.id then
    taskle.state.set(key(ui.path, "file"), created.id)
    remember(ui.path, created.version, ui.content)
    ui.status = "Created and paired Drive file " .. created.id
  else
    ui.status = "Create failed (HTTP " .. tostring(response.status) .. ")."
  end
end

local function view()
  local file_id = ui.path and taskle.state.get(key(ui.path, "file")) or nil
  return taskle.ui.column {
    taskle.ui.text { "Google Drive Sync", tone = "heading" },
    taskle.ui.text { "Uses drive.file and a user-supplied limited-input OAuth client.", tone = "dim" },
    taskle.ui.text_input { id = "client", placeholder = "OAuth client ID", value = ui.client_id, on_input = "client" },
    taskle.ui.text_input { id = "secret", placeholder = "OAuth client secret (if issued)", value = ui.client_secret, on_input = "secret" },
    taskle.ui.button { "Authorize", on_press = "authorize", style = "primary" },
    taskle.ui.text { ui.user_code ~= "" and ("Authorization code: " .. ui.user_code) or "", tone = "accent" },
    taskle.ui.button { "Create and pair current document", on_press = ui.path and not file_id and "create" or nil },
    taskle.ui.text { file_id and ("Paired file: " .. file_id) or "No Drive file paired for the current document.", tone = "dim" },
    taskle.ui.text { "Drive has no conditional media update; a detected post-write race becomes a conflict.", tone = "dim" },
    taskle.ui.text { ui.status, tone = "accent" },
    spacing = 6,
  }
end

local function update(_, message, value)
  if message == "client" then ui.client_id = value or ""; taskle.state.set("client_id", ui.client_id)
  elseif message == "secret" then ui.client_secret = value or ""
  elseif message == "authorize" then
    if ui.client_secret ~= "" then taskle.secrets.set("client_secret", ui.client_secret); ui.client_secret = "" end
    begin_auth()
  elseif message == "create" then create_remote()
  end
end

taskle.window { id = "gdrive-sync", title = "Google Drive Sync", command = "gdrive-sync.configure", view = view, update = update }
