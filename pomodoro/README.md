# pomodoro

Work in fixed intervals against one task, and keep the count on the task.

## What it adds

| | |
|---|---|
| Commands | `pomodoro.start`, `pomodoro.pause`, `pomodoro.resume`, `pomodoro.stop` |
| Menu | Its own rows, enabled or greyed to match what is running |
| Row prefix | The task being worked on is drawn with a countdown in front of it (`before_render`) |
| Notifications | When an interval ends and when a break ends |
| Count | `_pomo:<n>` on the task line |

The count lives on the task rather than in a store of this plugin's own: it
belongs to the task, survives archiving and being edited elsewhere, and syncs with
the file. The leading `_` keeps it out of the row's text.

25 minutes of work, then 5 minutes of break; every fourth completed interval
earns 15 instead.

## Capabilities

None. `taskle.timer`, `taskle.notify` and `taskle.task.*` are all the automation
stage, so it runs untrusted with no approval prompt.

## How the timing works, and what it cannot do

One recurring one-minute timer, registered at load, counting down a number held in
the plugin. Not a stopwatch: the sandbox has no clock beyond `taskle.today()`, so
elapsed time cannot be measured — only ticks can be counted. Two consequences:

- an interval is accurate to about a minute, not to the second;
- a run does not survive the app being closed, and does not continue while it is
  closed. Reopening starts from nothing rather than from a lie about how long you
  have been working.

Only one pomodoro at a time. Two at once is not a thing, and the state that would
allow it is state to get wrong.

## Menu enablement

`run` and `paused` are mirrored into `taskle.flag`s and pushed with
`taskle.set_flag` from the single place that changes them, because the host cannot
see a Lua local and running this file on every menu render would be the wrong way
to ask. That is what greys out Start while a pomodoro is running, and Stop while
none is.
