-- Git Sync on host links, against real repositories each case builds, run
-- with the host's taskle-plugin-test:
--   cargo run -p taskle-plugin-test -- plugins/git-sync

-- Run a shell command in the case's directory; fail the case if it fails.
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

-- The repository built and `work/todo.txt` open and linked to origin.
local function linked(t, content)
  repository(t, content or "a task\n")
  t.open("work/todo.txt", content or "a task\n")
  t.click("Link to origin")
  t.eq(t.link("work/todo.txt").status.state, "ok", "linked")
end

-- Commit `content` as `file` in the other clone and push it.
local function elsewhere(t, file, content)
  t.write("other/" .. file, content)
  shell(t, "cd other && git add -A && git commit -q -m elsewhere && git push -q origin main")
end

local function remote_has(t, file)
  return output(t, "git --git-dir=remote.git show main:" .. file)
end

case("Sync Now is refused for an unlinked document, and nothing runs", function(t)
  repository(t, "a task\n")
  t.open("work/todo.txt", "a task\n")
  local ok, said = t.command("git-sync.now")
  t.ok(not ok)
  t.contains(said, "Sync Now: this document is not linked to it")
  t.eq(#t.requests(), 0)
end)

case("a save is committed on its own and pushed", function(t)
  linked(t)
  t.edit("work/todo.txt", "a task\nanother\n")
  t.ok(t.save())
  local link = t.link("work/todo.txt")
  t.eq(link.status.state, "ok")
  t.eq(link.pending, false)
  t.eq(link.label, "git remote origin", "named without the repository's path")
  t.eq(remote_has(t, "todo.txt"), "a task\nanother")
  t.eq(output(t, "cd work && git log -1 --format=%s --name-only"), "todo: sync todo.txt\n\ntodo.txt")
  t.eq(output(t, "cd work && git status --porcelain"), "", "the index follows the commit")
  t.eq(output(t, "ls work/.git | grep -c taskle-sync || true"), "0", "no temporary index is left")
end)

case("a link can skip the repository's hooks, and runs them otherwise", function(t)
  linked(t)
  t.write("work/.git/hooks/pre-push", "#!/bin/sh\necho refused by the hook >&2\nexit 1\n")
  shell(t, "chmod +x work/.git/hooks/pre-push")
  t.edit("work/todo.txt", "a task\nanother\n")
  t.ok(t.save())
  t.eq(t.link("work/todo.txt").status.state, "error", "the hook ran and refused the push")
  t.eq(remote_has(t, "todo.txt"), "a task")

  t.window("hooks", "2")
  t.contains(t.link("work/todo.txt").state.config, "hooks=skip")
  t.ok(t.command("git-sync.now"))
  t.eq(t.link("work/todo.txt").status.state, "ok")
  t.eq(remote_has(t, "todo.txt"), "a task\nanother")
  t.eq(output(t, "cd work && git config --get core.hooksPath || true"), "", "the repository's config is untouched")
end)

case("what the user staged for other files is not committed", function(t)
  linked(t)
  t.write("work/notes.md", "changed notes\n")
  shell(t, "cd work && git add notes.md")
  t.edit("work/todo.txt", "a task\nanother\n")
  t.ok(t.save())
  t.eq(t.link("work/todo.txt").status.state, "ok")
  t.eq(output(t, "cd work && git status --porcelain"), "M  notes.md", "still staged, not committed")
  t.eq(remote_has(t, "notes.md"), "notes")
end)

case("the commit holds the saved snapshot, through the repository's filters", function(t)
  repository(t, "a task\n")
  t.write("work/.gitattributes", "*.txt text eol=lf\n")
  shell(t, "cd work && git add .gitattributes && git commit -q -m attrs && git push -q")
  t.open("work/todo.txt", "a task\r\nsecond\r\n")
  t.click("Link to origin")
  t.eq(t.link("work/todo.txt").status.state, "ok")
  t.eq(output(t, "cd work && git cat-file -p HEAD:todo.txt | od -c | grep -c '\\\\r' || true"), "0",
    "CRLF is normalized as git add would")
  t.eq(output(t, "cd work && git show HEAD:todo.txt"), "a task\nsecond")
  t.eq(output(t, "cd work && git status --porcelain"), "", "git sees the file as committed")
end)

case("a save another program wrote over is not committed until the host reads the file", function(t)
  linked(t)
  -- The save's own run is held, so its commit would happen in a later run.
  shell(t, "touch work/.git/index.lock")
  t.edit("work/todo.txt", "a task\nsaved\n")
  t.ok(t.save())
  t.eq(t.link("work/todo.txt").status.state, "held")
  shell(t, "rm work/.git/index.lock")
  local before = output(t, "cd work && git rev-parse HEAD")
  -- Another program writes the file before that run. The saved snapshot is
  -- no longer the file, so the host starts no run on it: neither version is
  -- committed until the host has read the change and the user has seen it.
  t.write("work/todo.txt", "written later by someone else\n")
  t.fire("sync", "work/todo.txt")
  t.eq(output(t, "cd work && git rev-parse HEAD"), before)
  t.eq(t.read("work/todo.txt"), "written later by someone else\n", "the file itself is not touched")
end)

case("an untracked linked file is committed", function(t)
  repository(t, "a task\n")
  t.open("work/new.txt", "fresh\n")
  t.click("Link to origin")
  t.eq(t.link("work/new.txt").status.state, "ok")
  t.eq(remote_has(t, "new.txt"), "fresh")
end)

case("staged changes to the linked file hold the run", function(t)
  linked(t)
  shell(t, "cd work && git update-index --cacheinfo 100644,$(printf 'staged by hand\\n' | git hash-object -w --stdin),todo.txt")
  t.edit("work/todo.txt", "a task\nsaved\n")
  t.ok(t.save())
  t.eq(t.link("work/todo.txt").status.state, "held")
  t.contains(t.link("work/todo.txt").status.message, "You have staged changes to todo.txt")
  t.eq(output(t, "cd work && git diff --cached --name-only"), "todo.txt", "what was staged is kept")
end)

case("a staged mode change to the linked file holds the run, and is kept", function(t)
  linked(t)
  shell(t, "cd work && git update-index --chmod=+x todo.txt")
  local before = output(t, "cd work && git rev-parse HEAD")
  t.edit("work/todo.txt", "a task\nsaved\n")
  t.ok(t.save())
  t.eq(t.link("work/todo.txt").status.state, "held")
  t.contains(t.link("work/todo.txt").status.message, "You have staged changes to todo.txt")
  t.eq(output(t, "cd work && git rev-parse HEAD"), before, "nothing is committed")
  t.contains(output(t, "cd work && git ls-files -s todo.txt"), "100755 ", "the staged mode is kept")
  t.eq(output(t, "test -e work/.git/index.lock && echo there || echo gone"), "gone")
end)

case("a repository with no index holds the run until git reset", function(t)
  repository(t, "a task\n")
  t.open("work/new.txt", "fresh\n")
  shell(t, "rm work/.git/index")
  local before = output(t, "cd work && git rev-parse HEAD")
  t.click("Link to origin")
  local link = t.link("work/new.txt")
  t.eq(link.status.state, "held")
  t.contains(link.status.message, t.dir .. "/work has no git index; run `git reset` there, then Sync Now")
  t.eq(output(t, "cd work && git rev-parse HEAD"), before, "nothing is committed")
  t.eq(output(t, "git --git-dir=remote.git rev-parse main"), before, "no ref moves")
  t.eq(output(t, "test -e work/.git/index && echo there || echo gone"), "gone", "the index is not rebuilt")

  shell(t, "cd work && git reset -q")
  t.click("Sync Now")
  t.eq(t.link("work/new.txt").status.state, "ok")
  t.eq(remote_has(t, "new.txt"), "fresh")
  t.eq(output(t, "cd work && git status --porcelain -- new.txt"), "", "git sees new.txt as committed")
end)

case("another branch holds the run", function(t)
  linked(t)
  shell(t, "cd work && git checkout -q -b side")
  t.click("Sync Now")
  t.eq(t.link("work/todo.txt").status.state, "held")
  t.contains(t.link("work/todo.txt").status.message, "On side; todo.txt is linked on main")
end)

case("a detached HEAD holds the run", function(t)
  linked(t)
  shell(t, "cd work && git checkout -q --detach")
  t.click("Sync Now")
  t.eq(t.link("work/todo.txt").status.state, "held")
  t.contains(t.link("work/todo.txt").status.message, "detached HEAD")
end)

case("a merge in progress holds the run", function(t)
  linked(t)
  shell(t, "cd work && git rev-parse HEAD > .git/MERGE_HEAD")
  t.click("Sync Now")
  t.eq(t.link("work/todo.txt").status.state, "held")
  t.contains(t.link("work/todo.txt").status.message, "MERGE_HEAD")
end)

case("a rebase in progress holds the run", function(t)
  linked(t)
  shell(t, "mkdir work/.git/rebase-merge")
  t.click("Sync Now")
  t.eq(t.link("work/todo.txt").status.state, "held")
end)

case("an existing index lock holds the run and is left alone", function(t)
  linked(t)
  shell(t, "touch work/.git/index.lock")
  t.edit("work/todo.txt", "a task\nsaved\n")
  t.ok(t.save())
  t.eq(t.link("work/todo.txt").status.state, "held")
  t.contains(t.link("work/todo.txt").status.message, "Another git command is running")
  t.eq(output(t, "test -e work/.git/index.lock && echo there"), "there")
  t.eq(t.link("work/todo.txt").pending, true)
end)

case("a lock left by a crashed run is reported, never removed", function(t)
  linked(t)
  -- What a run that died holding the lock leaves behind.
  shell(t, "touch work/.git/index.lock")
  t.link_state("lock", t.dir .. "/work/.git/index.lock", "work/todo.txt")
  t.fire("sync", "work/todo.txt")
  t.eq(t.link("work/todo.txt").status.state, "error")
  t.contains(t.link("work/todo.txt").status.message, "Remove " .. t.dir .. "/work/.git/index.lock")
  t.eq(output(t, "test -e work/.git/index.lock && echo there"), "there")

  -- Once the user removed it, the next run carries on.
  shell(t, "rm work/.git/index.lock")
  t.fire("sync", "work/todo.txt")
  t.eq(t.link("work/todo.txt").status.state, "ok")
end)

case("an incoming change to the linked file alone fast-forwards", function(t)
  linked(t)
  elsewhere(t, "todo.txt", "a task\nfrom elsewhere\n")
  t.click("Sync Now")
  t.eq(t.link("work/todo.txt").status.state, "ok")
  t.eq(t.read("work/todo.txt"), "a task\nfrom elsewhere\n")
end)

case("a fast-forward is not undone by the next run before the document reloads", function(t)
  linked(t)
  elsewhere(t, "todo.txt", "a task\nfrom elsewhere\n")
  t.click("Sync Now")
  -- The document still holds the old content until it reloads.
  t.fire("sync", "work/todo.txt")
  t.eq(t.read("work/todo.txt"), "a task\nfrom elsewhere\n")
  t.eq(remote_has(t, "todo.txt"), "a task\nfrom elsewhere")
end)

case("incoming commits touching another file are not applied", function(t)
  linked(t)
  elsewhere(t, "notes.md", "changed elsewhere\n")
  t.click("Sync Now")
  t.eq(t.link("work/todo.txt").status.state, "held")
  t.contains(t.link("work/todo.txt").status.message, "notes.md")
  t.eq(t.read("work/notes.md"), "notes\n")
end)

case("on a host that cannot report conflict answers, diverged history stops and changes nothing", function(t)
  linked(t)
  t.withhold("document.conflict_answer")
  elsewhere(t, "todo.txt", "a task\ntheirs\n")
  t.edit("work/todo.txt", "a task\nmine\n")
  t.ok(t.save())
  t.eq(t.link("work/todo.txt").status.state, "held")
  t.contains(t.link("work/todo.txt").status.message, "both have new commits")
  t.eq(remote_has(t, "todo.txt"), "a task\ntheirs")
  t.eq(t.link("work/todo.txt").pending, true)
end)

case("a push carrying another file waits for approval, then sends exactly what was approved", function(t)
  linked(t)
  t.write("work/notes.md", "local notes\n")
  shell(t, "cd work && git commit -q -am 'my notes'")
  t.edit("work/todo.txt", "a task\nsaved\n")
  t.ok(t.save())
  t.eq(t.link("work/todo.txt").status.state, "held")
  t.eq(remote_has(t, "notes.md"), "notes", "nothing was pushed")
  local shown = table.concat(t.view(), "\n")
  t.contains(shown, "my notes")
  t.contains(shown, "Files: notes.md, todo.txt")
  local approved = output(t, "cd work && git rev-parse HEAD")

  -- A commit made after the review is not part of the approval.
  t.write("work/notes.md", "later notes\n")
  shell(t, "cd work && git commit -q -am 'later'")
  t.click("Push these commits")
  t.eq(output(t, "git --git-dir=remote.git rev-parse main"), approved)
  t.eq(t.link("work/todo.txt").status.state, "held", "the later commit waits for its own review")
end)

case("an approval does not carry a commit made after it, even one to the document alone", function(t)
  linked(t)
  t.write("work/notes.md", "local notes\n")
  shell(t, "cd work && git commit -q -am 'my notes'")
  t.click("Sync Now")
  t.eq(t.link("work/todo.txt").status.state, "held")
  local approved = output(t, "cd work && git rev-parse HEAD")

  -- Made after the review, and touching only the linked file: a push of its
  -- own would be automatic, but the approval did not cover it.
  t.write("work/todo.txt", "a task\nlater\n")
  shell(t, "cd work && git commit -q -am 'later'")
  t.reload("work/todo.txt")
  t.click("Push these commits")
  t.eq(output(t, "git --git-dir=remote.git rev-parse main"), approved, "exactly the approved tip")
  t.eq(t.link("work/todo.txt").status.state, "held")
  t.contains(t.link("work/todo.txt").status.message, "checked on the next sync")
end)

case("an approval is discarded when the remote moved", function(t)
  linked(t)
  t.write("work/notes.md", "local notes\n")
  shell(t, "cd work && git commit -q -am 'my notes'")
  t.click("Sync Now")
  t.eq(t.link("work/todo.txt").status.state, "held")
  local before = output(t, "git --git-dir=remote.git rev-parse main")
  elsewhere(t, "todo.txt", "a task\ntheirs\n")
  t.click("Push these commits")
  t.eq(t.link("work/todo.txt").status.state, "held")
  t.ok(output(t, "git --git-dir=remote.git rev-parse main") ~= before, "only the other machine's push landed")
  t.eq(remote_has(t, "notes.md"), "notes")
end)

case("a branch the remote lacks is pushed only once approved, when it carries more than the file", function(t)
  repository(t, "a task\n")
  shell(t, "cd work && git checkout -q -b fresh")
  t.open("work/todo.txt", "a task\n")
  t.click("Link to origin")
  -- Its first commit also added notes.md: it is not published unasked.
  t.eq(t.link("work/todo.txt").status.state, "held")
  t.contains(t.view(), "[Push these commits]")
  t.eq(output(t, "git --git-dir=remote.git rev-parse -q --verify fresh || echo none"), "none")
end)

case("a failed fetch is an error", function(t)
  linked(t)
  shell(t, "mv remote.git gone.git")
  t.click("Sync Now")
  t.eq(t.link("work/todo.txt").status.state, "error")
  t.contains(t.link("work/todo.txt").status.message, "Fetch from origin failed")
end)

case("linking needs a remote, and a document in a repository", function(t)
  t.run_for_real("git", "sh")
  t.open("loose.txt", "a task\n")
  t.click("Link to origin")
  t.eq(t.link("loose.txt"), nil)
  t.contains(t.view(), "loose.txt is not in a git repository")
  t.contains(t.view(), "[Make this folder a repository]")
end)

case("an unlinked document runs nothing", function(t)
  repository(t, "a task\n")
  t.open("work/todo.txt", "a task\n")
  t.edit("work/todo.txt", "a task\nmore\n")
  t.ok(t.save())
  t.fire("poll")
  t.eq(#t.requests(), 0)
  t.eq(output(t, "cd work && git rev-list --count HEAD"), "1")
end)

case("Unlink stops syncing", function(t)
  linked(t)
  t.click("Unlink")
  t.edit("work/todo.txt", "a task\nmore\n")
  t.ok(t.save())
  t.eq(output(t, "cd work && git rev-list --count HEAD"), "1")
end)

case("a stored credential reaches git through a helper in the plugin's own state directory", function(t)
  repository(t, "a task\n")
  t.secret("token", "T")
  t.open("work/todo.txt", "a task\n")
  t.click("Link to origin")
  t.eq(t.link("work/todo.txt").status.state, "ok")
  local helper
  for _, request in ipairs(t.requests()) do
    if request.kind == "process" and request.argv[1] == "chmod" then helper = request.argv[3] end
  end
  t.ok(helper, "the helper was written and made executable")
  t.contains(helper, "/sources/user/git-sync/askpass")
  local file = io.open(helper)
  t.ok(file, "the helper is where git is told it is")
  t.contains(file:read("*a"), "GIT_SYNC_SECRET")
  file:close()
end)

-- ----- per-document settings -----

-- The last fetch the plugin ran: whether it carried an askpass helper, and
-- whether it asked for the ssh-agent.
local function last_fetch(t)
  local found
  for _, request in ipairs(t.requests()) do
    if request.kind == "process" and request.argv[4] == "fetch" then found = request end
  end
  t.ok(found, "a fetch ran")
  local askpass = false
  for _, name in ipairs(found.env or {}) do
    if name == "GIT_ASKPASS" then askpass = true end
  end
  return { askpass = askpass, agent = found.ssh_agent }
end

case("linking records the document's own settings", function(t)
  linked(t)
  local config = t.link("work/todo.txt").state.config
  t.contains(config, "remote=origin")
  t.contains(config, "auth=shared")
  t.contains(config, "target=coupled")
  t.contains(t.view(), "Credential: Shared")
end)

case("a link without settings holds until it is linked again", function(t)
  linked(t)
  t.link_state("config", "", "work/todo.txt")
  t.click("Sync Now")
  t.eq(t.link("work/todo.txt").status.state, "held")
  t.contains(t.link("work/todo.txt").status.message, "link it again")
end)

case("each document authenticates as its own setting says", function(t)
  repository(t, "a task\n")
  t.secret("token", "shared")
  t.open("work/todo.txt", "a task\n")
  t.click("Link to origin")
  t.eq(last_fetch(t), { askpass = true, agent = false }, "shared: the project's credential")

  t.window("auth", "2")
  t.contains(t.view(), "Credential: This document")
  t.contains(t.view(), "No credential stored for this document.")
  t.click("Sync Now")
  t.eq(last_fetch(t), { askpass = false, agent = false }, "its own, and it has none yet")
  t.window("document-token", "own")
  t.click("Save for this document")
  t.click("Sync Now")
  t.eq(last_fetch(t), { askpass = true, agent = false }, "its own, once saved")

  t.window("auth", "3")
  t.click("Sync Now")
  t.eq(last_fetch(t), { askpass = false, agent = true }, "the ssh-agent, and no helper")

  t.window("auth", "4")
  t.click("Sync Now")
  t.eq(last_fetch(t), { askpass = false, agent = false }, "nothing at all")
  t.eq(t.link("work/todo.txt").status.state, "ok", "a local remote needs none")
end)

case("the remote typed for one document is not another's", function(t)
  repository(t, "a task\n")
  t.open("work/todo.txt", "a task\n")
  t.window("remote", "upstream")
  t.contains(t.view(), "[Link to upstream]")
  t.open("work/notes.md", "notes\n")
  t.contains(t.view(), "[Link to origin]")
end)

case("a credential typed for one document is never saved for another", function(t)
  repository(t, "a task\n")
  t.open("work/todo.txt", "a task\n")
  t.click("Link to origin")
  t.window("auth", "2")
  t.window("document-token", "typed-for-todo")
  t.contains(t.view(), "typed-for-todo")

  t.open("work/notes.md", "notes\n")
  t.click("Link to origin")
  t.window("auth", "2")
  for _, line in ipairs(t.view()) do
    t.ok(line ~= "typed-for-todo", "the other document's draft is not shown here")
  end
  t.eq((pcall(t.click, "Save for this document")), false, "nothing to save for this document")
end)

case("a poll of a link without settings holds, not repeats an earlier ok", function(t)
  linked(t)
  t.link_state("config", "", "work/todo.txt")
  t.fire("poll", "work/todo.txt")
  t.eq(t.link("work/todo.txt").status.state, "held")
end)

case("a shared credential typed in one project is never saved into another's", function(t)
  t.write("project-a/.taskle/keep", "")
  t.write("project-b/.taskle/keep", "")
  t.open("project-a/todo.txt", "a task\n")
  t.window("token", "typed-in-a")
  t.contains(t.view(), "typed-in-a")

  t.open("project-b/todo.txt", "b task\n")
  for _, line in ipairs(t.view()) do
    t.ok(line ~= "typed-in-a", "project A's draft is not shown in project B")
  end
  t.eq((pcall(t.click, "Save")), false, "nothing to save for project B")
end)

-- ----- commit only -----

-- How many times the plugin asked git to reach a remote.
local function remote_calls(t)
  local n = 0
  for _, request in ipairs(t.requests()) do
    if request.kind == "process" and (request.argv[4] == "fetch" or request.argv[4] == "push") then n = n + 1 end
  end
  return n
end

-- `solo/` holds a repository with `todo.txt` committed, and no remote at all.
local function solo(t, content)
  t.run_for_real("git", "sh", "chmod")
  shell(t, "git init -q -b main solo && cd solo && " .. IDENTITY)
  t.write("solo/todo.txt", content)
  shell(t, "cd solo && git add -A && git commit -q -m start")
end

case("a repository with no remote syncs by committing only", function(t)
  solo(t, "a task\n")
  t.open("solo/todo.txt", "a task\n")
  t.window("action", "2")
  t.click("Link, commit only")
  local link = t.link("solo/todo.txt")
  t.eq(link.status.state, "ok")
  t.contains(link.state.config, "action=commit")
  t.contains(t.view(), "Action: Commit only")

  t.edit("solo/todo.txt", "a task\nanother\n")
  t.ok(t.save())
  t.eq(output(t, "cd solo && git show HEAD:todo.txt"), "a task\nanother")
  t.eq(output(t, "cd solo && git status --porcelain"), "", "committed, index in step")
  t.eq(t.link("solo/todo.txt").status.state, "ok")
  t.eq(t.link("solo/todo.txt").pending, false, "the commit is where it goes")
  t.eq(remote_calls(t), 0)
end)

case("pushing needs a remote, and says to choose commit only", function(t)
  solo(t, "a task\n")
  t.open("solo/todo.txt", "a task\n")
  t.click("Link to origin")
  t.eq(t.link("solo/todo.txt"), nil)
  t.contains(t.view(), "or choose Commit only")
end)

case("a pushing document can commit only for a while, and push what it made after", function(t)
  linked(t)
  local pushed = output(t, "git --git-dir=remote.git rev-parse main")
  t.window("action", "2")
  t.contains(t.view(), "Action: Commit only")
  local before = remote_calls(t)
  t.edit("work/todo.txt", "a task\nlocal only\n")
  t.ok(t.save())
  t.eq(output(t, "cd work && git show HEAD:todo.txt"), "a task\nlocal only")
  t.eq(output(t, "git --git-dir=remote.git rev-parse main"), pushed, "nothing pushed")
  t.eq(remote_calls(t), before, "nothing fetched either")

  t.window("action", "1")
  t.click("Sync Now")
  t.eq(output(t, "git --git-dir=remote.git rev-parse main"), output(t, "cd work && git rev-parse HEAD"))
  t.eq(t.link("work/todo.txt").status.state, "ok")
end)

case("a document linked without a remote cannot be switched to push", function(t)
  solo(t, "a task\n")
  t.open("solo/todo.txt", "a task\n")
  t.window("action", "2")
  t.click("Link, commit only")
  t.window("action", "1")
  t.contains(t.view(), "linked without a remote")
  t.contains(t.link("solo/todo.txt").state.config, "action=commit")
end)

case("committing only for a while drops a held push and its approval", function(t)
  linked(t)
  local pushed = output(t, "git --git-dir=remote.git rev-parse main")
  -- A hand-made commit to another file: its push waits for review.
  t.write("work/notes.md", "my notes\n")
  shell(t, "cd work && git commit -q -am 'my notes'")
  t.click("Sync Now")
  t.eq(t.link("work/todo.txt").status.state, "held")
  t.contains(t.view(), "[Push these commits]")

  t.window("action", "2")
  for _, line in ipairs(t.view()) do
    t.ok(line ~= "[Push these commits]", "no approval is offered while committing only")
  end
  t.eq(t.link("work/todo.txt").state.held_tip, nil)
  t.contains(t.view(), "Linked to git, commit only")
  -- The approval itself, sent as a stale window would.
  t.window("approve")
  t.contains(t.view(), "This document commits only; nothing is pushed.")
  t.click("Sync Now")
  t.eq(t.link("work/todo.txt").state.approved_tip, nil)

  -- Pushing again: the commit is reviewed afresh, not sent on an old approval.
  t.window("action", "1")
  t.click("Sync Now")
  t.eq(output(t, "git --git-dir=remote.git rev-parse main"), pushed, "nothing sent without a fresh review")
  t.eq(t.link("work/todo.txt").status.state, "held")
  t.contains(t.view(), "[Push these commits]")
  t.contains(t.view(), "Linked to git remote origin")
end)

-- ----- a separate branch -----

-- `side/` holds a repository whose `main` has a README, and `todo.txt` beside
-- it, untracked, holding `content`.
local function untracked(t, content)
  t.run_for_real("git", "sh", "chmod", "find")
  shell(t, "git init -q -b main side && cd side && " .. IDENTITY)
  t.write("side/README", "readme\n")
  shell(t, "cd side && git add README && git commit -q -m start")
  t.write("side/todo.txt", content)
end

-- `side/todo.txt` linked to commit only, on the separate branch `todo`.
local function on_todo_branch(t, content)
  untracked(t, content or "a task\n")
  t.open("side/todo.txt", content or "a task\n")
  t.window("action", "2")
  t.window("target", "2")
  t.click("Link, commit only")
  t.eq(t.link("side/todo.txt").status.state, "ok", "linked and committed")
end

case("an untracked file syncs to a separate branch, leaving the checked-out one alone", function(t)
  on_todo_branch(t)
  local main = output(t, "cd side && git rev-parse main")
  t.eq(output(t, "cd side && git show todo:todo.txt"), "a task")
  t.eq(t.link("side/todo.txt").label, "git branch todo, commit only")

  t.edit("side/todo.txt", "a task\nanother\n")
  t.ok(t.save())
  t.eq(output(t, "cd side && git show todo:todo.txt"), "a task\nanother")
  t.eq(output(t, "cd side && git rev-list --count todo"), "2")
  t.eq(output(t, "cd side && git rev-parse main"), main, "main does not move")
  t.eq(output(t, "cd side && git symbolic-ref --short HEAD"), "main")
  t.eq(output(t, "cd side && git ls-files todo.txt"), "", "the index never takes the file")
  t.eq(output(t, "cd side && git status --porcelain"), "?? todo.txt", "it stays untracked on main")
  t.eq(t.read("side/todo.txt"), "a task\nanother\n")
  t.eq(t.link("side/todo.txt").pending, false)
end)

case("a separate branch checked out in another worktree holds, and nothing moves", function(t)
  on_todo_branch(t)
  local tip = output(t, "cd side && git rev-parse todo")
  shell(t, "cd side && git worktree add -q ../elsewhere todo")
  t.edit("side/todo.txt", "a task\nanother\n")
  t.ok(t.save())
  t.eq(t.link("side/todo.txt").status.state, "held")
  t.contains(t.link("side/todo.txt").status.message, "todo is checked out in")
  t.eq(output(t, "cd side && git rev-parse todo"), tip)
end)

case("a branch checked out somewhere cannot be the separate branch", function(t)
  untracked(t, "a task\n")
  t.open("side/todo.txt", "a task\n")
  t.window("action", "2")
  t.window("target", "2")
  t.window("branch", "main")
  t.click("Link, commit only")
  t.eq(t.link("side/todo.txt"), nil)
  t.contains(t.view(), "main is checked out in")
end)

case("a separate branch's commit interrupted before the ref moved is made again", function(t)
  on_todo_branch(t)
  local tip = output(t, "cd side && git rev-parse todo")
  -- What a run that stopped before update-ref leaves: a record, and the ref
  -- where it was.
  t.link_state("committing", "kind=ref\nold=" .. tip .. "\nparent=" .. tip
    .. "\nref=refs/heads/todo\nsha=" .. string.rep("1", 40), "side/todo.txt")
  t.edit("side/todo.txt", "a task\nagain\n")
  t.ok(t.save())
  t.eq(t.link("side/todo.txt").state.committing, nil)
  t.eq(output(t, "cd side && git show todo:todo.txt"), "a task\nagain")
  t.eq(output(t, "cd side && git rev-parse todo~1"), tip)
end)

case("a separate branch's commit interrupted after the ref moved is finished", function(t)
  on_todo_branch(t)
  local before = output(t, "cd side && git rev-parse todo")
  t.edit("side/todo.txt", "a task\nmore\n")
  t.ok(t.save())
  local landed = output(t, "cd side && git rev-parse todo")
  -- What a run that stopped after update-ref leaves: the record still there.
  t.link_state("committing", "kind=ref\nold=" .. before .. "\nparent=" .. before
    .. "\nref=refs/heads/todo\nsha=" .. landed, "side/todo.txt")
  t.click("Sync Now")
  t.eq(t.link("side/todo.txt").state.committing, nil)
  t.eq(output(t, "cd side && git rev-parse todo"), landed, "nothing is committed twice")
  t.eq(t.link("side/todo.txt").status.state, "ok")
end)

case("a rebase of the separate branch in another worktree holds, and nothing moves", function(t)
  on_todo_branch(t)
  local tip = output(t, "cd side && git rev-parse todo")
  -- In a linked worktree, a branch whose todo.txt clashes with todo's, and a
  -- rebase of todo onto it that stops on the conflict: HEAD is detached there,
  -- and only that worktree's own git directory names the branch.
  shell(t, "cd side && git worktree add -q --detach ../elsewhere main")
  t.write("elsewhere/todo.txt", "clashing\n")
  shell(t, "cd elsewhere && git checkout -q -b other && git add todo.txt && git commit -q -m clash")
  shell(t, "cd elsewhere && (git rebase -q other todo || true)")
  t.contains(output(t, "cd side && git worktree list --porcelain"), "detached")

  t.edit("side/todo.txt", "a task\nanother\n")
  t.ok(t.save())
  t.eq(t.link("side/todo.txt").status.state, "held")
  t.contains(t.link("side/todo.txt").status.message, "A rebase of todo is in progress")
  t.eq(output(t, "cd side && git rev-parse todo"), tip)
end)

case("the checked-out path's cleanup leaves a separate branch's temporary index alone", function(t)
  linked(t)
  -- A separate-branch run's temporary index, in use in the same repository.
  local gitdir = output(t, "cd work && git rev-parse --absolute-git-dir")
  local scratch = gitdir .. "/taskle-ref-inuse.index"
  local file = io.open(scratch, "w")
  file:write("in use")
  file:close()
  t.edit("work/todo.txt", "a task\nmore\n")
  t.ok(t.save())
  t.eq(output(t, "cd work && git show HEAD:todo.txt"), "a task\nmore", "the checked-out path committed")
  t.ok(io.open(scratch), "and left the other path's file where it was")
end)

-- ----- a separate branch, pushed -----

-- `remote.git`, and `work/` cloned from it with `main` holding a README and
-- `todo.txt` untracked beside it, holding `content`; `other/` is a second
-- clone, standing for another machine.
local function separate_remote(t, content)
  t.run_for_real("git", "sh", "chmod", "find")
  shell(t, "git init -q --bare -b main remote.git")
  shell(t, "git init -q -b main work && cd work && " .. IDENTITY)
  t.write("work/README", "readme\n")
  shell(t, "cd work && git add README && git commit -q -m start && git remote add origin ../remote.git && git push -q -u origin main")
  t.write("work/todo.txt", content)
  shell(t, "git clone -q remote.git other && cd other && " .. IDENTITY)
end

-- `work/todo.txt` linked, pushing, on the separate branch `todo`.
local function pushing_todo_branch(t, content)
  separate_remote(t, content or "a task\n")
  t.open("work/todo.txt", content or "a task\n")
  t.window("target", "2")
  t.click("Link to origin")
end

-- Commit `content` as todo.txt on `todo` in `other/` and push it, as another
-- machine would.
local function elsewhere_on_todo(t, content, extra)
  shell(t, "cd other && git fetch -q && git checkout -q todo")
  t.write("other/todo.txt", content)
  if extra then t.write("other/" .. extra, "from elsewhere\n") end
  shell(t, "cd other && git add -A && git commit -q -m elsewhere && git push -q origin todo")
end

case("a separate branch's first sync creates it on the remote", function(t)
  pushing_todo_branch(t)
  t.eq(t.link("work/todo.txt").status.state, "ok")
  t.eq(t.link("work/todo.txt").pending, false)
  t.eq(output(t, "git --git-dir=remote.git show todo:todo.txt"), "a task")
  t.eq(output(t, "git --git-dir=remote.git rev-parse todo"), output(t, "cd work && git rev-parse todo"))
  t.eq(output(t, "cd work && git status --porcelain"), "?? todo.txt", "main and its index are untouched")
end)

case("a saved change on a separate branch is pushed", function(t)
  pushing_todo_branch(t)
  t.edit("work/todo.txt", "a task\nanother\n")
  t.ok(t.save())
  t.eq(output(t, "git --git-dir=remote.git show todo:todo.txt"), "a task\nanother")
  t.eq(t.link("work/todo.txt").status.state, "ok")
end)

case("an incoming change reaches the document, then the separate branch", function(t)
  pushing_todo_branch(t)
  elsewhere_on_todo(t, "a task\nfrom elsewhere\n")
  t.click("Sync Now")
  t.eq(t.content("work/todo.txt"), "a task\nfrom elsewhere\n")
  t.eq(t.read("work/todo.txt"), "a task\nfrom elsewhere\n")
  t.eq(output(t, "cd work && git rev-parse todo"), output(t, "git --git-dir=remote.git rev-parse todo"))
  t.eq(t.link("work/todo.txt").state.adopt, nil)
  t.eq(t.link("work/todo.txt").status.state, "ok")
  t.eq(t.link("work/todo.txt").pending, false)
end)

case("incoming commits that change other files of the separate branch still apply", function(t)
  pushing_todo_branch(t)
  elsewhere_on_todo(t, "a task\nfrom elsewhere\n", "notes.md")
  t.click("Sync Now")
  t.eq(t.content("work/todo.txt"), "a task\nfrom elsewhere\n")
  t.eq(output(t, "cd work && git rev-parse todo"), output(t, "git --git-dir=remote.git rev-parse todo"))
  t.eq(t.read("work/notes.md"), nil, "only the linked file is ever written")
end)

-- `remote.git` with a `todo` branch another machine started, holding `theirs`.
local function remote_started_todo(t, theirs)
  separate_remote(t, "placeholder\n")
  shell(t, "cd other && git checkout -q --orphan todo && git rm -rq --cached . && rm -f README")
  t.write("other/todo.txt", theirs)
  shell(t, "cd other && git add todo.txt && git commit -q -m todo && git push -q origin todo")
end

case("a separate branch only the remote has is started from when the document matches it", function(t)
  remote_started_todo(t, "theirs\n")
  t.write("work/todo.txt", "theirs\n")
  t.open("work/todo.txt", "theirs\n")
  t.window("target", "2")
  t.click("Link to origin")
  t.eq(t.link("work/todo.txt").status.state, "ok")
  t.eq(output(t, "cd work && git rev-parse todo"), output(t, "git --git-dir=remote.git rev-parse todo"))
end)

case("a separate branch only the remote has holds, saying how to start from it, when the document differs", function(t)
  remote_started_todo(t, "theirs\n")
  t.open("work/todo.txt", "mine\n")
  t.window("target", "2")
  t.click("Link to origin")
  t.eq(t.link("work/todo.txt").status.state, "held")
  t.contains(t.link("work/todo.txt").status.message, "git show origin/todo:todo.txt")
  t.eq(output(t, "cd work && git rev-parse -q --verify todo || echo none"), "none")
  t.eq(output(t, "git --git-dir=remote.git show todo:todo.txt"), "theirs", "nothing pushed over it")
end)

case("a separate branch deleted on the remote holds, and is not pushed back", function(t)
  pushing_todo_branch(t)
  shell(t, "cd other && git push -q origin --delete todo")
  t.edit("work/todo.txt", "a task\nmore\n")
  t.ok(t.save())
  t.eq(t.link("work/todo.txt").status.state, "held")
  t.contains(t.link("work/todo.txt").status.message, "origin no longer has todo")
  t.eq(t.link("work/todo.txt").pending, true)
  t.eq(output(t, "git --git-dir=remote.git rev-parse -q --verify todo || echo gone"), "gone")
end)

case("both sides changing a separate branch in different places are merged with a merge commit", function(t)
  pushing_todo_branch(t, "one\ntwo\nthree\n")
  elsewhere_on_todo(t, "ONE\ntwo\nthree\n")
  local theirs = output(t, "git --git-dir=remote.git rev-parse todo")
  t.edit("work/todo.txt", "one\ntwo\nTHREE\n")
  t.ok(t.save())
  t.eq(t.content("work/todo.txt"), "ONE\ntwo\nTHREE\n")
  t.eq(output(t, "git --git-dir=remote.git show todo:todo.txt"), "ONE\ntwo\nTHREE")
  t.eq(output(t, "cd work && git rev-parse todo"), output(t, "git --git-dir=remote.git rev-parse todo"))
  t.eq(output(t, "cd work && git rev-list --parents -n 1 todo | wc -w | tr -d ' '"), "3", "a merge commit")
  t.eq(output(t, "cd work && git merge-base --is-ancestor " .. theirs .. " todo && echo kept"), "kept",
    "the remote's history is kept, not replaced")
  t.eq(t.link("work/todo.txt").status.state, "ok")
end)

case("both sides changing the same line of a separate branch ask, and the answer is merged", function(t)
  pushing_todo_branch(t, "one\ntwo\n")
  elsewhere_on_todo(t, "THEIRS\ntwo\n")
  t.edit("work/todo.txt", "MINE\ntwo\n")
  t.ok(t.save())
  t.eq(t.link("work/todo.txt").status.state, "conflict")
  t.eq(t.conflict("work/todo.txt"), "THEIRS\ntwo\n")
  t.ok(t.answer("mine", "work/todo.txt"))
  t.eq(output(t, "git --git-dir=remote.git show todo:todo.txt"), "MINE\ntwo")
  t.eq(output(t, "cd work && git rev-list --parents -n 1 todo | wc -w | tr -d ' '"), "3", "a merge commit")
  t.eq(t.link("work/todo.txt").status.state, "ok")
end)

case("a merge made by hand on a separate branch that brings in another file waits for approval", function(t)
  pushing_todo_branch(t)
  local pushed = output(t, "git --git-dir=remote.git rev-parse todo")
  -- In a scratch worktree, a merge into todo whose side branch changes only
  -- todo.txt, but whose merge commit itself adds notes.md. The worktree is gone
  -- again before the sync, so todo is checked out nowhere.
  shell(t, "cd work && git worktree add -q ../hand todo")
  t.write("hand/todo.txt", "a task\nfrom the side\n")
  shell(t, "cd hand && git checkout -q -b side && git commit -q -am side && git checkout -q todo")
  shell(t, "cd hand && git merge -q --no-ff --no-commit side")
  t.write("hand/notes.md", "slipped in\n")
  shell(t, "cd hand && git add notes.md && git commit -q --no-edit")
  shell(t, "cd work && git worktree remove --force ../hand")
  t.click("Sync Now")
  t.eq(t.link("work/todo.txt").status.state, "held")
  t.contains(t.view(), "[Push these commits]")
  t.contains(t.view(), "Files: notes.md, todo.txt", "the merge's own change is shown before approving")
  t.eq(output(t, "git --git-dir=remote.git rev-parse todo"), pushed, "nothing pushed without review")
end)

-- ----- a remote by URL -----

case("a remote given by URL is used as it is, and the repository's remotes are left alone", function(t)
  separate_remote(t, "a task\n")
  local remotes = output(t, "cd work && git remote -v")
  local config = output(t, "cd work && cat .git/config")
  local url = t.dir .. "/remote.git"
  t.open("work/todo.txt", "a task\n")
  t.window("target", "2")
  t.window("remote", url)
  t.click("Link to " .. url)
  t.eq(t.link("work/todo.txt").status.state, "ok")
  t.eq(output(t, "git --git-dir=remote.git show todo:todo.txt"), "a task")
  t.contains(t.link("work/todo.txt").state.config, "url=" .. url)

  -- Incoming, through the link's own ref.
  elsewhere_on_todo(t, "a task\nfrom elsewhere\n")
  t.click("Sync Now")
  t.eq(t.content("work/todo.txt"), "a task\nfrom elsewhere\n")
  t.eq(output(t, "cd work && git remote -v"), remotes, "no remote was added")
  t.eq(output(t, "cd work && cat .git/config"), config, "the configuration is untouched")
  t.eq(output(t, "cd work && git for-each-ref --format='%(refname)' refs/remotes/origin/todo"), "",
    "and so are the remote-tracking branches")

  t.click("Unlink")
  t.eq(output(t, "cd work && git for-each-ref --format='%(refname)' refs/git-sync"), "", "its ref goes with it")
end)

case("a name that is neither a remote here nor a URL is refused", function(t)
  separate_remote(t, "a task\n")
  t.open("work/todo.txt", "a task\n")
  t.window("remote", "upstream")
  t.click("Link to upstream")
  t.eq(t.link("work/todo.txt"), nil)
  t.contains(t.view(), "no remote named upstream; enter a remote's name or a URL")
end)

-- ----- making a folder a repository -----

case("a folder made a repository syncs by committing only", function(t)
  t.run_for_real("git", "sh", "chmod", "find")
  t.open("notes/todo.txt", "a task\n")
  t.window("action", "2")
  t.click("Link, commit only")
  t.contains(t.view(), "todo.txt is not in a git repository; make its folder one")
  t.click("Make this folder a repository")
  t.contains(t.view(), "a git repository. Choose how to sync it")
  shell(t, "cd notes && " .. IDENTITY)
  t.click("Link, commit only")
  t.eq(t.link("notes/todo.txt").status.state, "ok")
  t.eq(output(t, "cd notes && git show HEAD:todo.txt"), "a task")
  t.eq(output(t, "cd notes && git status --porcelain"), "", "tracked, and the index in step")
  t.edit("notes/todo.txt", "a task\nanother\n")
  t.ok(t.save())
  t.eq(output(t, "cd notes && git rev-list --count HEAD"), "2")
end)

case("a folder made a repository pushes to a remote given by URL, creating its branch there", function(t)
  t.run_for_real("git", "sh", "chmod", "find")
  shell(t, "git init -q --bare -b main remote.git")
  t.open("notes/todo.txt", "a task\n")
  local url = t.dir .. "/remote.git"
  t.window("remote", url)
  t.click("Link to " .. url)
  t.click("Make this folder a repository")
  shell(t, "cd notes && " .. IDENTITY .. " && git symbolic-ref HEAD refs/heads/main")
  t.click("Link to " .. url)
  t.eq(t.link("notes/todo.txt").status.state, "ok")
  t.eq(output(t, "git --git-dir=remote.git show main:todo.txt"), "a task")
end)

case("a folder that became a repository meanwhile is left as it is", function(t)
  t.run_for_real("git", "sh", "chmod", "find")
  t.open("notes/todo.txt", "a task\n")
  t.window("action", "2")
  t.click("Link, commit only")
  t.contains(t.view(), "[Make this folder a repository]")
  -- Made a repository outside Taskle, with something staged, before the press.
  t.write("notes/staged.md", "staged\n")
  shell(t, "cd notes && git init -q && git add staged.md")
  t.click("Make this folder a repository")
  t.contains(t.view(), "is in a git repository now; link it")
  t.eq(output(t, "cd notes && git diff --cached --name-only"), "staged.md", "what was staged stays staged")
end)
