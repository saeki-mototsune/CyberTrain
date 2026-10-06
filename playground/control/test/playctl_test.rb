# frozen_string_literal: true

require_relative "test_helper"
require "open3"

class PlayctlTest < Minitest::Test
  include PlayTestHelpers

  H = "a1b2c3d4e5f60718"

  def setup
    @docker = FakeDocker.new
    @out = StringIO.new
    @err = StringIO.new
    @clock = FakeClock.new
  end

  def ctl(internal: -> { {} })
    sessions = Play::Sessions.new(config: play_config, docker: @docker, probe: nil, clock: @clock,
                                  log: Play::EventLog.new(@out))
    Play::Ctl.new(sessions: sessions, out: @out, err: @err, internal: internal, clock: @clock)
  end

  def paused_path
    File.join(play_config.data_dir, "paused")
  end

  def kill_path
    File.join(play_config.data_dir, "kill-all")
  end

  KILL_PENDING = "playctl: a kill-all is pending: sessions are ended as they appear until it completes\n"

  def test_pause_and_resume_write_and_remove_the_flag
    assert_equal 0, ctl.run(%w[pause maintenance until 14:00 UTC])
    assert_equal "maintenance until 14:00 UTC\n", File.read(paused_path)
    assert_includes @out.string, "paused: Maintenance until 14:00 UTC."
    assert_equal 0, ctl.run(["pause"])
    assert_equal "for maintenance\n", File.read(paused_path)
    assert_equal 0, ctl.run(["resume"])
    refute File.exist?(paused_path)
    assert_equal 0, ctl.run(["resume"])
    assert_empty @docker.calls
  end

  def test_end_tears_down_one_session
    @docker.default("ps sessions", FakeDocker.ok("c#{H}\tctplay-s-#{H}\trunning\t#{H}\t1\t2\n"))
    assert_equal 0, ctl.run(["end", H])
    assert_equal ["ps sessions", "network ls", "rm", "network inspect", "network rm"], @docker.keys
    assert_includes @out.string, "play event=ended handle=#{H} reason=killed"
    assert_includes @out.string, "ended #{H}\n"
  end

  # A well-formed handle that Docker does not have: teardown would count
  # every step as done and say "ended" while the real session runs on.
  def test_end_refuses_a_handle_that_no_listing_has
    assert_equal 1, ctl.run(["end", H])
    assert_equal ["ps sessions", "network ls"], @docker.keys
    assert_equal "playctl: no session #{H}\n", @err.string
    refute_includes @out.string, "ended"
  end

  def test_end_finds_a_session_that_only_has_its_network_left
    @docker.default("network ls", FakeDocker.ok("n#{H}\tctplay-n-#{H}\t#{H}\t1\n"))
    assert_equal 0, ctl.run(["end", H])
    assert_includes @out.string, "ended #{H}\n"
  end

  def test_end_fails_when_docker_cannot_list
    @docker.default("ps sessions", FakeDocker.fail("Cannot connect to the Docker daemon"))
    assert_equal 1, ctl.run(["end", H])
    assert_includes @out.string, "play event=docker_error step=ps status=1"
    assert_equal "playctl: docker ps failed (see the docker_error line)\n", @err.string
    assert_equal ["ps sessions"], @docker.keys
  end

  def test_end_takes_exactly_one_handle
    ["end", "end #{H} #{H}", "end ../etc", "end ctplay-s-#{H}", "end #{H.upcase}x"].each do |line|
      assert_equal 2, ctl.run(line.split), line
    end
    assert_includes @err.string, "usage: playctl status"
    assert_empty @docker.calls
  end

  # Handles are lower-case, and docker names are case-sensitive: an upper-case
  # one would end nothing (docker rm --force of a missing name succeeds).
  def test_end_refuses_an_upper_case_handle
    assert_equal 2, ctl.run(["end", H.upcase])
    assert_includes @err.string, "usage: playctl status"
    assert_empty @docker.calls
  end

  def test_kill_all_pauses_requests_the_reaper_and_ends_everything
    # Listed for kill-all's own pass; the listings that follow find nothing.
    @docker.on("ps sessions", FakeDocker.ok("c#{H}\tctplay-s-#{H}\trunning\t#{H}\t1\t2\n"))
    @docker.on("network ls", FakeDocker.ok("n#{H}\tctplay-n-#{H}\t#{H}\t1\n"))
    assert_equal 0, ctl.run(["kill-all"])
    assert_equal "for maintenance\n", File.read(paused_path)
    assert File.exist?(File.join(play_config.data_dir, "kill-all"))
    assert_includes @docker.calls, ["docker", "rm", "--force", "ctplay-s-#{H}"]
    assert_includes @out.string, "killed every session; the playground stays paused until playctl resume"
  end

  # The running control plane's reaper honours the same request, and a
  # teardown of playctl's can meet one of its half done: kill-all reports what
  # the listings show once the removal settles, not how its own teardowns went.
  def test_kill_all_waits_for_the_removal_to_settle_and_then_reports_it
    network = FakeDocker.ok("n#{H}\tctplay-n-#{H}\t#{H}\t1\n")
    @docker.on("ps sessions", FakeDocker.ok("c#{H}\tctplay-s-#{H}\trunning\t#{H}\t1\t2\n"))
    # kill-all's own pass, then a first look that still finds the network
    # (the reaper is removing it); the second look finds nothing.
    @docker.on("network ls", network, network)
    @docker.on("rm", FakeDocker.fail("Error response from daemon: removal of container ctplay-s-#{H} " \
                                     "is already in progress"))
    started = @clock.monotonic
    assert_equal 0, ctl.run(["kill-all"])
    assert_includes @out.string, "killed every session; the playground stays paused until playctl resume\n"
    assert_empty @err.string
    assert_equal [3, 3], [@docker.calls_for("ps sessions").size, @docker.calls_for("network ls").size]
    assert_in_delta 0.5, @clock.monotonic - started, 0.01
  end

  def test_kill_all_fails_after_20_s_naming_what_is_still_listed
    busy = "Error response from daemon: error while removing network: network ctplay-n-#{H} has active endpoints"
    @docker.default("network ls", FakeDocker.ok("n#{H}\tctplay-n-#{H}\t#{H}\t1\n"))
    @docker.default("network rm", FakeDocker.fail(busy))
    started = @clock.monotonic
    assert_equal 1, ctl.run(["kill-all"])
    assert_in_delta 20, @clock.monotonic - started, 0.5
    assert_equal "playctl: not fully removed after 20 s: ctplay-n-#{H} (see the docker_error lines); " \
                 "the reaper retries\n", @err.string
    refute_includes @out.string, "killed every session"
  end

  def test_kill_all_stops_waiting_when_docker_cannot_list
    @docker.default("ps sessions", FakeDocker.fail("Cannot connect to the Docker daemon"))
    assert_equal 1, ctl.run(["kill-all"])
    assert_equal "playctl: docker ps failed (see the docker_error line)\n", @err.string
    assert_equal 2, @docker.calls_for("ps sessions").size
  end

  def test_kill_all_keeps_an_existing_pause_message
    File.write(paused_path, "incident\n")
    assert_equal 0, ctl.run(["kill-all"])
    assert_equal "incident\n", File.read(paused_path)
  end

  def test_status_lists_sessions_with_their_clients
    @docker.default("ps sessions", FakeDocker.ok("c#{H}\tctplay-s-#{H}\trunning\t#{H}\t#{@clock.now - 720}\t#{@clock.now + 1080}\n"))
    @docker.default("stats", FakeDocker.ok("ctplay-s-#{H}\t12.5%\t420MiB / 1.5GiB\n"))
    assert_equal 0, ctl(internal: -> { { H => { "client" => "203.0.113.7" } } }).run(["status"])
    lines = @out.string.lines.map(&:rstrip)
    assert_match(/\AHANDLE +STATE +AGE +LEFT +CPU +MEMORY +CLIENT\z/, lines[0])
    assert_equal "#{H}  running     12m    18m   12.5%  420MiB / 1.5GiB         203.0.113.7", lines[1]
    assert_equal "1 of 5 sessions; accepting", lines[2]
  end

  # docker stats gets names made from the checked handles, not docker's own
  # output (as Sessions#collect_stats does).
  def test_status_names_the_containers_for_docker_stats_from_their_handles
    @docker.default("ps sessions", FakeDocker.ok("c#{H}\tsomething-else\trunning\t#{H}\t#{@clock.now}\t#{@clock.now + 60}\n"))
    @docker.default("stats", FakeDocker.ok("ctplay-s-#{H}\t3.0%\t1MiB / 1.5GiB\n"))
    assert_equal 0, ctl.run(["status"])
    assert_equal "ctplay-s-#{H}", @docker.calls_for("stats").last.last
    assert_includes @out.string.lines[1], "3.0%"
  end

  # A kill-all request stays until the reaper has ended every session, and
  # meanwhile ends new ones too, resumed or not: status and resume say so.
  def test_status_warns_while_a_kill_all_is_pending
    assert_equal 0, ctl.run(["status"])
    assert_empty @err.string
    File.write(kill_path, "")
    assert_equal 0, ctl.run(["status"])
    assert_equal "0 of 5 sessions; accepting\n", @out.string.lines.last
    assert_equal KILL_PENDING, @err.string
  end

  def test_resume_warns_while_a_kill_all_is_pending
    File.write(paused_path, "incident\n")
    File.write(kill_path, "")
    assert_equal 0, ctl.run(["resume"])
    assert_equal "resumed: new sessions are accepted\n", @out.string
    assert_equal KILL_PENDING, @err.string
    refute File.exist?(paused_path)
  end

  def test_unknown_command_is_a_usage_error
    assert_equal 2, ctl.run([])
    assert_equal 2, ctl.run(["start"])
  end

  # A command without arguments takes none: kill-all --help must not end
  # every session.
  def test_commands_without_arguments_refuse_extra_ones
    File.write(paused_path, "incident\n")
    [%w[kill-all --help], %w[status x], %w[resume x]].each do |argv|
      assert_equal 2, ctl.run(argv), argv.join(" ")
    end
    assert_empty @docker.calls
    assert_equal "incident\n", File.read(paused_path)
    refute File.exist?(kill_path)
    assert_includes @err.string, "usage: playctl status"
  end

  def test_pause_refuses_a_message_that_starts_with_a_dash
    assert_equal 2, ctl.run(%w[pause --help])
    refute File.exist?(paused_path)
    assert_includes @err.string, "usage: playctl status"
  end

  def test_pause_does_not_double_a_period
    assert_equal 0, ctl.run(%w[pause back at 14:00 UTC.])
    assert_includes @out.string, "paused: Back at 14:00 UTC. Running sessions go on"
    refute_includes @out.string, "UTC.."
  end

  def test_the_script_reports_a_missing_setting_and_bad_usage
    script = File.expand_path("../bin/playctl", __dir__)
    out, status = Open3.capture2e({ "PLAY_PUBLIC_URL" => nil }, RbConfig.ruby, script, "status")
    assert_equal [1, "error: PLAY_PUBLIC_URL is required\n"], [status.exitstatus, out]
    env = { "PLAY_PUBLIC_URL" => "https://play.example.test", "PLAY_SESSION_IMAGE" => "x@sha256:1",
            "PLAY_ABUSE_CONTACT" => "a@example.test", "PLAY_DATA_DIR" => play_config.data_dir }
    out, status = Open3.capture2e(env, RbConfig.ruby, script, "frobnicate")
    assert_equal 2, status.exitstatus
    assert_includes out, "usage: playctl status"
  end
end
