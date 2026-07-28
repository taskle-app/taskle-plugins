# notes

A long-form note attached to a task, edited in a window and stored as Markdown
beside the project.

## What it adds

| | |
|---|---|
| Commands | `notes.open`, `notes.clear` |
| Menu | Task ▸ Note ▸ Note…, Clear Note — and both on the task's right-click menu |
| Key | `gn` opens the note for the focused task |
| Window | **Notes** — a text area with Save, Open externally, and Delete |

Clearing a note asks first. It removes the file and the tag together.

## Where a note lives

`<workspace>/.taskle/notes/<id>.md`, so a note travels with the tasks it
annotates: copy the project, or commit it, and the notes come too. Not in the
app's data directory, which would strand every note the moment the todo file
moved.

At the workspace root rather than beside each todo file: a project with several
lists in subdirectories would otherwise grow a `.taskle` in every one of them, and
a note is about the project's work rather than about which file the task happens
to be listed in. A document in no workspace falls back to its own directory.

The task and the note are tied by a `_note:<id>` tag on the task line. That is
todo.txt, so it survives being edited in another program, sorted, archived or
synced — none of which a side table of task ids would survive, since task ids are
document-local and change on reload. The id is minted on first *save*: opening the
editor and changing nothing writes no tag.

Ids are ten lowercase letters. Lowercase because the id *is* a filename, and
macOS and Windows compare filenames case-insensitively — two ids differing only in
case would be one file, and one note would silently overwrite another. A collision
is checked for anyway.

## Capabilities

`read_documents`, `read_files`, `write_files`, `open_externally` — it reads and
writes note files under the workspace, and can hand a note to whatever the system
opens Markdown with. Install, trust, then grant (Help ▸ Plugins).

## Notes and limits

- One note per task.
- The note is Markdown, stored and edited as plain text; nothing renders it.
- Deleting the task does not delete the note file. The tag goes with the line, so
  an orphaned note stays on disk until Clear Note or a manual delete.
