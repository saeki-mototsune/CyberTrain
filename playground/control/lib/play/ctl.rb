# frozen_string_literal: true

require "json"
require "net/http"

module Play
  # bin/playctl, the operator's commands (spec §5.9). They act on Docker and
  # the flag files in PLAY_DATA_DIR directly, so they work whether or not the
  # control plane runs; only `status` asks the running process (GET
  # /internal/sessions on 127.0.0.1:9292) for the clients' addresses.
  class Ctl
    USAGE = <<~TEXT
      usage: playctl status
             playctl pause [message]
             playctl resume
             playctl end <handle>
             playctl kill-all
    TEXT
    INTERNAL_URL = "http://127.0.0.1:9292/internal/sessions"
    # The reaper keeps a kill-all request until it has ended every session,
    # and meanwhile ends new ones too, resumed or not.
    KILL_PENDING = "playctl: a kill-all is pending: sessions are ended as they appear until it completes"
    # kill-all waits this long for every session to leave Docker's listings,
    # looking again this often.
    KILL_SETTLE = 20
    KILL_LOOK_EVERY = 0.5

    def initialize(sessions:, out:, err:, internal: nil, clock: Clock.new)
      @sessions = sessions
      @config = sessions.config
      @out = out
      @err = err
      @internal = internal || -> { fetch_internal }
      @clock = clock
    end

    # The exit status: 0 done, 1 failed, 2 bad usage. A command that takes
    # no argument refuses any (kill-all --help must not end every session).
    def run(argv)
      command, *rest = argv
      case command
      when "status" then rest.empty? ? status : usage
      when "pause" then pause(rest.join(" ").strip)
      when "resume" then rest.empty? ? resume : usage
      when "end" then end_one(rest)
      when "kill-all" then rest.empty? ? kill_all : usage
      else usage
      end
    end

    private

    def usage
      @err.print USAGE
      2
    end

    def paused_path
      File.join(@config.data_dir, "paused")
    end

    def kill_path
      File.join(@config.data_dir, "kill-all")
    end

    # On stderr, after the command's own output: status's table still ends
    # with its summary line.
    def warn_if_kill_pending
      @err.puts KILL_PENDING if File.exist?(kill_path)
    end

    # MESSAGE is the operator's text; one that starts with "-" is an option
    # given by mistake (pause --help). Its own final period is not doubled.
    def pause(message)
      return usage if message.start_with?("-")

      write_paused(message.empty? ? "for maintenance" : message)
      @out.puts "paused: #{@sessions.pause_message.delete_suffix(".")}. Running sessions go on; " \
                "playctl resume starts accepting again."
      0
    end

    def write_paused(message)
      tmp = "#{paused_path}.tmp"
      File.write(tmp, "#{message}\n")
      File.rename(tmp, paused_path)
    end

    def resume
      File.delete(paused_path) if File.exist?(paused_path)
      @out.puts "resumed: new sessions are accepted"
      warn_if_kill_pending
      0
    end

    # Handles are lower-case hex, and docker names are case-sensitive. Only a
    # session Docker has (its container or its network) is ended: teardown
    # counts every absent step as done, so a mistyped handle would otherwise
    # be reported ended while the real session runs on.
    def end_one(args)
      handle = args.first.to_s
      return usage unless args.size == 1 && handle.match?(/\A[0-9a-f]{16}\z/)

      containers = @sessions.list_containers
      return listing_failed("docker ps") unless containers

      networks = @sessions.list_networks
      return listing_failed("docker network ls") unless networks

      unless (containers + networks).any? { |item| item[:handle] == handle }
        @err.puts "playctl: no session #{handle}"
        return 1
      end

      if @sessions.teardown(handle, reason: "killed")
        @out.puts "ended #{handle}"
        0
      else
        @err.puts "playctl: #{handle} is not fully removed (see the docker_error line); the reaper retries"
        1
      end
    end

    # The running control plane's reaper honours the same request at once,
    # and a teardown of this process can meet one of its own half done (a
    # container already being removed, a network going away) and fail while
    # the removal goes on. So what this reports is what Docker's listings show
    # once the removal has settled, not how its own teardowns went.
    def kill_all
      write_paused("for maintenance") unless @sessions.pause_message
      File.write(kill_path, "")
      @sessions.with_create_lock { @sessions.kill_all }
      settle_after_kill
    end

    # Looks at the sessions' containers and networks until neither listing
    # has any, for up to KILL_SETTLE seconds; names what is left (from the
    # checked handles) if they do not empty.
    def settle_after_kill
      deadline = @clock.monotonic + KILL_SETTLE
      loop do
        containers = @sessions.list_containers
        return listing_failed("docker ps") unless containers

        networks = @sessions.list_networks
        return listing_failed("docker network ls") unless networks

        left = containers.map { |c| "ctplay-s-#{c[:handle]}" } + networks.map { |n| "ctplay-n-#{n[:handle]}" }
        if left.empty?
          @out.puts "killed every session; the playground stays paused until playctl resume"
          return 0
        end
        if @clock.monotonic >= deadline
          @err.puts "playctl: not fully removed after #{KILL_SETTLE} s: #{left.join(", ")} " \
                    "(see the docker_error lines); the reaper retries"
          return 1
        end
        @clock.sleep(KILL_LOOK_EVERY)
      end
    end

    # The docker_error line itself comes from Sessions' log.
    def listing_failed(what)
      @err.puts "playctl: #{what} failed (see the docker_error line)"
      1
    end

    def status
      containers = @sessions.list_containers
      return listing_failed("docker ps") unless containers

      known = @internal.call
      # Names made from the checked handles, not docker's output (as
      # Sessions#collect_stats does).
      running = containers.select { |c| c[:state] == "running" }
      stats = @sessions.read_stats(running.map { |c| "ctplay-s-#{c[:handle]}" })
      now = @clock.now
      @out.puts format("%-16s  %-8s  %5s  %5s  %6s  %-22s  %s", "HANDLE", "STATE", "AGE", "LEFT", "CPU", "MEMORY", "CLIENT")
      containers.sort_by { |c| c[:created_at] }.each do |c|
        cpu, memory = stats["ctplay-s-#{c[:handle]}"]
        client = known.dig(c[:handle], "client") || "-"
        @out.puts format("%-16s  %-8s  %4dm  %4dm  %6s  %-22s  %s", c[:handle], c[:state], (now - c[:created_at]) / 60,
                         [(c[:expires_at] - now) / 60, 0].max, cpu ? format("%.1f%%", cpu) : "-", memory || "-", client)
      end
      state = (message = @sessions.pause_message) ? "paused: #{message}" : "accepting"
      @out.puts "#{containers.size} of #{@config.max_sessions} sessions; #{state}"
      warn_if_kill_pending
      0
    end

    def fetch_internal
      uri = URI(INTERNAL_URL)
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.open_timeout = 2
      http.read_timeout = 2
      response = http.request(Net::HTTP::Get.new(uri.request_uri))
      return {} unless response.code == "200"

      JSON.parse(response.body).to_h { |entry| [entry["handle"], entry] }
    rescue StandardError
      {}
    end
  end
end
