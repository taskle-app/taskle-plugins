# todo-ai

`todo-ai` turns natural-language text submitted through Taskle's existing Add
bar into a `todo.txt` task. It considers the open document's existing projects
and contexts, but never writes the document directly.

The model emits structured evidence. The Lua plugin validates that evidence,
resolves date, time, and recurrence phrases against the reference date, and
returns a structured task specification for Taskle to serialize. `CONTRACT.md`
defines what the model must emit and what the plugin does with it; the plugin
reads no meaning out of the raw text on its own. Taskle then runs its ordinary
creation preferences and hooks, so undo, redo, dirty tracking, and persistence
use the same host path as manually entered text.

A trailing `!a`, `!b` or `!c` sets the priority outright — `buy groceries !a`
becomes `(A) buy groceries` — matching the marker `quick-add` accepts, so a
typed priority reads the same whichever plugin handles the Add bar. The marker
is removed before inference and overrides any priority the model proposes.

If inference is unavailable, fails, produces invalid evidence, or is not
confident enough to propose a task, the plugin returns control to Taskle and
the original Add-bar text is created through the unchanged path. The separate
reviewed-draft window remains available for users who want to inspect a
proposal before saving.

The plugin requests only Taskle's bounded `wasm` capability. Its model and WASM
runtime are manifest-declared, size-limited, SHA-256-pinned resources. It has no
filesystem, process, or network capability.

## Layout

- `init.lua` — the deterministic policy: validation, date resolution and
  rendering
- `resources/` — the built module, the INT8 model container and its manifest
- `CONTRACT.md` — what the runtime must emit; `MODEL_CARD.md` — what the model
  is and is not

Nothing here is source for either artifact. Taskle installs a plugin by cloning
this repository and copying the directory, so what a user gets should be what
the plugin needs to run and nothing else. The corpus, trainer, export and the
runtime's own source live in the separate `todo-txt-model` repository.
Rebuilding both artifacts, from there:

```sh
cargo run --release -- train --out ../plugins/todo-ai/resources
cd runtime
cargo build --release --target wasm32-unknown-unknown
cp target/wasm32-unknown-unknown/release/todo_ai_runtime.wasm \
   ../../plugins/todo-ai/resources/
```

Then update the three `sha256` values in `plugin.toml` and the digest in
`init.lua`'s `MODEL_METADATA`. The artifacts under `resources/` are tracked
because Taskle installs plugins directly from a Git clone; omitting either file
produces an incomplete package that the host correctly refuses to run.

The current artifacts are engineering candidates, not a production release. See
`MODEL_CARD.md` for what they were measured against.
