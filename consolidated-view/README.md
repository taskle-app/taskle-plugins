# consolidated-view

Every task of every document open in the workspace, as one list.

A `taskle.source` says only *what exists*. The order, the quick filters, the
search box, the hide toggles, and any grouping or nesting over the result are the
host's pipeline — so this list sorts and filters exactly like a single document,
and nothing here knows which sort you picked.

## What it adds

| | |
|---|---|
| Source | **All Open Documents**, under the **File** menu beside the documents themselves |
| Tab | Opens in its own **Consolidated View** tab, created on first use and returned to afterwards |

The tab is its own because this list is a superset of every open document:
composing it over one of them would take that document's tab away to show
something it is already inside, leaving no way back except changing the source
again.

## Capabilities

`read_documents` — reading a document that is not the one in front is the whole
point, so the manifest asks for it up front rather than failing at the moment it
matters. Install and trust the plugin, then grant it (Help ▸ Plugins).

## Notes and limits

- Completed tasks are included. Which rows are *shown* is the filters' business,
  and the tab applies its own — dropping completed tasks here made an
  unremovable second filter, with "Show Completed Tasks" on and rows still
  missing.
- The tab recomposes when any document it read changes, including ones not in
  front.
- Editing a task from this tab edits the document the task came from.
