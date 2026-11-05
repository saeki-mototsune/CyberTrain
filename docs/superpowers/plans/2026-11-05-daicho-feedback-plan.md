# Daicho's proposals: what CyberTrain records and checks

Source: a report from Daicho, an application built on CyberTrain 0.4.1,
dated 2026-11-05, listing what it still works around in Spinel
2026.11.04.7026 and in CyberTrain. Its Spinel items (S1 to S3 there) are
for saeki-mototsune/spinel; this plan is the CyberTrain side (its C1 to
C3). No spec: the report is the design, and every claim about CyberTrain
was checked against the code before this plan was written.

What was checked before planning (2026-11-05, Spinel 2026.11.03.7025, the
prebuilt release on this machine; the pinned 2026.11.04.7026 was then
built with `cybertrain setup` to repeat the runs):

- S1 (a method's return type does not follow a widened ivar): the C does
  not compile, as reported. S2 (`TCPSocket.new` ignores
  `connect_timeout:`): hangs, as reported. S3 (Net::HTTP against a silent
  TLS peer, `SPINEL_WORKERS=1`): on 2026.11.03.7025 and 2026.11.04.7026
  the request returned only when the peer closed the socket after 30 s,
  28 s past `open_timeout`, and the other thread ran meanwhile; the
  report's 2026.10.27.7020 run (returned at the timeout, other threads
  stalled) was not repeated here. A first run without `require "openssl"`
  failed at once with Spinel's "an https request needs the openssl
  package" and showed nothing about the timeout.
- The refusal of a never-reached class-method call: refused, as reported.
- C3's table: `allow_private:` exists per client; 1xx responses are
  skipped (up to five, 101 refused); `max_body` raises `TooLargeError`
  rather than discarding; `127.1`, `0x7f.0.0.1`, `2130706433` and
  `0177.0.0.1` are resolved by glibc's `getaddrinfo` (CRuby and Spinel
  alike) to `127.0.0.1` and refused as loopback by `HttpClient`; macOS's
  resolver does not read them as inet_aton does (found by CI's macOS job):
  `127.1` and `0x7f.0.0.1` go to DNS and fail to resolve or run past the
  deadline, and `0177.0.0.1` is read with the leading zero as decimal, an
  address that is not loopback and did not answer the connect; none
  reaches 127.0.0.1; IPv6 addresses are dialled and classified.

## Tasks

1. docs/spinel-feedback.md: items N (S1), O (S2) and P (S3), each with the
   reduced program, what happens on each build (which runs were made here
   and which are the report's), the cause and the fix the report gives,
   and what CyberTrain does today; the refusal of a never-reached
   class-method call as a note (by design, a question for upstream); rows
   in "What can go upstream", "Status at a glance" and "What CyberTrain
   still works around"; the suggested order. Check: `script/gate
   docs/spinel-feedback.md`.
2. spikes/NOTES.md: rule 72 gains the `connect_timeout:` sentence; rule 84
   records the compile-time refusal and what a test program does about
   it; "Rules by topic" lists 81. Check: `script/gate spikes/NOTES.md`.
3. test/http_client.rb: one test that the `inet_aton` spellings of a
   loopback address are refused as loopback (the report's question about
   `Net::Address`). Snapshot: `script/regen-snapshot test/http_client.rb`
   with the pinned toolchain (the TLS layer is in the program, rule 23);
   the diff must be the new `ok` line and the counts only.
4. docs/design.md, D24: an addendum recording the comparison with the
   report's `HttpPost` (what matches, and the one difference left open:
   a body past `max_body` is an error that does not carry the status).
   Check: `script/gate docs/design.md`.

Not done here, and why: C1 (moving `SPINEL_TAG`) needs a fork tag that
carries the Net::HTTP fix (matz/spinel dcc46945c), which does not exist
yet; the header comment of cybertrain/http_client.rb is still true on the
pinned release and is revised with that move. The Spinel fixes themselves
belong in saeki-mototsune/spinel.
