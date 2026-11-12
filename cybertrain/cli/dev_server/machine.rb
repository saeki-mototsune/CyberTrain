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
      # What each event does in each state. "serving" is the machine's own
      # reader; "lock" is the runner's build_locked?; "pending" is a change (or
      # the first round) that has not run yet. A round moves the generation only
      # once it is past its last lock check, so until then the old child is still
      # the one of the current generation and its events are still seen.
      #
      # on_change         any state, lock free  -> a round (see run_round)
      #                   any state, lock held  -> log once, pending, no calls
      # start             lock free             -> the first round
      #                   lock held             -> hold, log once, pending
      # on_tick           pending, lock free    -> the round
      #                   pending, lock held    -> nothing (the lock line is logged once)
      #                   recover, lock free    -> release_hold, CRuby child (no gen, no build)
      #                   handover, lock free   -> hand over to the binary
      #                   otherwise             -> nothing
      # on_build_done ok  other generation, build not building, or pending -> ignored
      #                   current, lock held    -> build ready, handover waits for the tick
      #                   current, lock free    -> hand over (stop; start the binary unless a change is waiting)
      # on_build_done bad other generation, build not building, or pending -> ignored
      #                   current               -> build failed, output kept, the child keeps serving
      # on_child_exit     other generation      -> ignored
      #   :binary         serving spinel, lock free -> CRuby child again, build binary_failed
      #                   serving spinel, lock held -> hold, binary_failed, CRuby child on the tick
      #                   serving anything else -> ignored
      #   :cruby          serving cruby         -> hold (lock or not); a build that succeeds takes the port
      #                   serving anything else -> ignored
      # on_child_ready    other generation, or the kind is not the one serving -> ignored
      #                   serving child         -> log the seconds
      # stop              any state             -> cancel_build, stop_child, release_hold
      #
      # No child is ever started while the lock is held: `cybertrain build`
      # fills gen/views.rb, and a child booted on it takes itself for production.
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
          # The binary died while the lock was held; the CRuby child is started
          # on the first tick after it.
          @recover = false
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
            if @runner.build_locked?
              @runner.hold("the compiled binary stopped", info)
              @serving = :holding
              @recover = true
              log_lock_once
            else
              recover_cruby
            end
          elsif kind == :cruby && @serving == :cruby
            @runner.hold("the CRuby preview stopped", cruby_stopped_text(info))
            @serving = :holding
          end
          sync
        end

        def on_build_done(generation, ok, output)
          # A result is acted on only for the current generation and only when
          # no change is waiting: the waiting round starts its own build.
          return unless generation == @generation && @build == :building && !@pending

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
          elsif @recover
            if @runner.build_locked?
              log_lock_once
            else
              @lock_logged = false
              @recover = false
              recover_cruby
              sync
            end
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
          @recover = false
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
          @handover_pending = false
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

          @generation += 1
          @pending = false
          @recover = false
          @binary_info = nil
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

        # The binary died: the CRuby child serves again so that work continues.
        # Nothing changed, so there is no gen and no build; the next change
        # builds and tries the binary again.
        def recover_cruby
          @runner.log("=> spinel: the binary failed; serving the CRuby preview")
          leave_holding
          @runner.start_child(:cruby, @generation)
          @serving = :cruby
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
