# Phase 5b follow-ups: the maintainer's decisions on the open list

**Goal:** carry out the decisions the maintainer made (2026-11-14) on the list "Open for the maintainer"
in section 21 of the phase 5 spec and in pull request #232.

**Spec:** docs/superpowers/specs/2026-11-11-phase5-tests-operations-design.md, section 21 (Part 5b).
Decisions of record: docs/design.md D86 (the log line) and D88 (error reporting).

## The decisions

| # | Subject | Decision |
|---|---------|----------|
| 1 | `BuildLock#release` (answers nil) beside `Config#release` (answers a String) | Rename `BuildLock#release` |
| 2 | `RequestId` outermost in the supervised development stack | Stays |
| 3 | The dedupe key of a job's failure | Add the job's id (not the attempt) |
| 4 | `Application.new(config:)` and the sender reading `Cybertrain.config` | Stays |
| 5 | A Sentry host on a private network needs `http_allow_private` | Stays |
| 6 | Model columns named `request_id`, `release`, `handle` | gen refuses one only when its type differs from the framework method's |
| 7 | `discard_on Cybertrain::RecordNotFound` | Allowed: the framework's exception classes not named `...Error` join the list |
| 8 | An exception while a streamed body is written | Reported |
| 9 | Exception messages are sent unfiltered | A hook that runs before an event is handed on: it can change the event or drop it |
| 10 | Text log lines write a message's newlines as they are | Always escaped: one event, one line |

## Tasks

Each task is independent of the others in the files it owns; the documents come last.

### Task A: rename `BuildLock#release`, and the job macros' exception list (decisions 1, 7)
- Rename `BuildLock#release` to a name no other class defines (`unlock` if free); update every caller, the
  CRuby tests and `script/check-reserved-names` (the `release` row loses the file).
- `Gen::JobScan::FRAMEWORK_ERRORS` lists every framework exception class a job macro may name, not only
  those named `...Error`: `Cybertrain::RecordNotFound` and its like. test/gen_jobs.rb checks the list
  against the source by the new rule.
- examples/blog: `NotifyCommentJob` uses `discard_on Cybertrain::RecordNotFound` and no class of its own.

### Task B: text log lines escape newlines (decision 10)
- In a text line, a line feed in the message or in a tag is written as the two characters `\n`, a carriage
  return as `\r`. Nothing else changes; JSON lines are as they were.
- Where the framework itself logs a message of several lines on purpose, it logs one line per line.

### Task C: gen and the three column names (decision 6)
- A model column named like a framework method with one fixed return type is accepted when the column's
  Ruby type is that type, and refused by gen with a message naming the column, its type and the method
  when it is not. A name whose framework method has no single type is reserved outright.

### Task D: the reporter (decisions 3, 8, 9)
- A job failure's dedupe key includes the job's id: two jobs of one kind failing alike are two reports;
  two attempts of one job within the window are one.
- An exception while a streamed or upgraded body is written is reported, with the request's id. The HTTP
  layer still loads alone (script/check-http-layer).
- `Cybertrain.error` takes filters that run on the delivery thread before subscribers and the sender; a
  filter can change the event's message and context or drop the event. The framework's own log line is not
  filtered.

### Task E: documents
- Guides in en/ja/zh/fr/ru, docs/design.md, the spec's section 21 (the open list becomes what was decided),
  spikes/NOTES.md for anything new that Spinel taught.
