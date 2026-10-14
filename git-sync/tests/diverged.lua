-- Git Sync when local and origin both have new commits: the plugin's own
-- unpushed commits replaced with one on top of origin's, and every way a run
-- can be interrupted on the way there. Against real repositories each case
-- builds, run with the host's taskle-plugin-test:
--   cargo run -p taskle-plugin-test -- plugins/git-sync

local function shell(t, command)
  local full = "cd '" .. t.dir .. "' && " .. command .. " >/dev/null 2>&1"
  if not os.execute(full) then error("setup failed: " .. command, 2) end
end

local function output(t, command)
  local pipe = io.popen("cd '" .. t.dir .. "' && " .. command .. " 2>&1")
  local text = pipe:read("*a")
  pipe:close()
  return (text:gsub("%s+$", ""))
end

local IDENTITY = "git config user.email t@example.com && git config user.name Test && git config commit.gpgsign false"

-- `work/` holds a clone of `remote.git` with `todo.txt` (holding `content`)
-- committed and pushed on `main`; `other/` is a second clone, standing for
-- another machine.
local function repository(t, content)
  t.run_for_real("git", "sh", "chmod")
  shell(t, "git init -q --bare -b main remote.git")
  shell(t, "git init -q -b main work && cd work && " .. IDENTITY)
  t.write("work/todo.txt", content)
  t.write("work/notes.md", "notes\n")
  shell(t, "cd work && git add -A && git commit -q -m start && git remote add origin ../remote.git && git push -q -u origin main")
  shell(t, "git clone -q remote.git other && cd other && " .. IDENTITY)
end

local function linked(t, content)
  repository(t, content)
  t.open("work/todo.txt", content)
  t.click("Link to origin")
  t.eq(t.link("work/todo.txt").status.state, "ok", "linked")
end

-- Commit `content` as `file` in the other clone, up to date first, and push.
local function elsewhere(t, file, content)
  shell(t, "cd other && git pull -q --ff-only origin main")
  t.write("other/" .. file, content)
  shell(t, "cd other && git add -A && git commit -q -m elsewhere && git push -q origin main")
end

-- Pushes from `work` fail while blocked; fetches still reach origin.
local function block(t) shell(t, "cd work && git config remote.origin.pushurl ../nowhere.git") end
local function unblock(t) shell(t, "cd work && git config --unset remote.origin.pushurl") end

-- Save `content`: the plugin commits it and the push is refused, leaving a
-- commit of the plugin's own not yet pushed.
local function unpushed(t, content)
  block(t)
  t.edit("work/todo.txt", content)
  t.ok(t.save())
  t.eq(t.link("work/todo.txt").status.state, "error", "the push was refused")
  unblock(t)
end

local function head(t) return output(t, "cd work && git rev-parse HEAD") end
local function upstream(t) return output(t, "git --git-dir=remote.git rev-parse main") end
local function remote_has(t, file) return output(t, "git --git-dir=remote.git show main:" .. file) end
local function link_of(t) return t.link("work/todo.txt") end
local function state_of(t) return link_of(t).state or {} end

local function encode(record)
  local keys = {}
  for key in pairs(record) do keys[#keys + 1] = key end
  table.sort(keys)
  local lines = {}
  for _, key in ipairs(keys) do lines[#lines + 1] = key .. "=" .. record[key] end
  return table.concat(lines, "\n")
end

local function decode(text)
  local record = {}
  for line in (text or ""):gmatch("[^\n]+") do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key then record[key] = value end
  end
  return record
end

-- `entry` as `git update-index --cacheinfo` takes it, without the path.
local function cacheinfo(entry)
  local mode, blob = entry:match("^(%d+) (%x+)")
  return mode .. "," .. blob
end

-- `rev`'s index entry for todo.txt, as the plugin records one.
local function entry(t, rev)
  local mode, blob = output(t, "cd work && git ls-tree " .. rev .. " todo.txt"):match("^(%d+) blob (%x+)")
  return mode .. " " .. blob .. " 0"
end

local function clean(t)
  t.eq(output(t, "cd work && git status --porcelain"), "", "git status is clean")
end

local function no_leftovers(t)
  t.eq(output(t, "ls -a work/.git | grep -c -e taskle-sync -e '^index.lock$' || true"), "0",
    "no temporary file and no lock is left")
end

-- Local has the plugin's unpushed commit changing line one, and origin a
-- commit from elsewhere changing line five.
local function diverged(t)
  linked(t, "one\ntwo\nthree\nfour\nfive\n")
  unpushed(t, "ONE\ntwo\nthree\nfour\nfive\n")
  elsewhere(t, "todo.txt", "one\ntwo\nthree\nfour\nFIVE\n")
end

-- A commit of `content` as todo.txt on `parent`, built by hand as the plugin
-- builds one; the branch is not moved. Returns the commit and its entry.
local function build(t, content, parent)
  t.write("blob.txt", content)
  local blob = output(t, "cd work && git hash-object -w --path=todo.txt ../blob.txt")
  local tree = output(t, "cd work && GIT_INDEX_FILE=.git/case.index git read-tree " .. parent
    .. " && GIT_INDEX_FILE=.git/case.index git update-index --cacheinfo 100644," .. blob .. ",todo.txt"
    .. " && GIT_INDEX_FILE=.git/case.index git write-tree && rm -f .git/case.index ../blob.txt")
  local sha = output(t, "cd work && git commit-tree " .. tree .. " -p " .. parent .. " -m 'todo: sync todo.txt'")
  return sha, "100644 " .. blob .. " 0"
end

-- ----- replaying -----

case("diverged on different lines: one commit on top of origin's, pushed", function(t)
  diverged(t)
  local folded, theirs = head(t), upstream(t)
  t.fire("sync", "work/todo.txt")
  local link = link_of(t)
  t.eq(link.status.state, "ok")
  t.eq(link.pending, false)
  t.eq(t.content("work/todo.txt"), "ONE\ntwo\nthree\nfour\nFIVE\n")
  t.eq(remote_has(t, "todo.txt"), "ONE\ntwo\nthree\nfour\nFIVE")
  t.eq(output(t, "git --git-dir=remote.git rev-parse main^"), theirs, "one commit, on origin's")
  t.eq(output(t, "git --git-dir=remote.git rev-list --merges --count main"), "0", "history is linear")
  t.eq(head(t), upstream(t))
  t.eq(output(t, "cd work && git rev-parse 'main@{1}'"), folded,
    "the run that merged moved nothing; the branch went straight from the folded commit to the new one")
  t.eq(output(t, "cd work && git branch --contains " .. folded), "", "the folded commit is off the branch")
  t.contains(t.notices(), "Updated from", "the host put the merge in the document")
  t.eq(state_of(t).chain, nil, "the push ended the chain")
  t.eq(state_of(t).replay, nil)
  clean(t)
  no_leftovers(t)
end)

case("the run that merges only asks for the document to change", function(t)
  diverged(t)
  local before_head, before_up = head(t), upstream(t)
  -- Unsaved edits: the host keeps the merge in a conflict instead of applying it.
  t.edit("work/todo.txt", "ONE\ntwo\nthree\nfour\nfive\nunsaved\n")
  t.fire("sync", "work/todo.txt")
  -- The run ended `ok`, "Merging changes from origin"; the host refused the
  -- merge it queued, so the link says what is waiting rather than `ok`.
  t.eq(link_of(t).status.state, "error")
  t.contains(link_of(t).status.message, "review the conflict")
  t.eq(t.conflict("work/todo.txt"), "ONE\ntwo\nthree\nfour\nFIVE\n", "the merged text waits for the document")
  t.eq(head(t), before_head, "nothing moved in git")
  t.eq(upstream(t), before_up)
  t.ok(state_of(t).replay, "the replay is recorded")

  -- Taking it lets the next run commit what the document now holds.
  t.ok(t.answer("theirs"))
  t.eq(link_of(t).status.state, "ok")
  t.eq(remote_has(t, "todo.txt"), "ONE\ntwo\nthree\nfour\nFIVE")
  t.eq(output(t, "git --git-dir=remote.git rev-parse main^"), before_up)
  clean(t)
end)

-- The merged text in the document, and its commit held back by a lock.
local function replay_waiting(t)
  diverged(t)
  shell(t, "touch work/.git/index.lock")
  t.fire("sync", "work/todo.txt")
  t.eq(t.content("work/todo.txt"), "ONE\ntwo\nthree\nfour\nFIVE\n")
  t.eq(link_of(t).status.state, "held")
  t.contains(link_of(t).status.message, "Another git command is running")
  t.ok(state_of(t).replay, "the replay is still recorded")
end

case("interrupted after the replay was recorded, before the replacement landed: it starts over", function(t)
  diverged(t)
  shell(t, "cd work && git fetch -q origin")
  t.link_state("replay", encode {
    ["local"] = head(t), up = upstream(t), merged = string.rep("1", 40), blob = string.rep("2", 40),
  }, "work/todo.txt")
  t.fire("sync", "work/todo.txt")
  t.eq(link_of(t).status.state, "ok")
  t.eq(remote_has(t, "todo.txt"), "ONE\ntwo\nthree\nfour\nFIVE")
  clean(t)
end)

case("interrupted after the replacement, before the commit: the next run commits and pushes", function(t)
  replay_waiting(t)
  local theirs = upstream(t)
  shell(t, "rm work/.git/index.lock")
  t.fire("sync", "work/todo.txt")
  t.eq(link_of(t).status.state, "ok")
  t.eq(remote_has(t, "todo.txt"), "ONE\ntwo\nthree\nfour\nFIVE")
  t.eq(output(t, "git --git-dir=remote.git rev-parse main^"), theirs)
  clean(t)
  no_leftovers(t)
end)

case("origin moving before the commit: merged again against the new one", function(t)
  replay_waiting(t)
  elsewhere(t, "todo.txt", "one\ntwo\nTHREE\nfour\nFIVE\n")
  local latest = upstream(t)
  shell(t, "rm work/.git/index.lock")
  t.fire("sync", "work/todo.txt")
  t.eq(link_of(t).status.state, "ok")
  t.eq(remote_has(t, "todo.txt"), "ONE\ntwo\nTHREE\nfour\nFIVE")
  t.eq(output(t, "git --git-dir=remote.git rev-parse main^"), latest, "never committed on the old upstream")
  clean(t)
end)

case("HEAD moving before the commit: a hand commit holds", function(t)
  replay_waiting(t)
  local theirs = upstream(t)
  shell(t, "rm work/.git/index.lock")
  t.write("work/notes.md", "by hand\n")
  shell(t, "cd work && git commit -q -am 'by hand'")
  t.fire("sync", "work/todo.txt")
  t.eq(link_of(t).status.state, "held")
  t.contains(link_of(t).status.message, "not every local commit is Git Sync's")
  t.eq(upstream(t), theirs, "nothing was pushed")
end)

case("after the commit, before the push: the next run pushes", function(t)
  replay_waiting(t)
  local theirs = upstream(t)
  shell(t, "rm work/.git/index.lock")
  block(t)
  t.fire("sync", "work/todo.txt")
  t.eq(link_of(t).status.state, "error")
  t.eq(output(t, "cd work && git rev-parse HEAD^"), theirs, "committed on origin's")
  unblock(t)
  t.fire("sync", "work/todo.txt")
  t.eq(link_of(t).status.state, "ok")
  t.eq(upstream(t), head(t))
end)

case("a replay waiting to commit is not held back by the poll throttle", function(t)
  replay_waiting(t)
  shell(t, "rm work/.git/index.lock")
  t.fire("poll", "work/todo.txt")
  t.eq(link_of(t).status.state, "ok")
  t.eq(remote_has(t, "todo.txt"), "ONE\ntwo\nthree\nfour\nFIVE")

  -- With nothing under way, a poll so soon after a run skips the remote.
  elsewhere(t, "todo.txt", "one\ntwo\nTHREE\nfour\nFIVE\n")
  t.fire("poll", "work/todo.txt")
  t.eq(t.content("work/todo.txt"), "ONE\ntwo\nthree\nfour\nFIVE\n")
end)

-- ----- a commit the plugin was in the middle of -----

case("a commit that landed before its record was cleared is pushed, not held", function(t)
  linked(t, "a task\n")
  local old = head(t)
  local sha, new_entry = build(t, "a task\nsaved\n", old)
  -- The ref and the index moved; the run stopped before clearing its record.
  shell(t, "cd work && git update-ref refs/heads/main " .. sha .. " " .. old
    .. " && git update-index --cacheinfo " .. cacheinfo(new_entry) .. ",todo.txt")
  t.link_state("committing", encode {
    sha = sha, parent = old, ref = "refs/heads/main", old = old,
    old_entry = entry(t, old), new_entry = new_entry,
  }, "work/todo.txt")
  t.edit("work/todo.txt", "a task\nsaved\n")
  t.ok(t.save())
  t.eq(link_of(t).status.state, "ok")
  t.eq(upstream(t), sha, "that very commit is pushed")
  t.eq(state_of(t).committing, nil)
  clean(t)
end)

case("a replay commit that landed before its record was cleared is pushed", function(t)
  diverged(t)
  shell(t, "cd work && git fetch -q origin")
  local folded, theirs = head(t), upstream(t)
  local sha, new_entry = build(t, "ONE\ntwo\nthree\nfour\nFIVE\n", theirs)
  shell(t, "cd work && git update-ref refs/heads/main " .. sha .. " " .. folded
    .. " && git update-index --cacheinfo " .. cacheinfo(new_entry) .. ",todo.txt")
  t.link_state("committing", encode {
    sha = sha, parent = theirs, ref = "refs/heads/main", old = folded,
    old_entry = entry(t, folded), new_entry = new_entry,
  }, "work/todo.txt")
  t.link_state("replay", encode { ["local"] = folded, up = theirs, merged = string.rep("1", 40), blob = string.rep("2", 40) },
    "work/todo.txt")
  t.edit("work/todo.txt", "ONE\ntwo\nthree\nfour\nFIVE\n")
  t.ok(t.save())
  t.eq(link_of(t).status.state, "ok")
  t.eq(upstream(t), sha)
  t.eq(state_of(t).replay, nil, "the replay is done")
  clean(t)
end)

-- The ref moved to a commit of "a task\nsaved\n" and the index not yet: what
-- a crash between `update-ref` and the index update leaves, record included.
local function crashed_mid_commit(t)
  linked(t, "a task\n")
  local old = head(t)
  local sha, new_entry = build(t, "a task\nsaved\n", old)
  shell(t, "cd work && git update-ref refs/heads/main " .. sha .. " " .. old)
  t.link_state("committing", encode {
    sha = sha, parent = old, ref = "refs/heads/main", old = old,
    old_entry = entry(t, old), new_entry = new_entry,
  }, "work/todo.txt")
  return sha, old
end

case("a crash between update-ref and the index update is repaired before anything is pushed", function(t)
  local sha, old = crashed_mid_commit(t)
  t.contains(output(t, "cd work && git status --porcelain"), "M  todo.txt", "a staged change undoes the commit")
  shell(t, "touch work/.git/index.lock")
  t.edit("work/todo.txt", "a task\nsaved\n")
  t.ok(t.save())
  t.eq(link_of(t).status.state, "held")
  t.contains(link_of(t).status.message, "index.lock exists")
  t.eq(upstream(t), old, "nothing is pushed")
  t.ok(state_of(t).committing, "the record is kept")

  shell(t, "rm work/.git/index.lock")
  t.fire("sync", "work/todo.txt")
  t.eq(link_of(t).status.state, "ok")
  clean(t)
  t.eq(upstream(t), sha)
  t.eq(state_of(t).committing, nil)
end)

case("after such a crash, a third version staged by the user holds until unstaged", function(t)
  local sha = crashed_mid_commit(t)
  t.edit("work/todo.txt", "a task\nsaved\n")
  shell(t, "cd work && git update-index --cacheinfo 100644,$(printf 'by hand\\n' | git hash-object -w --stdin),todo.txt")
  t.ok(t.save())
  t.eq(link_of(t).status.state, "held")
  t.contains(link_of(t).status.message, "You have staged changes to todo.txt")
  t.ok(state_of(t).committing, "the record is kept")
  t.eq(output(t, "cd work && git show :todo.txt"), "by hand", "what was staged is kept")

  shell(t, "cd work && git reset -q -- todo.txt")
  t.fire("sync", "work/todo.txt")
  t.eq(link_of(t).status.state, "ok")
  t.eq(upstream(t), sha)
  clean(t)
end)

case("after such a crash, a staged mode change holds and is kept", function(t)
  local _, old = crashed_mid_commit(t)
  shell(t, "cd work && git update-index --chmod=+x todo.txt")
  t.edit("work/todo.txt", "a task\nsaved\n")
  t.ok(t.save())
  t.eq(link_of(t).status.state, "held")
  t.contains(link_of(t).status.message, "You have staged changes to todo.txt")
  t.ok(state_of(t).committing, "the record is kept")
  t.contains(output(t, "cd work && git ls-files -s todo.txt"), "100755 ", "the staged mode is kept")
  t.eq(upstream(t), old)
end)

case("a record whose commit never landed is dropped once the other process is done", function(t)
  linked(t, "a task\n")
  local old = head(t)
  local sha, new_entry = build(t, "a task\nelsewhere\n", old)
  -- Another Taskle process recorded its commit and holds the lock.
  t.link_state("committing", encode {
    sha = sha, parent = old, ref = "refs/heads/main", old = old,
    old_entry = entry(t, old), new_entry = new_entry,
  }, "work/todo.txt")
  shell(t, "touch work/.git/index.lock")
  t.edit("work/todo.txt", "a task\nsaved\n")
  t.ok(t.save())
  t.eq(link_of(t).status.state, "held")
  t.ok(state_of(t).committing, "the record survives")

  shell(t, "rm work/.git/index.lock")
  t.fire("sync", "work/todo.txt")
  t.eq(link_of(t).status.state, "ok")
  t.eq(state_of(t).committing, nil)
  t.eq(remote_has(t, "todo.txt"), "a task\nsaved", "the save is committed and pushed")
  t.ok(output(t, "cd work && git branch --contains " .. sha) == "", "the commit that never landed stays off")
end)

case("a ref that moved while the run waited for the lock is read again under it", function(t)
  linked(t, "a task\n")
  local old = head(t)
  local sha, new_entry = build(t, "a task\nsaved\n", old)
  t.link_state("committing", encode {
    sha = sha, parent = old, ref = "refs/heads/main", old = old,
    old_entry = entry(t, old), new_entry = new_entry,
  }, "work/todo.txt")
  shell(t, "touch work/.git/index.lock")
  t.edit("work/todo.txt", "a task\nsaved\n")
  t.ok(t.save())
  t.eq(link_of(t).status.state, "held")
  -- The other process moves the ref, then lets go of the lock.
  shell(t, "cd work && git update-ref refs/heads/main " .. sha .. " " .. old .. " && rm .git/index.lock")
  t.fire("sync", "work/todo.txt")
  t.eq(link_of(t).status.state, "ok")
  t.eq(upstream(t), sha, "the commit joined the chain and was pushed")
  clean(t)
end)

case("a record over a chain already holding its commit keeps the chain, and replays", function(t)
  linked(t, "one\ntwo\nthree\nfour\nfive\n")
  local start = head(t)
  block(t)
  t.edit("work/todo.txt", "ONE\ntwo\nthree\nfour\nfive\n")
  t.ok(t.save())
  local a = head(t)
  t.edit("work/todo.txt", "ONE\ntwo\nTHREE\nfour\nfive\n")
  t.ok(t.save())
  local b = head(t)
  unblock(t)
  t.eq(decode(state_of(t).chain), { from = start, tip = b })
  elsewhere(t, "todo.txt", "one\ntwo\nthree\nfour\nFIVE\n")
  local theirs = upstream(t)
  -- Stopped after writing the chain, before deleting the record.
  t.link_state("committing", encode {
    sha = b, parent = a, ref = "refs/heads/main", old = a,
    old_entry = entry(t, a), new_entry = entry(t, b),
  }, "work/todo.txt")
  t.fire("sync", "work/todo.txt")
  t.eq(link_of(t).status.state, "ok")
  t.eq(remote_has(t, "todo.txt"), "ONE\ntwo\nTHREE\nfour\nFIVE")
  t.eq(output(t, "git --git-dir=remote.git rev-parse main^"), theirs, "both local commits folded into one")
  clean(t)
end)

-- ----- what holds -----

case("an incoming commit touching another file holds", function(t)
  linked(t, "one\ntwo\nthree\nfour\nfive\n")
  unpushed(t, "ONE\ntwo\nthree\nfour\nfive\n")
  elsewhere(t, "notes.md", "changed elsewhere\n")
  local before = head(t)
  t.fire("sync", "work/todo.txt")
  t.eq(link_of(t).status.state, "held")
  t.contains(link_of(t).status.message, "notes.md")
  t.eq(head(t), before)
  t.eq(t.content("work/todo.txt"), "ONE\ntwo\nthree\nfour\nfive\n")
end)

case("a hand commit among the local ones holds", function(t)
  linked(t, "one\ntwo\nthree\nfour\nfive\n")
  unpushed(t, "ONE\ntwo\nthree\nfour\nfive\n")
  t.write("work/notes.md", "by hand\n")
  shell(t, "cd work && git commit -q -am 'by hand'")
  elsewhere(t, "todo.txt", "one\ntwo\nthree\nfour\nFIVE\n")
  local theirs = upstream(t)
  t.fire("sync", "work/todo.txt")
  t.eq(link_of(t).status.state, "held")
  t.contains(link_of(t).status.message, "not every local commit is Git Sync's")
  t.eq(upstream(t), theirs)
end)

case("a staged change to the linked file holds, and nothing moves", function(t)
  diverged(t)
  local before = head(t)
  shell(t, "cd work && git update-index --cacheinfo 100644,$(printf 'by hand\\n' | git hash-object -w --stdin),todo.txt")
  t.fire("sync", "work/todo.txt")
  t.eq(link_of(t).status.state, "held")
  t.contains(link_of(t).status.message, "You have staged changes to todo.txt")
  t.eq(head(t), before)
  t.eq(t.content("work/todo.txt"), "ONE\ntwo\nthree\nfour\nfive\n")
  t.eq(output(t, "cd work && git show :todo.txt"), "by hand")
end)

case("a linked file changed on disk is left alone until the host reads it", function(t)
  diverged(t)
  local before, theirs = head(t), upstream(t)
  t.write("work/todo.txt", "changed on disk\n")
  t.fire("sync", "work/todo.txt")
  t.eq(link_of(t).pending, true)
  t.eq(head(t), before)
  t.eq(upstream(t), theirs)
  t.eq(t.content("work/todo.txt"), "ONE\ntwo\nthree\nfour\nfive\n")
end)

case("a text eol=crlf file merges in worktree form and commits the normalized blob", function(t)
  repository(t, "one\ntwo\nthree\n")
  t.write("work/.gitattributes", "*.txt text eol=crlf\n")
  shell(t, "cd work && git add .gitattributes && git commit -q -m attrs && rm todo.txt && git checkout -- todo.txt && git push -q")
  t.open("work/todo.txt", "one\r\ntwo\r\nthree\r\n")
  t.click("Link to origin")
  t.eq(link_of(t).status.state, "ok")
  unpushed(t, "ONE\r\ntwo\r\nthree\r\n")
  elsewhere(t, "todo.txt", "one\r\ntwo\r\nTHREE\r\n")
  t.fire("sync", "work/todo.txt")
  t.eq(link_of(t).status.state, "ok")
  t.eq(t.content("work/todo.txt"), "ONE\r\ntwo\r\nTHREE\r\n")
  t.eq(output(t, "cd work && git cat-file -p HEAD:todo.txt | od -c | grep -c '\\\\r' || true"), "0",
    "the committed blob is normalized")
  t.eq(remote_has(t, "todo.txt"), "ONE\ntwo\nTHREE")
  clean(t)
end)

case("a path under a git filter holds", function(t)
  repository(t, "one\ntwo\nthree\nfour\nfive\n")
  t.write("work/.gitattributes", "todo.txt filter=lfs\n")
  shell(t, "cd work && git add .gitattributes && git commit -q -m attrs && git push -q")
  t.open("work/todo.txt", "one\ntwo\nthree\nfour\nfive\n")
  t.click("Link to origin")
  unpushed(t, "ONE\ntwo\nthree\nfour\nfive\n")
  elsewhere(t, "todo.txt", "one\ntwo\nthree\nfour\nFIVE\n")
  local before = head(t)
  t.fire("sync", "work/todo.txt")
  t.eq(link_of(t).status.state, "held")
  t.contains(link_of(t).status.message, "todo.txt uses a git filter; resolve in git")
  t.eq(head(t), before)
end)

case("both sides adding the file merge from an empty base", function(t)
  repository(t, "a task\n")
  block(t)
  t.open("work/new.txt", "mine\n")
  t.click("Link to origin")
  t.eq(t.link("work/new.txt").status.state, "error", "the push was refused")
  unblock(t)
  elsewhere(t, "new.txt", "theirs\n")
  t.fire("sync", "work/new.txt")
  t.eq(t.link("work/new.txt").status.state, "conflict")
  t.eq(t.conflict("work/new.txt"), "theirs\n")
end)

case("origin deleting the file holds", function(t)
  linked(t, "one\ntwo\nthree\nfour\nfive\n")
  unpushed(t, "ONE\ntwo\nthree\nfour\nfive\n")
  shell(t, "cd other && git pull -q --ff-only origin main && git rm -q todo.txt && git commit -q -m gone && git push -q origin main")
  t.fire("sync", "work/todo.txt")
  t.eq(link_of(t).status.state, "held")
  t.contains(link_of(t).status.message, "origin deleted todo.txt; resolve in git")
end)

case("unrelated histories hold", function(t)
  linked(t, "one\ntwo\nthree\nfour\nfive\n")
  unpushed(t, "ONE\ntwo\nthree\nfour\nfive\n")
  shell(t, "cd other && git checkout -q --orphan fresh && git commit -q -m unrelated && git push -q -f origin fresh:main")
  t.fire("sync", "work/todo.txt")
  t.eq(link_of(t).status.state, "held")
  t.contains(link_of(t).status.message, "unrelated histories")
end)

-- ----- conflicts -----

-- Both machines changed line one; the run stages origin's version for the
-- user to choose.
local function conflicted(t)
  linked(t, "one\ntwo\nthree\nfour\nfive\n")
  unpushed(t, "MINE\ntwo\nthree\n")
  elsewhere(t, "todo.txt", "THEIRS\ntwo\nthree\n")
  t.fire("sync", "work/todo.txt")
  t.eq(link_of(t).status.state, "conflict")
  t.contains(link_of(t).status.message, "Both machines changed todo.txt; choose which to keep")
  t.eq(t.conflict("work/todo.txt"), "THEIRS\ntwo\nthree\n")
  no_leftovers(t)
end

case("a conflict waits for the user, and later runs leave it alone", function(t)
  conflicted(t)
  local before, theirs = head(t), upstream(t)
  t.fire("sync", "work/todo.txt")
  t.eq(link_of(t).status.state, "conflict")
  t.eq(head(t), before)
  t.eq(upstream(t), theirs)
end)

case("Overwrite commits the local version on top of origin's", function(t)
  conflicted(t)
  local theirs = upstream(t)
  t.eq({ t.answer("mine") }, { true })
  t.eq(link_of(t).status.state, "ok")
  t.eq(link_of(t).pending, false)
  t.eq(remote_has(t, "todo.txt"), "MINE\ntwo\nthree")
  t.eq(output(t, "git --git-dir=remote.git rev-parse main^"), theirs)
  clean(t)
  no_leftovers(t)
end)

case("a merge, three-way against the merge base, commits on top of origin's", function(t)
  conflicted(t)
  local theirs = upstream(t)
  t.eq({ t.merge({ "both" }) }, { true, "three_way" })
  t.eq(link_of(t).status.state, "ok")
  t.eq(link_of(t).pending, false)
  t.eq(remote_has(t, "todo.txt"), "MINE\nTHEIRS\ntwo\nthree")
  t.eq(output(t, "git --git-dir=remote.git rev-parse main^"), theirs)
  clean(t)
  no_leftovers(t)
end)

case("Take incoming moves the branch to origin's, with nothing to push", function(t)
  conflicted(t)
  local theirs = upstream(t)
  t.eq({ t.answer("theirs") }, { true })
  t.eq(link_of(t).status.state, "ok")
  t.eq(link_of(t).pending, false)
  t.eq(head(t), theirs)
  t.eq(upstream(t), theirs)
  t.eq(t.content("work/todo.txt"), "THEIRS\ntwo\nthree\n")
  t.eq(state_of(t).chain, nil)
  clean(t)
end)

case("Keep both moves the branch to origin's and hands the local version back", function(t)
  conflicted(t)
  local theirs = upstream(t)
  t.eq({ t.answer("keep_both") }, { true, "MINE\ntwo\nthree\n" })
  t.eq(head(t), theirs)
  t.eq(t.content("work/todo.txt"), "THEIRS\ntwo\nthree\n")
  clean(t)
end)

case("Take incoming, then an edit saved before the run: the edit is committed on origin's", function(t)
  conflicted(t)
  local theirs = upstream(t)
  -- The run the answer starts is held up, so the edit comes first.
  shell(t, "touch work/.git/index.lock")
  t.ok(t.answer("theirs"))
  t.eq(link_of(t).status.state, "held")
  t.edit("work/todo.txt", "THEIRS\ntwo\nthree\nlater\n")
  t.ok(t.save())
  shell(t, "rm work/.git/index.lock")
  t.fire("sync", "work/todo.txt")
  t.eq(link_of(t).status.state, "ok")
  t.eq(remote_has(t, "todo.txt"), "THEIRS\ntwo\nthree\nlater", "the edit is not dropped")
  t.eq(output(t, "git --git-dir=remote.git rev-parse main^"), theirs)
  clean(t)
end)

case("Cancel postpones without asking again, until Sync Now", function(t)
  conflicted(t)
  local before = head(t)
  t.eq({ t.answer("cancel") }, { true })
  t.eq(link_of(t).status.state, "held")
  t.contains(link_of(t).status.message,
    "You postponed choosing between the two versions of todo.txt; press Sync Now to choose")
  t.eq(t.conflict("work/todo.txt"), nil)

  t.edit("work/todo.txt", "MINE\ntwo\nthree\nmore\n")
  t.ok(t.save())
  t.eq(link_of(t).status.state, "held", "a save does not ask again")
  t.contains(link_of(t).status.message, "You postponed choosing")
  t.eq(t.conflict("work/todo.txt"), nil)
  t.eq(link_of(t).pending, true)
  t.eq(head(t), before, "the save stays local")

  t.command("git-sync.now")
  t.eq(link_of(t).status.state, "conflict")
  t.eq(t.conflict("work/todo.txt"), "THEIRS\ntwo\nthree\n")
end)

case("a save after the conflict was lost stages it again, never committing over origin's", function(t)
  linked(t, "one\ntwo\nthree\nfour\nfive\n")
  unpushed(t, "MINE\ntwo\nthree\n")
  elsewhere(t, "todo.txt", "THEIRS\ntwo\nthree\n")
  local theirs = upstream(t)
  shell(t, "cd work && git fetch -q origin")
  -- What a restart or a reload leaves: the record, and no conflict in the
  -- document nor any answer to it.
  t.link_state("resolving", encode { ["local"] = head(t), up = theirs, theirs = "" }, "work/todo.txt")
  t.edit("work/todo.txt", "MINE\ntwo\nthree\nmore\n")
  t.ok(t.save())
  t.eq(link_of(t).status.state, "conflict")
  t.eq(t.conflict("work/todo.txt"), "THEIRS\ntwo\nthree\n")
  t.eq(upstream(t), theirs, "nothing was committed over origin's")
end)

case("origin moving while a conflict waits starts over against the new one", function(t)
  conflicted(t)
  local before = head(t)
  elsewhere(t, "todo.txt", "THEIRS\ntwo\nthree\nlater\n")
  local latest = upstream(t)
  t.ok(t.answer("mine"))
  t.eq(link_of(t).status.state, "conflict")
  t.eq(t.conflict("work/todo.txt"), "THEIRS\ntwo\nthree\nlater\n", "asked again, against the new upstream")
  t.eq(upstream(t), latest, "nothing was committed on the old one")
  t.eq(head(t), before)
end)

-- ----- long chains -----

case("150 unpushed saves keep the chain two SHAs, and replay as one commit", function(t)
  linked(t, "first\nsecond\n")
  local start = head(t)
  block(t)
  local content = "first\nsecond\n"
  for i = 1, 150 do
    content = content .. "save " .. i .. "\n"
    t.edit("work/todo.txt", content)
    t.ok(t.save())
  end
  unblock(t)
  t.eq(output(t, "cd work && git rev-list --count origin/main..HEAD"), "150")
  t.eq(decode(state_of(t).chain), { from = start, tip = head(t) })
  elsewhere(t, "todo.txt", "FIRST\nsecond\n")
  local theirs = upstream(t)
  t.fire("sync", "work/todo.txt")
  t.eq(link_of(t).status.state, "ok")
  t.eq(output(t, "git --git-dir=remote.git rev-parse main^"), theirs, "one commit on top of origin's")
  local merged = ("FIRST\n" .. content:sub(#"first\n" + 1)):gsub("\n$", "")
  t.eq(remote_has(t, "todo.txt"), merged)
  clean(t)
end)

case("a hand commit in the middle of a long chain holds", function(t)
  linked(t, "first\nsecond\n")
  block(t)
  local content = "first\nsecond\n"
  for i = 1, 6 do
    content = content .. "save " .. i .. "\n"
    t.edit("work/todo.txt", content)
    t.ok(t.save())
    if i == 3 then
      t.write("work/notes.md", "by hand\n")
      shell(t, "cd work && git commit -q -am 'by hand'")
    end
  end
  unblock(t)
  elsewhere(t, "todo.txt", "FIRST\nsecond\n")
  local theirs = upstream(t)
  t.fire("sync", "work/todo.txt")
  t.eq(link_of(t).status.state, "held")
  t.contains(link_of(t).status.message, "not every local commit is Git Sync's")
  t.eq(upstream(t), theirs)
end)
