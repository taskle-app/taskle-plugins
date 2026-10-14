# gdrive-sync

Synchronizes canonical local todo.txt files with Google Drive. Each document you
link syncs with one Drive file; a document you have not linked does not sync.

The local file stays canonical. Sync uploads and downloads it; it never becomes
the place your tasks live.

## What it adds

| | |
|---|---|
| Commands | `gdrive-sync.now`, `gdrive-sync.document`, `gdrive-sync.configure` |
| Menu | File ▸ Google Drive Sync ▸ Sync Now (greyed unless the document in front is linked), This Document… |
| Windows | **Google Drive Sync**, a panel over the document in front, opened from File ▸ Google Drive Sync ▸ This Document…: this project's sign-in (Authorize), this document's link (Create Drive file, Link existing file, Sync Now, Unlink). **Google Drive Sync Settings**, a window of its own: the OAuth client id and secret |
| Observers | Linked documents only: syncs on `file_loaded`, `after_save`, `external_change`, when a document is linked, on Sync Now, and on poll (Drive is asked at most once every five minutes) |
| Status bar | **Drive** with how the worst of its linked documents stands (✓ in sync, ↻ changes not yet sent, ⏸ held, ⚠ needs you), shown beside a document this plugin links, and nowhere else. Click to sync the document in front; right-click for Sync Now, This Document… and Settings… |
| Timers | A one-second poll while an authorization is in flight; a check every minute that tells you once when nothing is linked |

## Setting it up

1. Open Help ▸ Plugins ▸ gdrive-sync and press **Configure…** (or run
   `gdrive-sync.configure`). Enter the **OAuth client ID** of a limited-input
   (device-flow) client you created, and the **client secret** if Google issued
   one, then press **Save secret**.
2. With the document open in front, choose File ▸ Google Drive Sync ▸ This
   Document… (or run `gdrive-sync.document`) and press **Authorize**. The window
   shows a code to enter on Google's device page; the plugin polls until you
   finish.
3. In the same window, link the document:
   - **Create Drive file** makes a new Drive file from it.
   - **Link existing file** lists the text files in Drive this app may open;
     pick one. If the file you want is not listed, paste its id or its Drive
     link into the field below the list and press **Link this file**.

Use the same OAuth client on every machine. The `drive.file` scope lets the
plugin open only files this client created or opened, so a file made with
another client, or in another account, cannot be linked.

Linking an existing file compares the two copies first. If they are equal, they
are in sync. If they differ, neither is adopted: you choose which to keep in the
conflict dialog.

The OAuth client is entered once: its id and secret are the same app wherever
you use it, so they are kept for every project, and the settings window says
when a secret is stored. Signing in is per project: a document in another project (or
in none) asks you to press **Authorize** for it, which lets different projects
use different Google accounts.

The tokens, the device code and the client secret go to `taskle.secrets`,
encrypted and reachable only by this plugin; the client id goes to
`taskle.state`. Which Drive file each document syncs with, and the revision
last synced, are kept by Taskle with the link.

## Which account a link belongs to

Signing in records which Google account the credentials are for, and each link
records the account it was made under. The window shows both. A file id means
something else, or nothing, in another account, so a link whose account is
not the one signed in now holds and says which account it needs. It reads
and writes nothing until you sign in to that account again, or unlink it and
link it again under the new one. A link that records no account holds the
same way: link it again.

## Sync status

Every sync ends with a status Taskle shows on the document's tab: `↑` while
local changes have not reached Drive, `⚠` with a message when sync stopped and
what to do about it. A status stays until a later sync clears it. Closing or
quitting asks while a document still has changes not on Drive; sync resumes the
next time you open it.

Beside a linked document the status bar shows **Drive** with how that
document stands: `✓` synced, `↻` syncing, `⏸` held, `⚠` stopped. Click it to
sync the document now; right-click for more. When Google asks you to sign in
again, its tooltip says so beside every document it syncs.

A sync stops, and says so, when:

- you are not signed in, or Google asks you to sign in again;
- Drive cannot be reached, or an upload or download fails (it retries on the
  next sync);
- the Drive file was deleted or moved to the trash;
- both copies changed (a **conflict**: both are kept for you to choose).
- you cancelled the conflict dialog (**held** until you press Sync Now).

## How a conflict is handled

Drive v3 documents no conditional media update, so an upload cannot be made to
fail on a stale base the way Dropbox's revisions can. This plugin therefore
**detects after writing**: it records the version it based the upload on, and if
the result is not the one it expected it preserves that as an explicit conflict
rather than pretending the write was clean. Drive's version number also moves
for changes that leave the content alone, so a moved version is only a reason
to look: the plugin compares content before calling anything a change.

**This cannot catch every concurrent edit.** An upload is three requests: check
that Drive still holds the version the local change was based on, write the new
content, then read back what Drive holds. Another program's edit that lands
between the check and the write is **silently overwritten**: the write replaces
it, the read-back finds the plugin's own content, and the sync reports success.
Only an edit that lands after the write is caught. The window is as long as
those requests take, but nothing narrows it to zero. The overwritten text may
still be in the file's version history in Drive (Manage versions), for as long
as Drive keeps it. If the same file is edited from several places at once,
prefer Dropbox, whose uploads are refused outright when the file changed.

What you answer in the conflict dialog is what the plugin acts on: Overwrite,
Take incoming, Keep both or a saved Merge… is sent to Drive as the answer
to the version you were shown. Saving while the question is open is not an
answer. **Cancel** holds sync for the document until you press Sync Now,
which asks again. If you never saw Drive's copy (Taskle stopped, or the
document was closed, before it was shown), the next sync compares again from
the version both copies last agreed on, and shows it to you rather than
uploading over it.

The conflict dialog's **Merge…** goes through the two versions change by change.
The plugin hands Taskle the Drive revision both copies last agreed on, so a
change only one side made is proposed for you and only overlapping changes ask.
It does so only when Drive still has that revision and it matches what was
recorded at the last sync; otherwise the merge asks about every difference.

## Creating a file safely

**Create Drive file** reserves a Drive file id before it uploads. If the answer
to the upload is lost (a timeout, a closed app), the next sync looks the id up:
a file that landed is adopted, one that did not is created again under the same
id. Drive refuses a second file with an id that exists, so a retry never makes a
duplicate.

**Unlink** stops further work for the document, but an upload already on its
way can still land. A file created that way stays in Drive, and **Link existing
file** lists it.

## Capabilities

`network`, `notify`, `secrets`, `timers`. Granted only after you trust the plugin.

## Tests

`tests/links.lua` runs under the host's internal test runner, from a Taskle
checkout: `cargo run -p taskle-plugin-test -- plugins/gdrive-sync`.

## Notes and limits

- One Google account.
- A link follows the local file's path. A linked file you rename or move stops
  syncing: Taskle says so on Save As.
- Sync happens around loads, saves, external changes, polls and Sync Now; there
  is no continuous watcher.
- Encryption protects a leaked file, not a compromised account.
