-- git-sync: keep the todo.txt's git repository in sync.
--
--   * fetch when the file is opened, adopting one-sided remote changes and
--     asking before resolving divergent local and remote content
--   * commit + push after each save, so your changes are backed up
--
-- Requires the `run_process` and `secrets` capabilities and trust (see
-- ../README.md). If they weren't granted, the gated calls error and the app
-- shows a diagnostic; guard with `taskle.has` to degrade gracefully.
--
-- # Setting it up
--
-- The todo.txt has to already be inside a git repository — this syncs the
-- repository the file lives in, it does not create one. Everything else is
-- configured from the plugin's own window (Help ▸ Plugins ▸ git-sync, or the
-- `git-sync.configure` command):
--
--   Remote        the remote name to push to (default `origin`)
--   Remote URL    set once if the repository has no remote yet
--   Credentials   an HTTPS token, or the passphrase for your SSH key
--
-- Credentials go to `taskle.secrets`, which is encrypted and reachable only by
-- this plugin — never to the todo.txt, and never to a config file you might
-- share. The credential is handed to git through `GIT_ASKPASS` for the length of
-- one call rather than written into the remote URL, where it would end up in
-- `.git/config` and in every error message.

local REMOTE_KEY = "remote"
local URL_KEY = "url"
local TOKEN_KEY = "token"

local state = { status = "", remote = "", url = "", token = "", path = nil }

-- Read a stored value, tolerating a store that cannot be opened at all (no
-- capability, an unwritable config directory). Syncing an already-configured
-- repository does not need the store, so a plugin that refused to load without
-- one would be trading a working feature for a settings screen.
local function stored(key)
  if not taskle.has("secrets") then
    return nil
  end
  local ok, v = pcall(taskle.secrets.get, key)
  return ok and v or nil
end

local function remote_name()
  local v = stored(REMOTE_KEY)
  return (v ~= nil and v ~= "") and v or "origin"
end

-- Where the stored credential is written for the length of one git call. Kept
-- beside the store rather than in /tmp, which is world-readable on most systems.
local ASKPASS = taskle.config_dir .. "/git-sync-askpass"

-- Hand the credential to git through `GIT_ASKPASS`, which git calls and reads a
-- line from, rather than splicing it into the remote URL — a URL with a token in
-- it is written to `.git/config` and repeated in every error message.
--
-- `SSH_ASKPASS` is set from the same value so an encrypted SSH key's passphrase
-- works too; `SSH_ASKPASS_REQUIRE=force` is what makes ssh use it when there is
-- a terminal attached.
local function askpass_env()
  local token = stored(TOKEN_KEY)
  if not token or token == "" or not taskle.has("write_files") then
    return nil
  end
  local ok = pcall(taskle.fs.write, ASKPASS, "#!/bin/sh\nprintf '%s\\n' \"$GIT_SYNC_SECRET\"\n")
  if not ok then
    return nil
  end
  taskle.process.run { argv = { "chmod", "700", ASKPASS } }
  return {
    GIT_ASKPASS = ASKPASS,
    SSH_ASKPASS = ASKPASS,
    SSH_ASKPASS_REQUIRE = "force",
    GIT_TERMINAL_PROMPT = "0",
    GIT_SYNC_SECRET = token,
  }
end

-- Run git in the open document's repository. `taskle.process.run` inherits the
-- app's working directory, so the repository is named explicitly rather than
-- assumed.
local function git_at(path, ...)
  local dir = path and path:match("^(.*)[/\\][^/\\]*$") or "."
  local argv = { "git", "-C", dir }
  for _, a in ipairs({ ... }) do
    argv[#argv + 1] = a
  end
  local r = taskle.process.run { argv = argv, env = askpass_env() }
  if r.code ~= 0 then
    taskle.notify {
      title = "git-sync failed",
      message = "git " .. table.concat({ ... }, " ") .. ": " .. r.stderr,
      urgency = "critical",
    }
  end
  return r
end

local function content_hash(content)
  return taskle.codec.base64url_encode(taskle.codec.sha256(content))
end

local function state_key(path, name)
  return name .. ":" .. content_hash(path or "untitled")
end

local function remember(path, content)
  taskle.state.set(state_key(path, "base"), content_hash(content))
  taskle.state.delete(state_key(path, "pending_hash"))
end

local function stage(snapshot, content, diverged)
  taskle.state.set(state_key(snapshot.path, "pending_hash"), content_hash(content))
  local operation = diverged and taskle.document.conflict or taskle.document.replace
  operation {
    document_id = snapshot.document_id,
    token = snapshot.token,
    content = content,
    reason = "git-sync",
  }
end

local function git(...)
  return git_at(state.path, ...)
end

if not taskle.has("run_process") then
  taskle.notify { title = "git-sync", message = "not granted run_process; disabled" }
  return
end

-- Read the tracked remote version without modifying the canonical local file.
-- The host alone applies the returned bytes, conditioned on the immutable
-- snapshot this operation began with.
taskle.observe_document {
  event = "file_loaded",
  fn = function(snapshot)
    state.path = snapshot.path
    local remote = remote_name()
    if git_at(snapshot.path, "fetch", remote).code ~= 0 then return end
    local branch = git_at(snapshot.path, "rev-parse", "--abbrev-ref", "HEAD")
    local prefix = git_at(snapshot.path, "rev-parse", "--show-prefix")
    local branch_name = branch.stdout and branch.stdout:match("([^\r\n]+)")
    local directory_prefix = prefix.stdout and prefix.stdout:match("([^\r\n]*)") or ""
    local tracked_path = directory_prefix .. ((snapshot.path and snapshot.path:match("([^/\\]+)$")) or "todo.txt")
    if not branch_name or not tracked_path then return end
    local remote_file = git_at(snapshot.path, "show", remote .. "/" .. branch_name .. ":" .. tracked_path)
    if remote_file.code ~= 0 then return end
    local local_hash = content_hash(snapshot.saved_content)
    local remote_hash = content_hash(remote_file.stdout)
    if local_hash == remote_hash then remember(snapshot.path, snapshot.saved_content); return end

    local base = taskle.state.get(state_key(snapshot.path, "base"))
    if not base then
      local merge = git_at(snapshot.path, "merge-base", "HEAD", remote .. "/" .. branch_name)
      local commit = merge.stdout and merge.stdout:match("([^\r\n]+)")
      if commit then
        local base_file = git_at(snapshot.path, "show", commit .. ":" .. tracked_path)
        if base_file.code == 0 then
          base = content_hash(base_file.stdout)
          taskle.state.set(state_key(snapshot.path, "base"), base)
        end
      end
    end

    local local_changed = not base or local_hash ~= base
    local remote_changed = not base or remote_hash ~= base
    if local_changed and remote_changed then
      stage(snapshot, remote_file.stdout, true)
    elseif remote_changed then
      stage(snapshot, remote_file.stdout, false)
    end
  end,
}

taskle.observe_document {
  event = "external_change",
  fn = function(snapshot)
    local pending = taskle.state.get(state_key(snapshot.path, "pending_hash"))
    if pending and content_hash(snapshot.saved_content) == pending then
      remember(snapshot.path, snapshot.saved_content)
    end
  end,
}

-- Back up every save.
taskle.observe_document {
  event = "after_save",
  fn = function(snapshot)
    state.path = snapshot.path
    local file = (snapshot.path and snapshot.path:match("([^/\\]+)$")) or "todo.txt"
    git_at(snapshot.path, "add", "--", file)
    local staged = git_at(snapshot.path, "diff", "--cached", "--name-only", "--", file)
    if staged.code ~= 0 then return end
    if staged.stdout and staged.stdout:match("%S") then
      local committed = git_at(snapshot.path, "commit", "-m", "todo: sync", "--", file)
      if committed.code ~= 0 then return end
    end
    if git_at(snapshot.path, "push", remote_name()).code == 0 then
      remember(snapshot.path, snapshot.saved_content)
    end
  end,
}

-- ===== configuration window =====

local function load_state()
  if not taskle.has("secrets") then
    state.status = "not granted `secrets`; credentials cannot be stored"
    return
  end
  state.remote = stored(REMOTE_KEY) or "origin"
  state.url = stored(URL_KEY) or ""
  -- The stored token is never read back into the field. Showing it would put it
  -- on screen for no reason; the field says whether one is set and replaces it.
  state.token = ""
end

local function view()
  local has_token = stored(TOKEN_KEY) ~= nil
  local rows = {
    taskle.ui.text { "Repository", tone = "heading" },
    taskle.ui.text { "The todo.txt must already be inside a git repository.", tone = "dim" },
    taskle.ui.row {
      taskle.ui.text("Remote"),
      taskle.ui.text_input { id = "remote", placeholder = "origin", value = state.remote, on_input = "remote" },
    },
    taskle.ui.row {
      taskle.ui.text("Remote URL"),
      taskle.ui.text_input {
        id = "url",
        placeholder = "https://github.com/you/todo.git",
        value = state.url,
        on_input = "url",
      },
    },
    taskle.ui.button { "Set remote URL", on_press = state.url ~= "" and "set-url" or nil },
    taskle.ui.separator {},
    taskle.ui.text { "Credentials", tone = "heading" },
    taskle.ui.text {
      has_token and "A credential is stored." or "No credential stored.",
      tone = "dim",
    },
    taskle.ui.text {
      "An HTTPS token, or the passphrase for your SSH key. Stored encrypted.",
      tone = "dim",
    },
    taskle.ui.text_input {
      id = "token",
      placeholder = "paste a token or passphrase",
      value = state.token,
      on_input = "token",
    },
    taskle.ui.row {
      taskle.ui.button { "Save", on_press = state.token ~= "" and "save-token" or nil, style = "primary" },
      taskle.ui.button { "Forget", on_press = has_token and "forget-token" or nil, style = "danger" },
    },
  }
  if state.status ~= "" then
    rows[#rows + 1] = taskle.ui.separator {}
    rows[#rows + 1] = taskle.ui.text { state.status, tone = "accent" }
  end
  rows.spacing = 6
  return taskle.ui.column(rows)
end

local function update(_, msg, value)
  if msg == "remote" then
    state.remote = value or ""
    taskle.secrets.set(REMOTE_KEY, state.remote)
  elseif msg == "url" then
    state.url = value or ""
  elseif msg == "token" then
    state.token = value or ""
  elseif msg == "set-url" then
    taskle.secrets.set(URL_KEY, state.url)
    local name = remote_name()
    -- `set-url` on a remote that doesn't exist fails; add it instead.
    if git("remote", "set-url", name, state.url).code ~= 0 then
      git("remote", "add", name, state.url)
    end
    state.status = "remote " .. name .. " → " .. state.url
  elseif msg == "save-token" then
    taskle.secrets.set(TOKEN_KEY, state.token)
    state.token = ""
    state.status = "credential saved"
  elseif msg == "forget-token" then
    taskle.secrets.delete(TOKEN_KEY)
    state.status = "credential forgotten"
  end
end

load_state()

taskle.window {
  id = "git-sync",
  title = "Git Sync",
  command = "git-sync.configure",
  view = view,
  update = update,
}

-- Declaring a `command` on the window is enough to be reachable: the plugin
-- manager offers a Configure button beside any plugin that registered one. The
-- menu entry is for the action you take repeatedly, not for the settings.
taskle.menu { title = "Sync Now", command = "git-sync.now", menu = "File", submenu = "Git Sync" }

taskle.command {
  name = "git-sync.now",
  title = "Sync Now",
  fn = function()
    git("pull", "--rebase", "--autostash")
    git("add", "--all")
    if git("commit", "-m", "todo: sync").code == 0 then
      git("push", remote_name())
    end
    return "synced"
  end,
}
