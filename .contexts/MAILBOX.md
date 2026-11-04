---
name: mailbox-iteration
description: >
  Run design work as an asynchronous, email-style correspondence instead of a chat.
  Each subject lives in its own mailbox directory; every iteration is a numbered
  letter that is never overwritten. Use when planning, reviewing, or evolving a
  design document across multiple rounds with a human in the loop.
---

# Mailbox iteration

A skill for conducting design work as **letters**, not as a chat. The unit of
progress is an **iteration**, and each iteration is a **file** that stays on
disk. History is preserved by construction: a later iteration never overwrites
an earlier one.

## When to use

- The work is a design document, a plan, or a review that will take more than
  one round.
- The human will answer asynchronously, possibly days apart.
- Ambiguities must be tracked explicitly across rounds rather than resolved
  silently.
- A downstream agent will implement from the final letter, so unstated
  assumptions are expensive.

Do **not** use this skill for quick one-shot questions. Those belong in chat.

## Layout

```
.mailbox/
  <subject>/
    1.md
    2.md
    ...
```

- `<subject>` is a **placeholder** for the topic, not a document name. Use a
  short kebab-case slug such as `consensus-driver`, `wal-design`,
  `front-handshake`.
- `<N>.md` is the N-th letter in that subject. Numbers are dense and monotonic;
  they are never reused.
- Different subjects never share a directory. Cross-subject references are made
  by slug, not by copying content.
- When a subject is closed, the final letter is **compiled** (not copied) into
  the canonical document location, e.g. `designs/<subject>.md`; see "Promotion
  to a design document". The mailbox directory stays as history.

## Letter format

Every letter begins with a header and ends with a pad. The body is free-form,
but the header and pad are mandatory. The human may append a `# Critical`
section below the pad (see \"Rules for the critical section\").

```markdown
# Iteration <N>

- **Subject:** <subject>
- **From:** <author role, e.g. planner | reviewer>
- **U resolved:** <comma-separated U-ids, or "none">
- **U open:** <comma-separated U-ids, or "none">
- **Next:** <one sentence: what the next iteration is expected to do>

<free-form body>

## Open questions

- **U1.** <question, one paragraph, with enough context to be answered without
  re-reading earlier letters>
- **U2.** ...

# Pad

<!-- The human fills this in place. One block per U. Empty means "still open". -->

## U1.

## U2.
```

### Rules for the body

- Anchor every ambiguity with a `U<n>` tag **inline**, at the point in the text
  where it affects the plan. Do not defer it to a section at the bottom.
- The `## Open questions` section near the end is the **index** of `U` tags: one
  short paragraph per `U`, restating the question in a self-contained way.
- Do **not** invent answers to open questions. If a decision is needed, it
  becomes a `U`. If a decision is already made by the human, restate it as a
  fact, not as a `U`.
- If the letter proposes a decision that the human did not ask for, mark it with
  a `U` and phrase it as a proposal: "Proposed: ... — confirm or override."

### Rules for the pad

- `# Pad` is always the **last** section of the letter, separated by a rule.
- It contains one block per currently open `U`, headed by `## U<n>.`.
- The human fills each block in place. A block left empty means the `U` is still
  open.
- The pad is never edited by the agent. On the next iteration, the agent reads
  the filled pad, records the resolution in the header (`U resolved`), and
  removes the corresponding blocks from the new letter's pad.

### Rules for the critical section

- The human may add a `# Critical` section **below** `# Pad` in the letter.
- It is used to confront choices — made by the agent or by the human — in
  previous iterations that must be revisited before the thread can close.
- The agent must address every item in `# Critical` in the next letter:
  restate each item, respond to it, and either resolve it or escalate it as a
  new `U`.
- A letter is not a candidate for promotion while any `# Critical` item is
  unaddressed, even if `U open` is empty. The thread continues until all
  critical items are resolved.

## Iteration protocol

1. **Agent writes letter N.** It reads letter `N-1`, the filled `# Pad` from
   `N-1`, and any referenced sources. It produces `.mailbox/<subject>/<N>.md`.
2. **Human replies in place.** They edit `# Pad` of letter `N`. They may also
   add inline comments to the body, but the pad is the authoritative channel
   for answers to `U`.
3. **Agent writes letter N+1.** It opens by copying the header shape, moving
   every answered `U` from `open` to `resolved`, and restating the resolution
   as a fact in the body (not as a `U`). It then continues the work, adding new
   `U` only for genuinely new ambiguity.
4. **Repeat** until `U open` is empty **and** every `# Critical` item raised
   by the human is resolved. Only then is the letter a candidate for promotion
   to `designs/<subject>.md`.

The protocol is **strictly sequential**. The agent never writes letter `N+1`
before the human has filled the pad of letter `N`, and the human never edits
earlier letters. Corrections are made by writing a new letter that supersedes
the earlier one, with the header noting the supersession.

## Conventions for `U` tags

- `U` ids are scoped to the subject. `U1` in `consensus-driver` is unrelated to
  `U1` in `wal-design`.
- Once assigned, a `U` id is stable. If a question is split, the parts become
  `U3a`, `U3b`. If a question is dropped, it is marked resolved with the reason
  ("dropped: superseded by U7").
- A `U` may be **blocking** (the plan cannot proceed) or **non-blocking** (the
  plan can proceed with a stated assumption). Mark blocking ones with
  `**U<n> (blocking).**` so the human knows what to answer first.

## What not to do

- Do not overwrite an earlier letter. History is the point.
- Do not resolve a `U` silently by choosing an answer. If the choice is obvious,
  propose it **as a `U`** with a one-line rationale, and let the human confirm.
- Do not mix subjects in one directory. If a letter touches two subjects, split
  it into two letters and cross-reference by slug.
- Do not promote by copying the final letter. The design document is a
  compilation: every resolved `U` is inlined as normative text, and no `U` id,
  pad, or iteration number survives into it.
- Do not use this skill for chat-shaped back-and-forth. If the human wants a
  quick answer, they will ask in chat; the mailbox is for work that accumulates.

## Promotion to a design document

When `U open` is empty and every `# Critical` item raised by the human has been
resolved:

1. **Compile, do not copy.** Write `designs/<subject>.md` as a fresh,
   self-contained document composed from the final letter, rewording and
   reordering freely while preserving every decision. Every resolved `U` is
   **inlined**: stated as plain normative fact at the point in the plan where
   the question was anchored.
2. Strip the header, the `# Pad` section, and any resolved `# Critical`
   section; drop the `## Open questions` index and every `U<n>` marker. The
   compiled document never refers to `U` ids, iteration numbers, or the pad;
   each decision appears as a plain statement of fact where it belongs in the
   design.
3. Leave the mailbox directory in place as history. Optionally add a one-line
   pointer at the top of the promoted document: `Promoted from
.mailbox/<subject>/<N>.md`.
