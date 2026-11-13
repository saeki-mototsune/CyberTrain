# cybertrain: library entry (require "cybertrain")
#
# A Rails-like web application framework written natively for the Spinel
# AOT Ruby compiler. See docs/design.md for the architecture.
#
# Everything: the core and every optional subsystem. An application that
# uses only some of them requires "cybertrain/core" and their lines instead,
# and compiles less (docs/superpowers/specs/2026-11-13-optional-subsystems-design.md).
require "cybertrain/core"
require "cybertrain/jobs"
# Turbo Streams (the core still loads them today; cybertrain/streams later).
require "cybertrain/stream"
# WebSocket feeds (cybertrain/feeds later).
require "cybertrain/websocket/feed_table"
require "cybertrain/mailer"
require "cybertrain/mailer/later"
# The default store of Controller.rate_limit counts.
require "cybertrain/cache"
require "cybertrain/rate_limit"
