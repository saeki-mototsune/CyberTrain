# spikes

Programs kept as evidence of what the Spinel compiler does, and
[NOTES.md](NOTES.md), the numbered rules CyberTrain's code follows because
of it.

What Spinel does on a given build, what was asked upstream and whether a
behaviour is closed are in
[docs/spinel-feedback.md](../docs/spinel-feedback.md), the one record of
that. A rule or a program's header here may say what was seen on the build
it names; nothing here says where a behaviour stands on the pin. A program
here is evidence for an item of
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
- [bcrypt/](bcrypt/README.md): the programs that compared the framework's
  bcrypt verifier with roundhouse's bcrypt package (docs/design.md D97).
- `decimal/`, `phase4b/`, `phase5/`, `phase6/`: programs written while a
  part of the framework was designed, kept because a rule of NOTES.md, an
  item of docs/spinel-feedback.md or a comment in the code cites them.

A new program names its item in its header from the start, and gets a row
in the README beside it:

```ruby
# Evidence for docs/spinel-feedback.md <ID> (NOTES rule N). Kept until <ID> is closed.
```

The programs already here are not given that line: results recorded in
docs/spinel-feedback.md quote their line numbers. Their items are in the
tables, here and in the two READMEs under `rechecks/`.

## The phase programs and their items

"Item" is the identifier in docs/spinel-feedback.md, "Item register";
"Rules" the rules of NOTES.md that exist because of it. A program whose
item is a constraint or a refusal by design is permanent, and one that is
not evidence for a Spinel item stays while the file named cites it.

| Program | Item | Rules | Kept until |
| --- | --- | --- | --- |
| `decimal/float_round.rb` | AF, AH | 100 | AF and AH are closed |
| `decimal/exact_types.rb` | not a Spinel item: what the exact number types offer (docs/design.md D73) | 100 | while NOTES.md rule 100 cites it |
| `decimal/float_contract.rb` | not a Spinel item: the measurements behind docs/design.md D73 | | while test/decimal_contract.rb cites it |
| `decimal/spin.toml` | the package file the three programs are built with (`spin flags`) | | the last of them goes |
| `phase4b/make_keys.rb`, `phase4b/locale_case.rb`, `phase4b/locale_hash.rb`, `phase4b/locale_hash_split.rb` | AI | 101 | AI is closed |
| `phase4b/thread_locale.rb` | rule 102 (a record: a form that works) | 102 | while NOTES.md rule 102 cites it |
| `phase4b/dictionary_lambda.rb` | rule 103 (a record: a form that works) | 103 | while NOTES.md rule 103 cites it |
| `phase4b/spin.toml` | the package file the programs of `phase4b/` are built with | | the last of them goes |
| `phase5/assert_raises.rb` | AJ | 104 | AJ is closed |
| `phase5/backtrace.rb` | AM | 107 | AM is closed |
| `phase5/bundle_suite.sh` | AK | | AK is closed |
| `phase5/case_nullable_temp.rb` | AO | 110 | AO is closed |
| `phase5/nil_default_time.rb`, `phase5/nil_default_time_fixed.rb` | AN | 109 | AN is closed |
| `phase5/queue_in_array.rb` | AP | 117 | AP is closed |
| `phase5/stringio_threads.rb` | AQ | 116 | AQ is closed |
| `phase5/flock_fstat.rb` | AT | 112 | AT is closed |
| `phase5/durations_month.rb` | rule 105 (a constraint) | 105 | permanent |
| `phase5/durations.rb`, with `phase5/standins/` | rule 106 (a record: a form that works) | 106 | while NOTES.md rule 106, cybertrain/zoned_time.rb and script/check-reserved-names cite it |
| `phase5/time_now.rb`, with `phase5/standins/` | not a Spinel item: a `def self.now` on `Time` (docs/spinel-feedback.md, "What the rest of phase 5a met") | | nothing cites it by path; it goes with `durations.rb`, whose stand-ins it shares |
| `phase5/thread_scope.rb` | rule 114 (a constraint) | 114 | permanent |
| `phase5/logger_lock/` | rule 115 (a record: a measurement) | 115 | while NOTES.md rule 115 cites it |
| `phase5/class_app/`, with `phase5/standins/` | not a Spinel item: the class form of an application's tests, compiled | | while script/check-reserved-names cites `class_app/tests.rb` |
| `phase5/assert_select_args.rb` | not a Spinel item | | nothing in the repository cites it; to delete |
| `phase6/feature_registry.rb`, `phase6/feature_registry_ba.rb`, `phase6/feature_registry/` | rule 111 (a record: a form that works) | 111 | while NOTES.md rule 111 and cybertrain/feature.rb cite it |
| `phase6/feature_registry_rule88.rb`, `phase6/rule88_order.rb` | Z | 88, 111 | Z is closed |
| `phase6/polymorphic_reader.rb` | not a Spinel item: the polymorphic belongs_to reader and writer of docs/design.md D94 (a record: a form that works) | | while docs/design.md D94 and generator/association_emitter.rb cite it |
