# The supervisor's state machine: what `cybertrain server` decides, with no
# processes, sockets or files of its own. It receives events (a change, a build
# result, a child that is ready or has died, a tick) and tells a runner what to
# do. The runner (the next layer) does the real work and feeds the events back,
# one at a time. CRuby only: this is the gem's CLI, never compiled by Spinel,
# and it needs nothing outside the standard library.
#
# The runner answers: run_gen -> [ok, output] (blocks), start_child(kind,
# generation) with kind :cruby or :binary, stop_child (blocks; nothing without
# a child), start_build(generation), cancel_build, hold(title, text),
# release_hold, write_state(generation, serving, build, output) with strings,
# log(line), build_locked? (`cybertrain build` holds its lock), change_pending?
# (a change was seen that the machine has not been told of yet) and now (a
# monotonic clock in seconds).
module Cybertrain
  module CLI
    module DevServer
      class Machine
        LOCK_LINE = "=> cybertrain build in progress; the preview reloads when it finishes"

        attr_reader :generation, :serving, :build, :output

        def initialize(runner)
          @runner = runner
          @generation = 0
          @serving = :none
          @build = :idle
          @output = ""
          # The first round has not run yet (or was put off by the build lock).
          @started = false
          # A round is wanted and has not completed.
          @pending = false
          # The generation was already moved for the pending round; a round
          # put off by the lock and taken up again must not move it twice.
          @bumped = false
          # A build succeeded but the handover waits for the lock to go.
          @handover_pending = false
          @lock_logged = false
          @round_started = 0.0
          @binary_info = nil
          @written = nil
        end

        # The first round. While `cybertrain build` holds the lock the server
        # is not started: a child booted on its half-written gen/views.rb
        # would take itself for production.
        def start
          @pending = true
          if @runner.build_locked?
            @runner.hold("cybertrain build in progress", "the server starts when it finishes")
            @serving = :holding
            log_lock_once
            sync
            return
          end
          run_round
        end

        def on_change(paths)
          @runner.log("Changed #{paths.join(", ")}")
          @pending = true
          run_pending
        end

        def on_child_ready(kind, generation)
          return unless generation == @generation

          secs = elapsed
          if kind == :cruby && @serving == :cruby
            @runner.log("=> preview: CRuby (#{secs}s)")
          elsif kind == :binary && @serving == :spinel
            @runner.log("=> spinel: ready in #{secs}s; serving the compiled binary")
          end
        end

        def on_child_exit(kind, generation, info)
          return unless generation == @generation

          if kind == :binary && @serving == :spinel
            # Never retried by itself: the next change builds and tries again.
            @binary_info = info
            @build = :binary_failed
            @output = info
            @runner.log("=> spinel: the binary failed; serving the CRuby preview")
            @runner.start_child(:cruby, @generation)
            @serving = :cruby
          elsif kind == :cruby && @serving == :cruby
            @runner.hold("the CRuby preview stopped", cruby_stopped_text(info))
            @serving = :holding
          end
          sync
        end

        def on_build_done(generation, ok, output)
          return unless generation == @generation && @build == :building

          if ok
            @build = :ready
            @output = ""
            if @runner.build_locked?
              log_lock_once
              @handover_pending = true
            else
              hand_over
            end
          else
            @build = :failed
            @output = output
            @runner.log("=> spinel: build failed; still serving the CRuby preview (see tmp/rebuild.log)")
          end
          sync
        end

        # Takes up what was put off: a round while the lock was held, or a
        # handover to a binary that finished building in the meantime.
        def on_tick
          if @pending
            run_pending
          elsif @handover_pending
            if @runner.build_locked?
              log_lock_once
            else
              @lock_logged = false
              hand_over
              sync
            end
          end
        end

        def stop
          @runner.cancel_build
          @runner.stop_child
          @runner.release_hold
          @serving = :none
          @build = :idle
          @pending = false
          @handover_pending = false
        end

        private

        def run_pending
          if @runner.build_locked?
            log_lock_once
          else
            @lock_logged = false
            run_round
          end
        end

        # One round: cancel the build, run gen (the old child still serves),
        # stop the child, start the CRuby child, start the build. The first
        # round has no build to cancel and no child to stop.
        def run_round
          first = !@started
          @round_started = @runner.now
          if first
            leave_holding
          else
            @runner.cancel_build
            @build = :idle
          end
          unless @bumped
            @generation += 1
            @bumped = true
          end
          @handover_pending = false
          @binary_info = nil
          sync

          ok, out = @runner.run_gen
          # `cybertrain build` may have taken the lock while gen ran: the old
          # child keeps serving and the round is taken up again from the start.
          if @runner.build_locked?
            log_lock_once
            if first
              @runner.hold("cybertrain build in progress", "the server starts when it finishes")
              @serving = :holding
            end
            sync
            return
          end

          @bumped = false
          @pending = false
          @started = true
          @runner.stop_child unless first
          if ok
            leave_holding
            @runner.start_child(:cruby, @generation)
            @serving = :cruby
            @build = :building
            @output = ""
            @runner.start_build(@generation)
            @runner.log("=> spinel: building (log: tmp/rebuild.log)")
          else
            @runner.hold("gen failed", out)
            @serving = :holding
            @build = :idle
            @output = out
          end
          sync
        end

        # The build succeeded at the current generation: the binary takes the
        # port. The old child is stopped first (this blocks), and a change that
        # came in meanwhile means the binary is already stale, so it is not
        # started; the change round that follows starts the CRuby child.
        def hand_over
          @handover_pending = false
          @runner.stop_child
          if @runner.change_pending?
            @serving = :none if @serving == :cruby
            return
          end

          leave_holding
          @runner.start_child(:binary, @generation)
          @serving = :spinel
        end

        def leave_holding
          return unless @serving == :holding

          @runner.release_hold
          @serving = :none
        end

        def cruby_stopped_text(info)
          return info unless @binary_info

          "#{info}\n\nthe compiled binary also failed: #{@binary_info}"
        end

        def log_lock_once
          return if @lock_logged

          @lock_logged = true
          @runner.log(LOCK_LINE)
        end

        # Seconds since the round began, one decimal.
        def elapsed
          format("%.1f", @runner.now - @round_started)
        end

        # Writes the state when any of its four values changed since the last
        # write.
        def sync
          state = [@generation, @serving.to_s, @build.to_s, @output]
          return if state == @written

          @written = state
          @runner.write_state(*state)
        end
      end
    end
  end
end
