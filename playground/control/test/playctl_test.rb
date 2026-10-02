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
    assert_equal 0, ctl.run(["end", H])
    assert_equal ["rm", "network inspect", "network rm"], @docker.keys
    assert_includes @out.string, "play event=ended handle=#{H} reason=killed"
    assert_includes @out.string, "ended #{H}\n"
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
    @docker.default("ps sessions", FakeDocker.ok("c#{H}\tctplay-s-#{H}\trunning\t#{H}\t1\t2\n"))
    @docker.default("network ls", FakeDocker.ok("n#{H}\tctplay-n-#{H}\t#{H}\t1\n"))
    assert_equal 0, ctl.run(["kill-all"])
    assert_equal "for maintenance\n", File.read(paused_path)
    assert File.exist?(File.join(play_config.data_dir, "kill-all"))
    assert_includes @docker.calls, ["docker", "rm", "--force", "ctplay-s-#{H}"]
    assert_includes @out.string, "killed every session; the playground stays paused until playctl resume"
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
