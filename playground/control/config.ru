# frozen_string_literal: true

# The hosted playground's control plane (playground/README.md): Puma in
# single mode, so the limits and the session records live in this one
# process. playground/control/Dockerfile runs it; locally,
# playground/dev/compose.yml.
$stdout.sync = true
$LOAD_PATH.unshift File.expand_path("lib", __dir__)
require "play"
require "play/app"

begin
  config = Play::Config.from_env
rescue Play::Config::Error => e
  warn "error: #{e.message}"
  exit 1
end

log = Play::EventLog.new($stdout)
sessions = Play::Sessions.new(config: config, docker: Play::DockerCLI.new, probe: Play::Probe.new(config),
                              clock: Play::Clock.new, log: log)
sessions.check_availability
sessions.start_reaper
run Play::App.for(config: config, sessions: sessions, log: log)
