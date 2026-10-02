# frozen_string_literal: true

require_relative "test_helper"

class SessionsTest < Minitest::Test
  include PlayTestHelpers

  ROUTER = "f00dbabe00000001"

  def setup
    @docker = FakeDocker.new
    @docker.default("ps routers", FakeDocker.ok("#{ROUTER}\n"))
    @clock = FakeClock.new
    @probe = FakeProbe.new(ready_after: 2)
    @log = StringIO.new
  end

  def sessions(env = {})
    @sessions ||= Play::Sessions.new(config: play_config(env), docker: @docker, probe: @probe, clock: @clock,
                                     log: Play::EventLog.new(@log))
  end

  def container(handle, state, created: @clock.now - 100, expires: @clock.now + 1700)
    "c#{handle}\tctplay-s-#{handle}\t#{state}\t#{handle}\t#{created}\t#{expires}\n"
  end

  def network(handle, created: @clock.now - 100)
    "n#{handle}\tctplay-n-#{handle}\t#{handle}\t#{created}\n"
  end

  # [sid, pid] from the last `docker run`.
  def ids
    argv = @docker.calls_for("run").last
    argv.each_cons(2).select { |flag, _| flag == "--network-alias" }.map { |_, value| value[2..] }
  end

  def handle_of_last_network
    @docker.calls_for("network create").last.last.delete_prefix("ctplay-n-")
  end

  def assert_removed(handle)
    assert_includes @docker.calls, ["docker", "rm", "--force", "ctplay-s-#{handle}"]
    inspected = @docker.calls.include?(Play::Templates.network_containers(handle: handle))
    removed = @docker.calls.include?(["docker", "network", "rm", "ctplay-n-#{handle}"])
    assert inspected && removed, "the network ctplay-n-#{handle} was not removed"
  end

  # ---- creation ----------------------------------------------------------

  def test_create_lists_creates_attaches_runs_then_waits_for_the_router
    result = sessions.create("203.0.113.7")

    assert_kind_of Play::Sessions::Created, result
    assert_equal ["ps sessions", "ps routers", "network ls", "network create", "network connect", "run"], @docker.keys
    sid, pid = ids
    assert_match(/\A[0-9a-f]{32}\z/, sid)
    assert_match(/\A[0-9a-f]{32}\z/, pid)
    refute_equal sid, pid
    handle = Digest::SHA256.hexdigest(sid)[0, 16]
    assert_equal handle, result.handle
    assert_equal ["docker", "network", "connect", "ctplay-n-#{handle}", ROUTER], @docker.calls_for("network connect").first
    assert_includes @docker.calls_for("network create").first, "10.250.0.0/28"
    assert_equal sessions.config.editor_url(sid), result.editor_url
    assert_equal [sid, sid], @probe.calls
    assert_equal "play event=created handle=#{handle} subnet=10.250.0.0/28 ready_ms=250 live=1/5\n", @log.string
  end

  def test_the_next_session_gets_the_next_free_subnet
    @docker.default("network ls", FakeDocker.ok(network("a" * 16) + network("b" * 16)))
    @docker.on("network inspect", FakeDocker.ok("10.250.0.0/28\n"), FakeDocker.ok("10.250.0.32/28\n"))
    sessions.create("203.0.113.7")
    assert_includes @docker.calls_for("network create").first, "10.250.0.16/28"
  end

  def test_pool_overlaps_moves_on_and_gives_up_after_three
    overlap = FakeDocker.fail("Error response from daemon: invalid pool request: Pool overlaps with other one on this address space")
    @docker.on("network create", overlap, overlap)
    assert_kind_of Play::Sessions::Created, sessions.create("203.0.113.7")
    subnets = @docker.calls_for("network create").map { |argv| argv[argv.index("--subnet") + 1] }
    assert_equal ["10.250.0.0/28", "10.250.0.16/28", "10.250.0.32/28"], subnets

    @docker.on("network create", overlap, overlap, overlap)
    refusal = sessions.create("198.51.100.1")
    assert_equal :failed, refusal.reason
    assert_equal 6, @docker.calls_for("network create").size
    assert_empty(@docker.calls_for("run").drop(1))
  end

  # ---- refusals: no Docker call but the listings --------------------------

  def test_paused_refuses_without_touching_docker
    File.write(File.join(sessions.config.data_dir, "paused"), "maintenance until 14:00 UTC\n")
    refusal = sessions.create("203.0.113.7")
    assert_equal [:paused, 300, "Maintenance until 14:00 UTC"], [refusal.reason, refusal.retry_after, refusal.message]
    assert_empty @docker.calls
    assert_includes @log.string, "play event=refused reason=paused live=0/5\n"
  end

  def test_full_counts_starting_containers_too
    @docker.default("ps sessions", FakeDocker.ok(container("a" * 16, "running") + container("b" * 16, "created")))
    refusal = sessions("PLAY_MAX_SESSIONS" => "2").create("203.0.113.7")
    assert_equal [:full, 60], [refusal.reason, refusal.retry_after]
    assert_equal ["ps sessions"], @docker.keys
  end

  def test_no_router_refuses_before_creating_anything
    @docker.default("ps routers", FakeDocker.ok(""))
    refusal = sessions.create("203.0.113.7")
    assert_equal [:unavailable, 300, "It is starting up"], [refusal.reason, refusal.retry_after, refusal.message]
    assert_equal ["ps sessions", "ps routers"], @docker.keys
  end

  def test_one_live_session_per_client_and_an_ipv6_64_is_one_client
    key = ->(ip) { Play::Limits.client_key({ "HTTP_CF_CONNECTING_IP" => ip }, "HTTP_CF_CONNECTING_IP") }
    assert_kind_of Play::Sessions::Created, sessions.create(key.call("2001:db8:1:2::a"))
    calls = @docker.calls.size
    @clock.advance(60)

    refusal = sessions.create(key.call("2001:db8:1:2:ffff::b"))
    assert_equal :per_ip, refusal.reason
    assert_equal 1740, refusal.retry_after
    assert_equal 1_800_001_800, refusal.ends_at
    assert_equal calls, @docker.calls.size
    assert_kind_of Play::Sessions::Created, sessions.create(key.call("2001:db8:1:3::a"))
  end

  def test_successful_creations_per_client_are_limited_in_a_sliding_window
    s = sessions("PLAY_CREATE_LIMIT" => "2", "PLAY_MAX_SESSIONS_PER_IP" => "5")
    assert_kind_of Play::Sessions::Created, s.create("203.0.113.7")
    @clock.advance(100)
    assert_kind_of Play::Sessions::Created, s.create("203.0.113.7")
    calls = @docker.calls.size

    refusal = s.create("203.0.113.7")
    assert_equal [:rate, 500], [refusal.reason, refusal.retry_after]
    assert_equal calls, @docker.calls.size
    @clock.advance(500)
    assert_kind_of Play::Sessions::Created, s.create("203.0.113.7")
  end

  def test_a_refused_attempt_does_not_count
    @docker.on("ps sessions", FakeDocker.ok(container("a" * 16, "running")))
    s = sessions("PLAY_MAX_SESSIONS" => "1", "PLAY_CREATE_LIMIT" => "1")
    assert_equal :full, s.create("203.0.113.7").reason
    assert_kind_of Play::Sessions::Created, s.create("203.0.113.7")
  end

  # ---- failures leave nothing behind ---------------------------------------

  def test_a_failing_step_removes_the_new_session
    {
      "network create" => FakeDocker.fail("Error response from daemon: failed to create network"),
      "network connect" => FakeDocker.fail("Error response from daemon: container not running"),
      "run" => FakeDocker.fail("docker: Error response from daemon: Conflict."),
      "run " => :timeout
    }.each do |step, answer|
      setup
      @docker.on(step.strip, answer)
      refusal = sessions.create("203.0.113.7")
      assert_equal [:failed, 60], [refusal.reason, refusal.retry_after], step
      assert_removed(handle_of_last_network)
      assert_match(/play event=docker_error step=\w+ handle=#{handle_of_last_network} status=-?\d+ /, @log.string)
      assert_match(/play event=ended handle=#{handle_of_last_network} reason=failed age_s=0/, @log.string)
      assert_empty sessions.internal_list, step
      @sessions = nil
    end
  end

  def test_not_ready_in_time_removes_the_session
    @probe = FakeProbe.new(ready_after: nil)
    refusal = sessions("PLAY_READY_TIMEOUT" => "30").create("203.0.113.7")
    assert_equal :failed, refusal.reason
    assert_equal 121, @probe.calls.size
    assert_removed(handle_of_last_network)
    assert_includes @log.string, "reason=failed"
  end

  def test_a_missing_image_pauses_creation_until_it_is_back
    @docker.on("run", FakeDocker.fail("docker: Error response from daemon: No such image: ghcr.io/example/web@sha256:0123"))
    refusal = sessions.create("203.0.113.7")
    assert_equal [:unavailable, 300, "Its session image is missing"], [refusal.reason, refusal.retry_after, refusal.message]
    assert_removed(handle_of_last_network)
    assert_includes @log.string, "play event=unavailable reason=image_missing image=ghcr.io/example/cybertrain-playground-web@sha256:0123"

    calls = @docker.calls.size
    assert_equal :unavailable, sessions.create("198.51.100.1").reason
    assert_equal calls, @docker.calls.size

    @clock.advance(10)
    sessions.reap
    assert_includes @log.string, "play event=available\n"
    assert_kind_of Play::Sessions::Created, sessions.create("198.51.100.1")
  end

  def test_no_log_line_names_a_session_or_preview_id
    @docker.on("run", lambda do |argv|
      FakeDocker.fail("docker: Error response from daemon: alias #{argv[argv.index("--network-alias") + 1]} " \
                      "env #{argv.find { |a| a.start_with?("VSCODE_PROXY_URI=") }} rejected")
    end)
    sessions.create("203.0.113.7")
    sid, pid = ids
    assert_kind_of Play::Sessions::Created, sessions.create("198.51.100.1")
    sid2, pid2 = ids
    @clock.advance(1800)
    sessions.reap

    assert_includes @log.string, "alias s-<sid> env VSCODE_PROXY_URI=https://{{port}}-<pid>.play.example.test rejected"
    [sid, pid, sid2, pid2].each { |secret| refute_includes @log.string, secret }
    refute_match(/\h{32}/, @log.string)
    refute_includes @log.string, "203.0.113.7"
    refute_includes @log.string, "198.51.100.1"
  end

  # ---- teardown -------------------------------------------------------------

  def test_teardown_counts_absent_as_done
    @docker.on("rm", FakeDocker.fail("Error response from daemon: No such container: ctplay-s-#{"a" * 16}"))
    @docker.on("network inspect", FakeDocker.fail("Error response from daemon: network ctplay-n-#{"a" * 16} not found"))
    assert sessions.teardown("a" * 16, reason: "killed")
    assert_equal ["rm", "network inspect"], @docker.keys
    assert_includes @log.string, "play event=ended handle=#{"a" * 16} reason=killed\n"
  end

  def test_teardown_disconnects_every_attachment_before_removing_the_network
    @docker.on("network inspect", FakeDocker.ok("#{ROUTER} 0123abcd "))
    assert sessions.teardown("a" * 16, reason: "ttl")
    assert_equal [["docker", "network", "disconnect", "--force", "ctplay-n-#{"a" * 16}", ROUTER],
                  ["docker", "network", "disconnect", "--force", "ctplay-n-#{"a" * 16}", "0123abcd"]],
                 @docker.calls_for("network disconnect")
    assert_equal ["rm", "network inspect", "network disconnect", "network disconnect", "network rm"], @docker.keys
  end

  def test_a_failed_teardown_keeps_the_labels_for_the_next_pass
    @docker.on("network rm", FakeDocker.fail("Error response from daemon: error while removing network: network ctplay-n-x has active endpoints"))
    refute sessions.teardown("a" * 16, reason: "ttl")
    assert_match(/play event=docker_error step=network_rm handle=a{16} status=1 stderr="Error response/, @log.string)
    refute_includes @log.string, "event=ended"
  end

  # ---- the reaper -------------------------------------------------------------

  def test_reap_removes_expired_and_stopped_sessions
    @docker.default("ps sessions", FakeDocker.ok(container("a" * 16, "running", expires: @clock.now) +
                                                 container("b" * 16, "exited") + container("c" * 16, "running")))
    @docker.default("network ls", FakeDocker.ok(network("a" * 16) + network("b" * 16) + network("c" * 16)))
    assert sessions.reap
    assert_includes @log.string, "play event=ended handle=#{"a" * 16} reason=ttl age_s=100\n"
    assert_includes @log.string, "play event=ended handle=#{"b" * 16} reason=exited age_s=100\n"
    refute_includes @docker.calls, ["docker", "rm", "--force", "ctplay-s-#{"c" * 16}"]
  end

  def test_reap_removes_orphan_networks_older_than_a_minute_only
    @docker.default("network ls", FakeDocker.ok(network("a" * 16, created: @clock.now - 61) +
                                                network("b" * 16, created: @clock.now - 10)))
    sessions.reap
    assert_includes @log.string, "play event=ended handle=#{"a" * 16} reason=orphan age_s=61\n"
    refute_includes @docker.calls, ["docker", "rm", "--force", "ctplay-s-#{"b" * 16}"]
  end

  def test_a_session_whose_container_ended_by_itself_is_cleaned_up_as_idle
    created = sessions.create("203.0.113.7")
    @docker.default("network ls", FakeDocker.ok(network(created.handle, created: @clock.now)))
    sessions.reap
    assert_includes @log.string, "play event=ended handle=#{created.handle} reason=idle"
    assert_empty sessions.internal_list
  end

  def test_reap_attaches_every_running_router_once
    @docker.default("ps sessions", FakeDocker.ok(container("a" * 16, "running")))
    @docker.default("network ls", FakeDocker.ok(network("a" * 16)))
    @docker.default("ps routers", FakeDocker.ok("r1\nr2\n"))
    @docker.on("network connect", FakeDocker.ok, FakeDocker.fail("Error response from daemon: endpoint with name router already exists in network ctplay-n-x"))
    sessions.reap
    sessions.reap
    assert_equal [["docker", "network", "connect", "ctplay-n-#{"a" * 16}", "r1"],
                  ["docker", "network", "connect", "ctplay-n-#{"a" * 16}", "r2"]], @docker.calls_for("network connect")
    @docker.default("ps routers", FakeDocker.ok("r3\n"))
    sessions.reap
    assert_equal ["docker", "network", "connect", "ctplay-n-#{"a" * 16}", "r3"], @docker.calls_for("network connect").last
  end

  def test_a_restarted_control_plane_adopts_live_sessions_without_a_client
    @docker.default("ps sessions", FakeDocker.ok(container("a" * 16, "running", created: 1_799_999_000, expires: 1_800_000_800)))
    @docker.default("network ls", FakeDocker.ok(network("a" * 16)))
    sessions.reap
    assert_equal [{ handle: "a" * 16, state: "ready", created_at: 1_799_999_000, expires_at: 1_800_000_800, client: nil,
                    cpu: nil, memory: nil }], sessions.internal_list
    assert_equal 1, sessions.status[:live]
  end

  def test_the_kill_all_request_ends_everything_once
    path = File.join(sessions.config.data_dir, "kill-all")
    File.write(path, "")
    @docker.default("ps sessions", FakeDocker.ok(container("a" * 16, "running")))
    @docker.default("network ls", FakeDocker.ok(network("a" * 16) + network("b" * 16, created: @clock.now)))
    sessions.reap
    assert_includes @log.string, "handle=#{"a" * 16} reason=killed"
    assert_includes @log.string, "handle=#{"b" * 16} reason=killed"
    refute File.exist?(path)
    assert_empty @docker.calls_for("network connect")
  end

  def test_a_session_at_90_percent_cpu_ten_minutes_running_is_logged_once
    @docker.default("ps sessions", FakeDocker.ok(container("a" * 16, "running", expires: @clock.now + 3600)))
    @docker.default("network ls", FakeDocker.ok(network("a" * 16)))
    @docker.default("stats", FakeDocker.ok("ctplay-s-#{"a" * 16}\t99.8%\t420MiB / 1.5GiB\n"))
    11.times do
      sessions.reap
      @clock.advance(60)
    end
    assert_equal 11, @docker.calls_for("stats").size
    assert_equal ["play event=suspect handle=#{"a" * 16} cpu=99.8%"], @log.string.lines.map(&:chomp).grep(/suspect/)
    assert_equal [99.8, "420MiB / 1.5GiB"], sessions.internal_list.first.values_at(:cpu, :memory)
  end

  def test_up_is_healthy_while_the_reaper_reaches_docker
    refute sessions.healthy?
    assert sessions.reap
    assert sessions.healthy?
    @docker.default("ps sessions", FakeDocker.fail("Cannot connect to the Docker daemon at unix:///var/run/docker.sock"))
    @clock.advance(61)
    refute sessions.reap
    refute sessions.healthy?
  end

  def test_status_counts_live_sessions
    sessions.create("203.0.113.7")
    assert_equal({ accepting: true, paused: false, live: 1, capacity: 5, ttl_seconds: 1800 }, sessions.status)
    File.write(File.join(sessions.config.data_dir, "paused"), "")
    assert_equal({ accepting: false, paused: true, live: 1, capacity: 5, ttl_seconds: 1800 }, sessions.status)
    assert_equal "For maintenance", sessions.closed_message
  end
end
