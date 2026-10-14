# todo-ai parsing contract

The plugin loads a WebAssembly runtime that carries the model, sends it one
request per parse, and receives structured evidence. The runtime never renders a
task line and the Lua policy never reads meaning out of the raw text; everything
below is the seam between them.

The one thing the policy takes off the raw text before a request is built is a
trailing `!a`..`!c` priority marker, which is a typed control token rather than
language. The runtime is therefore never sent it and never has to explain it,
`input.text` echoes the text after it was removed, and a marker the user wrote
overrides the `priority` the runtime predicts.

`init.lua` is the enforcing copy of this document. Where the two disagree, the
Lua is right.

## Runtime entry points

| Export | Input | Output |
| --- | --- | --- |
| `initialize` | model metadata JSON, a newline, then the model bytes | empty on success, otherwise an error |
| `parse` | request JSON | response JSON |

The metadata line pins the artifact the plugin expects:

```json
{"schema_version":1,"model_version":"…","weights_sha256":"…"}
```

## Request

```json
{
  "schema_version": 1,
  "text": "call joshy every 3rd monday",
  "existing": { "projects": ["Home"], "contexts": ["phone"] }
}
```

`text` is at most 160 bytes and free of control characters. The inventories are
the document's existing project and context names, sorted case-insensitively and
truncated to 16 entries or 256 bytes, whichever comes first. They exist so the
model can prefer names already in use; they are not suggestions to add.

## Response

```json
{
  "schema_version": 1,
  "input": { "text": "…", "existing": { "projects": [], "contexts": [] } },
  "prediction": {
    "outcome": { "label": "parsed", "confidence": 0.98 },
    "priority": { "label": "A", "confidence": 0.94 },
    "evidence": [
      { "label": "TASK", "start": 0, "end": 10, "text": "call joshy", "confidence": 0.99 },
      { "label": "RECURRENCE", "start": 11, "end": 27, "text": "every 3rd monday", "confidence": 0.96 }
    ],
    "recurrence": {
      "interval": { "value": 3, "confidence": 0.96 },
      "unit": { "value": "w", "confidence": 0.97 },
      "strict": { "value": true, "confidence": 0.99 },
      "anchor": { "kind": "weekday", "value": 1, "confidence": 0.96 }
    }
  }
}
```

The response is at most 64 KiB. `input` is echoed verbatim and compared against
what was sent, so a runtime that answers a different question is caught rather
than trusted.

### Outcome

`parsed`, `clarify`, `unsupported`, `multiple`, or `cancel`. Only `parsed` at
0.90 confidence or above can become a task; everything else is a verdict the
plugin shows and the Add bar keeps the user's original text.

### Evidence

Spans are byte offsets into `input.text`, half-open, ordered, and
non-overlapping. `text` must equal those bytes exactly. Anything between spans
must be an unremarkable connective (`to`, `on`, `by`, `remind me`, and the like)
or the whole proposal is refused: text nobody accounted for is text the model did
not understand.

| Label | Meaning | Effect |
| --- | --- | --- |
| `TASK` | the words the task is about | joined, in order, into the title |
| `PRIORITY` | the priority phrase | supporting evidence; the letter comes from the priority head |
| `PROJECT` | a project name | `+name`, only if the name already exists or the user typed the sigil |
| `CONTEXT` | a context name | `@name`, same rule |
| `DATE` | a calendar phrase | resolved to `due:`, and dropped from the title |
| `TIME` | a time of day | pins the task to the reference day, and stays in the title |
| `RECURRENCE` | the phrase the repetition was read from | justifies the recurrence head |

Every span needs 0.85 confidence or above. A low-confidence span is refused even
when its text looks like a date: recovering it in Lua would be the policy
guessing, which is the failure mode this split exists to prevent.

`PROJECT` and `CONTEXT` spans also carry `matches_existing`, which must agree
with the inventories that were sent.

### Recurrence

A recurrence needs both halves: a `RECURRENCE` span and the structured head.
Either one alone is refused.

| Field | Values |
| --- | --- |
| `interval` | 1 to 999 |
| `unit` | `d`, `w`, `m`, `y`, `b` (business days) |
| `strict` | `true` renders `rec:+…`, `false` renders `rec:…` |
| `anchor` | optional `{"kind":"weekday","value":1}` (Sunday is 0) or `{"kind":"day_of_month","value":3}` |

Every field carries its own confidence and is thresholded on its own at 0.90.
A series whose interval is certain and whose anchor is a guess is not a series
anyone should be given, so one unsure field refuses the whole head rather than
riding on the confidence of the fields beside it.

Strictness is the difference between repeating from the completion date and
repeating from the due date. The model states it; the policy never infers it
from wording.

The anchor is structured rather than a second span because it overlaps the
recurrence phrase — `monday` in `every 3rd monday` is both the day the series
lands on and part of the phrase the interval was read from.

## What the policy does with it

Resolution is deterministic, uses the host's reference date, and is the only
place a phrase becomes a date.

Both phrase sets first drop the words that qualify a phrase without moving the
day it names — `by`, `before`, `on`, `over`, `around`, `due`, `the` — so
`by Monday`, `on Monday` and `Monday` are one phrase rather than three.

`DATE` accepts:

| Family | Wordings |
| --- | --- |
| calendar literal | `2026-08-10`, `due:2026-08-10` |
| relative day | `today`, `tomorrow`, `day after tomorrow` |
| weekday | `Monday`, `next Monday`, `this Sunday`, and the `Mon`/`Tues`/`Thurs` abbreviations |
| weekend | `this weekend`, `over the weekend` |
| next period | `next week`, `next month`, `next year`, `this time next year` |
| offset | `in 3 days`, `in three days`, `in a month`, `three days from now` |
| closing edge | `end of week`, `month end`, `this month`, `year end`, `before July ends`, `before today ends` |
| named month | `August 1`, `August 1st`, `1 Aug`, `29 Feb 2028`, `the first of August`, `mid-August` |
| day of month | `12th`, `the 12th`, `12th of the month` |
| fixed day | `New Year's Day`, `leap day 2028` |

A weekday phrase means the next such day, never the day it is said on. A month
named without a year means the next one that has not gone past: naming January
in July means next January, not one seven months gone.

`TIME` accepts `morning`, `noon`, `midday`, `afternoon`, `evening`, `tonight`,
`night`, `midnight`, and clock readings — `7pm`, `at 7 pm`, `19:30`, `at 8:15am`,
`half past seven`, `quarter past eight`. Its own qualifiers, `at`, `in`,
`sometime` and `this`, are dropped the same way, so `sometime this morning` and
`morning` are one phrase. All of them resolve to the reference day.

todo.txt has no time field, so a `TIME` phrase stays in the task title: `due:`
records the day, and dropping the phrase would lose the only record of the hour
the user typed. A `DATE` phrase is dropped from the title instead, because
`due:` states it exactly.

Text between spans must be a connective — `to`, `by`, `remind me`, `add`,
`please`, `. Due:` and the like. Nothing that names a day, a time or a
repetition belongs in that set: a word left in a gap is a word the task never
records, so allowing `every` there would let a repetition vanish silently.

Precedence for `due:` is `DATE`, then `TIME`, then the day the recurrence anchor
first lands on. An anchor counts today as its first occurrence, so `every monday`
said on a Monday is due that day.

The model is expected to label these phrase sets; a phrase outside them fails
closed. Training vocabulary and this list have to move together.

## Worked examples

Reference date 2026-07-29, a Wednesday.

| Input | Evidence | Result |
| --- | --- | --- |
| `call amy tonight` | `TASK`, `TIME` | `call amy tonight due:2026-07-29` |
| `call amy tomorrow to discuss plan` | `TASK`, `DATE`, `TASK` | `call amy to discuss plan due:2026-07-30` |
| `call joshy weekly` | `TASK`, `RECURRENCE` + `{1, w, strict false}` | `call joshy rec:1w` |
| `call joshy every week` | `TASK`, `RECURRENCE` + `{1, w, strict}` | `call joshy rec:+1w` |
| `call joshy every monday` | `TASK`, `RECURRENCE` + `{1, w, strict, weekday monday}` | `call joshy due:2026-08-03 rec:+1w` |
| `call joshy every 3rd` | `TASK`, `RECURRENCE` + `{1, m, strict, day 3}` | `call joshy due:2026-08-03 rec:+1m` |
| `call joshy every 3rd monday` | `TASK`, `RECURRENCE` + `{3, w, strict, weekday monday}` | `call joshy due:2026-08-03 rec:+3w` |

Every row of that table is executed, along with the phrase sets above and the
corpus that trains them. All four live in the `todo-txt-model` repository:

| Test | What it pins |
| --- | --- |
| `runtime/tests/artifact.rs` | what the runtime accepts as a model artifact |
| `tests/policy_spec.lua` | the worked examples, every accepted wording, and the phrases that must stay refused |
| `tests/corpus_policy.lua` | that every parsed sentence the corpus generates survives this policy and produces the line the corpus expects |
| `host-tests/tests/end_to_end.rs` | the whole path, through the real runtime and model |

The runtime that must satisfy this document, and the model it carries, are both
built by the separate `todo-txt-model` repository — its `runtime/` crate and its
trainer. Only their output is installed here.
