-- git-sync: keep a linked todo.txt in git.
--
-- Sync is opt-in per document: a document syncs once it is linked in this
-- plugin's window, and the host keeps that link with the document's own
-- settings. It syncs on the branch checked out in its
-- repository, or on a separate branch that is never checked out, and either
-- pushes or only commits. Every run, whatever started it, works through the
-- same steps and ends with a status the host shows on the document's tab:
--
--   1. fetch the linked branch by name;
--   2. commit the saved document, if it changed, as a commit touching that one
--      file, built in a temporary index so nothing else the user staged goes
--      with it (a commit-only link stops here);
--   3. take incoming commits, when only the remote moved: a fast-forward on the
--      checked-out branch, the document replaced first on a separate one;
--   4. merge, when both sides moved: the merged text goes into the document
--      first (or the user chooses), and a later run commits it, replacing
--      this plugin's own unpushed commits on the checked-out branch and as a
--      merge commit on a separate one; anything else stops (resolve in git);
--   5. push, when every outgoing commit touches only the linked file; anything
--      else waits for the user to approve exactly those commits here.
--
-- It never rewrites a commit it did not make, never leaves the repository
-- mid-merge or mid-rebase, never force-pushes, and never stages or commits any
-- other file.
--
-- Credentials go to `taskle.secrets`, which is encrypted and reachable only by
-- this plugin. The credential is handed to git through `GIT_ASKPASS` for the
-- length of one call rather than written into the remote URL, where it would
-- end up in `.git/config` and in every error message.

local NAME = "Git Sync"
local TOKEN_KEY = "token"
local ZERO = string.rep("0", 40)
-- A poll fires about every 30 seconds; the remote is fetched at most this often.
local POLL_SECONDS = 300
-- How many outgoing commits the approval list shows.
local MAX_LISTED = 20
-- The host tells a run how the user answered the conflict it staged; without
-- that, diverged history holds.
local FEATURE = "document.conflict_answer"

-- How a link authenticates to its remote, in the order the window offers them:
-- the credential shared by the project's documents, the document's own, the
-- user's ssh-agent, or nothing (a local remote, or one git's own credential
-- helper answers).
local AUTHS = { "shared", "secret", "agent", "none" }
local AUTH_LABELS = { shared = "Shared", secret = "This document", agent = "ssh-agent", none = "None" }

local ui = {
  status = "",
  -- The remote typed for the document `remote_for` names, until it is linked.
  remote = "origin",
  remote_for = nil,
  -- What the document in front will do once linked: "push" or "commit".
  action = "push",
  -- Whether it syncs on the branch checked out ("coupled") or on a separate
  -- one ("uncoupled"), and which.
  target = "coupled",
  branch = "todo",
  -- The shared credential typed while the document `token_for` names was in
  -- front ("" for none). The stored one is scoped to that document's project,
  -- so a value typed there is never saved into another project's.
  token = "",
  token_for = nil,
  -- The credential typed for the link `document_token_for` names. Another
  -- document's link in front starts with an empty one, so a value typed for
  -- one document is never saved under another's.
  document_token = "",
  document_token_for = nil,
  document_status = "",
}

local function stored(key)
  local ok, value = pcall(taskle.secrets.get, key)
  return ok and value or nil
end

-- The secret key a link's own credential is kept under.
local function document_token_key(link_id)
  return TOKEN_KEY .. ":" .. link_id
end

-- What a remote git call is run with for a link that authenticates by `auth`:
-- its environment, and whether it gets the user's ssh-agent.
--
-- A stored credential reaches git through `GIT_ASKPASS`, which git calls and
-- reads a line from. `SSH_ASKPASS` is set from the same value so an encrypted
-- SSH key's passphrase works too; `SSH_ASKPASS_REQUIRE=force` makes ssh use it.
-- The helper only prints `GIT_SYNC_SECRET` from its environment, so the file
-- holds no secret. It lives in this plugin's own state directory, which the
-- plugin may write wherever it acts, rather than in /tmp, which other users can
-- write to on most systems.
local function remote_options(auth, link_id)
  local env = { GIT_TERMINAL_PROMPT = "0" }
  if auth == "agent" then return { env = env, ssh_agent = true } end
  if auth == "none" then return { env = env } end
  local token = stored(auth == "secret" and document_token_key(link_id) or TOKEN_KEY)
  if not token or token == "" then return { env = env } end
  local function unused(why)
    taskle.log.warn(NAME .. ": could not prepare the askpass helper, so the stored credential is not used: " .. why)
    return { env = env }
  end
  local found, dir = pcall(function() return taskle.plugin.state_dir end)
  if not found then return unused(tostring(dir)) end
  local askpass = dir .. "/askpass"
  local written, err = pcall(taskle.fs.write, askpass, "#!/bin/sh\nprintf '%s\\n' \"$GIT_SYNC_SECRET\"\n")
  if not written then return unused(tostring(err)) end
  local ran, made = pcall(taskle.process.run, { argv = { "chmod", "700", askpass } })
  if not ran then return unused("chmod could not run: " .. tostring(made)) end
  if made.code ~= 0 then return unused("chmod failed: " .. ((made.stderr or ""):gsub("%s+$", ""))) end
  env.GIT_ASKPASS = askpass
  env.SSH_ASKPASS = askpass
  env.SSH_ASKPASS_REQUIRE = "force"
  env.GIT_SYNC_SECRET = token
  return { env = env }
end

local function dir_of(path)
  return path and path:match("^(.*)[/\\][^/\\]*$") or "."
end

local function file_name(path)
  return (path or ""):match("([^/\\]+)$") or "todo.txt"
end

-- Run git in `dir`. `options.index` names a `GIT_INDEX_FILE`, `options.env`
-- adds variables, `options.stdin` is fed to it, and `options.ssh_agent` hands
-- it the user's ssh-agent.
local function git(dir, args, options)
  options = options or {}
  local argv = { "git", "-C", dir }
  for _, arg in ipairs(args) do argv[#argv + 1] = arg end
  local env = {}
  for key, value in pairs(options.env or {}) do env[key] = value end
  if options.index then env.GIT_INDEX_FILE = options.index end
  return taskle.process.run { argv = argv, env = env, stdin = options.stdin, ssh_agent = options.ssh_agent }
end

local function first_line(result)
  return result.code == 0 and (result.stdout or ""):match("^([^\r\n]+)") or nil
end

local function trimmed(text)
  return ((text or ""):gsub("%s+$", ""))
end

-- Run a small POSIX shell script with `args` as its positional parameters,
-- and `stdin` fed to it.
local function sh(script, args, stdin)
  local argv = { "sh", "-c", script, "sh" }
  for _, arg in ipairs(args) do argv[#argv + 1] = arg end
  return taskle.process.run { argv = argv, stdin = stdin }
end

local function exists(path)
  return sh('[ -e "$1" ]', { path }).code == 0
end

local function remove(paths)
  sh('rm -f -- "$@"', paths)
end

-- A name no other run uses, for a temporary file in the git directory.
local function scratch_name(gitdir)
  return gitdir .. "/taskle-sync-" .. taskle.codec.base64url_encode(taskle.codec.random_bytes(9))
end

-- ----- one run of a linked document -----
--
-- Every step returns the status the run ends with when it stops there: a
-- state and a message saying what to do. `run` reports it, so no path can end
-- silently.

local state = taskle.links.state

local function ok(message) return "ok", message or "" end
local function failed(message) return "error", message end
local function held(message) return "held", message end
-- A status passed up from a step that stopped, as one value.
local function stop(...) return { ... } end

-- A record kept in one link-state value, so it is written and read whole:
-- one `key=value` per line.
local function encode(record)
  local keys = {}
  for key in pairs(record) do keys[#keys + 1] = key end
  table.sort(keys)
  local lines = {}
  for _, key in ipairs(keys) do lines[#lines + 1] = key .. "=" .. record[key] end
  return table.concat(lines, "\n")
end

local function decode(text)
  if not text or text == "" then return nil end
  local record = {}
  for line in text:gmatch("[^\n]+") do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key then record[key] = value end
  end
  return record
end

local function recorded(key) return decode(state.get(key)) end
local function record(key, value) state.set(key, encode(value)) end

local function rev(dir, spec)
  return first_line(git(dir, { "rev-parse", "-q", "--verify", spec }))
end

local function is_ancestor(dir, older, newer)
  return older == newer or git(dir, { "merge-base", "--is-ancestor", older, newer }).code == 0
end

-- Every commit in `range` touches only `rel`, and none is a merge; or why not.
-- With `merges`, merge commits are let through when, against their first
-- parent, they change `rel` alone: a separate branch's merges are git-sync's,
-- the remote's tree with the linked file, and one made by hand that brings in
-- anything else is held like any other commit.
local function only_linked(dir, range, rel, merges)
  local parents = git(dir, { "rev-list", "--parents", range })
  if parents.code ~= 0 then return false, trimmed(parents.stderr) end
  for line in (parents.stdout or ""):gmatch("[^\n]+") do
    local words = {}
    for word in line:gmatch("%S+") do words[#words + 1] = word end
    if #words > 2 then
      if not merges then return false, "it contains a merge commit" end
      local changed = git(dir, { "diff-tree", "--no-commit-id", "--name-only", "-r", words[2], words[1] })
      if changed.code ~= 0 then return false, trimmed(changed.stderr) end
      for path in (changed.stdout or ""):gmatch("[^\n]+") do
        if path ~= rel then return false, "a merge commit changes " .. path end
      end
    end
  end
  local log = git(dir, { "log", "--no-merges", "--format=commit %H", "--name-only", range })
  if log.code ~= 0 then return false, trimmed(log.stderr) end
  for line in (log.stdout or ""):gmatch("[^\n]+") do
    if not line:match("^commit ") and line ~= rel then
      return false, "a commit changes " .. line
    end
  end
  return true
end

-- What a held push would send, for the window: one line per commit (at most
-- MAX_LISTED), then every path the range touches.
local function describe_range(dir, range)
  local log = git(dir, { "log", "--format=commit %h %s", "--name-only", range })
  local lines, paths, seen, count = {}, {}, {}, 0
  for line in (log.stdout or ""):gmatch("[^\n]+") do
    local commit = line:match("^commit (.*)$")
    if commit then
      count = count + 1
      if count <= MAX_LISTED then lines[#lines + 1] = commit end
    elseif not seen[line] then
      seen[line] = true
      paths[#paths + 1] = line
    end
  end
  if count > MAX_LISTED then lines[#lines + 1] = "… and " .. (count - MAX_LISTED) .. " more" end
  -- `log --name-only` shows nothing for a merge; what one changes against its
  -- first parent is what pushing it adds, so it is listed too.
  local merges = git(dir, { "rev-list", "--merges", "--parents", range })
  for line in (merges.stdout or ""):gmatch("[^\n]+") do
    local merge, first = line:match("^(%x+) (%x+)")
    if merge then
      local changed = git(dir, { "diff-tree", "--no-commit-id", "--name-only", "-r", first, merge })
      for path in (changed.stdout or ""):gmatch("[^\n]+") do
        if not seen[path] then
          seen[path] = true
          paths[#paths + 1] = path
        end
      end
    end
  end
  table.sort(paths)
  lines[#lines + 1] = "Files: " .. table.concat(paths, ", ")
  local text = table.concat(lines, "\n")
  if #text > 4000 then text = text:sub(1, 3990) .. "\n…" end
  return text
end

-- The commits in `to` that `from` lacks, as a revision range; every commit of
-- `to` when `from` is nil (a branch the remote does not have yet).
local function span(from, to)
  return from and (from .. ".." .. to) or to
end

local function hold_push(dir, up, tip, why)
  state.set("held_tip", tip)
  state.set("held_base", up or ZERO)
  state.set("held_list", describe_range(dir, span(up, tip)))
  return held(why .. "; review them in " .. NAME .. " and press Push these commits")
end

-- Drop a held push, and any approval given for it: an approval is for the
-- commits that were shown, and goes when they are no longer waiting.
local function clear_held()
  state.delete("held_tip")
  state.delete("held_base")
  state.delete("held_list")
  state.delete("approved_tip")
  state.delete("approved_base")
end

-- ----- the index -----

-- The index entries `ls-files -s` lists for `rel` in `index` (the user's own
-- when nil), as one string ("<mode> <blob> <stage>" per entry), or nil and why
-- it failed.
local function index_entries(dir, index, rel)
  local listed = git(dir, { "ls-files", "-s", "--", rel }, { index = index })
  if listed.code ~= 0 then return nil, trimmed(listed.stderr) end
  local entries = {}
  for mode, blob, stage in (listed.stdout or ""):gmatch("(%d+) (%x+) (%d)\t[^\n]*") do
    entries[#entries + 1] = mode .. " " .. blob .. " " .. stage
  end
  return table.concat(entries, "\n")
end

-- The index entry `rev:rel` would give, as `index_entries` lists it; "" when
-- `rev` is nil or has no such path.
local function tree_entry(dir, rev_, rel)
  if not rev_ then return "" end
  local mode, blob = (first_line(git(dir, { "ls-tree", rev_, "--", rel })) or ""):match("^(%d+) blob (%x+)\t")
  return mode and (mode .. " " .. blob .. " 0") or ""
end

local function staged_changes(rel)
  return held("You have staged changes to " .. rel .. "; commit or unstage them")
end

local function no_index(repo)
  return held(repo.top .. " has no git index; run `git reset` there, then Sync Now")
end

-- Take git's index lock by creating `index.lock` exclusively, as git does,
-- filled with the current index; git's own commands then fail instead of
-- writing the index under us. Returns the lock's path, or nil and the status
-- to stop with.
local function take_lock(repo)
  local index, lock = repo.gitdir .. "/index", repo.gitdir .. "/index.lock"
  local took = sh('set -C; [ -f "$1" ] || exit 3; cat "$1" > "$2"', { index, lock })
  if took.code == 3 then
    return nil, stop(no_index(repo))
  elseif took.code ~= 0 then
    return nil, stop(held("Another git command is running (" .. lock .. " exists); will retry"))
  end
  state.set("lock", lock)
  return lock
end

-- Give the lock up, leaving the index as it was.
local function drop_lock(lock)
  remove({ lock })
  state.delete("lock")
end

-- Set the linked path's entry in the locked copy of the index to `entry`.
local function set_entry(repo, lock, entry)
  local args
  if entry == "" then
    args = { "update-index", "--force-remove", "--", repo.rel }
  else
    local mode, blob = entry:match("^(%d+) (%x+) 0$")
    if not mode then return false end
    args = { "update-index", "--add", "--cacheinfo", mode .. "," .. blob .. "," .. repo.rel }
  end
  return git(repo.dir, args, { index = lock }).code == 0
end

-- Make the locked copy the index, git's own lockfile protocol; the lock is
-- gone either way.
local function commit_lock(repo, lock)
  local renamed = sh('mv -f -- "$1" "$2"', { lock, repo.gitdir .. "/index" }).code == 0
  if not renamed then remove({ lock }) end
  state.delete("lock")
  return renamed
end

-- ----- the chain of the plugin's own unpushed commits -----
--
-- `from` is the commit the run of them starts on and `tip` the last of them:
-- every commit between is one this plugin made. Two SHAs, whatever the number
-- of commits.

local function chain_of()
  local chain = recorded("chain")
  if chain and chain.from and chain.tip then return chain end
end

-- Record that this plugin made `sha` on `parent` (nil for a first commit).
local function join_chain(dir, parent, sha)
  local chain = chain_of()
  if chain and (chain.tip == sha or (is_ancestor(dir, chain.from, sha) and is_ancestor(dir, sha, chain.tip))) then
    return
  end
  if chain and chain.tip == parent then
    record("chain", { from = chain.from, tip = sha })
  elseif parent then
    record("chain", { from = parent, tip = sha })
  else
    state.delete("chain")
  end
end

-- Every commit in `up..head` is this plugin's: `head` is the chain's tip, and
-- the chain starts at or before where `head` and `up` part.
local function all_ours(dir, head, base)
  local chain = chain_of()
  return chain ~= nil and chain.tip == head and is_ancestor(dir, chain.from, base)
end

-- ----- moving the branch -----

-- A new commit holding `blob` as the linked file on top of `parent` (nil for a
-- first commit), built in the temporary index `scratch`, so nothing else the
-- user staged goes with it. The file keeps the mode it has in `parent`, or
-- takes `mode`. Returns the commit and the index entry it gives the linked
-- path, or nil and the status to stop with (see `stop`).
local function build_commit(repo, scratch, parent, blob, mode, merge)
  local dir, rel = repo.dir, repo.rel
  mode = tree_entry(dir, parent, rel):match("^(%d+) ") or mode or "100644"
  local steps = {
    parent and { "read-tree", parent } or { "read-tree", "--empty" },
    { "update-index", "--add", "--cacheinfo", mode .. "," .. blob .. "," .. rel },
  }
  for _, step in ipairs(steps) do
    local result = git(dir, step, { index = scratch })
    if result.code ~= 0 then return nil, stop(failed("git " .. step[1] .. " failed: " .. trimmed(result.stderr))) end
  end
  local tree = first_line(git(dir, { "write-tree" }, { index = scratch }))
  if not tree then return nil, stop(failed("git write-tree failed")) end
  local args = { "commit-tree", tree, "-m", (merge and "todo: merge " or "todo: sync ") .. rel }
  if merge then table.insert(args, 3, "-p"); table.insert(args, 4, merge) end
  if parent then table.insert(args, 3, "-p"); table.insert(args, 4, parent) end
  if first_line(git(dir, { "config", "--bool", "commit.gpgsign" })) == "true" then args[#args + 1] = "-S" end
  local made = git(dir, args)
  local new = first_line(made)
  if not new then return nil, stop(failed("git commit-tree failed: " .. trimmed(made.stderr))) end
  -- Checked before any branch moves to it, since a temporary index that lost
  -- what `read-tree` or `update-index` put in it still writes a tree: the
  -- commit must change the linked file alone, and hold exactly what was asked.
  local entry = mode .. " " .. blob .. " 0"
  local changed = parent and git(dir, { "diff-tree", "--no-commit-id", "--name-only", "-r", parent, new })
    or git(dir, { "ls-tree", "-r", "--name-only", new })
  -- A merge that kept the incoming version changes nothing against `parent`.
  local paths = trimmed(changed.stdout)
  if changed.code ~= 0 or not (paths == rel or (merge and paths == "")) or tree_entry(dir, new, rel) ~= entry then
    return nil, stop(failed("A commit of " .. rel .. " did not come out as expected, so it was not used; "
      .. "will retry"))
  end
  return new, entry
end

-- Move the linked branch from `spec.old` (nil for a branch with no commits)
-- to a new commit holding `spec.blob` as the linked file on top of
-- `spec.parent`, or, with `spec.move`, to `spec.parent` itself. The user's
-- index entry for the path must be `spec.expect`, and becomes the new
-- commit's.
--
-- The whole sequence runs under git's index lock, and a `committing` record
-- is written before the ref moves and deleted only once the ref, the chain
-- and the index agree with it, so a stop anywhere leaves something the next
-- run settles (see `settle`). The new commit is built in a temporary index, so
-- nothing else the user staged goes with it, and the branch moves by
-- compare-and-swap.
--
-- Returns the commit the branch is on now, or nil and the status to stop with
-- (see `stop`), or nil and "moved" when the branch moved under it.
local function advance(repo, spec)
  local dir, gitdir, rel = repo.dir, repo.gitdir, repo.rel
  local lock, stopped = take_lock(repo)
  if not lock then return nil, stopped end
  local scratch = scratch_name(gitdir) .. ".index"
  local function release(why)
    remove({ scratch })
    drop_lock(lock)
    return nil, why
  end
  -- Leftovers of a run that crashed; safe now that this run holds the lock.
  sh('rm -f -- "$1"/taskle-sync-*.index', { gitdir })
  -- The whole entry, read under the lock: a staged mode change keeps the
  -- blob, and an unmerged path has entries at stages other than 0.
  local entries, why = index_entries(dir, lock, rel)
  if not entries then return release(stop(failed("git ls-files failed: " .. why))) end
  if entries ~= spec.expect then return release(stop(staged_changes(rel))) end

  local new, new_entry
  if spec.move then
    new, new_entry = spec.parent, tree_entry(dir, spec.parent, rel)
  else
    new, new_entry = build_commit(repo, scratch, spec.parent, spec.blob, spec.expect:match("^(%d+) "))
    if not new then return release(new_entry) end
  end

  local ref = "refs/heads/" .. repo.branch
  record("committing", {
    sha = new,
    parent = not spec.move and spec.parent or nil,
    move = spec.move and "1" or nil,
    ref = ref,
    old = spec.old or ZERO,
    old_entry = spec.expect,
    new_entry = new_entry,
  })
  if git(dir, { "update-ref", ref, new, spec.old or ZERO }).code ~= 0 then
    state.delete("committing")
    return release("moved")
  end
  local entry_set = set_entry(repo, lock, new_entry)
  if spec.move then
    state.delete("chain")
  else
    join_chain(dir, spec.parent, new)
  end
  remove({ scratch })
  if not (entry_set and commit_lock(repo, lock)) then
    if not entry_set then drop_lock(lock) end
    -- The record stays: the next run repairs the entry from it.
    return nil, stop(failed("Committed " .. rel .. ", but could not update git's index, so git status shows a "
      .. "staged change that undoes the sync until the next sync repairs it; do not commit " .. rel .. " before then"))
  end
  state.delete("committing")
  return new
end

-- ----- moving a branch that is not checked out -----
--
-- A separate branch has no index entry or file of its own to keep in step:
-- the document's file is the only copy, and the branch is git-sync's to move.
-- So there is no index lock to take. The ref's compare-and-swap is the only
-- arbiter, between this Taskle's runs and another process's, and a
-- `committing` record of kind `ref` is what a stop leaves for `settle_ref`.

-- Move the separate branch from `spec.old` (nil when it does not exist yet) to
-- a new commit holding `spec.blob` on top of `spec.parent` (and, for a merge,
-- `spec.merge` as its second parent), or, with `spec.move`, to `spec.parent`
-- itself. Returns what `advance` returns.
local function advance_ref(repo, spec)
  local dir, gitdir = repo.dir, repo.gitdir
  -- Leftovers of a run that crashed. With no lock, another run may be using
  -- its own right now, so only those older than any run can last are taken.
  -- Named apart from the checked-out path's (`taskle-sync-*`), whose sweep
  -- under the index lock would otherwise take one this path is using.
  sh('find "$1" -maxdepth 1 -name "taskle-ref-*.index" -mmin +2 -exec rm -f -- {} +', { gitdir })
  local new = spec.parent
  if not spec.move then
    local scratch = gitdir .. "/taskle-ref-" .. taskle.codec.base64url_encode(taskle.codec.random_bytes(9)) .. ".index"
    local why
    new, why = build_commit(repo, scratch, spec.parent, spec.blob, nil, spec.merge)
    remove({ scratch })
    if not new then return nil, why end
  end
  local ref = "refs/heads/" .. repo.branch
  record("committing", {
    kind = "ref",
    sha = new,
    parent = not spec.move and spec.parent or nil,
    move = spec.move and "1" or nil,
    ref = ref,
    old = spec.old or ZERO,
  })
  if git(dir, { "update-ref", ref, new, spec.old or ZERO }).code ~= 0 then
    state.delete("committing")
    return nil, "moved"
  end
  if spec.move or not spec.parent then
    state.delete("chain")
  else
    join_chain(dir, spec.parent, new)
  end
  state.delete("committing")
  return new
end

-- Finish a `committing` record of kind `ref`, as `settle` finishes one that
-- also kept an index entry. Returns nil to carry on.
local function settle_ref(repo, commit)
  state.delete("committing")
  if not (commit.sha and commit.ref and commit.old) then return nil end
  local now = rev(repo.dir, commit.ref) or ZERO
  -- It landed: the chain records it. Otherwise it never landed, or the branch
  -- moved to a history without it, and the outgoing gate judges what is there.
  if now ~= commit.old and (now == commit.sha or is_ancestor(repo.dir, commit.sha, now)) then
    if commit.move or not commit.parent then
      state.delete("chain")
    else
      join_chain(repo.dir, commit.parent, commit.sha)
    end
  end
  return nil
end

-- Finish what a `committing` record says was under way, before anything else
-- in a run. Entirely under the index lock, and with the ref read there, since
-- another Taskle process may be in the middle of the same sequence. Returns
-- nil to carry on, or the status to stop with.
local function settle(repo)
  local commit = recorded("committing")
  if not commit then return nil end
  if commit.kind == "ref" then return settle_ref(repo, commit) end
  if not (commit.sha and commit.ref and commit.old and commit.old_entry and commit.new_entry) then
    state.delete("committing")
    return nil
  end
  local dir, rel = repo.dir, repo.rel
  local lock, stopped = take_lock(repo)
  if not lock then return stopped end
  local now = rev(dir, commit.ref) or ZERO
  -- Nobody is in the sequence, and the commit did not land.
  if now == commit.old then
    state.delete("committing")
    drop_lock(lock)
    return nil
  end
  -- The ref moved to a history without the commit; the outgoing gate decides.
  if not (now == commit.sha or is_ancestor(dir, commit.sha, now)) then
    state.delete("committing")
    drop_lock(lock)
    return nil
  end
  -- It landed. The index entry, then the chain, then the record.
  local entries, why = index_entries(dir, lock, rel)
  if not entries then
    drop_lock(lock)
    return stop(failed("git ls-files failed: " .. why))
  end
  local repair = entries ~= commit.new_entry
  if repair and entries ~= commit.old_entry then
    -- Someone staged another version since.
    drop_lock(lock)
    return stop(staged_changes(rel))
  end
  if repair and not set_entry(repo, lock, commit.new_entry) then
    drop_lock(lock)
    return stop(failed("Could not repair git's index for " .. rel .. "; git status shows a staged change that "
      .. "undoes the last sync; do not commit " .. rel .. " until a sync repairs it"))
  end
  if commit.move then
    state.delete("chain")
  elseif commit.parent then
    join_chain(dir, commit.parent, commit.sha)
  else
    state.delete("chain")
  end
  if repair then
    if not commit_lock(repo, lock) then
      return stop(failed("Could not repair git's index for " .. rel .. "; git status shows a staged change that "
        .. "undoes the last sync; do not commit " .. rel .. " until a sync repairs it"))
    end
  else
    drop_lock(lock)
  end
  state.delete("committing")
  state.delete("replay")
  state.delete("resolving")
  return nil
end

-- Push exactly `tip` to the linked branch: never forced, so a remote that
-- moved since the fetch rejects it. A push that sends the chain's tip ends
-- the chain.
local function push(repo, tip)
  local pushed = git(repo.dir, { "push", repo.remote, tip .. ":refs/heads/" .. repo.branch }, remote_options(repo.auth, repo.link_id))
  if pushed.code ~= 0 then
    return false, stop(failed("Push to " .. repo.remote .. " failed: " .. trimmed(pushed.stderr)))
  end
  local chain = chain_of()
  if chain and chain.tip == tip then state.delete("chain") end
  return true
end

local separate -- below, after `checked_out_in`
local upstream_ref -- below, before `take_incoming`

-- The worktree `ref` is checked out in, if any: the main one or a linked one.
-- Returns nil, and why, when the worktrees cannot be listed: nothing then
-- shows the branch is free.
local function checked_out_in(dir, ref)
  local listed = git(dir, { "worktree", "list", "--porcelain" })
  if listed.code ~= 0 then return nil, trimmed(listed.stderr) end
  local where
  for line in (listed.stdout or ""):gmatch("[^\n]+") do
    local path = line:match("^worktree (.+)$")
    if path then where = path end
    if line == "branch " .. ref then return where end
  end
  return nil
end

-- Whether a rebase in any worktree of the repository is rewriting `ref`. A
-- rebase detaches HEAD, so the listing above shows that worktree as detached,
-- and only its own git directory says which branch the rebase will move.
local function rebasing(dir, ref)
  local common = first_line(git(dir, { "rev-parse", "--path-format=absolute", "--git-common-dir" }))
  if not common then return true end
  local names = sh('for f in "$1"/rebase-merge/head-name "$1"/rebase-apply/head-name '
    .. '"$1"/worktrees/*/rebase-merge/head-name "$1"/worktrees/*/rebase-apply/head-name; '
    .. 'do [ -f "$f" ] && cat "$f"; done; true', { common })
  for line in (names.stdout or ""):gmatch("[^\n]+") do
    if trimmed(line) == ref then return true end
  end
  return false
end

-- `repo` set up for a separate branch: one that is never checked out, so a
-- run moves only its ref and never the index or the work tree. It holds while
-- any worktree has the branch checked out, since moving it there would leave
-- that worktree's index and files behind it, and while a rebase here is
-- rewriting it.
separate = function(repo, branch)
  if not branch or branch == "" then
    return nil, stop(held("This link names no branch; unlink this document and link it again"))
  end
  local ref = "refs/heads/" .. branch
  local where, unlisted = checked_out_in(repo.dir, ref)
  if unlisted then
    return nil, stop(held("Could not list this repository's worktrees (" .. unlisted .. "), so " .. branch
      .. " may be checked out somewhere; will retry"))
  end
  if where then
    return nil, stop(held(branch .. " is checked out in " .. where .. "; " .. repo.rel
      .. " syncs on it only while no worktree has it checked out"))
  end
  if rebasing(repo.dir, ref) then
    return nil, stop(held("A rebase of " .. branch .. " is in progress; finish or abort it in git"))
  end
  repo.uncoupled, repo.branch = true, branch
  return repo
end

-- Where the repository, the linked file and its branch are, and how the link
-- reaches its remote; or the status to stop with.
local function locate(snapshot)
  -- What the user chose when linking. A link made before links kept it is
  -- linked again rather than guessed at.
  local config = recorded("config")
  if not config then
    return nil, stop(held("This link has no settings of its own; unlink this document and link it again"))
  end
  local action = config.action == "commit" and "commit" or "push"
  local url = config.url or ""
  if action == "push" and (config.remote or "") == "" and url == "" then
    return nil, stop(held("This document has no remote to push to; choose Commit only, or link it again with a remote"))
  end
  local dir = dir_of(snapshot.path)
  local gitdir = first_line(git(dir, { "rev-parse", "--absolute-git-dir" }))
  if not gitdir then
    return nil, stop(failed(file_name(snapshot.path) .. " is no longer in a git repository"))
  end
  local prefix = (git(dir, { "rev-parse", "--show-prefix" }).stdout or ""):match("^([^\r\n]*)") or ""
  local repo = {
    dir = dir,
    gitdir = gitdir,
    top = first_line(git(dir, { "rev-parse", "--show-toplevel" })) or dir,
    rel = prefix .. file_name(snapshot.path),
    -- What git is given to reach the remote, and what messages call it: the
    -- name of a remote the repository has, or a URL used as it is.
    remote = url ~= "" and url or (config.remote or ""),
    url = url ~= "" and url or nil,
    action = action,
    auth = config.auth or "shared",
    link_id = snapshot.link.id,
  }
  if config.target == "uncoupled" then return separate(repo, config.branch) end
  local branch = first_line(git(dir, { "symbolic-ref", "-q", "--short", "HEAD" }))
  local linked = state.get("branch")
  if not linked then
    if not branch then return nil, stop(held("HEAD is detached; check out the branch to sync on, then Sync Now")) end
    state.set("branch", branch)
    linked = branch
  end
  if branch ~= linked then
    return nil, stop(held("On " .. (branch or "a detached HEAD") .. "; " .. repo.rel .. " is linked on " .. linked))
  end
  repo.branch = linked
  local markers = { "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "BISECT_LOG" }
  local paths = {}
  for i, marker in ipairs(markers) do paths[i] = gitdir .. "/" .. marker end
  local busy = sh('for p; do [ -e "$p" ] && printf "%s\\n" "${p##*/}"; done; true', paths)
  local operation = first_line(busy)
  if operation then
    return nil, stop(held("A git operation is in progress (" .. operation .. "); finish or abort it in git"))
  end
  return repo
end

-- ----- diverged history -----

local function diverged(repo, why)
  return held("Local and " .. repo.remote .. " both have new commits" .. (why and (" (" .. why .. ")") or "")
    .. "; resolve them in git (merge or rebase), then Sync Now")
end

local function both_changed(repo)
  return "conflict", "Both machines changed " .. repo.rel .. "; choose which to keep"
end

local function postponed(repo)
  return held("You postponed choosing between the two versions of " .. repo.rel .. "; press Sync Now to choose")
end

-- The hash of `text` as bytes, whatever the repository's filters.
local function raw_hash(dir, text)
  return first_line(git(dir, { "hash-object", "--no-filters", "--stdin" }, { stdin = text }))
end

-- The linked file on disk still holds the snapshot; or the status to stop
-- with while the host has yet to read a newer one (its `external_change` run
-- follows).
local function file_is_snapshot(repo, snapshot, blob)
  local on_disk = first_line(git(repo.dir, { "hash-object", "--path=" .. repo.rel, "--", snapshot.path }))
  if on_disk ~= blob then return stop(ok("Waiting to read the latest change to " .. repo.rel)) end
end

-- Merge `ours` (worktree text) with `base_rev` and `theirs_rev` (`<rev>:<rel>`,
-- read in worktree form; no base reads as empty), from temporary files in the
-- git directory that the script removes on every way out. Returns the merged
-- text and the number of conflicts, or nil and why it failed.
local MERGE = [[
p=$1; dir=$2; base=$3; theirs=$4
trap 'rm -f -- "$p.ours" "$p.base" "$p.theirs"' EXIT
trap 'exit 129' HUP INT TERM
cat > "$p.ours" || exit 250
if [ -n "$base" ]; then
  git -C "$dir" cat-file --filters "$base" > "$p.base" || exit 251
else
  : > "$p.base" || exit 251
fi
git -C "$dir" cat-file --filters "$theirs" > "$p.theirs" || exit 252
git -C "$dir" merge-file -p -L mine -L base -L theirs "$p.ours" "$p.base" "$p.theirs"
]]

local function merge(repo, ours, base_rev, theirs_rev)
  local result = sh(MERGE, { scratch_name(repo.gitdir), repo.dir, base_rev or "", theirs_rev }, ours)
  if result.code >= 0 and result.code <= 127 then return result.stdout or "", result.code end
  return nil, "git merge-file failed: " .. trimmed(result.stderr)
end

-- Replace the plugin's unpushed commits with one on top of `up`, when every
-- gate passes; otherwise hold, as 5a did. This run only asks the host to put
-- the merged text in the document, or stages the conflict for the user: git
-- moves in a later run, once the document holds what is to be committed.
local function replay_or_hold(repo, snapshot, head, up, blob, current)
  local dir, rel = repo.dir, repo.rel
  if not taskle.supports(FEATURE) then return diverged(repo) end
  local base = first_line(git(dir, { "merge-base", head, up }))
  if not base then return held("Local and " .. repo.remote .. " have unrelated histories; resolve them in git") end
  if repo.uncoupled then
    -- A separate branch is merged rather than rewritten, so whose the local
    -- commits are does not matter, and incoming ones may change any file:
    -- the merge commit takes the remote's tree with the merged file. Local
    -- commits that changed other files would then lose those changes.
    local clean, why = only_linked(dir, base .. ".." .. head, rel)
    if not clean then return diverged(repo, "local: " .. why) end
  else
    -- Outgoing gate: every local commit is one this plugin made.
    if not all_ours(dir, head, base) then return diverged(repo, "not every local commit is " .. NAME .. "'s") end
    -- Incoming gate: no merge, and only the linked path.
    local clean, why = only_linked(dir, head .. ".." .. up, rel)
    if not clean then return diverged(repo, "incoming: " .. why) end
    -- Repository gate.
    if not exists(repo.gitdir .. "/index") then return no_index(repo) end
    local entries = index_entries(dir, nil, rel)
    if entries ~= tree_entry(dir, head, rel) then return staged_changes(rel) end
  end
  if not current then return diverged(repo, rel .. " differs from the last local commit") end
  local waiting = file_is_snapshot(repo, snapshot, blob)
  if waiting then return waiting[1], waiting[2] end
  -- Content gate.
  if not rev(dir, up .. ":" .. rel) then return held(repo.remote .. " deleted " .. rel .. "; resolve in git") end
  local filter = (first_line(git(dir, { "check-attr", "filter", "--", rel })) or ""):match(": filter: (.*)$")
  if filter ~= "unspecified" and filter ~= "unset" then return held(rel .. " uses a git filter; resolve in git") end
  local base_rev = rev(dir, base .. ":" .. rel) and (base .. ":" .. rel) or nil

  local merged, conflicts = merge(repo, snapshot.saved_content, base_rev, up .. ":" .. rel)
  if not merged then return failed(conflicts) end
  if conflicts == 0 then
    local hashed = git(dir, { "hash-object", "-w", "--stdin", "--path=" .. rel }, { stdin = merged })
    local merged_blob = first_line(hashed)
    local merged_hash = raw_hash(dir, merged)
    if not merged_blob or not merged_hash then return failed("git hash-object failed: " .. trimmed(hashed.stderr)) end
    record("replay", { ["local"] = head, up = up, merged = merged_hash, blob = merged_blob })
    taskle.document.replace {
      document_id = snapshot.document_id,
      token = snapshot.token,
      content = merged,
      reason = NAME,
    }
    return ok("Merging changes from " .. repo.remote)
  end
  local theirs = git(dir, { "cat-file", "--filters", up .. ":" .. rel })
  if theirs.code ~= 0 then return failed("git cat-file failed: " .. trimmed(theirs.stderr)) end
  -- The merge base is both sides' ancestor, so the user's merge can be
  -- three-way like git's. A file the base lacks was empty there.
  local shared
  if taskle.supports("document.conflict_base") then
    if base_rev then
      local read = git(dir, { "cat-file", "--filters", base_rev })
      if read.code == 0 then shared = read.stdout or "" end
    else
      shared = ""
    end
  end
  record("resolving", { ["local"] = head, up = up, theirs = raw_hash(dir, theirs.stdout or "") or "" })
  taskle.document.conflict {
    document_id = snapshot.document_id,
    token = snapshot.token,
    content = theirs.stdout or "",
    reason = NAME,
    base = shared,
  }
  return both_changed(repo)
end

-- A run that found the branch moving under its commit: once, it asks for one
-- more run at once; twice in a row is an error.
local function moved_again()
  if state.get("moved") then
    state.delete("moved")
    return failed("The branch kept moving while committing; will retry")
  end
  state.set("moved", "1")
  taskle.links.sync()
  return ok("The branch moved while committing; trying again")
end

-- The commit the linked branch is on: HEAD's for the checked-out branch, the
-- ref's own for a separate one; nil for a branch with no commits yet.
local function branch_tip(repo)
  if repo.uncoupled then return rev(repo.dir, "refs/heads/" .. repo.branch .. "^{commit}") end
  return rev(repo.dir, "HEAD^{commit}")
end

-- A link that only commits: the saved document is committed when it changed,
-- and nothing is fetched or pushed. Whatever an earlier push run left waiting
-- on the remote (a merge to replay, a conflict, a push to approve) is about a
-- remote this link no longer reaches, and goes.
local function commit_only(repo, snapshot)
  local dir, rel = repo.dir, repo.rel
  state.delete("replay")
  state.delete("resolving")
  state.delete("ask_again")
  clear_held()
  local hashed = git(dir, { "hash-object", "-w", "--stdin", "--path=" .. rel }, { stdin = snapshot.saved_content })
  local blob = first_line(hashed)
  if not blob then return failed("git hash-object failed: " .. trimmed(hashed.stderr)) end
  local head = branch_tip(repo)
  local head_blob = head and rev(dir, head .. ":" .. rel)
  -- As in a push run: a snapshot equal to what the last sync agreed on is not
  -- a change, even when HEAD moved under it.
  if blob ~= head_blob and blob ~= state.get("blob") then
    local new, why
    if repo.uncoupled then
      new, why = advance_ref(repo, { blob = blob, parent = head, old = head })
    else
      new, why = advance(repo, { blob = blob, parent = head, old = head, expect = tree_entry(dir, head, rel) })
    end
    if why == "moved" then return moved_again() end
    if not new then return why[1], why[2] end
    head_blob = blob
  end
  state.delete("moved")
  -- The commit is where a commit-only document's changes go, so it is
  -- confirmed once they are in one.
  if blob == head_blob then
    state.set("blob", blob)
    taskle.links.synced { token = snapshot.token }
  end
  return ok()
end

-- The ref the remote's copy of the linked branch is fetched into: the
-- remote's own tracking ref for a named remote, and for a URL one no remote
-- owns, so the repository's configuration and its remote-tracking branches are
-- left alone.
upstream_ref = function(repo)
  if repo.url then return "refs/git-sync/" .. repo.link_id .. "/upstream" end
  return "refs/remotes/" .. repo.remote .. "/" .. repo.branch
end

-- Incoming commits on a separate branch, with nothing local the remote lacks:
-- the branch moves to them once the document holds their text, which reaches
-- it the way any download does, through a conditional replacement. Incoming
-- commits may change other files of the branch; only the linked file reaches
-- the document, and git-sync writes nothing else.
local function take_incoming(repo, snapshot, head, up, blob)
  local dir, rel = repo.dir, repo.rel
  local up_blob = rev(dir, up .. ":" .. rel)
  if not up_blob then
    return held(repo.remote .. " deleted " .. rel .. " on " .. repo.branch .. "; resolve it in git")
  end
  if blob == up_blob then
    -- The document already holds it: only the branch moves, once the file
    -- does too.
    local waiting = file_is_snapshot(repo, snapshot, blob)
    if waiting then return waiting[1], waiting[2] end
    local new, why = advance_ref(repo, { move = true, parent = up, old = head })
    if why == "moved" then return moved_again() end
    if not new then return why[1], why[2] end
    state.set("blob", blob)
    taskle.links.synced { token = snapshot.token }
    return ok()
  end
  local text = git(dir, { "cat-file", "--filters", up .. ":" .. rel })
  if text.code ~= 0 then return failed("git cat-file failed: " .. trimmed(text.stderr)) end
  record("adopt", { ["local"] = head, up = up, blob = up_blob })
  taskle.document.replace {
    document_id = snapshot.document_id,
    token = snapshot.token,
    content = text.stdout or "",
    reason = NAME,
  }
  return ok("Updating from " .. repo.remote)
end

local function sync(snapshot)
  local leftover = state.get("lock")
  if leftover then
    if exists(leftover) then
      return failed("A sync stopped while holding git's index lock. Remove " .. leftover
        .. " if no git command is running")
    end
    state.delete("lock")
  end
  local repo, stopped = locate(snapshot)
  if not repo then return stopped[1], stopped[2] end
  local dir, rel = repo.dir, repo.rel

  -- What an earlier run was in the middle of comes first.
  local unsettled = settle(repo)
  if unsettled then return unsettled[1], unsettled[2] end

  if repo.action == "commit" then return commit_only(repo, snapshot) end

  local replay, resolving = recorded("replay"), recorded("resolving")
  if not (resolving and resolving.postponed) then state.delete("ask_again") end
  if resolving then
    -- While the user has the question in front of them, nothing else.
    if snapshot.conflict then return both_changed(repo) end
    -- Kept, so a run that stops before acting on it is not taken for one
    -- nobody answered.
    local answer = snapshot.conflict_answer
    if answer == "cancel" then
      resolving.answer, resolving.postponed = nil, "1"
      record("resolving", resolving)
    elseif answer == "mine" or answer == "theirs" or answer == "merged" then
      resolving.answer = answer
      record("resolving", resolving)
    end
  end

  -- 1. Fetch the linked branch by name. Fetching the whole remote leaves a
  -- remote-tracking ref behind when the branch is deleted there, which would
  -- read as a remote that has it; by name, a deleted branch is an answer.
  local tracking = upstream_ref(repo)
  local seen = rev(dir, tracking)
  local options = remote_options(repo.auth, repo.link_id)
  -- Read for "couldn't find remote ref", which a translated git would word
  -- otherwise.
  options.env.LC_ALL = "C"
  local fetched = git(dir, { "fetch", repo.remote, "+refs/heads/" .. repo.branch .. ":" .. tracking }, options)
  local missing = fetched.code ~= 0 and (fetched.stderr or ""):find("couldn't find remote ref", 1, true)
  if fetched.code ~= 0 and not missing then
    return failed("Fetch from " .. repo.remote .. " failed: " .. trimmed(fetched.stderr))
  end
  if missing and seen then
    -- It was there, and is gone: deleted on the remote, which a sync does
    -- not undo by pushing it back.
    return held(repo.remote .. " no longer has " .. repo.branch .. "; it was deleted there. Push it again in git "
      .. "to keep syncing, or unlink this document")
  end
  -- A branch the remote does not have yet is created by the first push. The
  -- outgoing gate still judges every commit it would send, so a branch that
  -- carries anything but the linked file waits for approval rather than being
  -- published.
  local up = not missing and rev(dir, tracking .. "^{commit}") or nil

  local hashed = git(dir, { "hash-object", "-w", "--stdin", "--path=" .. rel }, { stdin = snapshot.saved_content })
  local blob = first_line(hashed)
  if not blob then return failed("git hash-object failed: " .. trimmed(hashed.stderr)) end
  local head = branch_tip(repo)
  local head_blob = head and rev(dir, head .. ":" .. rel)
  if repo.uncoupled and up and not head then
    -- The remote has the branch and this repository does not: another
    -- machine started it. Starting here from its copy is safe only when the
    -- document already holds that copy; anything else would be pushed over it.
    if blob ~= rev(dir, up .. ":" .. rel) then
      return held(repo.remote .. " already has " .. repo.branch .. ", and " .. rel .. " here differs from its copy. "
        .. "To start from it, replace " .. rel .. " with `git show "
        .. (repo.url and upstream_ref(repo) or (repo.remote .. "/" .. repo.branch)) .. ":" .. rel .. "`, then Sync Now")
    end
    local new, why = advance_ref(repo, { move = true, parent = up })
    if why == "moved" then return moved_again() end
    if not new then return why[1], why[2] end
    head, head_blob = new, blob
  end

  -- A replay or a conflict is acted on only against the history it was
  -- measured on; otherwise it starts over from what is here now.
  local pending = replay or resolving
  if pending and (pending["local"] ~= head or pending.up ~= up) then
    state.delete("replay")
    state.delete("resolving")
    replay, resolving = nil, nil
  end

  -- Incoming text handed to the document on a separate branch: once the
  -- document holds it, the branch moves to the commit it came from.
  local committed = false
  local adopt = repo.uncoupled and recorded("adopt")
  if adopt then
    state.delete("adopt")
    if adopt["local"] == head and adopt.up == up and blob == adopt.blob then
      -- The snapshot was read before the fetch; the file is what has to hold
      -- the incoming text for the branch to move to it.
      local waiting = file_is_snapshot(repo, snapshot, blob)
      if waiting then
        record("adopt", adopt)
        return waiting[1], waiting[2]
      end
      local new, why = advance_ref(repo, { move = true, parent = up, old = head })
      if why == "moved" then return moved_again() end
      if not new then return why[1], why[2] end
      head, head_blob, committed = new, blob, true
    end
    -- Otherwise the document holds something else (an edit, or a replacement
    -- that was refused), or the histories moved: it is judged afresh below.
  end
  if replay then
    state.delete("replay")
    if raw_hash(dir, snapshot.saved_content) == replay.merged and not snapshot.conflict then
      -- The document holds the merged text: commit it on top of the upstream.
      local waiting = file_is_snapshot(repo, snapshot, blob)
      if waiting then
        record("replay", replay)
        return waiting[1], waiting[2]
      end
      local new, why
      if repo.uncoupled then
        new, why = advance_ref(repo, { blob = replay.blob, parent = up, merge = head, old = head })
      else
        new, why = advance(repo, { blob = replay.blob, parent = up, old = head, expect = tree_entry(dir, head, rel) })
      end
      if why == "moved" then return moved_again() end
      if not new then
        record("replay", replay)
        return why[1], why[2]
      end
      head, head_blob, committed = new, replay.blob, true
    end
    -- Otherwise the document holds something else, which is a local change
    -- like any other: it is committed and merged again below.
  elseif resolving then
    if resolving.answer then
      -- Answered: act on what the document holds now, whichever answer it
      -- was, since the user may have edited and saved since.
      local waiting = file_is_snapshot(repo, snapshot, blob)
      if waiting then return waiting[1], waiting[2] end
      local up_blob = rev(dir, up .. ":" .. rel)
      local new, why
      if repo.uncoupled then
        -- Whichever version was kept, the two histories are joined.
        new, why = advance_ref(repo, { blob = blob, parent = up, merge = head, old = head })
      else
        local spec = { parent = up, old = head, expect = tree_entry(dir, head, rel) }
        if blob == up_blob then spec.move = true else spec.blob = blob end
        new, why = advance(repo, spec)
      end
      if why == "moved" then
        state.delete("resolving")
        return moved_again()
      end
      if not new then return why[1], why[2] end
      state.delete("resolving")
      head, head_blob, committed = new, blob, true
    elseif resolving.postponed and not state.get("ask_again") then
      return postponed(repo)
    else
      -- Nobody answered (a restart, a reload, the document closed), or Sync
      -- Now asked again: start over.
      state.delete("resolving")
      state.delete("ask_again")
    end
  end

  -- 2. The saved document, committed if it changed since the last sync. A
  -- snapshot equal to what the last sync agreed on is not a change, even
  -- when HEAD moved under it: committing it would undo whatever moved HEAD.
  if not committed and blob ~= head_blob and blob ~= state.get("blob") then
    local new, why
    if repo.uncoupled then
      new, why = advance_ref(repo, { blob = blob, parent = head, old = head })
    else
      new, why = advance(repo, { blob = blob, parent = head, old = head, expect = tree_entry(dir, head, rel) })
    end
    if why == "moved" then return moved_again() end
    if not new then return why[1], why[2] end
    head, head_blob = new, blob
  end
  state.delete("moved")
  local current = blob == head_blob

  local behind = up and tonumber(first_line(git(dir, { "rev-list", "--count", head and (head .. ".." .. up) or up })) or "0") or 0
  local ahead = head and tonumber(first_line(git(dir, { "rev-list", "--count", span(up, head) })) or "0") or 0

  -- 4. Diverged.
  if behind > 0 and ahead > 0 then
    return replay_or_hold(repo, snapshot, head, up, blob, current)
  end

  -- 3. Incoming only.
  if behind > 0 and repo.uncoupled then return take_incoming(repo, snapshot, head, up, blob) end
  if behind > 0 then
    local clean, why = only_linked(dir, (head or "") .. ".." .. up, rel)
    if not clean then
      return held("Incoming commits cannot be applied automatically (" .. why .. "); update in git")
    end
    -- The document still holds what HEAD held until it reloads the file the
    -- fast-forward changes; until then that is not a local change to commit.
    if current then state.set("blob", blob) end
    local merged = git(dir, { "merge", "--ff-only", "-q", up })
    if merged.code ~= 0 then
      return failed("Could not fast-forward to " .. repo.remote .. ": " .. trimmed(merged.stderr))
    end
    return ok("Updated from " .. repo.remote)
  end

  -- 5. Outgoing only.
  if ahead > 0 then
    local approved_tip, approved_base = state.get("approved_tip"), state.get("approved_base")
    state.delete("approved_tip")
    state.delete("approved_base")
    local tip = head
    if approved_tip then
      local still = approved_base == (up or ZERO) and is_ancestor(dir, approved_tip, head)
      if not still then
        return hold_push(dir, up, head, "The commits changed since you approved them; review again")
      end
      tip = approved_tip
    else
      local clean, why = only_linked(dir, span(up, head), rel, repo.uncoupled)
      if not clean then
        return hold_push(dir, up, head, "Outgoing commits touch more than " .. rel .. " (" .. why .. ")")
      end
    end
    local pushed, stop_push = push(repo, tip)
    if not pushed then return stop_push[1], stop_push[2] end
    clear_held()
    if tip ~= head then
      -- An approval sends exactly the commits that were reviewed. Those made
      -- since are another range: the next run judges them as it judges any
      -- outgoing commits, pushing them only if they touch the document alone.
      return held("Pushed the approved commits; the commits made since are checked on the next sync")
    end
  end

  clear_held()
  if current then
    state.set("blob", blob)
    taskle.links.synced { token = snapshot.token }
  end
  return ok()
end

-- ----- the status bar -----
--
-- One item for everything this plugin syncs, saying how the worst of it stands:
-- the host's badge already says how the document in front does, so this is the
-- view across every linked document, and the place to act on them from. Hidden
-- while nothing is linked, so an idle sync plugin takes no room in the bar.

local status_item = nil -- registered at the end of the file, after what it runs

-- The links a user asked to sync, by id, until their run reports. The status
-- line is left alone — nothing could take a "Syncing…" there down once the run
-- ends — and the item shows the sync instead.
local syncing = {}

local MARKS = { ok = "✓", pending = "↻", held = "⏸", conflict = "⚠", error = "⚠" }
local RANK = { ok = 0, pending = 1, held = 2, conflict = 3, error = 3 }

-- Refresh the item from the links. A run reports its status as an effect the
-- host applies after it, so the run that just finished passes what it
-- reported, which `taskle.links.list()` does not show yet.
local function show_links(just_id, just_state, just_message)
  if not status_item then return end
  local links = taskle.links.list()
  if #links == 0 then
    status_item:set { hidden = true }
    return
  end
  local worst, attention, why = "ok", 0, nil
  for _, link in ipairs(links) do
    local just = link.id == just_id
    if just then syncing[link.id] = nil end
    local result = just and just_state or link.state
    if syncing[link.id] then result = "pending" end
    local message = (just and just_message or link.message) or ""
    if not result or (result == "ok" and link.pending and not just) then result = "pending" end
    if result ~= "ok" and result ~= "pending" then
      attention = attention + 1
      why = why or (link.label .. ": " .. (message ~= "" and message or result))
    end
    if (RANK[result] or 3) > RANK[worst] then worst = MARKS[result] and result or "error" end
  end
  local counted = #links == 1 and "1 document" or (#links .. " documents")
  local summary = why
    or (next(syncing) and "syncing to Git now")
    or (worst == "pending" and (counted .. ", changes not yet synced") or (counted .. " in sync"))
  status_item:set {
    hidden = false,
    text = "Git " .. MARKS[worst] .. (attention > 1 and (" " .. attention) or ""),
    tooltip = NAME .. " — " .. summary .. ". Click to sync, right-click for more.",
  }
end

-- The status the last run reported, for a poll that skips the remote.
local function last_status(link_id)
  for _, link in ipairs(taskle.links.list()) do
    if link.id == link_id and link.state then return link.state, link.message or "" end
  end
end

local function run_once(snapshot, event)
  -- A run with work under way is never put off: the host queues the run that
  -- finishes it, and if that run is lost a poll must not wait five minutes.
  local under_way = state.get("replay") or state.get("resolving") or state.get("committing") or state.get("adopt")
  -- And only for a link that still has its settings: one without them must
  -- reach `locate`, which holds, rather than repeat an `ok` from before.
  if event == "poll" and not under_way and recorded("config") then
    local checked = tonumber(state.get("checked") or "0") or 0
    if checked > taskle.now() - POLL_SECONDS then
      local kept, message = last_status(snapshot.link.id)
      if kept then
        taskle.links.status { state = kept, message = message }
        show_links(snapshot.link.id, kept, message)
        return
      end
    end
  end
  state.set("checked", tostring(taskle.now()))
  local result, message = sync(snapshot)
  taskle.links.status { state = result, message = message }
  show_links(snapshot.link.id, result, message)
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
    return "Could not reach the Git remote; check the network connection. It will try again on the next sync"
  end
  return "Sync failed: " .. message
end

local function run(snapshot, event)
  local ran, err = pcall(run_once, snapshot, event)
  if not ran then
    local message = trouble(err)
    taskle.links.status { state = "error", message = message }
    show_links(snapshot.link.id, "error", message)
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

local function check_unlinked()
  show_links()
  if #taskle.links.list() > 0 then
    taskle.state.delete("told_unlinked")
  elseif taskle.state.get("told_unlinked") ~= "1" then
    taskle.state.set("told_unlinked", "1")
    taskle.notify { title = NAME, message = NAME .. " is enabled but no document is linked; nothing is syncing." }
  end
end

taskle.timer { id = "git-unlinked", every = "60s", missed = "skip", fn = check_unlinked }

-- ----- the window -----

-- The repository of the document in front, or nil and why.
local function front_repository()
  local document, why = taskle.links.document()
  if not document then return nil, why end
  local dir = dir_of(document.path)
  local top = first_line(git(dir, { "rev-parse", "--show-toplevel" }))
  if not top then return nil, document.name .. " is not in a git repository" end
  local prefix = (git(dir, { "rev-parse", "--show-prefix" }).stdout or ""):match("^([^\r\n]*)") or ""
  return { dir = dir, top = top, rel = prefix .. document.name }
end

-- Whether `text` names a remote by its address rather than by a remote's
-- name: a URL, an scp-style `user@host:path`, or a path to a repository.
local function looks_like_url(text)
  return text:find("://", 1, true) ~= nil or text:match("^[%w._-]+@[%w._-]+:") ~= nil
    or text:match("^/") ~= nil or text:match("^%.%.?/") ~= nil
end

-- What the link is called: where the document goes, and from which repository.
local function link_label(config, top)
  local where = config.action == "commit" and "commit only" or ((config.url or "") ~= "" and config.url or config.remote)
  if config.target == "uncoupled" then where = where .. " → " .. config.branch end
  return where .. " @ " .. top
end

-- Make the folder of the document in front a git repository, so it can be
-- linked. Only ever asked for: git-sync does not make repositories otherwise.
local function make_repository()
  local document, why = taskle.links.document()
  if not document then ui.document_status = why; return end
  local dir = dir_of(document.path)
  -- Asked again: the folder may have become a repository since linking found
  -- it was not, and initializing one that is could disturb what it has staged.
  if git(dir, { "rev-parse", "--git-dir" }).code == 0 then
    ui.not_repository = nil
    ui.document_status = document.name .. " is in a git repository now; link it."
    return
  end
  local made = git(dir, { "init", "-q" })
  -- A new repository has no index file until something is staged, and a sync
  -- holds without one: an empty index is what the first commit starts from.
  if made.code == 0 and not exists(dir .. "/.git/index") then made = git(dir, { "read-tree", "--empty" }) end
  if made.code == 0 then ui.not_repository = nil end
  ui.document_status = made.code == 0 and ("Made " .. dir .. " a git repository. Choose how to sync it, then link it.")
    or ("Could not make " .. dir .. " a repository: " .. trimmed(made.stderr))
end

local function link_document()
  local repo, why = front_repository()
  if not repo then
    local document = taskle.links.document()
    ui.not_repository = document and why:find("is not in a git repository", 1, true) and document.path or nil
    ui.document_status = why .. (ui.not_repository and "; make its folder one to sync it there" or "")
    return
  end
  local action = ui.action == "commit" and "commit" or "push"
  local remote = ui.remote ~= "" and ui.remote or "origin"
  local url = ""
  if looks_like_url(remote) then
    remote, url = "", remote
  elseif git(repo.dir, { "remote", "get-url", remote }).code ~= 0 then
    if action == "push" then
      ui.document_status = "This repository has no remote named " .. remote
        .. "; enter a remote's name or a URL, or choose Commit only."
      return
    end
    -- A commit-only link keeps the remote when there is one, so choosing to
    -- push later needs no new link.
    remote = ""
  end
  local target = ui.target == "uncoupled" and "uncoupled" or "coupled"
  local branch = nil
  if target == "uncoupled" then
    branch = ui.branch
    if git(repo.dir, { "check-ref-format", "--branch", branch }).code ~= 0 then
      ui.document_status = (branch == "" and "Name" or (branch .. " is not")) .. " a branch to sync on."
      return
    end
    local where, unlisted = checked_out_in(repo.dir, "refs/heads/" .. branch)
    if unlisted then
      ui.document_status = "Could not list this repository's worktrees: " .. unlisted
      return
    end
    if where then
      ui.document_status = branch .. " is checked out in " .. where
        .. "; a separate branch must not be checked out anywhere."
      return
    end
  end
  local config = { repo = "containing", target = target, branch = branch, action = action, remote = remote,
    url = url ~= "" and url or nil, auth = "shared" }
  local made, refused = taskle.links.set {
    remote = url ~= "" and url or remote,
    label = link_label(config, repo.top),
    -- One link per file: two documents in one repository may both sync.
    match = repo.top .. ":" .. repo.rel,
  }
  if made then
    -- The document's own settings, which every run reads. The repository it
    -- is in, on the branch checked out there, pushed to `remote`, with the
    -- credential its project's documents share until the user picks another.
    record("config", config)
  end
  ui.document_status = made and (action == "commit" and ("Linked " .. repo.rel .. " to commit only.")
    or ("Linked " .. repo.rel .. " to " .. (url ~= "" and url or remote) .. ".")) or refused
end

-- The linked document's settings, with `auth` read as a known choice.
local function link_config()
  local config = recorded("config")
  if config and not AUTH_LABELS[config.auth or ""] then config.auth = "shared" end
  return config
end

local ACTIONS = { "push", "commit" }
local ACTION_LABELS = { push = "Commit and push", commit = "Commit only" }

-- The linked document's action, changed at any time: pushing needs the remote
-- the link was made with.
local function choose_action(index)
  local config = link_config()
  local action = ACTIONS[tonumber(index or "") or 0]
  if not (config and action) then return end
  if action == "push" and (config.remote or "") == "" and (config.url or "") == "" then
    ui.document_status = "This document was linked without a remote; unlink it and link it again with one to push."
    return
  end
  config.action = action
  record("config", config)
  -- A push held for review, and an approval given for it, are about pushing.
  if action == "commit" then clear_held() end
  -- The label says where the document goes, so it follows the action.
  local link, repo = taskle.links.get(), front_repository()
  if link and repo then
    taskle.links.update {
      expect = link.id,
      remote = link.remote,
      label = link_label(config, repo.top),
      match = repo.top .. ":" .. repo.rel,
    }
  end
  ui.document_status = "Action: " .. ACTION_LABELS[action] .. "."
end

local function choose_auth(index)
  local config = link_config()
  local auth = AUTHS[tonumber(index or "") or 0]
  if not (config and auth) then return end
  config.auth = auth
  record("config", config)
  ui.document_status = "Credential: " .. AUTH_LABELS[auth] .. "."
end

-- Sync Now: a run, and, when the user postponed choosing between two
-- versions, the question asked again by that run.
local function sync_now()
  local queued, why = taskle.links.sync()
  if queued then
    local resolving = decode(taskle.links.state.get("resolving"))
    if resolving and resolving.postponed then taskle.links.state.set("ask_again", "1") end
  end
  return queued, why
end

local function approve()
  local config = link_config()
  if not (config and config.action ~= "commit") then
    ui.document_status = "This document commits only; nothing is pushed."
    return
  end
  local tip, base = state.get("held_tip"), state.get("held_base")
  if not tip then ui.document_status = "Nothing is waiting to be pushed."; return end
  state.set("approved_tip", tip)
  state.set("approved_base", base)
  local queued, why = taskle.links.sync()
  ui.document_status = queued and "Pushing the approved commits…" or why
end


-- A choice between pushing and only committing, with `action` selected.
local function action_tabs(action)
  local tabs = { on_select = "action", active = action == "commit" and 2 or 1 }
  for i, each in ipairs(ACTIONS) do tabs[i] = ACTION_LABELS[each] end
  return taskle.ui.tabs(tabs)
end

-- The remote typed for the document in front: "origin" for each document until
-- the user types another for it.
local function remote_draft()
  local document = taskle.links.document()
  local path = document and document.path
  if ui.remote_for ~= path then
    ui.remote, ui.remote_for, ui.action, ui.target, ui.branch = "origin", path, "push", "coupled", "todo"
  end
  return ui.remote ~= "" and ui.remote or "origin"
end

-- What the shared credential is read and saved for now. The secret store
-- scopes it by the project of the document in front, and `taskle.workspace`
-- is fixed when the plugin loads, so the document itself stands in: the same
-- document is always the same project. Switching documents within one project
-- also starts the draft afresh, which costs only unsaved typing.
local function credential_scope()
  local document = taskle.links.document()
  return document and document.path or ""
end

-- The window is about the document it is opened over: a panel, which holds
-- that document in front until it closes. Everything in it is the document's
-- or its project's, so there is no separate settings window.
local function view()
  if ui.token_for ~= credential_scope() then ui.token, ui.token_for = "", credential_scope() end
  -- What the last actions said is about the document they were taken for.
  if ui.status_for ~= credential_scope() then
    ui.status, ui.document_status, ui.status_for = "", "", credential_scope()
  end
  local has_token = stored(TOKEN_KEY) ~= nil
  local remote = remote_draft()
  local children = {
    taskle.ui.text { "Repository", tone = "heading" },
    taskle.ui.text { "The document must already be inside a git repository; it needs a remote only to push.", tone = "dim" },
    taskle.ui.text { "A remote this repository already has, by name, or a URL used as it is. The repository's "
      .. "remotes are never changed.", tone = "dim" },
    taskle.ui.row {
      taskle.ui.text("Remote"),
      taskle.ui.text_input { id = "remote", placeholder = "origin, or a URL", value = ui.remote, on_input = "remote" },
    },
    taskle.ui.text { ui.status, tone = "accent" },
    taskle.ui.separator {},
    taskle.ui.text { "Shared credential", tone = "heading" },
    taskle.ui.text { has_token and "A credential is stored." or "No credential stored.", tone = "dim" },
    taskle.ui.text { "Used by this project's documents set to Shared. An HTTPS token, or the passphrase "
      .. "for your SSH key. Stored encrypted.", tone = "dim" },
    taskle.ui.text_input { id = "token", placeholder = "paste a token or passphrase", value = ui.token, on_input = "token" },
    taskle.ui.row {
      taskle.ui.button { "Save", on_press = ui.token ~= "" and "save-token" or nil, style = "primary" },
      taskle.ui.button { "Forget", on_press = has_token and "forget-token" or nil, style = "danger" },
    },
    taskle.ui.separator {},
    taskle.ui.text { "This document", tone = "heading" },
  }
  local function add(node) children[#children + 1] = node end
  local link = taskle.links.get()
  if link then
    if ui.document_token_for ~= link.id then ui.document_token, ui.document_token_for = "", link.id end
    add(taskle.ui.text("Linked to " .. link.label))
    local config = link_config()
    if config then
      add(taskle.ui.text("Action: " .. ACTION_LABELS[config.action == "commit" and "commit" or "push"]))
      add(action_tabs(config.action))
      local active = 1
      local labels = {}
      for i, auth in ipairs(AUTHS) do
        labels[i] = AUTH_LABELS[auth]
        if auth == config.auth then active = i end
      end
      add(taskle.ui.text("Credential: " .. AUTH_LABELS[config.auth]))
      labels.active, labels.on_select = active, "auth"
      add(taskle.ui.tabs(labels))
      if config.auth == "secret" then
        local own = stored(document_token_key(link.id)) ~= nil
        add(taskle.ui.text { own and "This document's credential is stored." or "No credential stored for this document.", tone = "dim" })
        add(taskle.ui.text_input { id = "document-token", placeholder = "paste a token or passphrase", value = ui.document_token, on_input = "document-token" })
        add(taskle.ui.row {
          taskle.ui.button { "Save for this document", on_press = ui.document_token ~= "" and "save-document-token" or nil, style = "primary" },
          taskle.ui.button { "Forget for this document", on_press = own and "forget-document-token" or nil, style = "danger" },
        })
      elseif config.auth == "agent" then
        add(taskle.ui.text { "Uses the ssh-agent Taskle was started with.", tone = "dim" })
      end
    end
    add(taskle.ui.row {
      taskle.ui.button { "Sync Now", on_press = "sync" },
      taskle.ui.button { "Unlink", on_press = "unlink", style = "danger" },
    })
    local listed = state.get("held_list")
    if listed and not (config and config.action == "commit") then
      add(taskle.ui.text { "Waiting for your approval to push:", tone = "heading" })
      for line in listed:gmatch("[^\n]+") do add(taskle.ui.text(line)) end
      add(taskle.ui.button { "Push these commits", on_press = "approve", style = "primary" })
    end
  else
    local document, why = taskle.links.document()
    add(taskle.ui.text { document and "Not linked: this document does not sync." or why, tone = "dim" })
    -- Known only once linking found out: a view cannot ask git.
    if document and ui.not_repository == document.path then
      add(taskle.ui.button { "Make this folder a repository", on_press = "init", style = "primary" })
    end
    add(action_tabs(ui.action))
    add(taskle.ui.tabs { "Checked-out branch", "Separate branch", active = ui.target == "uncoupled" and 2 or 1, on_select = "target" })
    if ui.target == "uncoupled" then
      add(taskle.ui.row {
        taskle.ui.text("Branch"),
        taskle.ui.text_input { id = "branch", placeholder = "todo", value = ui.branch, on_input = "branch" },
      })
      add(taskle.ui.text { "Committed to that branch without checking it out: the branch checked out "
        .. "here, its index and its files are left alone.", tone = "dim" })
    end
    add(taskle.ui.button {
      ui.action == "commit" and "Link, commit only" or ("Link to " .. remote),
      on_press = document and "link" or nil,
      style = "primary",
    })
  end
  add(taskle.ui.text { ui.document_status, tone = "accent" })
  children.spacing = 6
  return taskle.ui.column(children)
end

local function update_inner(_, message, value)
  if message == "remote" then
    -- Typed for the document in front, so the next one's draft starts afresh.
    local document = taskle.links.document()
    ui.remote, ui.remote_for = value or "", document and document.path
  elseif message == "token" then ui.token, ui.token_for = value or "", credential_scope()
  elseif message == "save-token" then
    if ui.token_for ~= credential_scope() or ui.token == "" then
      ui.token = ""
      return
    end
    taskle.secrets.set(TOKEN_KEY, ui.token)
    ui.token = ""
    ui.status = "Credential saved."
  elseif message == "forget-token" then
    taskle.secrets.delete(TOKEN_KEY)
    ui.status = "Credential forgotten."
  elseif message == "link" then link_document()
  elseif message == "init" then make_repository()
  elseif message == "auth" then choose_auth(value)
  elseif message == "action" then
    -- Before linking it is the draft; once linked, the link's own setting.
    if taskle.links.get() then
      choose_action(value)
    else
      -- Bound to the document in front first, so the draft is this one's.
      remote_draft()
      ui.action = ACTIONS[tonumber(value or "") or 0] or ui.action
    end
  elseif message == "target" then
    remote_draft()
    ui.target = value == "2" and "uncoupled" or "coupled"
  elseif message == "branch" then
    remote_draft()
    ui.branch = value or ""
  elseif message == "document-token" then
    local link = taskle.links.get()
    ui.document_token, ui.document_token_for = value or "", link and link.id
  elseif message == "save-document-token" then
    local link = taskle.links.get()
    if link and ui.document_token_for == link.id and ui.document_token ~= "" then
      taskle.secrets.set(document_token_key(link.id), ui.document_token)
      ui.document_token = ""
      ui.document_status = "This document's credential is saved."
    end
  elseif message == "forget-document-token" then
    local link = taskle.links.get()
    if link then
      taskle.secrets.delete(document_token_key(link.id))
      ui.document_status = "This document's credential is forgotten."
    end
  elseif message == "sync" then
    local queued, why = sync_now()
    ui.document_status = queued and "Syncing…" or why
  elseif message == "approve" then approve()
  elseif message == "unlink" then
    -- The document's own credential goes with its link: a new link is a new id.
    local link = taskle.links.get()
    local forgot, why = true, nil
    if link then forgot, why = pcall(taskle.secrets.delete, document_token_key(link.id)) end
    if not forgot then
      -- Left linked: its id is the only name the stored credential has.
      ui.document_status = "Not unlinked: this document's credential could not be forgotten ("
        .. tostring(why) .. ")."
      return
    end
    -- A URL link's upstream lives in a ref of its own, which goes with it.
    local config, repo = link_config(), front_repository()
    if link and config and (config.url or "") ~= "" and repo then
      git(repo.dir, { "update-ref", "-d", "refs/git-sync/" .. link.id .. "/upstream" })
    end
    taskle.links.clear()
    ui.document_status = "Unlinked: this document no longer syncs."
    check_unlinked()
  end
end


-- What the window did to the links — linked, unlinked, asked for a run — shows
-- in the bar as soon as it is done.
local function update(...)
  update_inner(...)
  show_links()
end

taskle.window {
  id = "git-sync",
  title = NAME,
  command = "git-sync.configure",
  settings = true,
  view = view,
  update = update,
}

taskle.menu { title = "Sync Now", command = "git-sync.now", menu = "File", submenu = "Git Sync" }
taskle.menu { title = "This Document…", command = "git-sync.configure", menu = "File", submenu = "Git Sync" }

-- Sync Now asks for a run and nothing else; all git work happens in the run.
-- When a push is waiting for approval, it also opens the window on it.
local function sync_front()
  local queued, why = sync_now()
  if not queued then return "Link this document in " .. NAME .. " first (" .. tostring(why) .. ")" end
  if taskle.links.state.get("held_tip") then taskle.run("git-sync.configure") end
  local link = taskle.links.get()
  if link then
    syncing[link.id] = true
    show_links()
  end
end

taskle.command { name = "git-sync.now", title = "Sync Now", requires = { "linked" }, fn = sync_front }

-- The item: a click syncs the document in front when it is linked here, and
-- opens the window to link it when it is not; a right-click offers both.
-- Each is a command too, for a key, the palette and a terminal, which cannot
-- click.
if taskle.supports("status_item") then
  status_item = taskle.status_item {
    id = "status",
    -- Drawn only beside a document this plugin syncs; its text still sums up
    -- every linked document, so a problem with another one shows here too.
    linked = true,
    text = "Git",
    hidden = true,
    on_click = function(ctx)
      local linked = taskle.links.get() ~= nil
      if ctx.button == "right" then
        local items = {}
        if linked then
          items[#items + 1] = { id = "sync", label = "Sync Now", detail = "the document in front" }
        end
        items[#items + 1] = { id = "document", label = "This Document…" }
        local choice = taskle.choose { prompt = NAME, items = items }
        if choice == "sync" then return sync_front() end
        if choice == "document" then taskle.run("git-sync.configure") end
        return
      end
      if linked then return sync_front() end
      taskle.run("git-sync.configure")
    end,
  }
  -- What the links say now, at load; a load with no document bound cannot
  -- read them, and the first run or the timer fills the item in instead.
  pcall(show_links)
end
