# kanban

The open document as a board: one column per stage, one card per task, moved with
the ◀ / ▶ buttons on the card.

## What it adds

| | |
|---|---|
| Commands | `kanban.open`, `kanban.configure` |
| Windows | **Kanban** (detached, its own OS window) and a small stage-list editor |

The board takes a window of its own because it is the thing this plugin does
rather than a form to answer: its columns sit side by side, and a panel's width
would put most of them behind a scrollbar before a single card was drawn. The
strip scrolls sideways and every column has a floor of 220px, so a narrow window
slides the board instead of squeezing each card to one word a line.

There is no drag and drop. The widget vocabulary is a description of a tree rather
than a surface with pointer events, and inventing a drag protocol for one plugin
would be the wrong place to start.

## Where a card's column is written

On the task line, in todo.txt:

- The **last** stage is `x` — the real completion state, not a column that shadows
  it. A board whose Done pile disagreed with what the app calls done would be a
  second source of truth for the one fact the format already has.
- The **first** stage is the absence of a tag, so a task nobody has touched needs
  no tag to appear on the board, and a document that has never met this plugin
  still opens as a full board rather than an empty one.
- Every stage between them is `_kanban:<slug>`. The leading underscore keeps this
  bookkeeping out of the task list's display.

So the board costs one tag on the tasks actually in flight.

## Stages

Configurable, because "To Do / Doing / Done" is one team's vocabulary and a board
is worth no more than its columns. The list lives in `taskle.state`, this plugin's
own namespace, and survives a reload.

A stage's tag is a slug of its name rather than its position, so reordering the
stages does not silently move every task. The trade: **renaming** a stage strands
the tasks tagged with the old slug — they come back in the first column, where
they are visible and can be moved again, rather than disappearing.

## Capabilities

None. It reads the document in front and edits tags through the task API.

## Notes and limits

- A column draws at most 50 cards, then says how many are left. A board is for
  seeing the shape of the work; a thousand-card column is a list, and the app
  already has a very good one of those.
- The board shows the document in front, not every open document.
- GUI only — plugin windows are not rendered by the terminal frontend.
