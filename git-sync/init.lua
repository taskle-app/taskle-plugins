-- git-sync: keep a linked todo.txt committed and pushed with its repository.
--
-- Sync is opt-in per document: a document syncs once it is linked to a remote
-- in this plugin's window, and the host keeps that link. Every run, whatever
-- started it, works through the same steps and ends with a status the host
-- shows on the document's tab:
--
--   1. fetch the remote;
--   2. commit the saved document, if it changed, as a commit touching that one
--      file, built in a temporary index so nothing else the user staged goes
--      with it;
--   3. fast-forward, when only the remote moved and only the linked file;
--   4. when both sides have new commits, and every local one is this plugin's
--      and every incoming one changes only the linked file, replace the local
--      ones with one commit on top of the remote's: the merged text goes into
--      the document first (or, when both changed the same lines, the user
--      chooses), and a later run commits what the document then holds;
--      anything else stops (resolve in git);
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
local URL_KEY = "url"
local TOKEN_KEY = "token"
local ZERO = string.rep("0", 40)
-- A poll fires about every 30 seconds; the remote is fetched at most this often.
local POLL_SECONDS = 300
-- How many outgoing commits the approval list shows.
local MAX_LISTED = 20
-- The host tells a run how the user answered the conflict it staged; without
-- that, diverged history holds.
local FEATURE = "document.conflict_answer"

local ui = {
  status = "",
  remote = "origin",
  url = "",
  token = "",
  document_status = "",
}

local function stored(key)
  local ok, value = pcall(taskle.secrets.get, key)
  return ok and value or nil
end

-- Where the stored credential is written for the length of one git call. Kept
-- beside the store rather than in /tmp, which is world-readable on most systems.
local ASKPASS = taskle.config_dir .. "/git-sync-askpass"

-- Hand the credential to git through `GIT_ASKPASS`, which git calls and reads a
-- line from. `SSH_ASKPASS` is set from the same value so an encrypted SSH key's
-- passphrase works too; `SSH_ASKPASS_REQUIRE=force` makes ssh use it.
local function remote_env()
  local env = { GIT_TERMINAL_PROMPT = "0" }
  local token = stored(TOKEN_KEY)
  if not token or token == "" then return env end
  local ok = pcall(taskle.fs.write, ASKPASS, "#!/bin/sh\nprintf '%s\\n' \"$GIT_SYNC_SECRET\"\n")
  if not ok then return env end
  taskle.process.run { argv = { "chmod", "700", ASKPASS } }
  env.GIT_ASKPASS = ASKPASS
  env.SSH_ASKPASS = ASKPASS
  env.SSH_ASKPASS_REQUIRE = "force"
  env.GIT_SYNC_SECRET = token
  return env
end

local function dir_of(path)
  return path and path:match("^(.*)[/\\][^/\\]*$") or "."
end

local function file_name(path)
  return (path or ""):match("([^/\\]+)$") or "todo.txt"
end

-- Run git in `dir`. `options.index` names a `GIT_INDEX_FILE`, `options.env`
-- adds variables, `options.stdin` is fed to it.
local function git(dir, args, options)
  options = options or {}
  local argv = { "git", "-C", dir }
  for _, arg in ipairs(args) do argv[#argv + 1] = arg end
  local env = {}
  for key, value in pairs(options.env or {}) do env[key] = value end
  if options.index then env.GIT_INDEX_FILE = options.index end
  return taskle.process.run { argv = argv, env = env, stdin = options.stdin }
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
local function only_linked(dir, range, rel)
  local parents = git(dir, { "rev-list", "--parents", range })
  if parents.code ~= 0 then return false, trimmed(parents.stderr) end
  for line in (parents.stdout or ""):gmatch("[^\n]+") do
    local words = 0
    for _ in line:gmatch("%S+") do words = words + 1 end
    if words > 2 then return false, "it contains a merge commit" end
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
  table.sort(paths)
  lines[#lines + 1] = "Files: " .. table.concat(paths, ", ")
  local text = table.concat(lines, "\n")
  if #text > 4000 then text = text:sub(1, 3990) .. "\n…" end
  return text
end

local function hold_push(dir, up, tip, why)
  state.set("held_tip", tip)
  state.set("held_base", up)
  state.set("held_list", describe_range(dir, up .. ".." .. tip))
  return held(why .. "; review them in " .. NAME .. " and press Push these commits")
end

local function clear_held()
  state.delete("held_tip")
  state.delete("held_base")
  state.delete("held_list")
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
    local mode = tree_entry(dir, spec.parent, rel):match("^(%d+) ") or spec.expect:match("^(%d+) ") or "100644"
    local steps = {
      spec.parent and { "read-tree", spec.parent } or { "read-tree", "--empty" },
      { "update-index", "--add", "--cacheinfo", mode .. "," .. spec.blob .. "," .. rel },
    }
    for _, step in ipairs(steps) do
      local result = git(dir, step, { index = scratch })
      if result.code ~= 0 then return release(stop(failed("git " .. step[1] .. " failed: " .. trimmed(result.stderr)))) end
    end
    local tree = first_line(git(dir, { "write-tree" }, { index = scratch }))
    if not tree then return release(stop(failed("git write-tree failed"))) end
    local args = { "commit-tree", tree, "-m", "todo: sync " .. rel }
    if spec.parent then table.insert(args, 3, "-p"); table.insert(args, 4, spec.parent) end
    if first_line(git(dir, { "config", "--bool", "commit.gpgsign" })) == "true" then args[#args + 1] = "-S" end
    local made = git(dir, args)
    new = first_line(made)
    if not new then return release(stop(failed("git commit-tree failed: " .. trimmed(made.stderr)))) end
    new_entry = mode .. " " .. spec.blob .. " 0"
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

-- Finish what a `committing` record says was under way, before anything else
-- in a run. Entirely under the index lock, and with the ref read there, since
-- another Taskle process may be in the middle of the same sequence. Returns
-- nil to carry on, or the status to stop with.
local function settle(repo)
  local commit = recorded("committing")
  if not commit then return nil end
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
  local pushed = git(repo.dir, { "push", repo.remote, tip .. ":refs/heads/" .. repo.branch }, { env = remote_env() })
  if pushed.code ~= 0 then
    return false, stop(failed("Push to " .. repo.remote .. " failed: " .. trimmed(pushed.stderr)))
  end
  local chain = chain_of()
  if chain and chain.tip == tip then state.delete("chain") end
  return true
end

-- Where the repository, the linked file and its branch are, or the status to
-- stop with.
local function locate(snapshot)
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
    remote = snapshot.link.remote,
  }
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
  -- Outgoing gate: every local commit is one this plugin made.
  if not all_ours(dir, head, base) then return diverged(repo, "not every local commit is " .. NAME .. "'s") end
  -- Incoming gate: no merge, and only the linked path.
  local clean, why = only_linked(dir, head .. ".." .. up, rel)
  if not clean then return diverged(repo, "incoming: " .. why) end
  -- Repository gate.
  if not exists(repo.gitdir .. "/index") then return no_index(repo) end
  local entries = index_entries(dir, nil, rel)
  if entries ~= tree_entry(dir, head, rel) then return staged_changes(rel) end
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
  record("resolving", { ["local"] = head, up = up, theirs = raw_hash(dir, theirs.stdout or "") or "" })
  taskle.document.conflict {
    document_id = snapshot.document_id,
    token = snapshot.token,
    content = theirs.stdout or "",
    reason = NAME,
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
    elseif answer == "mine" or answer == "theirs" then
      resolving.answer = answer
      record("resolving", resolving)
    end
  end

  -- 1. Fetch.
  local fetched = git(dir, { "fetch", repo.remote }, { env = remote_env() })
  if fetched.code ~= 0 then
    return failed("Fetch from " .. repo.remote .. " failed: " .. trimmed(fetched.stderr))
  end
  local up = rev(dir, "refs/remotes/" .. repo.remote .. "/" .. repo.branch .. "^{commit}")
  if not up then
    return failed(repo.remote .. " has no branch " .. repo.branch .. "; push it once in git to start syncing")
  end

  local hashed = git(dir, { "hash-object", "-w", "--stdin", "--path=" .. rel }, { stdin = snapshot.saved_content })
  local blob = first_line(hashed)
  if not blob then return failed("git hash-object failed: " .. trimmed(hashed.stderr)) end
  local head = rev(dir, "HEAD^{commit}")
  local head_blob = head and rev(dir, head .. ":" .. rel)

  -- A replay or a conflict is acted on only against the history it was
  -- measured on; otherwise it starts over from what is here now.
  local pending = replay or resolving
  if pending and (pending["local"] ~= head or pending.up ~= up) then
    state.delete("replay")
    state.delete("resolving")
    replay, resolving = nil, nil
  end

  local committed = false
  if replay then
    state.delete("replay")
    if raw_hash(dir, snapshot.saved_content) == replay.merged and not snapshot.conflict then
      -- The document holds the merged text: commit it on top of the upstream.
      local waiting = file_is_snapshot(repo, snapshot, blob)
      if waiting then
        record("replay", replay)
        return waiting[1], waiting[2]
      end
      local new, why = advance(repo, { blob = replay.blob, parent = up, old = head, expect = tree_entry(dir, head, rel) })
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
      local spec = { parent = up, old = head, expect = tree_entry(dir, head, rel) }
      if blob == up_blob then spec.move = true else spec.blob = blob end
      local new, why = advance(repo, spec)
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
    local new, why = advance(repo, { blob = blob, parent = head, old = head, expect = tree_entry(dir, head, rel) })
    if why == "moved" then return moved_again() end
    if not new then return why[1], why[2] end
    head, head_blob = new, blob
  end
  state.delete("moved")
  local current = blob == head_blob

  local behind = tonumber(first_line(git(dir, { "rev-list", "--count", head and (head .. ".." .. up) or up })) or "0")
  local ahead = head and tonumber(first_line(git(dir, { "rev-list", "--count", up .. ".." .. head })) or "0") or 0

  -- 4. Diverged.
  if behind > 0 and ahead > 0 then
    return replay_or_hold(repo, snapshot, head, up, blob, current)
  end

  -- 3. Incoming only.
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
      local still = approved_base == up and is_ancestor(dir, approved_tip, head)
      if not still then
        return hold_push(dir, up, head, "The commits changed since you approved them; review again")
      end
      tip = approved_tip
    else
      local clean, why = only_linked(dir, up .. ".." .. head, rel)
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

-- The status the last run reported, for a poll that skips the remote.
local function last_status(link_id)
  for _, link in ipairs(taskle.links.list()) do
    if link.id == link_id and link.state then return link.state, link.message or "" end
  end
end

local function run(snapshot, event)
  -- A run with work under way is never put off: the host queues the run that
  -- finishes it, and if that run is lost a poll must not wait five minutes.
  local under_way = state.get("replay") or state.get("resolving") or state.get("committing")
  if event == "poll" and not under_way then
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
  local result, message = sync(snapshot)
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

local function check_unlinked()
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

local function link_document()
  local repo, why = front_repository()
  if not repo then ui.document_status = why; return end
  local remote = ui.remote ~= "" and ui.remote or "origin"
  if git(repo.dir, { "remote", "get-url", remote }).code ~= 0 then
    ui.document_status = "This repository has no remote named " .. remote .. "; set its URL above first."
    return
  end
  local made, refused = taskle.links.set {
    remote = remote,
    label = remote .. " @ " .. repo.top,
    -- One link per file: two documents in one repository may both sync.
    match = repo.top .. ":" .. repo.rel,
  }
  ui.document_status = made and ("Linked " .. repo.rel .. " to " .. remote .. ".") or refused
end

local function set_url()
  local repo, why = front_repository()
  if not repo then ui.status = why; return end
  taskle.secrets.set(URL_KEY, ui.url)
  local name = ui.remote ~= "" and ui.remote or "origin"
  local result = git(repo.dir, { "remote", "set-url", name, ui.url })
  if result.code ~= 0 then result = git(repo.dir, { "remote", "add", name, ui.url }) end
  ui.status = result.code == 0 and ("Remote " .. name .. " of " .. repo.top .. " → " .. ui.url)
    or ("Could not set the remote: " .. trimmed(result.stderr))
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
  local tip, base = state.get("held_tip"), state.get("held_base")
  if not tip then ui.document_status = "Nothing is waiting to be pushed."; return end
  state.set("approved_tip", tip)
  state.set("approved_base", base)
  local queued, why = taskle.links.sync()
  ui.document_status = queued and "Pushing the approved commits…" or why
end

local function described(link)
  local status = link.state and (link.state .. (link.message ~= "" and (": " .. link.message) or "")) or "not synced yet"
  if link.pending and link.state ~= "error" and link.state ~= "conflict" and link.state ~= "held" then
    status = "changes not yet pushed"
  end
  return file_name(link.path) .. " → " .. link.label
    .. (link.exists and "" or " (missing: the local file was moved or deleted)")
    .. " — " .. status
end

local function view()
  local has_token = stored(TOKEN_KEY) ~= nil
  local children = {
    taskle.ui.text { "Repository", tone = "heading" },
    taskle.ui.text { "The document must already be inside a git repository with a remote.", tone = "dim" },
    taskle.ui.row {
      taskle.ui.text("Remote"),
      taskle.ui.text_input { id = "remote", placeholder = "origin", value = ui.remote, on_input = "remote" },
    },
    taskle.ui.row {
      taskle.ui.text("Remote URL"),
      taskle.ui.text_input { id = "url", placeholder = "https://github.com/you/todo.git", value = ui.url, on_input = "url" },
    },
    taskle.ui.button { "Set remote URL", on_press = ui.url ~= "" and "set-url" or nil },
    taskle.ui.text { ui.status, tone = "accent" },
    taskle.ui.separator {},
    taskle.ui.text { "Credentials", tone = "heading" },
    taskle.ui.text { has_token and "A credential is stored." or "No credential stored.", tone = "dim" },
    taskle.ui.text { "An HTTPS token, or the passphrase for your SSH key. Stored encrypted.", tone = "dim" },
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
    add(taskle.ui.text("Linked to " .. link.label))
    add(taskle.ui.row {
      taskle.ui.button { "Sync Now", on_press = "sync" },
      taskle.ui.button { "Unlink", on_press = "unlink", style = "danger" },
    })
    local listed = state.get("held_list")
    if listed then
      add(taskle.ui.text { "Waiting for your approval to push:", tone = "heading" })
      for line in listed:gmatch("[^\n]+") do add(taskle.ui.text(line)) end
      add(taskle.ui.button { "Push these commits", on_press = "approve", style = "primary" })
    end
  else
    local document, why = taskle.links.document()
    add(taskle.ui.text { document and "Not linked: this document does not sync." or why, tone = "dim" })
    add(taskle.ui.button { "Link to " .. (ui.remote ~= "" and ui.remote or "origin"), on_press = document and "link" or nil, style = "primary" })
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
  if message == "remote" then ui.remote = value or ""
  elseif message == "url" then ui.url = value or ""
  elseif message == "token" then ui.token = value or ""
  elseif message == "set-url" then set_url()
  elseif message == "save-token" then
    taskle.secrets.set(TOKEN_KEY, ui.token)
    ui.token = ""
    ui.status = "Credential saved."
  elseif message == "forget-token" then
    taskle.secrets.delete(TOKEN_KEY)
    ui.status = "Credential forgotten."
  elseif message == "link" then link_document()
  elseif message == "sync" then
    local queued, why = sync_now()
    ui.document_status = queued and "Syncing…" or why
  elseif message == "approve" then approve()
  elseif message == "unlink" then
    taskle.links.clear()
    ui.document_status = "Unlinked: this document no longer syncs."
    check_unlinked()
  end
end

ui.url = stored(URL_KEY) or ""

taskle.window {
  id = "git-sync",
  title = NAME,
  command = "git-sync.configure",
  settings = true,
  view = view,
  update = update,
}

taskle.menu { title = "Sync Now", command = "git-sync.now", menu = "File", submenu = "Git Sync" }

-- Sync Now asks for a run and nothing else; all git work happens in the run.
-- When a push is waiting for approval, it also opens the window on it.
taskle.command {
  name = "git-sync.now",
  title = "Sync Now",
  fn = function()
    local queued, why = sync_now()
    if not queued then return "Link this document in " .. NAME .. " first (" .. tostring(why) .. ")" end
    if taskle.links.state.get("held_tip") then taskle.run("git-sync.configure") end
    return "Syncing…"
  end,
}
