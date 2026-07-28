# git-sync

Keeps the git repository your todo.txt lives in up to date:

- fetch when the file is opened, adopting one-sided remote changes and asking
  before resolving divergent local and remote content;
- commit and push after each save, so your changes are backed up.

## What it adds

| | |
|---|---|
| Commands | `git-sync.now`, `git-sync.configure` |
| Menu | File ▸ Git Sync ▸ Sync Now |
| Window | **Git Sync** — remote, remote URL, credentials |

## Setting it up

The todo.txt has to be inside a git repository already. This syncs the repository
the file lives in; it does not create one.

Everything else is configured from the plugin's own window (Help ▸ Plugins ▸
git-sync, or the `git-sync.configure` command):

| Field | |
|---|---|
| Remote | the remote name to push to (default `origin`) |
| Remote URL | set once, if the repository has no remote yet |
| Credentials | an HTTPS token, or the passphrase for your SSH key |

## Capabilities

`run_process` (it shells out to `git`), `secrets` (the remote and any credential
live in this plugin's own encrypted namespace), `notify`, and `write_files` (the
short-lived askpass helper). All granted only after you trust the plugin; if a
grant is missing, the gated calls fail and the app shows a diagnostic rather than
the plugin silently doing nothing.

## Where the credential goes

Into `taskle.secrets`, which is encrypted and reachable only by this plugin —
never into the todo.txt, and never into a config file you might share. It is
handed to git through `GIT_ASKPASS` for the length of one call rather than written
into the remote URL, where it would end up in `.git/config` and in every error
message. The askpass helper is written beside the secret store rather than in
`/tmp`, which is world-readable on most systems.

## Notes and limits

- Divergent local and remote content is a question, not a merge: you are asked
  before anything is resolved.
- Syncing a repository that is already configured does not need the secret store,
  so an unopenable store degrades rather than refusing to load.
- Encryption protects a leaked file, not a compromised account.
