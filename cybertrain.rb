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
# The order of these lines does not matter: the features run in their
# rank order (Feature#feature_rank), so the server role starts and stops
# Job, Scheduler, Background, Stream::Poller in this order, as it did
# before they were optional.
require "cybertrain/feeds"
require "cybertrain/streams"
require "cybertrain/mailer"
require "cybertrain/mailer/later"
require "cybertrain/cache"
require "cybertrain/rate_limit"
