-- Dropbox synchronization for canonical local todo.txt files.
--
-- Sync is opt-in per document: a document syncs once it is linked to a
-- Dropbox path in this plugin's document window, and the host keeps that link. Every
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
  -- The Dropbox app this plugin is registered as: the same whichever project
  -- is in front, so it is kept once, globally. The sign-in stays per project.
  client_id = taskle.state.global.get("client_id") or "",
  code = "",
  status = "",
}

-- What the document window holds for the document it is open on; each
-- document has its own, so a path typed for one is never offered for another.
local function new_document_ui()
  return {
    -- The Dropbox path typed for the document `draft_for` names.
    draft = "",
    draft_for = nil,
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
  local response = token_request {
    grant_type = "refresh_token",
    refresh_token = record.refresh_token,
    client_id = ui.client_id,
  }
  local body = json(response)
  if response.status ~= 200 or not body or not body.access_token then
    return nil, "Authorization must be renewed"
  end
  record.access_token = body.access_token
  record.expires = taskle.now() + (body.expires_in or 14400)
  store(record)
  return record.access_token
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
  return "conflict", why .. "; both versions were kept. Choose which to keep in the conflict dialog."
end

local function forget_staged()
  state.delete("pending_rev")
  state.delete("pending_hash")
end

local function remember(rev, content)
  state.set("rev", rev)
  state.set("base", content_hash(content))
  forget_staged()
  state.delete("postponed")
end

local function postponed()
  return "held", "You postponed choosing between this document and Dropbox; press Sync Now to choose"
end

-- ----- the account -----
--
-- The credentials belong to the plugin, not to a link, and signing in again may
-- switch accounts, where a link's path names some other file or none. So each
-- link records the account it was made under, and a run under any other
-- account holds instead of reading or writing there.

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
    return "held", "This link does not record which Dropbox account it belongs to; unlink and link it again"
  end
  local current = signed_in(record)
  if not current then
    return failed("Sign in to Dropbox again in " .. NAME .. "; which account it is for was not recorded")
  end
  if current.id ~= pinned then
    return "held", "Linked under " .. (state.get("account_name") or pinned) .. ", but " .. NAME
      .. " is signed in as " .. current.name .. "; sign in to that account, or unlink and link again"
  end
end

-- The text the document and Dropbox last agreed on, for a merge to measure the
-- two versions against: the revision recorded at that sync, provided it still
-- hashes to what was recorded. Dropbox drops old revisions, and a base that is
-- not the one both sides shared would make the merge propose wrong changes, so
-- anything short of a match is no base at all.
local function shared_base(token)
  local rev, base = state.get("rev"), state.get("base")
  if not (token and rev and base and taskle.supports("document.conflict_base")) then return nil end
  local response = download(token, "rev:" .. rev)
  if response.status == 200 and content_hash(response.body or "") == base then return response.body end
end

-- Hand Dropbox's copy to the host: as a replacement when only Dropbox
-- changed, as a conflict that keeps both when both did.
local function stage(snapshot, remote, rev, diverged, token)
  state.set("pending_rev", rev)
  state.set("pending_hash", content_hash(remote))
  if diverged then
    taskle.document.conflict {
      document_id = snapshot.document_id,
      token = snapshot.token,
      content = remote,
      reason = "dropbox-sync",
      base = shared_base(token),
    }
  else
    taskle.document.replace {
      document_id = snapshot.document_id,
      token = snapshot.token,
      content = remote,
      reason = "dropbox-sync",
    }
  end
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
      stage(snapshot, downloaded.body, remote.rev, true, token)
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
    -- Dropbox's copy was handed over. The marker records only that: the
    -- replacement may never have been applied (a crash, a closed document, an
    -- expired token), and a conflict may never have been answered, so the
    -- user may not have seen that copy at all. Only the document holding it,
    -- or the user's answer, settles it.
    if snapshot.conflict then return both_kept("This document and Dropbox both changed") end
    local answer = snapshot.conflict_answer
    if answer == "cancel" then
      forget_staged()
      state.set("postponed", "1")
      return postponed()
    end
    if local_hash == pending_hash then
      remember(pending_rev, snapshot.saved_content)
      taskle.links.synced { token = snapshot.token }
      return ok()
    end
    if answer == "mine" or answer == "theirs" or answer == "merged" then
      -- The user chose, and the document holds the outcome (or what they
      -- saved since): it replaces the revision they were shown.
      return upload(snapshot, token, path, pending_rev)
    end
    -- Neither: compare again from the last agreed base, as if nothing had
    -- been handed over.
    forget_staged()
  end
  if state.get("postponed") then
    if event ~= "sync" then return postponed() end
    state.delete("postponed")
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
    stage(snapshot, downloaded.body, latest.rev, true, token)
    return both_kept("This document and the Dropbox file differ")
  end
  local base = state.get("base")
  local local_changed = base ~= nil and local_hash ~= base
  local remote_changed = latest.rev ~= known_rev
  if local_changed and remote_changed then
    stage(snapshot, downloaded.body, latest.rev, true, token)
    return both_kept("This document and Dropbox both changed")
  elseif remote_changed then
    stage(snapshot, downloaded.body, latest.rev, false)
    return ok("Updated from Dropbox")
  end
  -- Saved local content Dropbox has not got, with Dropbox unchanged since the
  -- last sync. Every snapshot is saved content, so any event may send it.
  return upload(snapshot, token, path, latest.rev)
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

-- The status the last run reported, for a poll that skips Dropbox this time.
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
    return "Could not reach Dropbox; check the network connection. It will try again on the next sync"
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

taskle.timer { id = "dropbox-unlinked", every = "60s", missed = "skip", fn = check_unlinked }

-- ----- authorization -----

local function begin_authorization()
  if ui.client_id == "" then ui.status = "Set the Dropbox app key in Settings first."; return end
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

-- The account's email, for messages; nil when Dropbox does not say (an app
-- without the `account_info.read` scope), and the account id stands in.
local function account_email(token)
  local reached, response = pcall(taskle.http.post, {
    url = API .. "/users/get_current_account",
    headers = { Authorization = "Bearer " .. token, ["Content-Type"] = "application/json" },
    body = "null",
  })
  local body = reached and response.status == 200 and json(response)
  return body and body.email ~= "" and body.email or nil
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
  if not body.account_id or body.account_id == "" then
    ui.status = "Authorization failed: Dropbox did not say which account it is for."
    return
  end
  local name = account_email(body.access_token) or body.account_id
  store {
    access_token = body.access_token,
    refresh_token = body.refresh_token,
    expires = taskle.now() + (body.expires_in or 14400),
    account_id = body.account_id,
    account_name = name,
  }
  taskle.state.delete("pkce_verifier")
  ui.code = ""
  ui.status = "Dropbox connected as " .. name .. "."
end

-- ----- this document -----

-- A Dropbox path as Dropbox names it: rooted, no trailing slash.
local function normalized(path)
  path = (path or ""):match("^%s*(.-)%s*$"):gsub("\\", "/"):gsub("/+", "/"):gsub("/$", "")
  if path ~= "" and path:sub(1, 1) ~= "/" then path = "/" .. path end
  return path
end

local function link_path(doc)
  local path = normalized(doc.draft)
  if path == "" or not path:match("[^/]$") then
    doc.document_status = "Enter the Dropbox path to sync with, such as /Taskle/todo.txt."
    return
  end
  local record = credential()
  if not access_token(record) then doc.document_status = "Authorize Dropbox first."; return end
  local account = signed_in(record)
  if not account then
    doc.document_status = "Authorize Dropbox again: which account it is for was not recorded."
    return
  end
  -- Dropbox paths are case-insensitive: two spellings are one file.
  local made, why = taskle.links.set { remote = path, label = "Dropbox: " .. path, match = path:lower() }
  if made then pin(account) end
  doc.document_status = made and ("Linked to " .. path .. " in " .. account.name .. ". Comparing the two copies…") or why
end

-- ----- the window -----


-- The settings window: the Dropbox app, which is the same for every project.
-- Detached, because nothing in it is about the document in front.
local function settings_view()
  return taskle.ui.column {
    taskle.ui.text { "Dropbox app", tone = "heading" },
    taskle.ui.text { "The app key this plugin signs in with, kept for every project.", tone = "dim" },
    taskle.ui.text_input { id = "client", placeholder = "Dropbox app key", value = ui.client_id, on_input = "client" },
    spacing = 6,
  }
end

local function settings_update(_, message, value)
  if message == "client" then
    ui.client_id = value or ""
    taskle.state.global.set("client_id", ui.client_id)
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
    add(taskle.ui.text { "Set the Dropbox app key in Settings to sign in.", tone = "dim" })
    add(taskle.ui.button { "Settings…", on_press = "settings" })
  else
    add(taskle.ui.button { "Authorize", on_press = "authorize", style = "primary" })
    add(taskle.ui.text_input { id = "code", placeholder = "authorization code", value = ui.code, on_input = "code" })
    add(taskle.ui.button { "Finish authorization", on_press = ui.code ~= "" and "finish" or nil })
  end
  add(taskle.ui.text { ui.status, tone = "accent" })
  add(taskle.ui.separator {})
  add(taskle.ui.text { "This document", tone = "heading" })
  local link = taskle.links.get()
  if link then
    local pinned = state.get("account_name") or state.get("account")
    add(taskle.ui.text("Linked to " .. link.remote .. (pinned and (" in " .. pinned) or "")))
    add(taskle.ui.row {
      taskle.ui.button { "Sync Now", on_press = "sync" },
      taskle.ui.button { "Unlink", on_press = "unlink", style = "danger" },
    })
  else
    local document, why = taskle.links.document()
    if document then
      -- A fresh suggestion for each document, until the user types one.
      if doc.draft_for ~= document.path then
        doc.draft, doc.draft_for = "/Taskle/" .. document.name, document.path
      end
      add(taskle.ui.text { "Not linked: this document does not sync.", tone = "dim" })
      add(taskle.ui.text_input { id = "path", placeholder = "/Taskle/todo.txt", value = doc.draft, on_input = "path" })
      add(taskle.ui.button { "Link", on_press = "link", style = "primary" })
    else
      add(taskle.ui.text { why, tone = "dim" })
    end
  end
  add(taskle.ui.text { doc.document_status, tone = "accent" })
  children.spacing = 6
  return taskle.ui.column(children)
end

local function update(doc, message, value)
  if message == "settings" then taskle.run("dropbox-sync.configure")
  elseif message == "code" then ui.code = value or ""
  elseif message == "authorize" then begin_authorization()
  elseif message == "finish" then finish_authorization()
  elseif message == "path" then
    -- Typed for the document in front, so the suggestion never replaces it.
    local document = taskle.links.document()
    doc.draft, doc.draft_for = value or "", document and document.path
  elseif message == "link" then link_path(doc)
  elseif message == "sync" then
    local queued, why = taskle.links.sync()
    doc.document_status = queued and "Syncing…" or why
  elseif message == "unlink" then
    taskle.links.clear()
    doc.document_status = "Unlinked: this document no longer syncs. The Dropbox file is kept."
    check_unlinked()
  end
end

-- A Dropbox path typed and not linked yet, or an authorization code typed
-- and not used, is asked about before the window closes, the app quits, or
-- the plugins reload.
local function before_close(doc)
  if ui.code ~= "" then
    return { confirm = "The authorization code you typed is not used yet.", save = "finish" }
  end
  if doc.draft ~= "" and not taskle.links.get() then
    return { confirm = "The Dropbox path you typed is not linked yet.", save = "link" }
  end
end

taskle.window {
  id = "dropbox-sync",
  title = NAME,
  command = "dropbox-sync.document",
  scope = "document",
  state = new_document_ui,
  view = view,
  update = update,
  before_close = before_close,
}
taskle.window {
  id = "settings",
  title = NAME .. " Settings",
  command = "dropbox-sync.configure",
  settings = true,
  detached = true,
  view = settings_view,
  update = settings_update,
}

-- Sync Now asks for a run of the document in front and nothing else; all the
-- Dropbox work happens in the run.
local function sync_front()
  local queued, why = taskle.links.sync()
  if not queued then return "Link this document in " .. NAME .. " first (" .. tostring(why) .. ")" end
end

taskle.command { name = "dropbox-sync.now", title = "Sync Now", requires = { "linked" }, fn = sync_front }
taskle.menu { title = "Sync Now", command = "dropbox-sync.now", menu = "File", submenu = NAME }
taskle.menu { title = "This Document…", command = "dropbox-sync.document", menu = "File", submenu = NAME }

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
    text = "Dropbox",
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
        if choice == "document" then taskle.run("dropbox-sync.document") end
        if choice == "settings" then taskle.run("dropbox-sync.configure") end
        return
      end
      if linked then return sync_front() end
      taskle.run("dropbox-sync.document")
    end,
  }
end
