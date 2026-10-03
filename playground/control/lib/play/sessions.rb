# frozen_string_literal: true

require "digest"
require "fileutils"
require "securerandom"
require "set"

module Play
  # The sessions (spec §5.3, §5.5-§5.9, §5.12): creation under the create
  # lock, teardown, the reaper that reconciles memory with Docker, and the
  # pause and kill-all switches. Docker is the truth (labels
  # cybertrain-play.*); the records here serve the limits, the status and the
  # operator. The session and preview ids live only inside #create: they are
  # in the argv of `docker run` and in the editor URL it returns, and never in
  # a record or a log line.
  class Sessions
    # reason: why it is ending, set when its teardown begins; the reaper
    # repeats a failed teardown for that reason.
    Session = Struct.new(:handle, :subnet, :created_at, :expires_at, :client, :state, :cpu, :memory, :hot, :reason)
    Created = Struct.new(:editor_url, :handle)
    Refusal = Struct.new(:reason, :retry_after, :message, :ends_at)

    # The create lock stayed taken for the whole wait.
    class LockTimeout < StandardError; end

    # A creation waits this long for the create lock, trying again this often:
    # a slow Docker (a pull during a deploy) must not keep every Puma thread
    # waiting behind the lock.
    CREATE_LOCK_WAIT = 10
    LOCK_RETRY_EVERY = 0.05
    CREATE_TIMEOUT = 30
    LIST_TIMEOUT = 10
    ORPHAN_GRACE = 60
    HEALTHY_WITHIN = 60
    AVAILABILITY_EVERY = 10
    STATS_EVERY = 60
    HOT_CPU = 90.0
    HOT_COUNT = 10
    PROBE_EVERY = 0.25
    LIVE = %i[creating ready].freeze
    ABSENT = /No such (container|network|object)|not found|is not connected/i
    OVERLAP = /Pool overlaps/i
    NO_IMAGE = /No such image/i
    ALREADY = /already exists/i
    # A container id or name as Docker writes them: the only docker output
    # that becomes an argv element, and none of it reads as a flag.
    CONTAINER_REF = /\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/
    # Where a handle stands for a pass of the reaper when nobody is ending
    # it (#standing): the pass may end it, attach routers to it, sample it.
    NOT_ENDING = %i[in_progress settled unknown].freeze

    attr_reader :config

    def self.handle_for(sid)
      Digest::SHA256.hexdigest(sid)[0, 16]
    end

    def initialize(config:, docker:, probe:, clock:, log:, random: SecureRandom)
      @config = config
      @docker = docker
      @probe = probe
      @clock = clock
      @log = log
      @random = random
      @subnets = Subnets.new(config.subnet_pool, config.subnet_prefix)
      @limits = Limits.new(limit: config.create_limit, window: config.create_window, clock: clock)
      @records = {}
      @connected = Hash.new { |hash, handle| hash[handle] = [] }
      @tearing_down = Set.new # handles whose teardown runs now, in any thread
      @unusable = []
      @mutex = Mutex.new
      @unavailable = nil
      @last_reap_ok = nil
      @last_availability = nil
      @last_stats = nil
      FileUtils.mkdir_p(config.data_dir)
    end

    # ---- what the pages and the operator read ------------------------------

    def status
      live = live_count
      paused = !pause_message.nil?
      { accepting: !paused && @unavailable.nil? && live < @config.max_sessions,
        paused: paused, live: live, capacity: @config.max_sessions, ttl_seconds: @config.ttl }
    end

    # Why nothing can start right now (the pause message, or what is
    # missing), or nil.
    def closed_message
      pause_message || @unavailable
    end

    # The operator's message from playctl pause, or nil when not paused.
    # Read as UTF-8 whatever LANG says, and scrubbed: it may be in any
    # language.
    def pause_message
      text = File.read(paused_path, encoding: Encoding::UTF_8).scrub.strip
      text.empty? ? "For maintenance" : text[0].upcase + text[1..]
    rescue Errno::ENOENT
      nil
    end

    # True while the reaper has succeeded within the last minute (GET /up).
    def healthy?
      !@last_reap_ok.nil? && @clock.monotonic - @last_reap_ok <= HEALTHY_WITHIN
    end

    # The records for GET /internal/sessions (playctl status).
    def internal_list
      @mutex.synchronize do
        @records.values.sort_by(&:created_at).map do |s|
          { handle: s.handle, state: s.state.to_s, created_at: s.created_at, expires_at: s.expires_at,
            client: s.client, cpu: s.cpu, memory: s.memory }
        end
      end
    end

    # A refusal decided outside (POST /sessions from another origin).
    def note_refusal(reason)
      @log.event("refused", reason: reason, live: "#{live_count}/#{@config.max_sessions}")
    end

    # ---- creation ------------------------------------------------------------

    # Starts a session for CLIENT (Limits.client_key). Returns Created, whose
    # editor_url is the only copy of the session id, or a Refusal. Whatever
    # fails, nothing of the new session is left behind. What memory already
    # knows is refused before the create lock (the pause, the client's
    # limits, live records at the cap), so that such a refusal neither waits
    # for the lock nor holds it for a `docker ps`; inside the lock Docker's
    # count stays the authority.
    def create(client)
      if (message = pause_message)
        return refuse(:paused, 300, message)
      end
      return refuse(:unavailable, 300, @unavailable) if @unavailable

      refusal = client_refusal(client)
      return refusal if refusal
      return refuse(:full, 60) if live_count >= @config.max_sessions

      sid, pid = new_ids
      handle = self.class.handle_for(sid)
      begin
        refusal = with_create_lock(wait: CREATE_LOCK_WAIT) { admit_and_start(client, handle, sid, pid) }
        return refusal if refusal

        wait_until_ready(handle, sid, client)
      rescue LockTimeout
        @log.event("lock_timeout", waited_s: CREATE_LOCK_WAIT)
        refuse(:failed, 60)
      rescue StandardError => e
        teardown(handle, reason: "failed")
        @log.event("error", step: "create", handle: handle,
                            message: DockerCLI.redact("#{e.class}: #{e.message}", "sid" => sid, "pid" => pid))
        refuse(:failed, 60)
      end
    end

    # Holds the host-wide create lock (PLAY_DATA_DIR/create.lock): threads of
    # this process, a second control plane during a deploy and playctl all
    # take it before they count or start sessions. WAIT: at most that many
    # seconds for it (nil: as long as it takes), then LockTimeout, without
    # running the block.
    def with_create_lock(wait: nil)
      File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |file|
        raise LockTimeout unless lock(file, wait)

        yield
      end
    end

    # ---- teardown ------------------------------------------------------------

    # Removes the session HANDLE: its container, every attachment of its
    # network, the network. Each step counts "absent" as done. Returns true
    # when nothing is left; on false the labels stay and the reaper retries
    # (a record of HANDLE keeps REASON for that). While it runs, the reaper's
    # passes leave HANDLE to it.
    def teardown(handle, reason:, created_at: nil)
      session = @mutex.synchronize do
        @tearing_down << handle
        @records[handle]&.tap do |s|
          s.state = :ending
          s.reason = reason
        end
      end
      return false unless remove_everything(handle)

      @mutex.synchronize do
        @records.delete(handle)
        @connected.delete(handle)
      end
      born = session&.created_at || created_at
      fields = { handle: handle, reason: reason }
      fields[:age_s] = @clock.now - born if born
      @log.event("ended", **fields)
      true
    ensure
      @mutex.synchronize { @tearing_down.delete(handle) }
    end

    # Every labelled session (playctl kill-all, and the reaper when it finds
    # the kill-all request).
    def kill_all(reason: "killed")
      containers = list_containers
      networks = list_networks
      return false unless containers && networks

      handles = (containers.map { |c| c[:handle] } + networks.map { |n| n[:handle] }).uniq
      handles.map { |handle| teardown(handle, reason: reason) }.all?
    end

    # ---- the reaper ----------------------------------------------------------

    def start_reaper
      Thread.new do
        # An unexpected error ends the process; Docker restarts it and the
        # first pass reconciles (spec §5.1).
        Thread.current.abort_on_exception = true
        loop do
          reap
          @clock.sleep(@config.reap_interval)
        end
      end
    end

    # One pass (spec §5.8). Returns true when it reached Docker.
    def reap
      check_availability if @unavailable && due?(@last_availability, AVAILABILITY_EVERY)
      # The record states before the listings: a creation that completes
      # while the pass runs is judged by them (#standing), since the
      # listings may predate its network or its container.
      before = @mutex.synchronize { @records.transform_values(&:state) }
      containers = list_containers
      networks = list_networks
      routers = list_routers
      return false unless containers && networks && routers

      now = @clock.now
      killing = File.exist?(kill_path)
      ended = Set.new
      done = true

      containers.each do |c|
        reason = container_reason(c, standing(c[:handle], before), killing, now)
        next unless reason

        ended << c[:handle]
        done &= teardown(c[:handle], reason: reason, created_at: c[:created_at])
      end

      with_container = containers.to_set { |c| c[:handle] }
      networks.each do |n|
        next if with_container.include?(n[:handle])

        reason = network_reason(n, standing(n[:handle], before), killing, now)
        next unless reason

        ended << n[:handle]
        done &= teardown(n[:handle], reason: reason, created_at: n[:created_at])
      end

      alive = killing ? [] : containers.select { |c| alive?(c, before, ended, now) }
      attach_routers(alive, routers)
      reconcile(containers, networks, alive, before)
      collect_stats(alive) if due?(@last_stats, STATS_EVERY)
      # rm_f: during a deploy the other control plane's reaper may have
      # honoured the request and removed the file first.
      FileUtils.rm_f(kill_path) if killing && done
      @last_reap_ok = @clock.monotonic
      true
    end

    # Docker and the session image, checked at boot and every 10 s while
    # something is missing; creation is refused meanwhile.
    def check_availability
      @last_availability = @clock.monotonic
      version = docker(Templates.version, LIST_TIMEOUT)
      return unavailable!("It cannot reach Docker", "docker_unreachable", version) unless version.ok?

      image = docker(Templates.image_inspect(@config), LIST_TIMEOUT)
      return unavailable!("Its session image is missing", "image_missing", image) unless image.ok?

      @log.event("available") if @unavailable
      @unavailable = nil
      true
    end

    # ---- Docker listings (also used by playctl) -------------------------------

    def list_containers
      result = docker(Templates.list_containers, LIST_TIMEOUT)
      return listing_failed("ps", result) unless result.ok?

      result.stdout.lines.filter_map do |line|
        id, name, state, handle, created, expires = line.chomp.split("\t")
        next unless handle.to_s.match?(/\A\h{16}\z/)

        { id: id, name: name, state: state, handle: handle, created_at: created.to_i, expires_at: expires.to_i }
      end
    end

    def list_networks
      result = docker(Templates.list_networks, LIST_TIMEOUT)
      return listing_failed("network_ls", result) unless result.ok?

      result.stdout.lines.filter_map do |line|
        id, name, handle, created = line.chomp.split("\t")
        next unless handle.to_s.match?(/\A\h{16}\z/)

        { id: id, name: name, handle: handle, created_at: created.to_i }
      end
    end

    def list_routers
      result = docker(Templates.list_routers(@config), LIST_TIMEOUT)
      return listing_failed("routers", result) unless result.ok?

      container_refs(result.stdout, "routers")
    end

    # {container name => [cpu %, memory]} from one `docker stats` sample.
    def read_stats(names)
      return {} if names.empty?

      result = docker(Templates.stats(names), LIST_TIMEOUT)
      return listing_failed("stats", result) || {} unless result.ok?

      result.stdout.lines.to_h do |line|
        name, cpu, memory = line.chomp.split("\t")
        [name, [cpu.to_s.delete("%").to_f, memory.to_s]]
      end
    end

    private

    def paused_path
      File.join(@config.data_dir, "paused")
    end

    def kill_path
      File.join(@config.data_dir, "kill-all")
    end

    def lock_path
      File.join(@config.data_dir, "create.lock")
    end

    def live_count
      @mutex.synchronize { @records.count { |_, s| LIVE.include?(s.state) } }
    end

    # Takes FILE's exclusive lock, waiting at most WAIT seconds for it (nil:
    # as long as it takes). False when the wait ran out.
    def lock(file, wait)
      return file.flock(File::LOCK_EX) if wait.nil?

      deadline = @clock.monotonic + wait
      until file.flock(File::LOCK_EX | File::LOCK_NB)
        return false if @clock.monotonic >= deadline

        @clock.sleep(LOCK_RETRY_EVERY)
      end
      true
    end

    def new_ids
      sid = @random.hex(16)
      pid = @random.hex(16)
      pid = @random.hex(16) while pid == sid
      [sid, pid]
    end

    def refuse(reason, retry_after, message = nil, ends_at = nil)
      note_refusal(reason)
      Refusal.new(reason, retry_after, message, ends_at)
    end

    # Inside the create lock: the pause again (playctl pause, or a kill-all
    # that paused, may have come while this creation waited for the lock),
    # the limits, then the network, the routers and the container. nil once
    # the container runs, else a Refusal (after removing whatever was made).
    def admit_and_start(client, handle, sid, pid)
      if (message = pause_message)
        return refuse(:paused, 300, message)
      end

      refusal = client_refusal(client)
      return refusal if refusal

      containers = list_containers
      return refuse(:failed, 60) unless containers
      return refuse(:full, 60) if containers.count { |c| %w[running created].include?(c[:state]) } >= @config.max_sessions

      routers = list_routers
      return refuse(:failed, 60) unless routers
      return refuse(:unavailable, 300, "It is starting up") if routers.empty?

      now = @clock.now
      session = Session.new(handle, nil, now, now + @config.ttl, client, :creating, nil, nil, 0)
      @mutex.synchronize { @records[handle] = session }
      refusal = start_session(session, sid, pid, routers)
      teardown(handle, reason: "failed") if refusal
      refusal
    end

    def client_refusal(client)
      mine = @mutex.synchronize { @records.values.select { |s| s.client == client && LIVE.include?(s.state) } }
      if mine.size >= @config.max_sessions_per_ip
        ends_at = mine.map(&:expires_at).min
        return refuse(:per_ip, [ends_at - @clock.now, 1].max, nil, ends_at)
      end
      wait = @limits.retry_after(client)
      wait.positive? ? refuse(:rate, wait) : nil
    end

    def start_session(session, sid, pid, routers)
      secrets = { "sid" => sid, "pid" => pid }
      return refuse(:failed, 60) unless create_network(session, secrets)

      routers.each do |router|
        result = docker(Templates.network_connect(handle: session.handle, container: router), CREATE_TIMEOUT)
        unless result.ok? || result.stderr.match?(ALREADY)
          docker_error("connect", session.handle, result, secrets)
          return refuse(:failed, 60)
        end
        @mutex.synchronize { @connected[session.handle] |= [router] }
      end

      run = Templates.session_run(@config, handle: session.handle, sid: sid, pid: pid,
                                           created: session.created_at, expires: session.expires_at)
      result = docker(run, CREATE_TIMEOUT)
      return nil if result.ok?

      docker_error("run", session.handle, result, secrets)
      return refuse(:failed, 60) unless result.stderr.match?(NO_IMAGE)

      unavailable!("Its session image is missing", "image_missing", result)
      refuse(:unavailable, 300, @unavailable)
    end

    # The lowest free subnet; a "Pool overlaps" answer (a network without our
    # labels holds that range) marks it unusable for this process and tries
    # the next, three times in all (spec §5.5).
    def create_network(session, secrets)
      networks = list_networks
      return false unless networks

      used = networks.filter_map { |n| subnet_of(n[:handle]) }
      3.times do
        subnet = @subnets.first_free(used + @unusable)
        return false unless subnet

        argv = Templates.network_create(handle: session.handle, subnet: subnet,
                                        created: session.created_at, expires: session.expires_at)
        result = docker(argv, CREATE_TIMEOUT)
        if result.ok?
          session.subnet = subnet
          return true
        end
        docker_error("network", session.handle, result, secrets)
        return false unless result.stderr.match?(OVERLAP)

        @unusable << subnet
      end
      false
    end

    def subnet_of(handle)
      known = @mutex.synchronize { @records[handle]&.subnet }
      return known if known

      result = docker(Templates.network_subnet(handle: handle), LIST_TIMEOUT)
      result.ok? ? result.stdout.strip : nil
    end

    def wait_until_ready(handle, sid, client)
      started = @clock.monotonic
      until @probe.ready?(sid)
        if @clock.monotonic - started >= @config.ready_timeout
          teardown(handle, reason: "failed")
          return refuse(:failed, 60)
        end
        @clock.sleep(PROBE_EVERY)
      end
      # Only a session still creating becomes ready (spec §5.3). One that a
      # teardown began ending meanwhile (kill-all, an operator's end) is left
      # to that teardown, or to the pass that repeats it.
      session = @mutex.synchronize do
        record = @records[handle]
        next unless record&.state == :creating

        record.state = :ready
        record
      end
      return refuse(:failed, 60) unless session

      @limits.record(client)
      @log.event("created", handle: handle, subnet: session.subnet,
                            ready_ms: ((@clock.monotonic - started) * 1000).round,
                            live: "#{live_count}/#{@config.max_sessions}")
      Created.new(@config.editor_url(sid), handle)
    end

    # The order matters (spec §5.4, §15): the container goes first, and its
    # exit closes the router's connections to it; then every attachment,
    # then the network. Detaching the router from a running session first
    # left the router a pooled connection that hung for minutes.
    def remove_everything(handle)
      result = docker(Templates.remove_container(handle: handle), CREATE_TIMEOUT)
      return step_failed("rm", handle, result) unless result.ok? || result.stderr.match?(ABSENT)

      result = docker(Templates.network_containers(handle: handle), CREATE_TIMEOUT)
      return result.stderr.match?(ABSENT) || step_failed("inspect", handle, result) unless result.ok?

      container_refs(result.stdout, "inspect", handle).each do |container|
        detached = docker(Templates.network_disconnect(handle: handle, container: container), CREATE_TIMEOUT)
        return step_failed("disconnect", handle, detached) unless detached.ok? || detached.stderr.match?(ABSENT)
      end
      result = docker(Templates.network_remove(handle: handle), CREATE_TIMEOUT)
      result.ok? || result.stderr.match?(ABSENT) || step_failed("network_rm", handle, result)
    end

    # Where the session HANDLE stands for this pass of the reaper, from
    # BEFORE (the record states taken before the listings) and its record
    # now:
    # :being_ended - a teardown of it runs now, or began during the pass:
    #                left to whoever is ending it
    # :retry       - its teardown failed before the pass: ended again, for
    #                the reason that teardown recorded
    # :gone        - its record went during the pass: ended meanwhile
    # :in_progress - a creation under way before the listings or begun since,
    #                which they may predate: never ended as exited or idle,
    #                never forgotten or adopted
    # :settled     - known and not creating before the listings: what they
    #                lack is really gone
    # :unknown     - no record, before or now: a restart, or the other
    #                control plane's session
    def standing(handle, before)
      @mutex.synchronize do
        record = @records[handle]
        if @tearing_down.include?(handle) then :being_ended
        elsif record.nil? then before.key?(handle) ? :gone : :unknown
        elsif [nil, :creating].include?(before[handle]) then :in_progress
        elsif record.state == :ending then before[handle] == :ending ? :retry : :being_ended
        else :settled
        end
      end
    end

    # Why the pass ends container C, or nil. One still `created` that nobody
    # here knows has the grace of its network (spec §5.8 item 3): it may be
    # the other control plane's `docker run` under way during a deploy. A
    # leftover from a crash holds its slot for that minute at most.
    def container_reason(c, standing, killing, now)
      return recorded_reason(c[:handle]) if standing == :retry
      return unless NOT_ENDING.include?(standing)

      if killing then "killed"
      elsif c[:expires_at] <= now then "ttl"
      elsif c[:state] == "running" || standing == :in_progress then nil
      elsif standing == :unknown && c[:state] == "created" && now - c[:created_at] < ORPHAN_GRACE then nil
      else "exited"
      end
    end

    # Why the pass ends network N, which has no container, or nil. A known
    # session whose container ended by itself (code-server's idle timeout,
    # or the container's own end) is `idle`; a network nobody here knows is
    # an `orphan` once it is old enough not to be the other control plane's
    # creation in progress during a deploy.
    def network_reason(n, standing, killing, now)
      return recorded_reason(n[:handle]) if standing == :retry
      return unless NOT_ENDING.include?(standing)

      if killing then "killed"
      elsif standing == :settled then "idle"
      elsif standing == :unknown && now - n[:created_at] >= ORPHAN_GRACE then "orphan"
      end
    end

    def recorded_reason(handle)
      @mutex.synchronize { @records[handle]&.reason }
    end

    # A running, unexpired container that this pass did not end and that
    # nobody is ending: its network gets every router, its record the stats.
    def alive?(c, before, ended, now)
      c[:state] == "running" && c[:expires_at] > now && !ended.include?(c[:handle]) &&
        NOT_ENDING.include?(standing(c[:handle], before))
    end

    def attach_routers(alive, routers)
      alive.each do |c|
        missing = routers - @mutex.synchronize { @connected[c[:handle]].dup }
        missing.each do |router|
          result = docker(Templates.network_connect(handle: c[:handle], container: router), CREATE_TIMEOUT)
          if result.ok? || result.stderr.match?(ALREADY)
            @mutex.synchronize { @connected[c[:handle]] |= [router] }
          else
            docker_error("connect", c[:handle], result)
          end
        end
      end
    end

    # Forget the records Docker no longer has, among those settled before the
    # listings; adopt the live sessions this process knows nothing of, before
    # or now (a restart, or the other control plane during a deploy). A
    # creation under way is neither forgotten nor adopted, nor is a session
    # that was ended meanwhile.
    def reconcile(containers, networks, alive, before)
      seen = (containers.map { |c| c[:handle] } + networks.map { |n| n[:handle] }).to_set
      @mutex.synchronize do
        @records.delete_if { |handle, _| %i[ready ending].include?(before[handle]) && !seen.include?(handle) }
        alive.each do |c|
          next if before.key?(c[:handle]) || @records.key?(c[:handle])

          @records[c[:handle]] = Session.new(c[:handle], nil, c[:created_at], c[:expires_at], nil, :ready, nil, nil, 0)
        end
      end
    end

    # Every minute: CPU and memory per session; ten samples in a row at 90 %
    # or more log one `suspect` line (spec §5.8). Nothing is stopped. The
    # containers are named from their checked handles, not from docker's
    # {{.Names}}.
    def collect_stats(alive)
      @last_stats = @clock.monotonic
      read_stats(alive.map { |c| "ctplay-s-#{c[:handle]}" }).each do |name, (cpu, memory)|
        handle = name.delete_prefix("ctplay-s-")
        hot = @mutex.synchronize do
          session = @records[handle]
          if session
            session.cpu = cpu
            session.memory = memory
            session.hot = cpu >= HOT_CPU ? session.hot.to_i + 1 : 0
          end
        end
        @log.event("suspect", handle: handle, cpu: format("%.1f%%", cpu)) if hot == HOT_COUNT
      end
    end

    # The container ids or names in docker's TEXT (separated by whitespace,
    # already scrubbed by #docker) that may become argv elements. Anything
    # else never reaches a command line: one `dropped` line per call counts
    # it, without its text.
    def container_refs(text, step, handle = nil)
      words = text.split
      refs = words.grep(CONTAINER_REF)
      return refs if refs.size == words.size

      fields = { step: step }
      fields[:handle] = handle if handle
      fields[:count] = words.size - refs.size
      @log.event("dropped", **fields)
      refs
    end

    def due?(last, every)
      last.nil? || @clock.monotonic - last >= every
    end

    # Runs ARGV with the docker CLI; a hung docker counts as a failure. Both
    # outputs are read as UTF-8 and scrubbed here, once: without LANG, Ruby
    # labels them US-ASCII, and one odd byte would make every split and
    # match on them raise, the reaper thread with it.
    def docker(argv, timeout)
      result = @docker.run(argv, timeout: timeout)
      DockerCLI::Result.new(result.status, utf8(result.stdout), utf8(result.stderr))
    rescue DockerCLI::Timeout => e
      DockerCLI::Result.new(-1, "", e.message)
    end

    def utf8(text)
      text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    end

    def docker_error(step, handle, result, secrets = {})
      fields = { step: step }
      fields[:handle] = handle if handle
      fields[:status] = result.status
      fields[:stderr] = DockerCLI.redact(result.stderr, secrets)
      @log.event("docker_error", **fields)
    end

    def step_failed(step, handle, result)
      docker_error(step, handle, result)
      false
    end

    def listing_failed(step, result)
      docker_error(step, nil, result)
      nil
    end

    def unavailable!(message, reason, result)
      if @unavailable != message
        fields = { reason: reason }
        fields[:image] = @config.session_image if reason == "image_missing"
        fields[:stderr] = DockerCLI.redact(result.stderr)
        @log.event("unavailable", **fields)
      end
      @unavailable = message
      false
    end
  end
end
