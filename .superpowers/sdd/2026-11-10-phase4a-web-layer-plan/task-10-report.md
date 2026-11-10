# Task 10 report: status symbols, send_data, HTTP caching (C-9, C-2, C-3)

Status: DONE

## Built

- `Controller::STATUS_SYMBOLS`: every Rack 3 symbol (100 `continue` to 511 `network_authentication_required`, 61 codes) plus the aliases `payload_too_large`, `request_entity_too_large`, `unprocessable_entity`, `request_uri_too_long`, `requested_range_not_satisfiable`.
- `Response::STATUS_TEXT`: the same 61 codes with RFC 9110 phrases (413 "Content Too Large", 422 "Unprocessable Content"). `test/server.rb` now expects `413 Content Too Large`.
- `Controller#send_data(data, filename: "", type:, disposition:, status: DEFAULT_STATUS)`.
- `UploadedFile.content_disposition_utf8(disposition, filename)`: per-character `?` fallback (a UTF-8 lead byte emits one `?`, continuation bytes none, controls `?`), `"` and `\` backslash-escaped, `filename*` percent-encoded outside attr-char, empty name gives the bare disposition. Reads the name through a fresh local (rule 62).
- `Controller#fresh_when`, `#stale?`, `#expires_in`; private helpers `apply_validators`, `validator_key`, `validator_time`, `request_fresh?`, `etag_listed?`, `strip_weak`.
- `Request.http_date` and `Request.parse_http_date` (IMF-fixdate only, own byte parser and days-from-civil arithmetic, -1 when not a date).
- `script/check-reserved-names`: NAME_HOMES row for `send_data` (Controller and Mailer's SMTP connection). `CLI::Templates::ATTACHMENT_RESERVED_ACTIONS` gained the new public and private controller names.

## Design notes and deviations

- `etag:` and `last_modified:` default to a boxed `DEFAULT_VALIDATOR = [nil, "", Model.new, Time.at(0)][0]` (the DEFAULT_STATUS pattern); `validator_key` does `case String / Model`, `validator_time` `case Time` (rule 8). A record's key is `"<pluralized underscored model_name>/<to_param>-<updated_at epoch>"` via `read_attribute(:updated_at)` (the generated override), no timestamp when the column is absent.
- SHA-256: `Crypto` exposes only HMAC and `hex`, not a plain digest, so I used `Digest::SHA256.hexdigest` directly (what `UploadedFile#sha256_hex` does).
- Freshness follows Rails' `Request#fresh?`: both validators must match when the request sends both; an unparseable If-Modified-Since counts as absent. I also restrict 304 to GET and HEAD (RFC 9110), which the brief did not state.
- `fresh_when` keeps an existing Cache-Control (from `expires_in`) and only sets the default when none is present.
- `request.rb` could not use `Cast.parse_rfc2822` (check-http-layer forbids `cybertrain/cast` there), hence the own parser.
- `send_blob` untouched.
- Implementation was written before the tests were run (tests were written in the same pass, then run); all new behaviour has a test.

## Tests

- New: `test/send_data.rb` (6 tests), `test/http_caching.rb` (8 tests, 46 assertions); grown: `test/controller_status.rb` (9), `test/http_response.rb` (23). Snapshots regenerated for these four; the only changed lines of the existing two are the added test names and counts.
- Green under `spin test`: controller_status, http_response, send_data, http_caching, send_blob, client, error_pages, http_request, server.
- `ruby script/check-reserved-names` green; `script/api-docs` 98.73% documented, no new undocumented items; `ruby script/gate` green (before the last test-only edit; re-run noted in the final message).
- Whole suite not run, as instructed. No generator emitter changed, so no fixtures regenerated.

## Fix round 1

- Freshness: a non-empty If-None-Match now decides alone (If-Modified-Since ignored, RFC 9110 13.1.3); without it a parseable If-Modified-Since decides. Test rewritten: matching ETag with an older date gives 304, mismatching ETag with a matching date gives 200, date alone gives 304. Comments corrected.
- `Request.http_digits` reads its argument through a fresh local (rule 62).
- response.rb comments: dropped 451 from the "Unknown" example, alias note now lists all five.
- `etag:` that is neither nil, a String nor a Model raises ArgumentError ("etag: must be a String or a record, got Integer"), message built into a local first; test added.
- `Response#to_http` omits Content-Type (default and explicit) and Content-Length for status 304; 204 and all other statuses unchanged. Test added; no existing snapshot changed.
