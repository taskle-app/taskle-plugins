# dropbox-sync

Synchronizes canonical local todo.txt files with Dropbox, using Dropbox's
conditional revisions so a concurrent edit is a detected conflict rather than a
silent overwrite. Each document you link syncs with one Dropbox path; a
document you have not linked does not sync.

The local file stays canonical. Sync uploads and downloads it; it never becomes
the place your tasks live.

## What it adds

| | |
|---|---|
| Commands | `dropbox-sync.now`, `dropbox-sync.document`, `dropbox-sync.configure` |
| Menu | File ▸ Dropbox Sync ▸ Sync Now (greyed unless the document in front is linked), This Document… |
| Windows | **Dropbox Sync**, a panel over the document in front, opened from File ▸ Dropbox Sync ▸ This Document…: this project's sign-in (Authorize, Finish authorization), this document's link (a Dropbox path and **Link**, or **Sync Now** and **Unlink**). **Dropbox Sync Settings**, a window of its own: the app key |
| Observers | Linked documents only: syncs on `file_loaded`, `after_save`, `external_change`, when a document is linked, on Sync Now, and on poll (Dropbox is asked at most once every five minutes) |
| Status bar | **Dropbox** with how the worst of its linked documents stands (✓ in sync, ↻ changes not yet sent, ⏸ held, ⚠ needs you), shown beside a document this plugin links, and nowhere else. Click to sync the document in front; right-click for Sync Now, This Document… and Settings… |
| Timer | A check every minute that tells you once when nothing is linked |

## Setting it up

1. Open Help ▸ Plugins ▸ dropbox-sync and press **Configure…** (or run
   `dropbox-sync.configure`), and enter the **app key** of a Dropbox app you
   created.
2. With the document open in front, choose File ▸ Dropbox Sync ▸ This
   Document… (or run `dropbox-sync.document`) and press **Authorize**. Dropbox
   opens in your browser and gives you a code.
3. Paste the code and press **Finish authorization**.
4. In the same window, check the path (it is suggested as
   `/Taskle/<file name>`) and press **Link**.

Linking compares both copies first. If nothing is at the path yet, the document
is uploaded there. If an equal file is there, they are in sync. If a different
one is, neither is adopted: you choose which to keep in the conflict dialog. Dropbox paths are case-insensitive, so two documents cannot be
linked to the same file under different spellings.

Authorization is PKCE, so no client secret is needed. The app key is entered
once and kept for every project. Signing in is per project: a document in
another project (or in none) asks you to authorize for it, which lets
different projects use different Dropbox accounts.

The access and refresh tokens go to `taskle.secrets`, encrypted and reachable
only by this plugin; the app key goes to `taskle.state`. Which path each
document syncs with, and the revision last synced, are kept by Taskle with the
link.

## Which account a link belongs to

Signing in records which Dropbox account the credentials are for, and each link
records the account it was made under. The window shows both. A path means
something else, or nothing, in another account, so a link whose account is
not the one signed in now holds and says which account it needs. It reads
and writes nothing until you sign in to that account again, or unlink it and
link it again under the new one. A link that records no account holds the
same way: link it again.

## Sync status

Every sync ends with a status Taskle shows on the document's tab: `↑` while
local changes have not reached Dropbox, `⚠` with a message when sync stopped and
what to do about it. A status stays until a later sync clears it. Closing or
quitting asks while a document still has changes not on Dropbox; sync resumes
the next time you open it.

Beside a linked document the status bar shows **Dropbox** with how that
document stands: `✓` synced, `↻` syncing, `⏸` held, `⚠` stopped. Click it to
sync the document now; right-click for more. When Dropbox asks you to sign in
again, its tooltip says so beside every document it syncs.

A sync stops, and says so, when you are not signed in, Dropbox cannot be
reached, a transfer fails (it retries on the next sync), the linked Dropbox
file was deleted or moved (it is never re-created on its own), both copies
changed (a **conflict**: both are kept for you to choose), or you cancelled the
conflict dialog (**held** until you press Sync Now).

## Capabilities

`network`, `notify`, `secrets`, `timers`. Granted only after you trust the plugin.

## How a conflict is handled

Each upload carries the revision the local copy was based on, and a first
upload asks Dropbox to add a new file. If the remote has moved on, or a file
appeared at the path, Dropbox refuses the write and the plugin keeps both
versions instead of choosing a winner. A save never waits on the network, and a
local file is never replaced behind your back.

What you answer in the conflict dialog is what the plugin acts on: Overwrite,
Take incoming, Keep both or a saved Merge… is sent to Dropbox as the answer
to the version you were shown. Saving while the question is open is not an
answer. **Cancel** holds sync for the document until you press Sync Now,
which asks again. If you never saw Dropbox's copy (Taskle stopped, or the
document was closed, before it was shown), the next sync compares again from
the version both copies last agreed on, and shows it to you rather than
uploading over it.

The conflict dialog's **Merge…** goes through the two versions change by change.
The plugin hands Taskle the revision both copies last agreed on, so a change
only one side made is proposed for you and only overlapping changes ask. It
does so only when Dropbox still has that revision and it matches what was
recorded at the last sync; otherwise the merge asks about every difference.

**Unlink** stops further work for the document, but an upload already on its
way can still land.

## Tests

`tests/links.lua` runs under the host's internal test runner, from a Taskle
checkout: `cargo run -p taskle-plugin-test -- plugins/dropbox-sync`.

## Notes and limits

- One Dropbox account.
- A link follows the local file's path. A linked file you rename or move stops
  syncing: Taskle says so on Save As.
- Sync happens around loads, saves, external changes, polls and Sync Now; there
  is no continuous watcher.
