# subtasks

A parent/child hierarchy over ordinary todo.txt lines: indented rows, a family
that stays together under every sort, roll-up completion, and a filter that hides
children.

Taskle has no sub-task feature and no notion of a parent. The relation is this
plugin's, declared once and applied by the host's composition pipeline.

## The convention

A parent carries `_id:<n>`; each child carries `_parent:<n>` naming it.

```
(A) ship the release +work _id:1
write the changelog +work _parent:1
tag the commit +work _parent:1
```

The id lives in the line rather than being the app's own task id, which is a
position in the loaded document: archiving one task renumbers the rest, and every
child would then point at the wrong parent. Both tags begin with `_`, so the app
hides them from the row — turn on "Show hidden tags" in Preferences to see them.

## What it adds

| | |
|---|---|
| Commands | `subtasks.new`, `subtasks.indent`, `subtasks.outdent` |
| Menu | Task ▸ Sub-tasks ▸ New Sub-task, Make Sub-task of Previous, Promote Sub-task |
| Keys | `N` new, `>>` indent, `<<` outdent |
| Filter | **Hide Sub Tasks** (Filter menu) — show only top-level tasks |
| Nesting | Child rows are indented, a family stays contiguous under every sort, and a filtered-out parent is shown as an inert context row |
| Hooks | `before_complete` cascades to children, `before_delete` takes them with it, `before_render` flags a duplicate `_id:` |

`subtasks.new` drafts the child rather than creating it outright, so the app's own
new-task rules apply and abandoning the editor leaves no `_id:` behind on the
parent.

## Capabilities

None — not even `read_documents`. Asking for it would put the whole plugin behind
an approval prompt, including under `tsk`, where the cascade-on-complete hook is
the reason to have it at all. The cost is that a cross-document source switches
the hierarchy off with a notice.

## Notes and limits

- The hierarchy is within one document. `_parent:` names an `_id:` in the same
  file.
- A duplicate `_id:` makes every `_parent:` naming it ambiguous; the rows say so
  rather than guessing.
- Ordering inside a family follows the sort, not the file. There is no manual
  reordering, so "Make Sub-task of Previous" means the row above in the list you
  are looking at.
- Tags are read and written through the task API, never as raw text, so a
  malformed line is not something this plugin can produce.
