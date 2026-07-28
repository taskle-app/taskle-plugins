# dropbox-sync

Synchronizes canonical local todo.txt files with Dropbox, using Dropbox's
conditional revisions so a concurrent edit is a detected conflict rather than a
silent overwrite.

The local file stays canonical. Sync uploads and downloads it; it never becomes
the place your tasks live.

## What it adds

| | |
|---|---|
| Command | `dropbox-sync.configure` |
| Window | **Dropbox Sync** — app key, folder, Authorize / Finish authorization |
| Observers | Syncs on `file_loaded`, `after_save`, `external_change`, and on poll |

## Setting it up

Open Help ▸ Plugins ▸ dropbox-sync (or run `dropbox-sync.configure`):

1. Enter the **app key** of a Dropbox app you created, and the **folder** to keep
   files in (default `/Taskle`).
2. Press **Authorize**. Dropbox opens in your browser and gives you a code.
3. Paste the code and press **Finish authorization**.

Authorization is PKCE, so no client secret is needed. The access and refresh
tokens go to `taskle.secrets`, encrypted and reachable only by this plugin; the app
key, the folder, and each file's last-seen revision go to `taskle.state`.

## Capabilities

`network`, `notify`, `secrets`. Granted only after you trust the plugin.

## How a conflict is handled

Each upload carries the revision the local copy was based on. If the remote has
moved on, Dropbox refuses the write and the plugin reports a conflict instead of
choosing a winner — a save never waits on the network, and a local file is never
replaced behind your back.

## Notes and limits

- One Dropbox account, one folder.
- A file is matched to its remote by path; moving it locally re-pairs it on the
  next sync.
- Sync happens around loads, saves, external changes and polls — there is no
  continuous watcher.
