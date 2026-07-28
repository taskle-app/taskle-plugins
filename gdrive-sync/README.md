# gdrive-sync

Synchronizes canonical local todo.txt files with Google Drive, pairing each local
document with one Drive file.

The local file stays canonical. Sync uploads and downloads it; it never becomes
the place your tasks live.

## What it adds

| | |
|---|---|
| Command | `gdrive-sync.configure` |
| Window | **Google Drive Sync** — OAuth client id and secret, Authorize, and "Create and pair current document" |
| Observers | Syncs on `file_loaded`, `after_save`, `external_change`, and on poll (at most once every five minutes) |
| Timer | A one-second poll while an authorization is in flight |

## Setting it up

Open Help ▸ Plugins ▸ gdrive-sync (or run `gdrive-sync.configure`):

1. Enter the **OAuth client ID** of a limited-input (device-flow) client you
   created, and the **client secret** if Google issued one.
2. Press **Authorize**. The window shows a code to enter on Google's device page;
   the plugin polls until you finish.
3. With a document open, press **Create and pair current document** to make its
   Drive file. The pairing is remembered per local path.

Tokens, the device code and the client secret go to `taskle.secrets`, encrypted
and reachable only by this plugin. The client id, the paired file id and the
last-checked stamp go to `taskle.state`.

The scope is `drive.file`, so the plugin can only see files it created.

## Capabilities

`network`, `notify`, `secrets`, `timers`. Granted only after you trust the plugin.

## How a conflict is handled

Drive v3 documents no conditional media update, so an upload cannot be made to
fail on a stale base the way Dropbox's revisions can. This plugin therefore
**detects after writing**: it records the version it based the upload on, and if
the result is not the one it expected it preserves that as an explicit conflict
rather than pretending the write was clean.

## Notes and limits

- One Google account.
- A document must be paired before it syncs; a new local file does not appear in
  Drive on its own.
- Sync happens around loads, saves, external changes and polls — there is no
  continuous watcher.
- Encryption protects a leaked file, not a compromised account.
