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

    def initialize(sessions:, out:, err:, internal: nil, clock: Clock.new)
      @sessions = sessions
      @config = sessions.config
      @out = out
      @err = err
      @internal = internal || -> { fetch_internal }
      @clock = clock
    end

    # The exit status: 0 done, 1 failed, 2 bad usage.
    def run(argv)
      command, *rest = argv
      case command
      when "status" then status
      when "pause" then pause(rest.join(" ").strip)
      when "resume" then resume
      when "end" then end_one(rest)
      when "kill-all" then kill_all
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

    def pause(message)
      write_paused(message.empty? ? "for maintenance" : message)
      @out.puts "paused: #{@sessions.pause_message}. Running sessions go on; playctl resume starts accepting again."
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
      0
    end

    def end_one(args)
      handle = args.first.to_s
      return usage unless args.size == 1 && handle.match?(/\A\h{16}\z/)

      if @sessions.teardown(handle, reason: "killed")
        @out.puts "ended #{handle}"
        0
      else
        @err.puts "playctl: #{handle} is not fully removed (see the docker_error line); the reaper retries"
        1
      end
    end

    def kill_all
      write_paused("for maintenance") unless @sessions.pause_message
      File.write(File.join(@config.data_dir, "kill-all"), "")
      if @sessions.with_create_lock { @sessions.kill_all }
        @out.puts "killed every session; the playground stays paused until playctl resume"
        0
      else
        @err.puts "playctl: some sessions are not fully removed (see the docker_error lines); the reaper retries"
        1
      end
    end

    def status
      containers = @sessions.list_containers
      unless containers
        @err.puts "playctl: docker ps failed (see the docker_error line)"
        return 1
      end
      known = @internal.call
      stats = @sessions.read_stats(containers.select { |c| c[:state] == "running" }.map { |c| c[:name] })
      now = @clock.now
      @out.puts format("%-16s  %-8s  %5s  %5s  %6s  %-22s  %s", "HANDLE", "STATE", "AGE", "LEFT", "CPU", "MEMORY", "CLIENT")
      containers.sort_by { |c| c[:created_at] }.each do |c|
        cpu, memory = stats[c[:name]]
        client = known.dig(c[:handle], "client") || "-"
        @out.puts format("%-16s  %-8s  %4dm  %4dm  %6s  %-22s  %s", c[:handle], c[:state], (now - c[:created_at]) / 60,
                         [(c[:expires_at] - now) / 60, 0].max, cpu ? format("%.1f%%", cpu) : "-", memory || "-", client)
      end
      state = (message = @sessions.pause_message) ? "paused: #{message}" : "accepting"
      @out.puts "#{containers.size} of #{@config.max_sessions} sessions; #{state}"
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
