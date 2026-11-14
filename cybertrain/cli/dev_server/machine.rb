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
# release_hold (hold replaces whatever hold page is showing, and one
# release_hold ends holding however many holds preceded it),
# write_state(generation, serving, build, output) with strings,
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
      # on_change         any state, lock free  -> a round (see run_round); the lock is read
      #                                            after gen and after stop_child, and a round
      #                                            that finds it held holds and stays pending
      #                   any state, lock held  -> the "Changed" line, the lock line once, pending,
      #                                            no calls; when nothing serves (none), the lock's
      #                                            hold, so that the port is not left unanswered
      #                   gen fails             -> stop_child (not on the first round), hold
      #                                            "gen failed"; no child, no build; the
      #                                            generation moves
      # start             lock free             -> the first round
      #                   lock held             -> hold, log once, pending
      # on_tick           pending, lock free    -> the round, from the start (gen again)
      #                   recover :cruby, lock free -> release_hold, CRuby child (no gen, no build)
      #                   recover :rebuild, lock free -> release_hold, CRuby child, build (no gen)
      #                   rebuild, lock free    -> start_build (no gen, no restart; the serving
      #                                            child, if any, keeps serving)
      #                   serving none, build ready, no change pending
      #                                         -> hand over again (a handover that gave way to a
      #                                            change that never came, e.g. a file that was
      #                                            gone by the next poll)
      #                   anything waiting, lock held -> nothing (the lock line is logged once)
      #                   otherwise             -> nothing
      # on_build_done ok  other generation, build not building, or pending -> ignored
      #                   current, lock held    -> build idle; the result is dropped, a fresh build
      #                                            starts on the tick after the lock (build/bin/NAME
      #                                            is shared with `cybertrain build`)
      #                   current, lock free    -> hand over: stop_child, then
      #                                              a change is waiting -> nothing more (serving
      #                                                none; the change's round, or the tick
      #                                                above, follows)
      #                                              the lock appeared   -> hold, recover :rebuild
      #                                              else                -> start the binary
      # on_build_done bad other generation, build not building, or pending -> ignored
      #                   current               -> build failed, output kept, the child keeps serving
      # on_child_exit     other generation      -> ignored
      #   :binary         serving spinel, lock free -> CRuby child again, build binary_failed
      #                   serving spinel, lock held -> hold, binary_failed, CRuby child on the tick
      #                   serving anything else -> ignored
      #   :cruby          serving cruby         -> hold (lock or not); a build that succeeds
      #                                            later takes the port, unless the lock was held
      #                                            when it finished (then it is dropped and rebuilt)
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
          # What the first tick after the lock must do: :cruby (the binary died
          # while the lock was held) starts the CRuby child; :rebuild (the lock
          # stopped a handover) starts it and a fresh build.
          @recover = nil
          # A build succeeded while the lock was held. build/bin/NAME is shared
          # with `cybertrain build`, which replaces it under the lock, so the
          # result is never handed over: a fresh build starts after the lock.
          @rebuild = false
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
              @recover = :cruby
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
            @output = ""
            if @runner.build_locked?
              log_lock_once
              @build = :idle
              @rebuild = true
            else
              @build = :ready
              hand_over
            end
          else
            @build = :failed
            @output = output
            @runner.log("=> spinel: build failed; still serving the CRuby preview (see tmp/rebuild.log)")
          end
          sync
        end

        # Takes up what was put off while the lock was held: a round, the CRuby
        # child after a dead binary or a stopped handover, or a fresh build
        # for a result that waited through the lock.
        def on_tick
          if @pending
            run_pending
          elsif @recover || @rebuild
            if @runner.build_locked?
              log_lock_once
            else
              @lock_logged = false
              mode = @recover
              @recover = nil
              @rebuild = false
              if mode == :cruby
                recover_cruby
              elsif mode == :rebuild
                recover_cruby_and_build
              else
                start_fresh_build
              end
              sync
            end
          elsif @serving == :none && @build == :ready && !@runner.change_pending?
            # hand_over reads the lock again after its stop.
            hand_over
            sync
          end
        end

        def stop
          @runner.cancel_build
          @runner.stop_child
          @runner.release_hold
          @serving = :none
          @build = :idle
          @pending = false
          @recover = nil
          @rebuild = false
        end

        private

        def run_pending
          if @runner.build_locked?
            log_lock_once
            if @serving == :none
              @runner.hold("cybertrain build in progress", "the server starts when it finishes")
              @serving = :holding
              sync
            end
          else
            @lock_logged = false
            run_round
          end
        end

        # One round: cancel the build, run gen (the old child still serves),
        # stop the child, start the CRuby child, start the build. The first
        # round has no build to cancel and no child to stop. The lock is read
        # after gen and again after the stop; the generation moves only when
        # the round goes on to start a child (or to hold on a gen failure).
        def run_round
          first = !@started
          @round_started = @runner.now
          if first
            leave_holding
          else
            @runner.cancel_build
            @build = :idle
          end
          @rebuild = false
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

          @runner.stop_child unless first
          # stop_child blocks, and the lock may have appeared meanwhile. A round
          # that is about to start a child holds instead and stays pending; the
          # generation has not moved, and the next round runs gen again from the
          # start (the lock holder rewrote the generated files). The first round
          # stops nothing, so its check above is directly before the start.
          if ok && !first && @runner.build_locked?
            log_lock_once
            @runner.hold("cybertrain build in progress", "the server starts when it finishes")
            @serving = :holding
            @build = :idle
            sync
            return
          end

          @generation += 1
          @pending = false
          @recover = nil
          @binary_info = nil
          @started = true
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
        # started; the change round that follows starts the CRuby child. The
        # lock is read again after the stop: `cybertrain build` replaces the
        # same binary file, so with the lock held the binary is not started
        # (and the old one is not trusted after the lock either): the server
        # holds, and after the lock goes the CRuby child and a fresh build
        # take over.
        def hand_over
          @runner.stop_child
          if @runner.change_pending?
            @serving = :none if @serving == :cruby
            return
          end
          if @runner.build_locked?
            @runner.hold("cybertrain build in progress", "the server starts when it finishes")
            @serving = :holding
            @build = :idle
            @recover = :rebuild
            log_lock_once
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

        # After a handover that the lock stopped: nothing changed in the
        # sources, so no gen; the CRuby child serves and a fresh build starts.
        def recover_cruby_and_build
          leave_holding
          @runner.start_child(:cruby, @generation)
          @serving = :cruby
          start_fresh_build
        end

        def start_fresh_build
          @build = :building
          @output = ""
          @runner.start_build(@generation)
          @runner.log("=> spinel: building (log: tmp/rebuild.log)")
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
