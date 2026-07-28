-- Dropbox synchronization for canonical local todo.txt files.

local AUTH = "https://www.dropbox.com/oauth2/authorize"
local TOKEN = "https://api.dropboxapi.com/oauth2/token"
local API = "https://api.dropboxapi.com/2"
local CONTENT = "https://content.dropboxapi.com/2"

local ui = {
  client_id = taskle.state.get("client_id") or "",
  folder = taskle.state.get("folder") or "/Taskle",
  code = "",
  status = "",
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

local function content_hash(content)
  return taskle.codec.base64url_encode(taskle.codec.sha256(content))
end

local function document_key(path)
  return content_hash(path or "untitled")
end

local function state_key(path, name)
  return name .. ":" .. document_key(path)
end

local function filename(path)
  return (path and path:match("([^/\\]+)$")) or "todo.txt"
end

local function remote_path(path)
  local folder = ui.folder:gsub("/+$", "")
  if folder == "" then folder = "/Taskle" end
  return folder .. "/" .. filename(path)
end

local function notify(message, urgency)
  taskle.notify { title = "Dropbox Sync", message = message, urgency = urgency or "normal" }
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
  local response = token_request {
    grant_type = "refresh_token",
    refresh_token = refresh,
    client_id = ui.client_id,
  }
  local body = json(response)
  if response.status ~= 200 or not body or not body.access_token then
    notify("Authorization must be renewed.", "critical")
    return nil
  end
  taskle.secrets.set("access_token", body.access_token)
  taskle.state.set("access_expires", tostring(taskle.now() + (body.expires_in or 14400)))
  return body.access_token
end

local function request(url, token, args, body)
  local headers = {
    Authorization = "Bearer " .. token,
    ["Content-Type"] = body and "application/octet-stream" or "application/json",
  }
  if args then headers["Dropbox-API-Arg"] = taskle.codec.json_encode(args) end
  return taskle.http.post {
    url = url,
    headers = headers,
    body = body or (args and taskle.codec.json_encode(args) or "{}"),
  }
end

local function metadata(token, path)
  local response = request(API .. "/files/get_metadata", token, { path = remote_path(path) })
  return response, json(response)
end

local function download(token, path)
  local response = request(CONTENT .. "/files/download", token, { path = remote_path(path) }, "")
  local result
  for key, value in pairs(response.headers or {}) do
    if key:lower() == "dropbox-api-result" then
      local ok, decoded = pcall(taskle.codec.json_decode, value)
      if ok then result = decoded end
    end
  end
  return response, result
end

local function remember(path, rev, content)
  taskle.state.set(state_key(path, "rev"), rev)
  taskle.state.set(state_key(path, "base"), content_hash(content))
  taskle.state.delete(state_key(path, "pending_rev"))
  taskle.state.delete(state_key(path, "pending_hash"))
end

local function stage(snapshot, remote, rev, diverged)
  taskle.state.set(state_key(snapshot.path, "pending_rev"), rev)
  taskle.state.set(state_key(snapshot.path, "pending_hash"), content_hash(remote))
  local operation = diverged and taskle.document.conflict or taskle.document.replace
  operation {
    document_id = snapshot.document_id,
    token = snapshot.token,
    content = remote,
    reason = "dropbox-sync",
  }
end

local function upload(snapshot, token, known_rev)
  local args = {
    path = remote_path(snapshot.path),
    autorename = false,
    mute = true,
    strict_conflict = true,
    mode = known_rev and { [".tag"] = "update", update = known_rev } or { [".tag"] = "add" },
  }
  local response = request(CONTENT .. "/files/upload", token, args, snapshot.saved_content)
  local body = json(response)
  if response.status == 200 and body and body.rev then
    remember(snapshot.path, body.rev, snapshot.saved_content)
    return true
  end
  if response.status == 409 then
    local downloaded, remote = download(token, snapshot.path)
    if downloaded.status == 200 and remote and remote.rev then
      stage(snapshot, downloaded.body, remote.rev, true)
    else
      notify("The remote file changed and could not be downloaded.", "critical")
    end
    return false
  end
  notify("Upload failed (HTTP " .. tostring(response.status) .. ").", "critical")
  return false
end

local function sync(snapshot, after_save)
  local token = access_token()
  if not token then return end
  local known_rev = taskle.state.get(state_key(snapshot.path, "rev"))
  local base = taskle.state.get(state_key(snapshot.path, "base"))
  local local_hash = content_hash(snapshot.saved_content)
  local pending_rev = taskle.state.get(state_key(snapshot.path, "pending_rev"))
  local pending_hash = taskle.state.get(state_key(snapshot.path, "pending_hash"))
  if pending_rev and pending_hash then
    if local_hash == pending_hash then
      remember(snapshot.path, pending_rev, snapshot.saved_content)
    elseif after_save then
      upload(snapshot, token, pending_rev)
    end
    return
  end
  local response, remote_meta = metadata(token, snapshot.path)
  if response.status == 409 then
    if known_rev then
      notify("The paired Dropbox file was deleted or moved.", "critical")
    elseif after_save then
      upload(snapshot, token, nil)
    end
    return
  end
  if response.status ~= 200 or not remote_meta or not remote_meta.rev then
    notify("Dropbox is unavailable (HTTP " .. tostring(response.status) .. ").")
    return
  end
  local downloaded, latest = download(token, snapshot.path)
  if downloaded.status ~= 200 or not latest or not latest.rev then
    notify("Download failed (HTTP " .. tostring(downloaded.status) .. ").", "critical")
    return
  end
  local remote_hash = content_hash(downloaded.body)
  local local_changed = base and local_hash ~= base
  local remote_changed = not known_rev or latest.rev ~= known_rev
  if not known_rev and local_hash ~= remote_hash then
    stage(snapshot, downloaded.body, latest.rev, true)
  elseif local_changed and remote_changed and local_hash ~= remote_hash then
    stage(snapshot, downloaded.body, latest.rev, true)
  elseif remote_changed and local_hash ~= remote_hash then
    stage(snapshot, downloaded.body, latest.rev, false)
  elseif local_hash ~= remote_hash then
    -- Local content Dropbox has not got. A save is what makes local content
    -- canonical, so only that uploads; any other event leaves `base` alone so
    -- the divergence is still on record. Recording this as synchronized would
    -- lose the local edits twice over: they would never upload, and the next
    -- remote change would read as a one-sided remote edit and replace them.
    if after_save then
      upload(snapshot, token, latest.rev)
    end
  else
    remember(snapshot.path, latest.rev, snapshot.saved_content)
  end
end

for _, event in ipairs { "file_loaded", "after_save", "external_change", "poll" } do
  local observed = event
  taskle.observe_document {
    event = observed,
    fn = function(snapshot)
      if observed == "poll" then
        local checked = tonumber(taskle.state.get(state_key(snapshot.path, "checked")) or "0") or 0
        if checked > taskle.now() - 300 then return end
        taskle.state.set(state_key(snapshot.path, "checked"), tostring(taskle.now()))
      end
      sync(snapshot, observed == "after_save")
    end,
  }
end

local function begin_authorization()
  if ui.client_id == "" then ui.status = "Enter a Dropbox app key first."; return end
  local verifier = taskle.codec.base64url_encode(taskle.codec.random_bytes(48))
  local challenge = taskle.codec.base64url_encode(taskle.codec.sha256(verifier))
  taskle.state.set("pkce_verifier", verifier)
  local url = AUTH .. "?" .. form {
    client_id = ui.client_id,
    response_type = "code",
    token_access_type = "offline",
    code_challenge_method = "S256",
    code_challenge = challenge,
  }
  local opened = taskle.open_url(url)
  ui.status = opened.opened and "Authorize in Dropbox, then paste the displayed code." or (opened.error or "No browser available.")
end

local function finish_authorization()
  local verifier = taskle.state.get("pkce_verifier")
  if not verifier or ui.code == "" then ui.status = "Start authorization and paste its code."; return end
  local response = token_request {
    code = ui.code,
    grant_type = "authorization_code",
    client_id = ui.client_id,
    code_verifier = verifier,
  }
  local body = json(response)
  if response.status ~= 200 or not body or not body.access_token then
    ui.status = "Authorization failed (HTTP " .. tostring(response.status) .. ")."
    return
  end
  taskle.secrets.set("access_token", body.access_token)
  if body.refresh_token then taskle.secrets.set("refresh_token", body.refresh_token) end
  taskle.state.set("access_expires", tostring(taskle.now() + (body.expires_in or 14400)))
  taskle.state.delete("pkce_verifier")
  ui.code = ""
  ui.status = "Dropbox connected."
end

local function view()
  return taskle.ui.column {
    taskle.ui.text { "Dropbox Sync", tone = "heading" },
    taskle.ui.text { "Files remain local; Dropbox synchronization runs after open and save.", tone = "dim" },
    taskle.ui.text_input { id = "client", placeholder = "Dropbox app key", value = ui.client_id, on_input = "client" },
    taskle.ui.text_input { id = "folder", placeholder = "/Taskle", value = ui.folder, on_input = "folder" },
    taskle.ui.button { "Authorize", on_press = "authorize", style = "primary" },
    taskle.ui.text_input { id = "code", placeholder = "authorization code", value = ui.code, on_input = "code" },
    taskle.ui.button { "Finish authorization", on_press = ui.code ~= "" and "finish" or nil },
    taskle.ui.text { ui.status, tone = "accent" },
    spacing = 6,
  }
end

local function update(_, message, value)
  if message == "client" then ui.client_id = value or ""; taskle.state.set("client_id", ui.client_id)
  elseif message == "folder" then ui.folder = value or ""; taskle.state.set("folder", ui.folder)
  elseif message == "code" then ui.code = value or ""
  elseif message == "authorize" then begin_authorization()
  elseif message == "finish" then finish_authorization()
  end
end

taskle.window { id = "dropbox-sync", title = "Dropbox Sync", command = "dropbox-sync.configure", view = view, update = update }
