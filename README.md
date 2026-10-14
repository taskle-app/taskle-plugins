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
description = "Commits each linked todo.txt on its own and pushes it."
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
| [`dropbox-sync`](dropbox-sync/README.md) | Dropbox sync per linked document, with revision compare-and-swap |
| [`gdrive-sync`](gdrive-sync/README.md) | Google Drive sync per linked document (`drive.file`) |
| [`git-sync`](git-sync/README.md) | Commit and push a linked todo.txt on its own, nothing unchecked pushed |
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

### Sync plugins: git-sync, dropbox-sync, gdrive-sync

Sync is opt-in per document. Each sync plugin syncs only the documents you link
in its window (Help ▸ Plugins ▸ the plugin ▸ **Configure…**, with the document
open in front); Taskle keeps the link. Linking compares both copies first: equal
copies are in sync, different ones open the conflict sheet and keep both.

Taskle shows every linked document's status on its tab (`↑` changes not yet
synced, `⚠` sync stopped, with what to do), and asks before closing or quitting
while a document has changes not yet synced. A sync never stops silently.

- **git-sync** links a document to a remote of the repository it is in; the
  todo.txt has to be in a git repository with an upstream already
  (`cd ~/todo && git init && git add todo.txt && git commit -m todo`, then add
  and push to a remote). Each sync fetches, commits the saved document as a
  commit touching only that file, fast-forwards when only that file changed
  remotely, and pushes when every outgoing commit touches only that file;
  anything else waits for you to approve the listed commits, or to resolve
  diverged history in git. The credential (an HTTPS token, or your SSH key's
  passphrase) goes to `taskle.secrets` and reaches git through `GIT_ASKPASS`,
  never the remote URL.
- **dropbox-sync** links a document to a Dropbox path. Create a Dropbox app with
  scoped file access, enter its app key, press **Authorize**, and paste
  Dropbox's code back. It uses PKCE and stores only the refresh token; uploads
  are conditional on the revision they replace.
- **gdrive-sync** links a document to a Drive file it creates, or to one this
  OAuth client may open (from a list, or by pasting its id or link). Create a
  Google OAuth client for limited-input devices and use the same one on every
  machine. Drive v3 documents no conditional media update, so the plugin checks
  the version before and after an upload and turns a detected race into a
  conflict; it cannot give Dropbox's compare-and-swap.

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

- **`git-sync/`** — commits each linked todo.txt on its own through git's
  plumbing and pushes only checked or approved commits, via
  `taskle.process.run` from suspendable document observers on `taskle.links`.
  Needs `notify`, `run_process`, `secrets`, `timers`, and `write_files`.
- **`consolidated-view/`** — projects the tasks of all documents open in the
  current workspace. Needs `read_documents`.
- **`dropbox-sync/`** — local-first Dropbox synchronization per linked document
  with revision compare-and-swap, PKCE authorization, and explicit conflicts.
  Needs `network`, `notify`, `secrets`, and `timers`.
- **`gdrive-sync/`** — local-first Drive synchronization per linked document,
  with a create that survives a lost answer and detect-after-write conflict
  handling. Needs `network`, `notify`, `secrets`, and `timers`.
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

## Testing a plugin

A plugin can keep tests in `tests/*.lua`, run against a real Taskle host by the
host's internal runner. From a Taskle checkout (this repository is its
`plugins/` submodule):

```sh
cargo run -p taskle-plugin-test -- plugins/gdrive-sync          # every case
cargo run -p taskle-plugin-test -- plugins/gdrive-sync "Create" # names containing "Create"
```

Each case runs in a fresh host loaded from the plugin's manifest, granted what
it declares, over documents in a scratch directory:

```lua
case("a saved change uploads", function(t)
  t.secret("access_token", "T")
  t.open("todo.txt", "a task\n")
  t.http { method = "POST", url = "https://example.com/upload", status = 200 }
  t.edit("todo.txt", "a task\nmore\n")
  t.ok(t.save())
  t.eq(t.link().status.state, "ok")
end)
```

HTTP and process requests are answered from what the case scripts (`t.http`,
`t.process`); a request nothing answers fails the case. `t.run_for_real("git")`
lets a case drive git against repositories it builds in `t.dir`. A linked run
that ends without `taskle.links.status` fails the case too. The full fixture
list is in the runner's crate docs (`crates/taskle-plugin-test/src/lib.rs`). It
is internal and unstable: it may change with these plugins until it is
promoted to a public `tsk plugin test`.

