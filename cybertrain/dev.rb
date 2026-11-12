# The development loop (docs/design.md D12): Application#run in development
# watches the Ruby sources and the asset roots (Dev::WATCHED, in
# cybertrain/dev/watched.rb), rebuilds the server with `spin run gen && spin
# build <name> -- --incremental` (the app's package name; without the flag
# when the toolchain predates it), and replaces itself with the new
# binary; ErrorPage shows exceptions and failed builds in the browser.
# Production never loads any of it into the request path. Dev::Supervision
# (cybertrain/dev/supervision.rb) reads what `cybertrain server` hands a
# child it supervises; Roles requires that file on its own. Such a child
# learns about the background build from the supervisor's state file
# (Dev::StateFile), which ErrorPage reads through a Dev::BuildStatus.
require "cybertrain/dev/watched"
require "cybertrain/dev/watcher"
require "cybertrain/dev/rebuilder"
require "cybertrain/dev/reexec"
require "cybertrain/dev/error_page"
require "cybertrain/dev/supervision"
require "cybertrain/dev/state_file"
require "cybertrain/dev/build_status"
