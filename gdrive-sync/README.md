# gdrive-sync

Synchronizes canonical local todo.txt files with Google Drive. Each document you
link syncs with one Drive file; a document you have not linked does not sync.

The local file stays canonical. Sync uploads and downloads it; it never becomes
the place your tasks live.

## What it adds

| | |
|---|---|
| Command | `gdrive-sync.configure` |
| Window | **Google Drive Sync**: the account (OAuth client id and secret, Authorize), this document's link (Create Drive file, Link existing file, Sync Now, Unlink), and every linked document with its status |
| Observers | Linked documents only: syncs on `file_loaded`, `after_save`, `external_change`, when a document is linked, on Sync Now, and on poll (Drive is asked at most once every five minutes) |
| Timers | A one-second poll while an authorization is in flight; a check every minute that tells you once when nothing is linked |

## Setting it up

Open Help ▸ Plugins ▸ gdrive-sync and press **Configure…** (or run
`gdrive-sync.configure`):

1. Enter the **OAuth client ID** of a limited-input (device-flow) client you
   created, and the **client secret** if Google issued one.
2. Press **Authorize**. The window shows a code to enter on Google's device page;
   the plugin polls until you finish.
3. With the document open in front, link it:
   - **Create Drive file** makes a new Drive file from it.
   - **Link existing file** lists the text files in Drive this app may open;
     pick one. If the file you want is not listed, paste its id or its Drive
     link into the field below the list and press **Link this file**.

Use the same OAuth client on every machine. The `drive.file` scope lets the
plugin open only files this client created or opened, so a file made with
another client, or in another account, cannot be linked.

Linking an existing file compares the two copies first. If they are equal, they
are in sync. If they differ, neither is adopted: you choose which to keep in the
conflict dialog, then save.

Tokens, the device code and the client secret go to `taskle.secrets`, encrypted
and reachable only by this plugin. The client id goes to `taskle.state`. Which
Drive file each document syncs with, and the revision last synced, are kept by
Taskle with the link.

## Sync status

Every sync ends with a status Taskle shows on the document's tab: `↑` while
local changes have not reached Drive, `⚠` with a message when sync stopped and
what to do about it. A status stays until a later sync clears it. Closing or
quitting asks while a document still has changes not on Drive; sync resumes the
next time you open it.

A sync stops, and says so, when:

- you are not signed in, or Google asks you to sign in again;
- Drive cannot be reached, or an upload or download fails (it retries on the
  next sync);
- the Drive file was deleted or moved to the trash;
- both copies changed (a **conflict**: both are kept for you to choose).

## How a conflict is handled

Drive v3 documents no conditional media update, so an upload cannot be made to
fail on a stale base the way Dropbox's revisions can. This plugin therefore
**detects after writing**: it records the version it based the upload on, and if
the result is not the one it expected it preserves that as an explicit conflict
rather than pretending the write was clean.

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
  syncing: Taskle says so on Save As, and the window marks a link whose file is
  gone as missing.
- Sync happens around loads, saves, external changes, polls and Sync Now; there
  is no continuous watcher.
- Encryption protects a leaked file, not a compromised account.
