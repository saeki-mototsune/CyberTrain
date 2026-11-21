# spikes

Programs kept as evidence of what the Spinel compiler does, and
[NOTES.md](NOTES.md), the numbered rules CyberTrain's code follows because
of it.

What Spinel does on a given build, what was asked upstream and whether a
behaviour is closed are in
[docs/spinel-feedback.md](../docs/spinel-feedback.md), the one record of
that; nothing here repeats it. A program here is evidence for an item of
that document and is kept until the item is closed there ("Item register"
says what closed means). A program that now prints CRuby's result is still
kept: passing is not closed.

A program's header, and the README beside it, record once the run that
produced the program and its `.expected` file: the date, the machine and
the tools. They are never updated for a later pin. What a program did on
each pin goes only to docs/spinel-feedback.md, "Status by rule".

- [rechecks/](rechecks/README.md): small programs that match CRuby, run
  together by `rechecks/run.sh`. `rechecks/differing/` holds those that
  differ from CRuby or need the framework on the load path, and
  [rechecks/2026.11.15.7033/](rechecks/2026.11.15.7033/README.md) the
  reduced programs written when that build was checked.
- `decimal/`, `phase4b/`, `phase5/`, `phase6/`: programs written while a
  part of the framework was designed, kept because a rule of NOTES.md, an
  item of docs/spinel-feedback.md or a comment in the code cites them.
