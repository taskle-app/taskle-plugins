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
| Command | `dropbox-sync.configure` |
| Window | **Dropbox Sync**: the account (app key, Authorize, Finish authorization), this document's link (a Dropbox path and **Link**, or **Sync Now** and **Unlink**), and every linked document with its status |
| Observers | Linked documents only: syncs on `file_loaded`, `after_save`, `external_change`, when a document is linked, on Sync Now, and on poll (Dropbox is asked at most once every five minutes) |
| Timer | A check every minute that tells you once when nothing is linked |

## Setting it up

Open Help ▸ Plugins ▸ dropbox-sync and press **Configure…** (or run
`dropbox-sync.configure`):

1. Enter the **app key** of a Dropbox app you created.
2. Press **Authorize**. Dropbox opens in your browser and gives you a code.
3. Paste the code and press **Finish authorization**.
4. With the document open in front, check the path (it is suggested as
   `/Taskle/<file name>`) and press **Link**.

Linking compares both copies first. If nothing is at the path yet, the document
is uploaded there. If an equal file is there, they are in sync. If a different
one is, neither is adopted: you choose which to keep in the conflict dialog,
then save. Dropbox paths are case-insensitive, so two documents cannot be
linked to the same file under different spellings.

Authorization is PKCE, so no client secret is needed. The access and refresh
tokens go to `taskle.secrets`, encrypted and reachable only by this plugin; the
app key goes to `taskle.state`. Which path each document syncs with, and the
revision last synced, are kept by Taskle with the link.

## Sync status

Every sync ends with a status Taskle shows on the document's tab: `↑` while
local changes have not reached Dropbox, `⚠` with a message when sync stopped and
what to do about it. A status stays until a later sync clears it. Closing or
quitting asks while a document still has changes not on Dropbox; sync resumes
the next time you open it.

A sync stops, and says so, when you are not signed in, Dropbox cannot be
reached, a transfer fails (it retries on the next sync), the linked Dropbox
file was deleted or moved (it is never re-created on its own), or both copies
changed (a **conflict**: both are kept for you to choose).

## Capabilities

`network`, `notify`, `secrets`, `timers`. Granted only after you trust the plugin.

## How a conflict is handled

Each upload carries the revision the local copy was based on, and a first
upload asks Dropbox to add a new file. If the remote has moved on, or a file
appeared at the path, Dropbox refuses the write and the plugin keeps both
versions instead of choosing a winner. A save never waits on the network, and a
local file is never replaced behind your back.

**Unlink** stops further work for the document, but an upload already on its
way can still land.

## Tests

`tests/links.lua` runs under the host's internal test runner, from a Taskle
checkout: `cargo run -p taskle-plugin-test -- plugins/dropbox-sync`.

## Notes and limits

- One Dropbox account.
- A link follows the local file's path. A linked file you rename or move stops
  syncing: Taskle says so on Save As, and the window marks a link whose file is
  gone as missing.
- Sync happens around loads, saves, external changes, polls and Sync Now; there
  is no continuous watcher.
