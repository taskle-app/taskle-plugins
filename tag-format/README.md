# tag-format

Say how projects, contexts and tags should look: rewrite the text, recolour it, or
drop it from the row.

A todo.txt line carries its metadata in the open — `+work`, `@phone`,
`due:2026-08-01`, and whatever `key:value` a plugin keeps. That is the format's
great virtue in a file and its main cost in a list: the words you actually read
share a row with bookkeeping you already know.

This plugin does not change the file. It changes how a tag is **drawn**.

## What it adds

| | |
|---|---|
| Command | `tag-format.configure` |
| Menu | View ▸ Tag Format… |
| Window | **Tag Format** — the rules, Save, Reload saved, Restore the example |

## Rules

One rule a line, in the plugin's window:

```
+urgent  = 🔥{value}          fg:#f38ba8
@waiting =                    fg:#89b4fa bg:#1e1e2e
due      = ⏰{value}           fg:#f9e2af
_pomo    = 🍅{value}          show
_kanban  =                    hide
*        = {key}
```

**Selector** — the tag as it is written, minus the value:

| | |
|---|---|
| `+name` | a project |
| `@name` | a context |
| `key` | a `key:value` tag — `due`, `t` and `rec` included |
| `+*`, `@*`, `*` | any project, context, or `key:value` tag |

First matching rule wins, so put the specific ones above the wildcards.

**What a rule may say**

| | |
|---|---|
| a label | the text to draw. `{value}` is the bare value, `{key}` the key, `{text}` what the row would have drawn. An empty label keeps the original text — for a rule that is only about colour. |
| `fg:#hex` | text colour, `#rrggbb` or `#rrggbbaa` |
| `bg:#hex` | background behind the tag |
| `hide` | leave the tag out of the row (it stays in the file) |
| `show` | draw a hidden `_`-prefixed tag that would otherwise be left out |

Blank lines and `#` comments are ignored. A line that cannot be read is reported
by the window and skipped — one typo does not cost the rest, and the rules that
parsed are still saved.

Out of the box the rules are all comments, so installing this plugin changes
nothing until you write one.

## Capabilities

None. Rewriting the row's parts and keeping rules in its own state namespace are
both the automation stage, so there is no approval prompt.

## Notes and limits

- **Display only.** It hooks `before_render`, which returns parts; the host owns
  serialization, so the worst a bad rule can do is look wrong until it is fixed.
  The file, the tooltip and every other tool see the tag as it was written.
- GUI only. `before_render` is one of the surfaces that are inert under `tsk`.
- Rules are per install, not per document, and live in `taskle.state`.
- Colours are taken as written. A hex colour that fights the active theme is not
  corrected — use the theme's own palette if you switch themes often.
