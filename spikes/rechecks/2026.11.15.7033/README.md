# Rechecks for the 2026.11.15.7033 pin

The reduced programs behind
[docs/spinel-feedback.md](../../../docs/spinel-feedback.md), "Status by
rule", "On 2026.11.15.7033". Each program here is evidence for an item of
that document, named in the table below, and is kept until that item is
closed there ("Item register" says what closed means). A program that now
prints CRuby's result is still kept: passing is not closed.

The file names carry the rule number (`r49_decode.rb` is
rule 49). Each was compiled with 2026.11.15.7033, 2026.11.15.7032 and
2026.11.14.7031, with 2026.11.04.7026 as a control, and run beside CRuby
4.0.7 on macOS arm64
(`LANG=en_US.UTF-8`, `TZ=UTC`); that section gives each result, and this
file none. Programs that
already live in a phase folder (spikes/phase4b, spikes/phase5,
spikes/decimal) were run from there and are not copied here.

Some need more than `spinel prog.rb -o prog`:

- `r80_ffi_*.rb`: run with `SPINEL_WORKERS=1` and `SPINEL_WORKERS=2`.
- `r83_gets_flush.rb`: run under a pty; `pty_drive.rb` (CRuby) drives it.
- `r104_*.rb`: `--strict-require -I .` from the repository root.

They are not part of `spin test` or the CI gate. Binaries, generated C and
logs go outside the package tree (rule 98).

## Programs and their items

| Program | Item | Rules | Kept until |
| --- | --- | --- | --- |
| `r02_instance_exec.rb`, `r02_instance_exec_stored.rb` | rule 2 (a constraint) | 2 | permanent |
| `r25_to_i.rb` | D (a constraint) | 25 | permanent |
| `r49_decode.rb` | AC | 49 | AC is closed |
| `r52_byteindex.rb` | AD | 52 | AD is closed |
| `r54_superclass.rb` | AE | 54 | AE is closed |
| `r78_puts_nil_io.rb` | K | 78 | K is closed |
| `r79_raise_block.rb` | rule 79 | 79 | rule 79 is closed |
| `r80_ffi_blocking.rb`, `r80_ffi_none.rb`, `r80_ffi_offload.rb` | AB | 80 | AB is closed |
| `r81_rescue_relative.rb` | R | 81 | R is closed |
| `r82_module_ivar_lambda.rb` | Y | 82 | Y is closed |
| `r83_gets_flush.rb`, with `pty_drive.rb` | M | 83 | M is closed |
| `r86_date_range.rb`, `r86_range_boxed.rb`, `r86_range_direct.rb` | Q | 86 | Q is closed |
| `r88_stored_block_override.rb` | Z | 88 | Z is closed |
| `r89_rescue_gone.rb`, `r89_rescue_missing.rb` | R | 89 | R is closed |
| `r90_yield_arg.rb` | S | 90 | S is closed |
| `r91_exit_thread.rb` | T | 91 | T is closed |
| `r92_concern_keeps_block.rb`, `r92_concern_refusal.rb` | rule 92 (a refusal by design) | 92 | permanent |
| `r93_def_in_block.rb` | U | 93 | U is closed |
| `r100_float_round.rb` | AF | 100 | AF is closed |
| `r104_builtin_superclass.rb`, `r104_builtin_variants.rb` | AJ | 104 | AJ is closed |
