# bcrypt

Programs written while docs/design.md D97 was decided (verifying the bcrypt
digests Rails' `has_secure_password` wrote). They are not evidence for an
item of docs/spinel-feedback.md: the behaviour they show is the package's,
not the compiler's.

Run on 2026-11-28 with Spinel 2026.11.27.7037 (13405b63), Linux x86_64,
GCC 13.3.0, on a 4-core cloud container. Each directory is a spin package;
`spin build` there writes `build/bin/vectors`.

| Program | What it shows |
| --- | --- |
| [framework/bin/vectors.rb](framework/bin/vectors.rb) | `Cybertrain::Bcrypt` (cybertrain/bcrypt.rb) compiled: six published vectors verify and a changed password does not (`true false`, except the vector whose password is past 72 bytes: `true true`); then the time per cost. Printed 1, 24, 89 and 335 ms for costs 4, 8, 10 and 12. |
| [package/bin/vectors.rb](package/bin/vectors.rb) | roundhouse-rb/spinel-bcrypt v0.1.1 (commit cc29f69e), the package roundhouse's generator adds for `has_secure_password`, compiled: the same vectors pass, at 1, 16, 63 and 275 ms. Then two threads hash at once, one the right password of a digest and one a wrong password of the same digest, 200 times each. With `SPINEL_WORKERS=1` none goes wrong. With `SPINEL_WORKERS=3`, two runs printed `right password refused: 31` / `wrong password accepted: 22` and 40 / 16: `sp_bcrypt.c` returns every result in one static buffer, which the OS workers share. |

package/ fetches the package from GitHub when it is built; it has no
spin.lock, and its spin.toml names the tag (spin passes `ref` to
`git clone --branch`, so it must be a tag or a branch).
