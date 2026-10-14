-- A cross-document list: every task of every open document, as one candidate
-- set. A source says only what exists — the ordering, the filters, and any
-- grouping or nesting over it are the host pipeline's, so nothing here knows or
-- cares which sort the user picked.

taskle.source {
  name = "consolidated",
  title = "All Open Documents",
  -- Under File, beside the commands for the open documents themselves, rather
  -- than under View with the structure toggles over one document's rows. The
  -- host puts the default "Document" choice in the same menu, so the two read as
  -- the one either/or they are.
  menu = "File",
  -- A tab of its own. This list is a superset of every open document, so
  -- composing it over one of them would take that document's tab away to show
  -- something it is already inside — and leave no way back to the file you were
  -- reading except changing the source again. The host opens the tab the first
  -- time and returns to it after that.
  tab = "Consolidated View",
  -- Reading a document that is not the one in front is the whole point of this
  -- plugin, so it says so rather than being skipped at the moment it matters.
  requires = { "read_documents" },
  -- Completed tasks included: which rows are *shown* is the filters' answer and
  -- the host applies the tab's own — the hide toggles, the preset, the search
  -- box. Dropping them here made an unremovable second filter, with "Show
  -- Completed Tasks" on and the rows still missing.
  --
  -- `ctx.documents` and `ctx.tasks` rather than the global accessors, which
  -- raise inside a slot: the host records what a source read, and that read set
  -- is what makes this tab recompose when a document it does not have in front
  -- changes underneath it.
  tasks = function(ctx)
    local out = {}
    for _, document in ipairs(ctx.documents) do
      for _, task in ipairs(ctx.tasks(document)) do
        out[#out + 1] = task.ref
      end
    end
    return out
  end,
}
