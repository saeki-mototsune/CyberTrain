# Rechecks for the 2026.11.15.7033 pin

The reduced programs behind [NOTES.md](../../NOTES.md), "Status on
2026.11.15.7033". The file names carry the rule number (`r49_decode.rb` is
rule 49). Each was compiled with 2026.11.15.7033, 2026.11.15.7032 and
2026.11.14.7031, with 2026.11.04.7026 as a control, and run beside CRuby
4.0.7 on macOS arm64
(`LANG=en_US.UTF-8`, `TZ=UTC`); the section gives each result. Programs that
already live in a phase folder (spikes/phase4b, spikes/phase5,
spikes/decimal) were run from there and are not copied here.

Some need more than `spinel prog.rb -o prog`:

- `r80_ffi_*.rb`: run with `SPINEL_WORKERS=1` and `SPINEL_WORKERS=2`.
- `r83_gets_flush.rb`: run under a pty; `pty_drive.rb` (CRuby) drives it.
- `r104_*.rb`: `--strict-require -I .` from the repository root.

They are not part of `spin test` or the CI gate. Binaries, generated C and
logs go outside the package tree (rule 98).
