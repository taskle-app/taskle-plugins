# git-sync

Keeps a linked todo.txt in git. Each document you link syncs on its own, with
settings of its own; a document you have not linked does not sync.

Two choices decide what a sync does:

- **Where its history goes.** On the **checked-out branch** of the repository
  the file is in, as an ordinary commit of that file. Or on a **separate
  branch** that is never checked out, such as `todo`: the checked-out branch,
  the index and the other files are left alone, so a `todo.txt` untracked on
  `main` stays untracked there while its history builds up on `todo`.
- **Whether it pushes.** **Commit and push** keeps the branch in step with a
  remote. **Commit only** commits each saved change and reaches no remote,
  for a repository without one or one you do not want to push. That is
  version history, not a backup and not sync: nothing leaves the machine until
  you push it yourself.

Whatever the choices, git-sync commits only the linked file, and only what
Taskle saved. It never force-pushes, never stages another file, never leaves
a repository in the middle of a merge or rebase, never rewrites a commit it did
not make, and pushes nothing it did not check or you did not approve.

## What it adds

| | |
|---|---|
| Commands | `git-sync.now`, `git-sync.configure` |
| Menu | File ▸ Git Sync ▸ Sync Now (greyed unless the document in front is linked), This Document… |
| Window | **Git Sync**, a panel over the document in front, opened from File ▸ Git Sync ▸ This Document… or **Configure…**: the remote to push to, this project's shared credential; for the document, how to link it, or its action, credential, **Sync Now** and **Unlink**, and outgoing commits waiting for approval with **Push these commits** |
| Observers | Linked documents only: syncs on `file_loaded`, `after_save`, `external_change`, when a document is linked, on Sync Now, and on poll (fetching at most once every five minutes) |
| Status bar | **Git** with how the worst of its linked documents stands (✓ in sync, ↻ changes not yet synced, ⏸ held, ⚠ needs you), shown beside a document this plugin links, and nowhere else. Click to sync the document in front; right-click for Sync Now and This Document… |
| Timer | A check every minute that tells you once when nothing is linked |

## Setting it up

With the document in front, choose File ▸ Git Sync ▸ This Document… (or press
**Configure…** in Help ▸ Plugins ▸ git-sync, or run `git-sync.configure`), and
choose:

| Setting | |
|---|---|
| **Commit and push** / **Commit only** | whether this document pushes |
| **Checked-out branch** / **Separate branch** | where its history goes; a separate branch is named in **Branch** (`todo` by default) |
| **Remote** | where to push (default `origin`): the name of a remote this repository already has, or a URL (`https://…`, `ssh://…`, `user@host:path`, or a path) used as it is |

Then press **Link to origin** (or **Link, commit only**). The settings are the
document's own, kept with its link. With the checked-out branch, the branch
checked out at the first sync is the one the document syncs on. A separate
branch must not be checked out anywhere, and is created by the first sync if
it does not exist. Either way, a branch the remote does not have yet is
created there by the first push; one that carries commits changing other files
waits for your approval first, as any such push does.

The document has to be in a git repository. When it is not, linking says so
and offers **Make this folder a repository**, which runs `git init` in the
document's folder; from then on it is an ordinary repository of your own.
git-sync makes a repository only when asked like this.

git-sync never changes a repository's remotes or its configuration. A remote
given by name is reached at the URL the repository has for it, and its branch
is tracked as `git fetch` would track it. A URL is kept with the link: fetch
and push name it directly, and its branch is tracked in a ref of the link's
own (`refs/git-sync/<link>/upstream`), which goes when the document is
unlinked.

Once linked, the action can be changed at any time. A document linked with a
remote can switch from **Commit only** to **Commit and push**, and its next sync
pushes what it committed meanwhile; one linked without a remote has to be
linked again with one. Switching to **Commit only** drops a push waiting for
your approval, and a merge or conflict waiting on the remote. Where the
history goes is fixed for the link: unlink and link again to change it.

### Credentials

Once linked, choose how the document authenticates to its remote:

| Credential | |
|---|---|
| **Shared** (the default) | the shared credential: an HTTPS token, or the passphrase for your SSH key, saved under **Shared credential** |
| **This document** | a token or passphrase of its own, saved for this document alone; unlinking forgets it |
| **ssh-agent** | the ssh-agent Taskle was started with; nothing is stored |
| **None** | nothing: a local remote, or one git's own credential helper answers |

A key whose agent is named in `~/.ssh/config` (`IdentityAgent`) works with
**None** too, since git reads that file as it always does.

A credential goes into `taskle.secrets`, which is encrypted and reachable only
by this plugin; never into the todo.txt, and never into a config file you might
share. The shared credential is shared by the documents of one project (or by
those in no project), which is how the secret store is scoped; a document's own
is kept under its link. Either is handed to git through `GIT_ASKPASS` for the
length of one call rather than written into the remote URL, where it would end
up in `.git/config` and in every error message. The askpass helper holds no
secret: it prints the credential from its own environment, set for that one
call. It lives in this plugin's own state directory (under
`$XDG_STATE_HOME/taskle/sources/`) rather than in `/tmp`, which other users can
write to on most systems. If it cannot be prepared, the credential is not used
and the log says why.

## What each sync does

Every sync, whatever started it, works through the same steps and stops at the
first one that cannot go ahead safely. With **Commit only** it does step 2 and
nothing else, and a change counts as synced once it is committed.

1. **Fetch** the linked branch from the remote, by name.
2. **Commit** the saved document, if it changed since the last sync, as a
   commit touching only that file (`todo: sync <file>`). The commit is built in
   a temporary index from exactly what Taskle saved, through the repository's
   filters (line endings, LFS), so what you staged for other files stays
   staged and uncommitted. It is checked to change that file alone, and to hold
   exactly what was saved, before the branch moves to it, and the branch moves
   only if nothing else moved it in the meantime. On the checked-out branch your
   index is updated for that one file under git's own lock, so `git status`
   stays clean. Commit hooks are skipped; signing is honoured.
3. **Take incoming commits** when only the remote has new ones.
4. **Merge** when both your branch and the remote have new commits.
5. **Push** when only your branch has new ones. Every outgoing commit must
   change only the linked file; otherwise the push waits for you: the window
   lists the commits that would be sent and every file they change, and **Push
   these commits** sends exactly those. A commit made after you looked is not
   part of the approval: the next sync checks it as it checks any outgoing
   commit. If the remote moved, the approval is dropped and you review again.
   A push is never forced.

Steps 3 and 4 differ with where the history goes.

### On the checked-out branch

3. Incoming commits are fast-forwarded when every one of them changes only the
   linked file. The file changes on disk, and Taskle reloads it as it would
   after any other program's write.
4. Diverged history is merged when every local commit is one git-sync made and
   every incoming one changes only the linked file. The three versions of the
   file are merged (line endings handled as git would; a file under a git
   filter such as LFS stops instead):
   - Changes in different places merge cleanly. The merged text goes into the
     document first, and the next sync, which starts at once, commits it on top
     of the remote's and pushes it.
   - Changes to the same lines ask you which version to keep, as any conflict
     does. **Overwrite** commits your version on top of the remote's; **Take
     incoming** and **Keep both** move your branch to the remote's commit (Keep
     both also opens your version as an unsaved document); **Merge…** goes
     through the changes one by one, measured against the two histories' merge
     base. If you edited and saved before the sync ran, what you saved is
     committed instead. **Cancel** postpones the choice: saves stay local until
     you press Sync Now, which asks again.

   git-sync's unpushed commits are replaced by that one commit, so each
   intermediate save no longer appears as a commit of its own on the branch.
   Their content is all in the new commit, and the old commits stay reachable
   from the reflog until git expires it. Anything else stops: a commit you made
   yourself among the local ones, an incoming commit touching another file or a
   merge, a remote that deleted the file, or unrelated histories. Resolve those
   in git, then Sync Now.

### On a separate branch

3. Incoming commits reach the document the way any download does: their text is
   handed to Taskle to replace the document, and the branch moves to them once
   the document and its file hold it. They may change other files of the
   branch; only the linked file is ever written.
4. Diverged history is merged as on the checked-out branch (a clean merge goes
   into the document; the same lines changed ask you), and the result is
   recorded as a merge commit joining the two histories (`todo: merge <file>`),
   so nothing either side made is rewritten. It stops instead when local commits
   on the branch changed other files, which the merge would lose.

On another machine, where the remote has the branch and this repository does
not yet: when the document already holds the remote's copy, the branch starts
from the remote's; otherwise the sync holds and says how to take that copy
(`git show origin/todo:todo.txt`).

## Sync status

Every sync ends with a status Taskle shows on the document's tab: `↑` while
saved changes are not yet synced, `⚠` with a message when a sync stopped and
what to do about it. A status stays until a later sync clears it. Closing or
quitting asks while a document still has changes not synced; sync resumes the
next time you open it. A sync interrupted anywhere (a crash, a quit, another
git command) is finished by the next one.

A sync **holds**, and says why, when:

- on the checked-out branch: you are on another branch or a detached `HEAD`; a
  merge, rebase, cherry-pick, revert or bisect is in progress; you staged
  changes to the linked file yourself; the repository has no git index (run
  `git reset` there); another git command holds the index lock;
- on a separate branch: any worktree has the branch checked out; a rebase in
  any worktree is rewriting it; the worktrees cannot be listed; the remote has
  the branch, this repository does not, and the document differs from the
  remote's copy;
- either way: incoming commits cannot be applied, or the histories diverged in
  a way it does not merge (see step 4); the remote branch was deleted after it
  synced, which a sync does not push back; you postponed choosing between two
  versions; a push needs your approval; a link has no settings of its own,
  having been made before documents had them, and has to be linked again.

While a conflict is in front of you, it reports `conflict` and does nothing
else. It is an **error** when the fetch or push fails, or a sync was
interrupted while holding git's index lock: that lock is reported, never
removed for you.

## Capabilities

`run_process` (it runs `git`), `secrets` (the credentials, in this plugin's own
encrypted namespace), `ssh_agent` (git may use your ssh-agent for a document
set to it), `write_files` (the askpass helper), `notify` and `timers`. All
granted only after you trust the plugin.

## Tests

`tests/links.lua` and `tests/diverged.lua` run under the host's internal test
runner against real repositories, from a Taskle checkout:
`cargo run -p taskle-plugin-test -- plugins/git-sync [name filter]`. The whole
suite takes a few minutes. Run it with `TMPDIR` outside any git repository (the
cases build their own) and on a filesystem with room for a few hundred small
repositories; a run that fails keeps them, in `taskle-plugin-test-*` there.

## Notes and limits

- **Unlink** stops further work for the document, but a `git` command already
  running finishes: it can still commit, update the index, or push.
- A link follows the local file's path. A linked file you rename or move stops
  syncing: Taskle says so on Save As.
- The file has to be in a git repository, its own folder's if need be;
  git-sync keeps no repository of its own for a folder that must not or cannot
  get a `.git`.
- The project's `.taskle/config/` and `.taskle/data/` are not synced: only the
  linked file is.
- Two documents linked on the checked-out branch of one repository each see
  the other's commits as not their own, so diverged history holds for both. A
  separate branch per document avoids that.
- Encryption protects a leaked file, not a compromised account.
