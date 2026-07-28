# Taskle plugins

The plugin repository for [Taskle](https://github.com/taskle-app/taskle). Add it in
**Help ▸ Plugins**, or clone it beside the app's own checkout.

These demonstrate that Taskle's integrations are **plugins built on the public API**, not built-in
features — the app binary contains no git, calendar, or issue-tracker code. They are not compiled
into the app, and are disabled until you install and trust them.

## The plugin model

A plugin is a directory with a `plugin.toml` manifest and its Lua:

```toml
name = "git-sync"        # the identifier: keys the trust store, keep it stable
title = "Git Sync"       # optional; what the plugin manager shows instead
description = "Fetches your todo.txt on open and pushes it after each save."
version = "0.1.0"
api_version = 1          # must not exceed taskle.api_version
entry = "init.lua"       # optional; defaults to init.lua
capabilities = ["run_process"]   # the ceiling of what it may be granted
```

`title` and `description` are prose for the plugin manager, and both are optional — without a
`title` the manager shows `name`. They are free to change without invalidating an approval,
which `name` is not: renaming a plugin makes it a new one as far as trust is concerned. Both are
flattened to a single line, so a multi-line TOML string will not reflow the list.

The `capabilities` list is what the plugin *requests* — a ceiling, never an automatic grant.
In-app capabilities (`read_tasks`, `write_tasks`, `notify`, `timers`) come with the automation
stage; external ones (`read_files`, `write_files`, `run_process`, `network`, `network_local`,
`clipboard`, `git`, `secrets`) are granted only to **trusted** sources, and only after you approve
them.

`network` reaches the public internet and **not** this machine or your local network — a database
on localhost, a printer's admin page, a cloud metadata endpoint. A plugin that genuinely needs one
of those asks for `network_local`, which is a claim you can weigh separately.

Grants are **default-deny**: an engine starts able to do nothing, and the host resolves the real
set through the trust model before the script runs. Forgetting that step disables a plugin; it
cannot accidentally over-privilege one. Every gated call raises a clear error when its capability
is missing — none of them silently no-op.

## Using the bundled plugins

Every plugin also carries its own README — what it adds, what it needs granted,
how to set it up, and what it will not do:

| Plugin | |
|---|---|
| [`consolidated-view`](consolidated-view/README.md) | Every open document as one list |
| [`dropbox-sync`](dropbox-sync/README.md) | Dropbox sync with revision compare-and-swap |
| [`gdrive-sync`](gdrive-sync/README.md) | Google Drive sync for a paired `drive.file` |
| [`git-sync`](git-sync/README.md) | Fetch on open, commit and push after save |
| [`kanban`](kanban/README.md) | The document as a board |
| [`notes`](notes/README.md) | A long-form note attached to a task |
| [`pomodoro`](pomodoro/README.md) | Fixed work intervals, counted on the task |
| [`quick-add`](quick-add/README.md) | Dates and priority parsed out of plain English |
| [`subtasks`](subtasks/README.md) | A parent/child hierarchy over plain lines |
| [`todo-ai`](todo-ai/README.md) | Add-bar text turned into a task by a bounded WASM model |

### subtasks

There is no "add subtask" command — a child is an ordinary task that carries a
`_parent:<id>` tag naming its parent's id. The way you make one:

1. Add the parent, then add the child as a normal task on the line below it.
2. With the child focused, run **`subtasks.indent`** — it reads the task above
   and writes the `_parent:` tag for you. **`subtasks.outdent`** removes it.

Neither has a default key, because the plugin cannot know what is free in your
keymap. Bind them in `~/.config/taskle/init.lua`:

```lua
taskle.bind { keys = ">>", command = "subtasks.indent" }
taskle.bind { keys = "<<", command = "subtasks.outdent" }
```

The `_parent:` tag is hidden from the row by default (it begins with `_`); turn
on **Preferences ▸ List ▸ Show hidden tags** to see it. Children are drawn
indented under their parent and stay with it under every sort order.

### kanban

Run `kanban.open` for the open document as a board, in a window of its own. A
card moves with the ◀ / ▶ buttons on it; there is no drag and drop, because the
widget vocabulary describes a tree rather than a surface with pointer events.

Where a card sits is written on the task line. The last stage is the document's
own `x`, so the Done pile cannot disagree with what the app calls done; the first
is the absence of a tag, so a document that has never met this plugin still opens
as a full board; every stage between them is `_kanban:<slug>`, hidden from the
row by its leading underscore.

The stages are yours — **Configure…** in the plugin manager takes one name per
line, left to right, at least two. A stage's tag is a slug of its *name* rather
than its position, so reordering the stages does not move every task at once; the
trade is that renaming one leaves the tasks already in it in the first column,
where they are visible and can be moved again.

The strip scrolls sideways and every column has a minimum width, so a narrow
window slides the board rather than squeezing each card down to one word a line.

### pomodoro

Focus a task and run **Task ▸ Pomodoro ▸ Start** (or `pomodoro.start`). Twenty-five
minutes later it notifies you, records the interval on the task as `_pomo:<n>`,
and starts a break; every fourth one is a long break. The count shows as dots on
the row, and the minutes left show in front of the words of the task being worked.

**Pause** holds the countdown where it is rather than ending the interval, so
answering the door does not cost twenty minutes; **Resume** picks it up. Each of
the four menu rows is greyed when it has nothing to do — Start while one is
running, Stop while none is — which the plugin says with `taskle.flag` rather
than by letting the row run and refuse.

The count lives on the task rather than in the plugin, so it survives archiving
and syncs with the file. It is not a stopwatch: the sandbox has no clock beyond
`taskle.today()`, so a run counts one-minute ticks — accurate to about a minute,
and it does not continue while the app is closed.

### quick-add

Type a task the way you would say it; the phrase at the end becomes tags.

```
pay rent every month          →  pay rent rec:1m due:…
call mom tomorrow             →  call mom due:…
review notes next friday !a   →  (A) review notes due:…
book flights in 3 weeks       →  book flights due:…
```

Only a *trailing* phrase counts — "remind me about the tomorrow deadline" keeps
its words — and anything you wrote as a real tag wins. It runs on
`before_create`, so it applies however the task arrived: the add bar, a paste,
another plugin.

### consolidated-view

Choose **File ▸ Consolidated View** to show the tasks of every document open in
the current workspace, in a tab of its own. The tab's own filters narrow it, so
the hide toggles decide whether completed tasks appear, as in any other tab. The plugin uses `taskle.open_documents()`,
`taskle.tasks(document.doc)`, and an ordinary row projection; the host has no
consolidated-view mode. The selected sort order is applied across the returned
rows, and active custom filters continue to subtract from the result.

### git-sync

The todo.txt has to already be inside a git repository — the plugin syncs the
repository the file lives in, it does not create one:

```
cd ~/todo && git init && git add todo.txt && git commit -m "todo"
```

Everything else is set from **Help ▸ Plugins ▸ git-sync** (or the
`git-sync.configure` command): the remote name, the remote URL if the repository
has none yet, and a credential — an HTTPS token, or the passphrase for your SSH
key.

The credential goes to `taskle.secrets`, encrypted and reachable only by this
plugin. It is never written into the remote URL, where it would land in
`.git/config` and in every error message. For SSH remotes, the key itself stays
where `ssh` expects it; only the passphrase is stored here.

Opening a document fetches the remote branch and reads that file without
checking it out over the local copy. Taskle applies a download only if the
document has not changed since the fetch began. Saving commits and pushes the
file in the background.

### dropbox-sync

Create a Dropbox app with scoped file access and copy its app key into
**Help ▸ Plugins ▸ dropbox-sync**. Choose a remote folder, press **Authorize**,
complete consent in the browser, and paste Dropbox's displayed code back into
the window. The plugin uses PKCE and stores only the resulting refresh token as
a secret; no client credential is shipped in this repository.

Dropbox revision updates are conditional. If both copies move, or if an
existing remote path differs during initial pairing, Taskle opens its normal
conflict sheet and keeps both contents available.

### gdrive-sync

Create a Google OAuth client for limited-input devices and enter its client ID
in **Help ▸ Plugins ▸ gdrive-sync**. If Google issued that client a secret,
enter it too. Authorize with the displayed device code, then press **Create and
pair current document**. The plugin asks only for `drive.file` and creates the
Drive file it manages; it does not browse arbitrary existing Drive files.

Google Drive v3 does not document a conditional media-update operation. This
plugin checks the remote version immediately before and after an upload and
turns a detected race into a conflict, but it cannot provide Dropbox's atomic
remote compare-and-swap. The configuration window states that limitation.

## Secrets

A plugin that needs a credential asks for the `secrets` capability and gets four
functions, all scoped to itself:

```lua
taskle.secrets.set("token", value)
taskle.secrets.get("token")     -- nil when unset
taskle.secrets.delete("token")
taskle.secrets.keys()           -- names only
```

The namespace is the **source name**, supplied by the host — there is no
argument for it, so one plugin cannot address another's entries. Each namespace
also gets its own key derived from the master key, so ciphertext lifted out of
the file for one namespace cannot be opened with another's.

The store is `~/.local/share/taskle/secrets.toml`, encrypted with the key in
`~/.local/share/taskle/secret.key` (mode 0600). That protects a config directory that
gets committed, backed up or pasted into an issue. It does **not** protect
against someone who can already read your home directory as you — they can read
the key too.

## Capability approval

Installing a plugin is not consenting to what it asks for. A plugin that
requests any **external** capability (`read_files`, `write_files`,
`run_process`, `network`, `network_local`, `clipboard`, `git`, `secrets`) does not run at all
until you allow it in **Help ▸ Plugins**, which names exactly what it asked for.

The approval is pinned to a digest of the manifest and the entry script, so an
update that changes the code — or that widens what it requests — asks again
rather than inheriting the answer you gave the version before it. **Revoke**
takes the grant back and the plugin stops running.

Installed plugins are also confined: an installed plugin reaches its own
directory and the open document's, not your whole disk. A repository plugin
reaches its own directory and the repository that shipped it. Only your
hand-written `init.lua` is unconfined.

## Trust

- **User plugins** (`~/.local/share/taskle/plugins/`) are yours, so they are trusted by default.
- **Repository plugins** (`<repo>/.taskle/`) are *not* run with external powers until you trust the
  folder. Untrusted sources get nothing; their registrations are ignored.

A plugin probes what it was granted with `taskle.has("run_process")`. A gated call it wasn't granted
(e.g. `taskle.process.run` without `run_process`) errors and surfaces a diagnostic — it never
silently no-ops.

## Examples here

- **`git-sync/`** — fetches on file open and commits+pushes after save, via
  `taskle.process.run` from suspendable document observers. Needs
  `notify`, `run_process`, `secrets`, and `write_files`.
- **`consolidated-view/`** — projects the tasks of all documents open in the
  current workspace. Needs `read_documents`.
- **`dropbox-sync/`** — local-first Dropbox synchronization with revision
  compare-and-swap, PKCE authorization, and explicit conflicts. Needs
  `network`, `notify`, `secrets`, and `timers`.
- **`gdrive-sync/`** — local-first Drive synchronization for a plugin-created
  `drive.file`, with detect-after-write conflict handling. Needs `network`,
  `notify`, `secrets`, and `timers`.
- **`subtasks/`** — a full parent/child hierarchy, and the reference example for the composition
  API. Children carry a `_parent:<id>` tag; from that the plugin indents rows (`before_render`),
  keeps a family adjacent under every sort order with the parent standing in for the family's best
  priority and earliest due date, shows an unmatched ancestor as an inert row through the same
  projection, and offers `subtasks.indent` / `subtasks.outdent`
  (`taskle.task.set_tag` / `remove_tag`) plus a `roots` filter. Needs no external capabilities
  (runs untrusted).

  Worth being precise about what this demonstrates: **the app has no sub-task feature.** It has no
  notion of a parent, of a family, or of why a row is on screen — it validates and displays the
  projection's task references. Every rule above lives in that one Lua file.

`taskle.http`, `taskle.codec`, and `taskle.state` are general public primitives;
the cloud plugins are their reference consumers rather than privileged host
integrations.
