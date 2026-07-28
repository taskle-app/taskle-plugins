# quick-add

Type a task the way you would say it; the dates, recurrence and priority are
parsed out of plain English as it is created.

```
pay rent every month            → pay rent rec:1m due:<the 1st>
call mom tomorrow               → call mom due:<tomorrow>
review notes next friday !a     → (A) review notes due:<friday>
book flights in 3 weeks         → book flights due:<+21d>
file taxes by the end of month  → file taxes due:<last of month>
```

Taskle already resolves an explicit `due:tomorrow` when "Convert relative dates
on entry" is on. This is the other half: recognising the phrase when it was never
written as a tag, which is what people actually type into a one-line box.

## What it adds

Nothing to a menu and nothing to a key. It hooks `before_create`, which is the
one path every new task takes — the add bar, the editor sheet, a paste, another
plugin — so the rule holds however the task arrived. A command would have been a
second way to add a task that missed all the others.

## Capabilities

None. Reading and rewriting the task being created is the automation stage, so
there is no approval prompt.

## What it will not do

- **Only phrases at the end of the line are consumed.** "call mom tomorrow" has
  a date; "remind me about the tomorrow deadline" does not. Guessing at the
  middle of a sentence is how a quick-add starts eating words you meant.
- **No repetition todo.txt cannot state.** "every 3rd monday" is either the third
  Monday of a month or one week in three depending on who is saying it, and
  `rec:` records neither faithfully.
- If nothing matches, the line is left exactly as typed.
