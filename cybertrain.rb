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
# After jobs and before streams: the server role starts and stops the
# features in this order (Job, Scheduler, Background, Stream::Poller), as
# it did before they were optional.
require "cybertrain/feeds"
require "cybertrain/streams"
require "cybertrain/mailer"
require "cybertrain/mailer/later"
require "cybertrain/cache"
require "cybertrain/rate_limit"
