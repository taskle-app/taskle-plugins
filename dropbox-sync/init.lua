-- Dropbox synchronization for canonical local todo.txt files.
--
-- Sync is opt-in per document: a document syncs once it is linked to a
-- Dropbox path in this plugin's window, and the host keeps that link. Every
-- run ends with a status the host shows on the document's tab, so a document
-- that stopped syncing never looks synced.
--
-- Dropbox uploads are conditional on the revision they replace, so a write
-- never overwrites a change it has not seen.

local NAME = "Dropbox Sync"
local AUTH = "https://www.dropbox.com/oauth2/authorize"
local TOKEN = "https://api.dropboxapi.com/oauth2/token"
local API = "https://api.dropboxapi.com/2"
local CONTENT = "https://content.dropboxapi.com/2"
-- A poll fires about every 30 seconds; Dropbox is asked at most this often.
local POLL_SECONDS = 300

local ui = {
  client_id = taskle.state.get("client_id") or "",
  code = "",
  status = "",
  -- The Dropbox path typed for the document `draft_for` names.
  draft = "",
  draft_for = nil,
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

local function content_hash(content)
  return taskle.codec.base64url_encode(taskle.codec.sha256(content))
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
  if not refresh or refresh == "" or ui.client_id == "" then return nil, "Not authorized" end
  local response = token_request {
    grant_type = "refresh_token",
    refresh_token = refresh,
    client_id = ui.client_id,
  }
  local body = json(response)
  if response.status ~= 200 or not body or not body.access_token then
    return nil, "Authorization must be renewed"
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
  if args and body then headers["Dropbox-API-Arg"] = taskle.codec.json_encode(args) end
  return taskle.http.post {
    url = url,
    headers = headers,
    body = body or (args and taskle.codec.json_encode(args) or "{}"),
  }
end

local function metadata(token, path)
  local response = request(API .. "/files/get_metadata", token, { path = path })
  return response, json(response)
end

-- Whether a 409 from Dropbox means there is no file at the path.
local function not_found(response)
  return response.status == 409 and (response.body or ""):find("not_found", 1, true) ~= nil
end

local function download(token, path)
  local response = request(CONTENT .. "/files/download", token, { path = path }, "")
  local result
  for key, value in pairs(response.headers or {}) do
    if key:lower() == "dropbox-api-result" then
      local ok, decoded = pcall(taskle.codec.json_decode, value)
      if ok then result = decoded end
    end
  end
  return response, result
end

-- ----- one run of a linked document -----
--
-- Every function below returns the status the run ends with: a state and a
-- message saying what to do. `run` reports it, so no path can end silently.

local state = taskle.links.state

local function ok(message) return "ok", message or "" end
local function failed(message) return "error", message end
local function both_kept(why)
  return "conflict", why .. "; both versions were kept. Choose which to keep, then save."
end

local function remember(rev, content)
  state.set("rev", rev)
  state.set("base", content_hash(content))
  state.delete("pending_rev")
  state.delete("pending_hash")
end

-- Hand Dropbox's copy to the host: as a replacement when only Dropbox
-- changed, as a conflict that keeps both when both did.
local function stage(snapshot, remote, rev, diverged)
  state.set("pending_rev", rev)
  state.set("pending_hash", content_hash(remote))
  local operation = diverged and taskle.document.conflict or taskle.document.replace
  operation {
    document_id = snapshot.document_id,
    token = snapshot.token,
    content = remote,
    reason = "dropbox-sync",
  }
end

-- Write the snapshot to `path`, replacing revision `known_rev`, or adding a
-- new file when there is none. Either way Dropbox refuses rather than
-- overwrite something this run has not seen.
local function upload(snapshot, token, path, known_rev)
  local args = {
    path = path,
    autorename = false,
    mute = true,
    strict_conflict = true,
    mode = known_rev and { [".tag"] = "update", update = known_rev } or { [".tag"] = "add" },
  }
  local response = request(CONTENT .. "/files/upload", token, args, snapshot.saved_content)
  local body = json(response)
  if response.status == 200 and body and body.rev then
    remember(body.rev, snapshot.saved_content)
    taskle.links.synced { token = snapshot.token }
    return ok()
  end
  if response.status == 409 then
    local downloaded, remote = download(token, path)
    if downloaded.status == 200 and remote and remote.rev then
      stage(snapshot, downloaded.body, remote.rev, true)
      return both_kept("Dropbox changed before the upload")
    end
    return failed("Dropbox changed and its copy could not be downloaded (HTTP "
      .. tostring(downloaded.status) .. "); the local changes are not on Dropbox yet")
  end
  return failed("Upload failed (HTTP " .. tostring(response.status) .. "); the local changes are not on Dropbox yet")
end

local function compare(snapshot, token, path, event)
  local local_hash = content_hash(snapshot.saved_content)
  local pending_rev = state.get("pending_rev")
  local pending_hash = state.get("pending_hash")
  if pending_rev and pending_hash then
    -- Dropbox's copy was handed over. Once the document holds it, the two
    -- agree; until then the user is choosing, and only their save says which
    -- version they kept.
    if local_hash == pending_hash then
      remember(pending_rev, snapshot.saved_content)
      taskle.links.synced { token = snapshot.token }
      return ok()
    elseif event == "after_save" then
      return upload(snapshot, token, path, pending_rev)
    end
    return both_kept("This document and Dropbox both changed")
  end
  local known_rev = state.get("rev")
  local response, remote_meta = metadata(token, path)
  if not_found(response) then
    if known_rev then
      return failed("The Dropbox file was deleted or moved; unlink this document and link it again to sync it")
    end
    -- A first comparison with nothing there: upload as a new file. `add`
    -- refuses if one appeared since.
    return upload(snapshot, token, path, nil)
  end
  if response.status ~= 200 or not remote_meta or not remote_meta.rev then
    return failed("Dropbox is unavailable (HTTP " .. tostring(response.status) .. "); will retry")
  end
  local downloaded, latest = download(token, path)
  if downloaded.status ~= 200 or not latest or not latest.rev then
    return failed("Download failed (HTTP " .. tostring(downloaded.status) .. "); will retry")
  end
  local remote_hash = content_hash(downloaded.body)
  if local_hash == remote_hash then
    remember(latest.rev, snapshot.saved_content)
    taskle.links.synced { token = snapshot.token }
    return ok()
  end
  if not known_rev then
    -- A first comparison: neither copy can be shown to come from the other,
    -- so neither is adopted.
    stage(snapshot, downloaded.body, latest.rev, true)
    return both_kept("This document and the Dropbox file differ")
  end
  local base = state.get("base")
  local local_changed = base ~= nil and local_hash ~= base
  local remote_changed = latest.rev ~= known_rev
  if local_changed and remote_changed then
    stage(snapshot, downloaded.body, latest.rev, true)
    return both_kept("This document and Dropbox both changed")
  elseif remote_changed then
    stage(snapshot, downloaded.body, latest.rev, false)
    return ok("Updated from Dropbox")
  end
  -- Saved local content Dropbox has not got, with Dropbox unchanged since the
  -- last sync. Every snapshot is saved content, so any event may send it.
  return upload(snapshot, token, path, latest.rev)
end

-- The status the last run reported, for a poll that skips Dropbox this time.
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

taskle.timer { id = "dropbox-unlinked", every = "60s", missed = "skip", fn = check_unlinked }

-- ----- authorization -----

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

-- ----- this document -----

-- A Dropbox path as Dropbox names it: rooted, no trailing slash.
local function normalized(path)
  path = (path or ""):match("^%s*(.-)%s*$"):gsub("\\", "/"):gsub("/+", "/"):gsub("/$", "")
  if path ~= "" and path:sub(1, 1) ~= "/" then path = "/" .. path end
  return path
end

local function link_path()
  local path = normalized(ui.draft)
  if path == "" or not path:match("[^/]$") then
    ui.document_status = "Enter the Dropbox path to sync with, such as /Taskle/todo.txt."
    return
  end
  if not access_token() then ui.document_status = "Authorize Dropbox first."; return end
  -- Dropbox paths are case-insensitive: two spellings are one file.
  local made, why = taskle.links.set { remote = path, label = "Dropbox: " .. path, match = path:lower() }
  ui.document_status = made and ("Linked to " .. path .. ". Comparing the two copies…") or why
end

-- ----- the window -----

local function described(link)
  local status = link.state and (link.state .. (link.message ~= "" and (": " .. link.message) or "")) or "not synced yet"
  if link.pending and link.state ~= "error" and link.state ~= "conflict" and link.state ~= "held" then
    status = "changes not yet on Dropbox"
  end
  return link.label .. " ← " .. file_name(link.path)
    .. (link.exists and "" or " (missing: the local file was moved or deleted)")
    .. " — " .. status
end

local function view()
  local children = {
    taskle.ui.text { "Account", tone = "heading" },
    taskle.ui.text_input { id = "client", placeholder = "Dropbox app key", value = ui.client_id, on_input = "client" },
    taskle.ui.button { "Authorize", on_press = "authorize", style = "primary" },
    taskle.ui.text_input { id = "code", placeholder = "authorization code", value = ui.code, on_input = "code" },
    taskle.ui.button { "Finish authorization", on_press = ui.code ~= "" and "finish" or nil },
    taskle.ui.text { ui.status, tone = "accent" },
    taskle.ui.separator {},
    taskle.ui.text { "This document", tone = "heading" },
  }
  local function add(node) children[#children + 1] = node end
  local link = taskle.links.get()
  if link then
    add(taskle.ui.text("Linked to " .. link.remote))
    add(taskle.ui.row {
      taskle.ui.button { "Sync Now", on_press = "sync" },
      taskle.ui.button { "Unlink", on_press = "unlink", style = "danger" },
    })
  else
    local document, why = taskle.links.document()
    if document then
      -- A fresh suggestion for each document, until the user types one.
      if ui.draft_for ~= document.path then
        ui.draft, ui.draft_for = "/Taskle/" .. document.name, document.path
      end
      add(taskle.ui.text { "Not linked: this document does not sync.", tone = "dim" })
      add(taskle.ui.text_input { id = "path", placeholder = "/Taskle/todo.txt", value = ui.draft, on_input = "path" })
      add(taskle.ui.button { "Link", on_press = "link", style = "primary" })
    else
      add(taskle.ui.text { why, tone = "dim" })
    end
  end
  add(taskle.ui.text { ui.document_status, tone = "accent" })
  add(taskle.ui.separator {})
  add(taskle.ui.text { "Linked documents", tone = "heading" })
  local links = taskle.links.list()
  if #links == 0 then
    add(taskle.ui.text { "No documents are linked; nothing is syncing.", tone = "danger" })
  end
  for _, each in ipairs(links) do add(taskle.ui.text(described(each))) end
  children.spacing = 6
  return taskle.ui.column(children)
end

local function update(_, message, value)
  if message == "client" then ui.client_id = value or ""; taskle.state.set("client_id", ui.client_id)
  elseif message == "code" then ui.code = value or ""
  elseif message == "authorize" then begin_authorization()
  elseif message == "finish" then finish_authorization()
  elseif message == "path" then
    -- Typed for the document in front, so the suggestion never replaces it.
    local document = taskle.links.document()
    ui.draft, ui.draft_for = value or "", document and document.path
  elseif message == "link" then link_path()
  elseif message == "sync" then
    local queued, why = taskle.links.sync()
    ui.document_status = queued and "Syncing…" or why
  elseif message == "unlink" then
    taskle.links.clear()
    ui.document_status = "Unlinked: this document no longer syncs. The Dropbox file is kept."
    check_unlinked()
  end
end

taskle.window { id = "dropbox-sync", title = NAME, command = "dropbox-sync.configure", settings = true, view = view, update = update }
