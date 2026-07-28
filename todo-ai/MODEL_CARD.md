# todo-ai model card

## Status

The packaged `todo-ai-tiny-conv-0.2.0` artifact is an engineering candidate. It
is suitable for end-to-end integration testing but is not approved for a
production release: it is evaluated only against the generator that produced its
training data, and a synthetic evaluation cannot stand in for people.

## Purpose

The model extracts structured evidence for one proposed `todo.txt` task:
outcome, task text, priority, project, context, date and time phrases, and a
structured recurrence. It also receives bounded inventories of existing project
and context names so it can prefer metadata already used by the open document.

The model does not render a task line, resolve dates, mutate files, call
networks, or execute commands. Deterministic Lua policy validates the evidence,
resolves phrases against the reference date, and returns a structured
specification to Taskle's Add bar. Taskle owns serialization and ordinary task
creation; the plugin's separate reviewed-draft workflow uses the same validated
specification. `CONTRACT.md` defines the seam in full.

## Architecture

- 129,459-parameter byte-level encoder: byte, position and inventory
  embeddings, then four residual convolutions dilated 1, 2, 4 and 8
- one label per byte, and outcome, priority and recurrence heads over the
  pooled encoding
- symmetric INT8 weights with one float32 scale per tensor
- fixed Rust inference runtime compiled to WebAssembly, importing nothing

Recurrence is a structured head rather than another byte label because its parts
overlap the phrase they are read from: in `every 3rd monday`, `monday` is both
the day the series lands on and part of the span the interval comes from, which
a single flat per-byte label cannot express.

## Training data

Training uses deterministic synthetic records generated from semantic frames
down to their bytes, so every label is known rather than annotated. Task texts
are combinations of verbs and objects rather than a fixed list, and the people
in the records are assembled from syllables, so no record carries a real name,
contact or identifier. No task text, project name or context name is taken from
anyone's list.

Wording and sentence frame are drawn independently, so a phrase is not tied to
the sentence shape it first appeared in. Position is drawn independently too: a
date, time or repetition appears before the task ("add weekly reminder to call
joshy"), in the middle of it ("call amy tomorrow to discuss plan"), and after it,
because a phrase seen in one place teaches the place rather than the phrase.

The corpus is regenerated from a seed rather than stored: 96,108 training,
11,796 validation and 12,096 test records for the packaged artifact.

## Results

Measured on the held-out test split, after quantization — the numbers describe
the artifact that ships, not a float32 model that does not:

| Measure | Value |
| --- | --- |
| Byte label accuracy | 0.9991 |
| Entity F1 | 0.9987 |
| Whole-sequence label match | 0.9580 |
| Outcome accuracy | 0.9996 |
| Priority accuracy | 1.0000 |
| Recurrence exact match | 0.9548 |

Recurrence exact match counts every record where either the model or the target
claims a repetition, and requires all five recurrence fields to agree.
Quantization costs little: whole-sequence accuracy differs from float32 by
0.0044.

## Known limitations

- Evaluated only against its own generator. A phrase nobody generated is a
  phrase the model has no reason to get right.
- No frozen, human-authored gold set, so nothing here is evidence about real
  users' phrasing.
- Confidence is uncalibrated. The policy's thresholds are safety limits, not
  probabilities anyone should read as such.
- Date and time phrases are claimed only inside the set the policy can resolve.
  The generator and `CONTRACT.md` have to move together, and a check that hands
  every generated sentence to the policy is what holds them together; neither
  side notices the drift alone.
- Voice input has no special model path; speech recognition must provide text,
  locale, timezone, and reference time through the same parsing contract.

`resources/manifest.json` carries the full per-epoch record, the corpus seed and
the artifact digest. The trainer and the runtime are both in the `todo-txt-model`
repository; only their output is installed here.
