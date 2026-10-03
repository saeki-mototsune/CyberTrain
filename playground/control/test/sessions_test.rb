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

  # Runs the block with Ruby's default external encoding set to ENCODING, as
  # LANG would set it (US-ASCII when LANG is unset). Ruby warns about the
  # change under -w, so the change itself is made quietly.
  def with_default_external(encoding)
    before = Encoding.default_external
    quietly { Encoding.default_external = encoding }
    yield
  ensure
    quietly { Encoding.default_external = before }
  end

  def quietly
    verbose = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = verbose
  end

  # Holds the host-wide create lock as another process would (the other
  # control plane during a deploy, playctl kill-all) while the block runs.
  def while_another_holds_the_lock
    File.open(File.join(sessions.config.data_dir, "create.lock"), File::RDWR | File::CREAT, 0o644) do |file|
      file.flock(File::LOCK_EX)
      yield file
    end
  end

  # CLIENT's creation by S, which must come back within 5 s (a creation
  # waiting for the lock with no deadline never would).
  def create_at_once(client, s = sessions)
    creation = Thread.new { s.create(client) }
    assert creation.join(5), "the creation for #{client} is still waiting for the lock"
    creation.value
  ensure
    creation&.kill
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

  def test_a_pause_message_in_japanese_is_read_whatever_lang_says
    File.write(File.join(sessions.config.data_dir, "paused"), "メンテナンス中、14:00 UTC まで\n")
    with_default_external(Encoding::US_ASCII) do
      refusal = sessions.create("203.0.113.7")
      assert_equal [:paused, "メンテナンス中、14:00 UTC まで"], [refusal.reason, refusal.message]
      assert_equal "メンテナンス中、14:00 UTC まで", sessions.closed_message
      assert sessions.status[:paused]
    end
  end

  def test_a_creation_that_takes_the_lock_after_a_pause_is_refused_without_docker
    on_its_way = Queue.new
    random = Object.new
    random.define_singleton_method(:hex) do |n|
      on_its_way << true
      SecureRandom.hex(n)
    end
    # The real clock: the creation must really wait for the lock (its wait
    # has a deadline, which a fake clock would reach at once).
    s = Play::Sessions.new(config: play_config, docker: @docker, probe: @probe, clock: Play::Clock.new,
                           log: Play::EventLog.new(@log), random: random)
    creation = nil
    s.with_create_lock do
      # The creation passes its first pause check, then waits for the lock
      # while the operator pauses (playctl pause, or a kill-all that pauses).
      creation = Thread.new { s.create("203.0.113.7") }
      on_its_way.pop
      File.write(File.join(s.config.data_dir, "paused"), "maintenance\n")
    end
    refusal = creation.value
    assert_kind_of Play::Sessions::Refusal, refusal
    assert_equal [:paused, 300, "Maintenance"], [refusal.reason, refusal.retry_after, refusal.message]
    assert_empty @docker.calls
  end

  # ---- refusals that memory decides, before the host-wide lock -------------

  def test_a_client_with_a_live_session_is_refused_before_the_lock_without_docker
    assert_kind_of Play::Sessions::Created, sessions.create("203.0.113.7")
    @clock.advance(60)
    calls = @docker.calls.size
    refusal = while_another_holds_the_lock { create_at_once("203.0.113.7") }
    assert_equal [:per_ip, 1740], [refusal.reason, refusal.retry_after]
    assert_equal calls, @docker.calls.size
  end

  def test_a_client_past_its_rate_is_refused_before_the_lock_without_docker
    s = sessions("PLAY_CREATE_LIMIT" => "1", "PLAY_MAX_SESSIONS_PER_IP" => "5")
    assert_kind_of Play::Sessions::Created, s.create("203.0.113.7")
    calls = @docker.calls.size
    refusal = while_another_holds_the_lock { create_at_once("203.0.113.7") }
    assert_equal [:rate, 600], [refusal.reason, refusal.retry_after]
    assert_equal calls, @docker.calls.size
  end

  def test_live_records_at_the_cap_refuse_as_full_before_the_lock_without_docker
    s = sessions("PLAY_MAX_SESSIONS" => "2")
    assert_kind_of Play::Sessions::Created, s.create("203.0.113.7")
    assert_kind_of Play::Sessions::Created, s.create("198.51.100.1")
    calls = @docker.calls.size
    refusal = while_another_holds_the_lock { create_at_once("198.51.100.2") }
    assert_equal [:full, 60], [refusal.reason, refusal.retry_after]
    assert_equal calls, @docker.calls.size
    assert_includes @log.string, "play event=refused reason=full live=2/2\n"
  end

  def test_a_session_ended_by_another_process_counts_against_the_cap_until_the_next_pass
    s = sessions("PLAY_MAX_SESSIONS" => "2")
    first = s.create("203.0.113.7")
    assert_kind_of Play::Sessions::Created, s.create("198.51.100.1")
    # playctl end, another process, removed the second session: Docker lists
    # the first only, and this process learns it at the reaper's next pass.
    @docker.default("ps sessions", FakeDocker.ok(container(first.handle, "running")))
    @docker.default("network ls", FakeDocker.ok(network(first.handle)))
    calls = @docker.calls.size
    assert_equal [:full, 60], s.create("198.51.100.2").to_a.first(2)
    assert_equal calls, @docker.calls.size
    s.reap
    assert_kind_of Play::Sessions::Created, s.create("198.51.100.2")
  end

  def test_a_creation_that_cannot_have_the_lock_within_10_s_is_refused_as_failed_without_docker
    started = @clock.monotonic
    refusal = while_another_holds_the_lock { create_at_once("203.0.113.7") }
    assert_equal [:failed, 60], [refusal.reason, refusal.retry_after]
    assert_in_delta 10, @clock.monotonic - started, 0.1
    assert_empty @docker.calls
    assert_equal "play event=lock_timeout waited_s=10\nplay event=refused reason=failed live=0/5\n", @log.string
  end

  def test_a_creation_waits_for_the_lock_and_goes_on_once_it_is_released
    slept = []
    clock = FakeClock.new
    s = Play::Sessions.new(config: play_config, docker: @docker, probe: @probe, clock: clock,
                           log: Play::EventLog.new(@log))
    created = while_another_holds_the_lock do |holder|
      # The other holder lets go while the creation waits.
      clock.define_singleton_method(:sleep) do |seconds|
        slept << seconds
        holder.flock(File::LOCK_UN) if slept.size == 10
        advance(seconds)
      end
      create_at_once("203.0.113.7", s)
    end
    assert_kind_of Play::Sessions::Created, created
    assert_equal [Play::Sessions::LOCK_RETRY_EVERY] * 10, slept.first(10)
    assert_equal ["ps sessions", "ps routers", "network ls", "network create", "network connect", "run"], @docker.keys
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

  def test_a_session_ended_during_its_readiness_wait_is_not_made_ready
    @probe = FakeProbe.new(ready_after: 2) do |sid, call|
      next unless call == 2

      # Another thread's teardown of the session (kill-all, an operator's
      # end) fails at `docker rm` while the creation waits; then the probe
      # answers, since the container still runs.
      @docker.on("rm", FakeDocker.fail("Error response from daemon: removal of container ctplay-s-x is already in progress"))
      refute sessions.teardown(Play::Sessions.handle_for(sid), reason: "killed")
    end
    refusal = sessions.create("203.0.113.7")
    assert_kind_of Play::Sessions::Refusal, refusal
    assert_equal [:failed, 60], [refusal.reason, refusal.retry_after]
    handle = handle_of_last_network
    assert_equal ["ending"], sessions.internal_list.map { |s| s[:state] }
    refute_includes @log.string, "event=created"

    # The next pass repeats the teardown, for the reason it recorded.
    @docker.default("ps sessions", FakeDocker.ok(container(handle, "running")))
    @docker.default("network ls", FakeDocker.ok(network(handle)))
    sessions.reap
    assert_includes @log.string, "play event=ended handle=#{handle} reason=killed age_s=0\n"
  end

  def test_an_unexpected_error_in_a_creation_is_cleaned_up_and_logged_redacted
    @docker.on("run", lambda do |argv|
      raise "boom with #{argv[argv.index("--network-alias") + 1]} and #{argv.find { |a| a.start_with?("VSCODE_PROXY_URI=") }}"
    end)
    refusal = sessions.create("203.0.113.7")
    sid, pid = ids
    handle = handle_of_last_network
    assert_equal [:failed, 60], [refusal.reason, refusal.retry_after]
    assert_removed(handle)
    assert_empty sessions.internal_list
    assert_includes @log.string, "play event=ended handle=#{handle} reason=failed age_s=0\n"
    assert_includes @log.string, "play event=error step=create handle=#{handle} message=\"RuntimeError: boom with s-<sid> " \
                                 "and VSCODE_PROXY_URI=https://{{port}}-<pid>.play.example.test\"\n"
    [sid, pid].each { |secret| refute_includes @log.string, secret }
    refute_match(/\h{32}/, @log.string)
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

  def test_kill_all_ends_every_listed_session_and_network_in_the_teardown_order
    @docker.default("ps sessions", FakeDocker.ok(container("a" * 16, "running") + container("b" * 16, "exited")))
    @docker.default("network ls", FakeDocker.ok(network("a" * 16) + network("b" * 16) + network("c" * 16)))
    @docker.default("network inspect", FakeDocker.ok("#{ROUTER} "))
    assert sessions.kill_all
    expected = %w[a b c].flat_map do |letter|
      handle = letter * 16
      [Play::Templates.remove_container(handle: handle), Play::Templates.network_containers(handle: handle),
       Play::Templates.network_disconnect(handle: handle, container: ROUTER), Play::Templates.network_remove(handle: handle)]
    end
    assert_equal ["ps sessions", "network ls"], @docker.keys.first(2)
    assert_equal expected, @docker.calls.drop(2)
    assert_equal %w[a b c].map { |letter| "play event=ended handle=#{letter * 16} reason=killed" },
                 @log.string.lines.map(&:chomp).grep(/event=ended/)
  end

  # ---- docker output -------------------------------------------------------------

  def test_a_router_listing_word_that_is_not_an_id_reaches_no_command
    @docker.default("ps routers", FakeDocker.ok("#{ROUTER}\n--alias=evil\n"))
    created = sessions.create("203.0.113.7")
    assert_kind_of Play::Sessions::Created, created
    @docker.default("ps sessions", FakeDocker.ok(container(created.handle, "running")))
    @docker.default("network ls", FakeDocker.ok(network(created.handle)))
    @docker.default("ps routers", FakeDocker.ok("#{ROUTER}\n--alias=evil\nr2\n"))
    sessions.reap
    assert_equal [ROUTER, "r2"], @docker.calls_for("network connect").map(&:last)
    refute(@docker.calls.any? { |argv| argv.include?("--alias=evil") })
    assert_equal 2, @log.string.scan("play event=dropped step=routers count=1\n").size
    refute_includes @log.string, "evil"
  end

  def test_a_listing_byte_that_is_not_utf8_is_dropped_without_raising
    # Without LANG, Ruby labels docker's output US-ASCII.
    @docker.default("ps routers", FakeDocker.ok("#{ROUTER}\n\xFFr2\n".dup.force_encoding(Encoding::US_ASCII)))
    assert_kind_of Play::Sessions::Created, sessions.create("203.0.113.7")
    assert_equal [ROUTER], @docker.calls_for("network connect").map(&:last)
    assert_includes @log.string, "play event=dropped step=routers count=1\n"
  end

  def test_an_attachment_that_is_not_an_id_is_skipped_and_the_teardown_stays_failed
    @docker.default("network inspect", FakeDocker.ok("#{ROUTER} -x "))
    @docker.on("network rm", FakeDocker.fail("Error response from daemon: error while removing network: network ctplay-n-x has active endpoints"))
    refute sessions.teardown("a" * 16, reason: "ttl")
    assert_equal [Play::Templates.network_disconnect(handle: "a" * 16, container: ROUTER)], @docker.calls_for("network disconnect")
    refute(@docker.calls.any? { |argv| argv.include?("-x") })
    assert_includes @log.string, "play event=dropped step=inspect handle=#{"a" * 16} count=1\n"
    assert_match(/play event=docker_error step=network_rm handle=a{16} status=1 /, @log.string)
    refute_includes @log.string, "event=ended"

    # Its labels stay, so the reaper tries again.
    @docker.default("network ls", FakeDocker.ok(network("a" * 16, created: @clock.now - 61)))
    sessions.reap
    assert_equal 2, @docker.calls_for("network rm").size
    assert_includes @log.string, "play event=ended handle=#{"a" * 16} reason=orphan age_s=61\n"
  end

  def test_docker_stats_names_each_session_from_its_checked_handle
    @docker.default("ps sessions", FakeDocker.ok("c1\t-x\trunning\t#{"a" * 16}\t#{@clock.now - 100}\t#{@clock.now + 1700}\n"))
    @docker.default("network ls", FakeDocker.ok(network("a" * 16)))
    sessions.reap
    assert_equal [Play::Templates.stats(["ctplay-s-#{"a" * 16}"])], @docker.calls_for("stats")
  end

  def test_a_stray_byte_in_docker_output_does_not_stop_the_pass
    # Without LANG, Ruby labels docker's output US-ASCII; a byte that is not
    # ASCII then makes splitting and matching raise.
    odd = ->(text) { text.b.force_encoding(Encoding::US_ASCII) }
    @docker.default("ps sessions", FakeDocker.ok(odd.call(container("a" * 16, "exited") + container("b" * 16, "running") +
                                                          "c\tctplay-s-x\trunning\t\xFF\t1\t2\n")))
    @docker.default("network ls", FakeDocker.ok(odd.call("#{network("a" * 16)}#{network("b" * 16)}n\t\xFF\n")))
    @docker.on("rm", FakeDocker.fail(odd.call("Error response from daemon: No such container: \xFF")))
    @docker.default("stats", FakeDocker.ok(odd.call("ctplay-s-#{"b" * 16}\t12.5%\t420MiB / 1.5GiB\n\xFF\n")))
    assert sessions.reap
    assert_includes @log.string, "play event=ended handle=#{"a" * 16} reason=exited age_s=100\n"
    assert_equal [["b" * 16, 12.5, "420MiB / 1.5GiB"]], sessions.internal_list.map { |s| s.values_at(:handle, :cpu, :memory) }
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

  def test_an_unknown_container_still_starting_has_the_grace_of_its_network
    born = @clock.now - 10
    @docker.default("ps sessions", FakeDocker.ok(container("a" * 16, "created", created: born) +
                                                 container("b" * 16, "exited", created: born)))
    @docker.default("network ls", FakeDocker.ok(network("a" * 16, created: born) + network("b" * 16, created: born)))
    sessions.reap
    refute_includes @log.string, "handle=#{"a" * 16}"
    assert_includes @log.string, "play event=ended handle=#{"b" * 16} reason=exited age_s=10\n"

    # Still starting a minute after it was made: no creation takes that long.
    @docker.default("ps sessions", FakeDocker.ok(container("a" * 16, "created", created: born)))
    @docker.default("network ls", FakeDocker.ok(network("a" * 16, created: born)))
    @clock.advance(50)
    sessions.reap
    assert_includes @log.string, "play event=ended handle=#{"a" * 16} reason=exited age_s=60\n"
  end

  def test_a_session_whose_container_ended_by_itself_is_cleaned_up_as_idle
    created = sessions.create("203.0.113.7")
    @docker.default("network ls", FakeDocker.ok(network(created.handle, created: @clock.now)))
    sessions.reap
    assert_includes @log.string, "play event=ended handle=#{created.handle} reason=idle"
    assert_empty sessions.internal_list
  end

  def test_a_pass_during_a_creation_leaves_its_starting_container_to_it
    @probe = FakeProbe.new(ready_after: 2) do |sid, call|
      next unless call == 1

      # A pass runs while the creation waits for readiness: Docker lists its
      # network and its container, still in state `created`.
      handle = Play::Sessions.handle_for(sid)
      @docker.default("ps sessions", FakeDocker.ok(container(handle, "created", created: @clock.now)))
      @docker.default("network ls", FakeDocker.ok(network(handle, created: @clock.now)))
      sessions.reap
    end
    assert_kind_of Play::Sessions::Created, sessions.create("203.0.113.7")
    refute_includes @log.string, "event=ended"
  end

  def test_a_session_ready_between_the_listings_is_not_ended_as_idle
    created = nil
    @docker.default("network ls", lambda do |_argv|
      next FakeDocker.ok("") if created # the creation's own listing

      # A creation runs to the end after the pass listed the containers:
      # its network is in the network listing, its container is not.
      created = :creating
      created = sessions.create("203.0.113.7")
      FakeDocker.ok(network(created.handle, created: @clock.now))
    end)
    assert sessions.reap
    assert_kind_of Play::Sessions::Created, created
    refute_includes @log.string, "event=ended"
    assert_equal [[created.handle, "203.0.113.7"]], sessions.internal_list.map { |s| s.values_at(:handle, :client) }
  end

  def test_a_session_ready_during_a_pass_keeps_its_record_and_its_client
    created = nil
    @docker.default("ps routers", lambda do |_argv|
      unless created
        # A creation runs to the end after the pass listed the containers
        # and the networks: neither listing has it.
        created = :creating
        created = sessions.create("203.0.113.7")
      end
      FakeDocker.ok("#{ROUTER}\n")
    end)
    assert sessions.reap
    assert_equal [[created.handle, "203.0.113.7"]], sessions.internal_list.map { |s| s.values_at(:handle, :client) }
    assert_equal :per_ip, sessions.create("203.0.113.7").reason
  end

  def test_a_failed_teardown_of_a_failed_creation_is_retried_by_the_next_pass
    # Not ready within the first creation's second (five probes), ready on
    # the next creation's first probe.
    @probe = FakeProbe.new(ready_after: 6)
    s = sessions("PLAY_MAX_SESSIONS" => "1", "PLAY_READY_TIMEOUT" => "1")
    @docker.on("rm", FakeDocker.fail("Error response from daemon: removal of container ctplay-s-x is already in progress"))
    assert_equal :failed, s.create("203.0.113.7").reason
    handle = handle_of_last_network
    refute_includes @log.string, "event=ended"

    # Docker still runs it: it holds the only slot until a pass removes it.
    @docker.default("ps sessions", FakeDocker.ok(container(handle, "running")))
    @docker.default("network ls", FakeDocker.ok(network(handle)))
    assert_equal :full, s.create("198.51.100.1").reason
    assert s.reap
    assert_equal [Play::Templates.remove_container(handle: handle)] * 2, @docker.calls_for("rm")
    assert_includes @log.string, "play event=ended handle=#{handle} reason=failed age_s=1\n"
    @docker.default("ps sessions", FakeDocker.ok(""))
    @docker.default("network ls", FakeDocker.ok(""))
    assert_kind_of Play::Sessions::Created, s.create("198.51.100.1")
  end

  def test_a_teardown_that_left_only_the_network_is_retried_for_its_reason
    created = sessions.create("203.0.113.7")
    @docker.default("ps sessions", FakeDocker.ok(container(created.handle, "running", expires: @clock.now)))
    @docker.default("network ls", FakeDocker.ok(network(created.handle)))
    @docker.on("network rm", FakeDocker.fail("Error response from daemon: error while removing network: network ctplay-n-x has active endpoints"))
    sessions.reap
    refute_includes @log.string, "event=ended"

    # The container is gone; the network is left for the next pass.
    @docker.default("ps sessions", FakeDocker.ok(""))
    sessions.reap
    assert_equal ["play event=ended handle=#{created.handle} reason=ttl age_s=0"],
                 @log.string.lines.map(&:chomp).grep(/event=ended/)
  end

  def test_a_pass_leaves_a_teardown_that_is_still_running_to_it
    created = sessions.create("203.0.113.7")
    @docker.default("ps sessions", FakeDocker.ok(container(created.handle, "running")))
    @docker.default("network ls", FakeDocker.ok(network(created.handle)))
    # A pass runs while another thread's teardown of the session waits on
    # its `docker rm`.
    @docker.on("rm", lambda do |_argv|
      sessions.reap
      FakeDocker.ok
    end)
    assert sessions.teardown(created.handle, reason: "killed")
    assert_equal 1, @docker.calls_for("rm").size
    assert_equal ["play event=ended handle=#{created.handle} reason=killed age_s=0"],
                 @log.string.lines.map(&:chomp).grep(/event=ended/)
  end

  def test_a_teardown_that_fails_during_a_pass_is_retried_by_the_next_one_only
    created = sessions.create("203.0.113.7")
    @docker.default("network ls", FakeDocker.ok(network(created.handle)))
    failed = nil
    @docker.default("ps sessions", lambda do |_argv|
      if failed.nil?
        # Another thread's teardown begins after the pass took its snapshot,
        # and its `docker rm` fails.
        @docker.on("rm", FakeDocker.fail("Error response from daemon: removal of container ctplay-s-x is already in progress"))
        failed = !sessions.teardown(created.handle, reason: "killed")
      end
      FakeDocker.ok(container(created.handle, "running"))
    end)
    sessions.reap
    assert failed
    assert_equal 1, @docker.calls_for("rm").size, "the pass left the session to the teardown that began during it"
    sessions.reap
    assert_equal 2, @docker.calls_for("rm").size
    assert_includes @log.string, "play event=ended handle=#{created.handle} reason=killed age_s=0\n"
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

  def test_a_kill_all_request_removed_meanwhile_by_the_other_control_plane_does_not_stop_the_pass
    path = File.join(sessions.config.data_dir, "kill-all")
    File.write(path, "")
    @docker.default("ps sessions", FakeDocker.ok(container("a" * 16, "running")))
    @docker.default("network ls", FakeDocker.ok(network("a" * 16)))
    # During a deploy, the other control plane's reaper honours it first.
    @docker.on("rm", lambda do |_argv|
      File.delete(path)
      FakeDocker.ok
    end)
    assert sessions.reap
    assert_includes @log.string, "play event=ended handle=#{"a" * 16} reason=killed"
    refute File.exist?(path)
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
