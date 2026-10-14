# git-sync

Keeps a linked todo.txt committed and pushed with the git repository it lives
in. Each document you link syncs on its own; a document you have not linked
does not sync.

It commits only the linked file, and only what Taskle saved. It never
force-pushes, never stages any other file, never leaves the repository in the
middle of a merge or rebase, and pushes nothing it did not check or you did not
approve. When both this machine and the remote have new commits, it replaces
its own unpushed commits with one commit on top of the remote's (see below);
it never rewrites a commit it did not make.

## What it adds

| | |
|---|---|
| Commands | `git-sync.now`, `git-sync.configure` |
| Menu | File ▸ Git Sync ▸ Sync Now |
| Window | **Git Sync**: remote, remote URL, credentials; this document's link (**Link to origin**, or **Sync Now** and **Unlink**); outgoing commits waiting for approval with **Push these commits**; every linked document with its status |
| Observers | Linked documents only: syncs on `file_loaded`, `after_save`, `external_change`, when a document is linked, on Sync Now, and on poll (fetching at most once every five minutes) |
| Timer | A check every minute that tells you once when nothing is linked |

## Setting it up

The document has to be inside a git repository already, on a branch with an
upstream on the remote. This syncs the repository the file lives in; it does
not create one.

Open Help ▸ Plugins ▸ git-sync and press **Configure…** (or run
`git-sync.configure`), with the document open in front:

| Field | |
|---|---|
| Remote | the remote to sync with (default `origin`) |
| Remote URL | set once, if the repository has no such remote yet; it applies to the repository of the document in front |
| Credentials | an HTTPS token, or the passphrase for your SSH key |

Then press **Link to origin**. The branch checked out then is the branch the
document syncs on.

## What each sync does

Every sync, whatever started it, works through the same steps and stops at the
first one that cannot go ahead safely:

1. **Fetch** the remote.
2. **Commit** the saved document, if it changed since the last sync, as a
   commit touching only that file (`todo: sync <file>`). The commit is built in
   a temporary index from exactly what Taskle saved, through the repository's
   filters (line endings, LFS), so what you staged for other files stays
   staged and uncommitted. The branch only moves if nothing else moved it in
   the meantime. Your index is updated for that one file under git's own lock,
   so `git status` stays clean. Commit hooks are skipped; signing is honoured.
3. **Fast-forward** when only the remote has new commits and every one of them
   changes only the linked file. The file changes on disk, and Taskle reloads
   it as it would after any other program's write.
4. **Merge** when your branch and the remote both have new commits, every
   local one is a commit git-sync made and every incoming one changes only the
   linked file. The three versions of the file are merged (line endings
   handled as git would; a file under a git filter such as LFS stops instead):
   - Changes in different places merge cleanly. The merged text goes into the
     document first, and the next sync, which starts at once, commits it as
     one commit on top of the remote's and pushes it.
   - Changes to the same lines ask you which version to keep, as any
     conflict does. **Overwrite** commits your version on top of the remote's;
     **Take incoming** and **Keep both** move your branch to the remote's
     commit (Keep both also opens your version as an unsaved document). If you
     edited and saved before the sync ran, what you saved is committed instead.
     **Cancel** postpones the choice: saves stay local until you press Sync
     Now, which asks again.

   **What this costs:** git-sync's unpushed commits are replaced by the one
   commit, so each intermediate save no longer appears as a commit of its own
   (with its time) on the branch. Their content is all in the new commit, and
   the old commits stay reachable from the reflog until git expires it.

   Anything else stops: a commit you made yourself among the local ones, an
   incoming commit touching another file or a merge, a remote that deleted the
   file, or unrelated histories. Resolve those in git (merge or rebase), then
   Sync Now. On a Taskle version that cannot tell git-sync how a conflict was
   answered, diverged history always stops.
5. **Push** when only your branch has new commits and every one changes only
   the linked file. Otherwise the push waits for you: the window lists the
   commits that would be sent and the files they touch, and **Push these
   commits** sends exactly those. A commit made after you looked is not part of
   the approval, even one that changes only the linked file: it is checked by
   the next sync, as any outgoing commit is. If the remote moved the approval is
   dropped and you review again. A push is never forced.

## Sync status

Every sync ends with a status Taskle shows on the document's tab: `↑` while
saved changes are not yet pushed, `⚠` with a message when sync stopped and what
to do about it. A status stays until a later sync clears it. Closing or quitting
asks while a document still has changes not pushed; sync resumes the next time
you open it.

A sync **holds**, and says why, when you are on another branch or a detached
`HEAD`, a merge, rebase, cherry-pick, revert or bisect is in progress, you have
staged changes to the linked file yourself (a mode change or an unresolved
merge entry included), the repository has no git index (run `git reset` there),
another git command holds the index lock, incoming commits touch other files,
the histories diverged in a way it cannot merge (see step 4), you postponed
choosing between two versions, or a push needs your approval. While you have a
conflict in front of you, it reports `conflict` and does nothing else. It is an **error** when the fetch or push fails, the
branch has no upstream on the remote, or a sync was interrupted while holding
git's index lock: that lock is reported, never removed for you.

A sync interrupted anywhere (a crash, a quit, another git command) is finished
by the next one. Every commit is recorded before the branch moves, so if the
branch moved and git's index did not, the next sync repairs the index entry
for the linked file under git's lock before it pushes anything; if you staged
something else for that file meanwhile, it holds rather than overwrite it. A
merge waiting to be committed starts over if the document, your branch or the
remote changed since.

## Capabilities

`run_process` (it runs `git`), `secrets` (the credential lives in this
plugin's own encrypted namespace), `notify`, `timers`, and `write_files` (the
short-lived askpass helper). All granted only after you trust the plugin.

## Where the credential goes

Into `taskle.secrets`, which is encrypted and reachable only by this plugin;
never into the todo.txt, and never into a config file you might share. It is
handed to git through `GIT_ASKPASS` for the length of one call rather than
written into the remote URL, where it would end up in `.git/config` and in
every error message. The askpass helper is written beside the secret store
rather than in `/tmp`, which is world-readable on most systems.

## Tests

`tests/links.lua` and `tests/diverged.lua` run under the host's internal test
runner against real repositories, from a Taskle checkout:
`cargo run -p taskle-plugin-test -- plugins/git-sync`. Run them with `TMPDIR`
outside any git repository (the cases build their own) and on a filesystem
that has room for a few hundred small repositories.

## Notes and limits

- **Unlink** stops further work for the document, but a `git` command already
  running finishes: it can still commit, update the index, or push.
- A link follows the local file's path. A linked file you rename or move stops
  syncing: Taskle says so on Save As, and the window marks a link whose file is
  gone as missing.
- Diverged history is merged only when every local commit is git-sync's own;
  anything else is yours to resolve in git.
- One linked file per repository: two documents linked in the same repository
  each see the other's commits as not their own, so diverged history holds for
  both.
- Encryption protects a leaked file, not a compromised account.
