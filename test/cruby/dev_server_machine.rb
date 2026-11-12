require "cybertrain/test"
require "cybertrain/cli/dev_server/machine"

# The supervisor's state machine (cybertrain/cli/dev_server/machine.rb), with a
# fake runner that records what the machine asks for. CRuby only.

Machine = Cybertrain::CLI::DevServer::Machine

LOCK_LINE = "=> cybertrain build in progress; the preview reloads when it finishes"

# Records [:name, args...] for every action except write_state and log, which
# go to states and lines. build_locked?, change_pending? and now are questions,
# not actions, so they are not recorded.
class FakeRunner
  attr_accessor :calls, :states, :lines, :gen_result, :locked, :pending, :clock
  # A block runs inside run_gen, to let a test change the world mid-round.
  attr_accessor :during_gen

  def initialize
    @calls = []
    @states = []
    @lines = []
    @gen_result = [true, ""]
    @locked = false
    @pending = false
    @clock = 0.0
    @during_gen = nil
  end

  def run_gen
    @calls << [:run_gen]
    @during_gen.call(self) if @during_gen
    @gen_result
  end

  def start_child(kind, generation) = @calls << [:start_child, kind, generation]
  def stop_child = @calls << [:stop_child]
  def start_build(generation) = @calls << [:start_build, generation]
  def cancel_build = @calls << [:cancel_build]
  def hold(title, text) = @calls << [:hold, title, text]
  def release_hold = @calls << [:release_hold]
  def write_state(generation, serving, build, output) = @states << [generation, serving, build, output]
  def log(line) = @lines << line
  def build_locked? = @locked
  def change_pending? = @pending
  def now = @clock
end

def calls_after(runner) = runner.calls.tap { runner.calls = [] }

test "start: gen, the CRuby child, the build" do
  r = FakeRunner.new; m = Machine.new(r); m.start
  assert_equal [[:run_gen], [:start_child, :cruby, 1], [:start_build, 1]], calls_after(r)
  assert_equal [1, :cruby, :building], [m.generation, m.serving, m.build]
  assert_equal [1, "cruby", "building", ""], r.states.last
end

test "a machine that has not started has nothing" do
  r = FakeRunner.new; m = Machine.new(r)
  assert_equal [0, :none, :idle, ""], [m.generation, m.serving, m.build, m.output]
  assert_equal [], r.calls
end

test "a change: cancel, gen, stop, CRuby child, build (P12)" do
  r = FakeRunner.new; m = Machine.new(r); m.start; calls_after(r)
  m.on_change(["app/models/article.rb"])
  assert_equal [[:cancel_build], [:run_gen], [:stop_child], [:start_child, :cruby, 2], [:start_build, 2]], calls_after(r)
  assert r.lines.include?("Changed app/models/article.rb")
end

test "build ok at the current generation hands the port to the binary" do
  r = FakeRunner.new; m = Machine.new(r); m.start; calls_after(r)
  m.on_build_done(1, true, "")
  assert_equal [[:stop_child], [:start_child, :binary, 1]], calls_after(r)
  assert_equal [:spinel, :ready], [m.serving, m.build]
end

test "a stale build is discarded" do
  r = FakeRunner.new; m = Machine.new(r); m.start; m.on_change(["a.rb"]); calls_after(r)
  m.on_build_done(1, true, "")
  assert_equal [], calls_after(r)
  assert_equal [:cruby, :building], [m.serving, m.build]
end

test "a change while the binary serves goes back to CRuby" do
  r = FakeRunner.new; m = Machine.new(r); m.start; m.on_build_done(1, true, ""); calls_after(r)
  m.on_change(["a.rb"])
  assert_equal [[:cancel_build], [:run_gen], [:stop_child], [:start_child, :cruby, 2], [:start_build, 2]], calls_after(r)
end

test "a failed build keeps CRuby and publishes the output" do
  r = FakeRunner.new; m = Machine.new(r); m.start; calls_after(r)
  m.on_build_done(1, false, "a.rb:3: error")
  assert_equal [], calls_after(r)
  assert_equal [1, "cruby", "failed", "a.rb:3: error"], r.states.last
end

test "gen fails: stop, hold, no build; the next change leaves holding" do
  r = FakeRunner.new; m = Machine.new(r); m.start; calls_after(r)
  r.gen_result = [false, "config/routes.rb:9: no such controller"]
  m.on_change(["config/routes.rb"])
  assert_equal [[:cancel_build], [:run_gen], [:stop_child], [:hold, "gen failed", "config/routes.rb:9: no such controller"]], calls_after(r)
  assert_equal [:holding, :idle], [m.serving, m.build]
  r.gen_result = [true, ""]
  m.on_change(["config/routes.rb"])
  assert_equal [[:cancel_build], [:run_gen], [:stop_child], [:release_hold], [:start_child, :cruby, 3], [:start_build, 3]], calls_after(r)
end

test "gen fails at start: hold, nothing to stop, no build" do
  r = FakeRunner.new; r.gen_result = [false, "boom"]; m = Machine.new(r); m.start
  assert_equal [[:run_gen], [:hold, "gen failed", "boom"]], calls_after(r)
  assert_equal [1, :holding, :idle], [m.generation, m.serving, m.build]
end

test "the CRuby child dies: hold; a build that then succeeds takes the port" do
  r = FakeRunner.new; m = Machine.new(r); m.start; calls_after(r)
  m.on_child_exit(:cruby, 1, "SyntaxError: app/models/a.rb:3: unexpected end")
  assert_equal [[:hold, "the CRuby preview stopped", "SyntaxError: app/models/a.rb:3: unexpected end"]], calls_after(r)
  assert_equal [:holding, :building], [m.serving, m.build]
  m.on_build_done(1, true, "")
  assert_equal [[:stop_child], [:release_hold], [:start_child, :binary, 1]], calls_after(r)
end

test "the binary dies, before or after ready: CRuby again, no retry" do
  r = FakeRunner.new; m = Machine.new(r); m.start; m.on_build_done(1, true, ""); calls_after(r)
  m.on_child_exit(:binary, 1, "signal 11 (SEGV)")
  assert_equal [[:start_child, :cruby, 1]], calls_after(r)
  assert_equal [1, "cruby", "binary_failed", "signal 11 (SEGV)"], r.states.last
  m.on_tick
  assert_equal [], calls_after(r)
end

test "both dead: holding with what is known of each" do
  r = FakeRunner.new; m = Machine.new(r); m.start; m.on_build_done(1, true, "")
  m.on_child_exit(:binary, 1, "signal 11 (SEGV)"); calls_after(r)
  m.on_child_exit(:cruby, 1, "RuntimeError: boom")
  held = calls_after(r).last
  assert_equal :hold, held[0]
  assert held[2].include?("RuntimeError: boom") && held[2].include?("signal 11 (SEGV)")
end

test "locked by cybertrain build: nothing runs, then the pending change is handled once" do
  r = FakeRunner.new; m = Machine.new(r); m.start; calls_after(r)
  r.locked = true
  m.on_change(["a.rb"]); m.on_change(["b.rb"]); m.on_tick
  assert_equal [], calls_after(r)
  assert_equal 1, r.lines.count("=> cybertrain build in progress; the preview reloads when it finishes")
  r.locked = false
  m.on_tick
  assert_equal [[:cancel_build], [:run_gen], [:stop_child], [:start_child, :cruby, 2], [:start_build, 2]], calls_after(r)
  m.on_tick
  assert_equal [], calls_after(r)
end

test "a build that finishes while locked does not take the port until the lock is gone" do
  r = FakeRunner.new; m = Machine.new(r); m.start; calls_after(r)
  r.locked = true
  m.on_build_done(1, true, "")
  assert_equal [], calls_after(r)
  r.locked = false
  m.on_tick
  assert_equal [[:stop_child], [:start_child, :binary, 1]], calls_after(r)
end

test "events of another generation are ignored; stop ends everything" do
  r = FakeRunner.new; m = Machine.new(r); m.start; m.on_change(["a.rb"]); calls_after(r)
  m.on_child_ready(:cruby, 1); m.on_child_exit(:cruby, 1, "late")
  assert_equal [], calls_after(r)
  m.stop
  assert_equal [[:cancel_build], [:stop_child], [:release_hold]], calls_after(r)
end

test "start while the build lock is held: hold, then start on the first tick after it (R4)" do
  r = FakeRunner.new; r.locked = true; m = Machine.new(r); m.start
  assert_equal [[:hold, "cybertrain build in progress", "the server starts when it finishes"]], calls_after(r)
  assert_equal [LOCK_LINE], r.lines
  m.on_tick
  assert_equal [], calls_after(r)
  assert_equal 1, r.lines.count(LOCK_LINE)
  r.locked = false
  m.on_tick
  assert_equal [[:release_hold], [:run_gen], [:start_child, :cruby, 1], [:start_build, 1]], calls_after(r)
  assert_equal [:cruby, :building], [m.serving, m.build]
  m.on_tick
  assert_equal [], calls_after(r)
end

test "a change that arrives before the locked start has run joins the start" do
  r = FakeRunner.new; r.locked = true; m = Machine.new(r); m.start; calls_after(r)
  m.on_change(["a.rb"])
  assert_equal [], calls_after(r)
  r.locked = false
  m.on_tick
  assert_equal [[:release_hold], [:run_gen], [:start_child, :cruby, 1], [:start_build, 1]], calls_after(r)
end

test "a binary handover does not start a stale binary after a blocking stop (P16)" do
  r = FakeRunner.new; m = Machine.new(r); m.start; calls_after(r)
  r.pending = true
  m.on_build_done(1, true, "")
  assert_equal [[:stop_child]], calls_after(r)
  r.pending = false
  m.on_change(["a.rb"])
  assert_equal [[:cancel_build], [:run_gen], [:stop_child], [:start_child, :cruby, 2], [:start_build, 2]], calls_after(r)
end

test "the lock appears while gen runs: the round stops, the old child keeps serving (P17)" do
  r = FakeRunner.new; m = Machine.new(r); m.start; calls_after(r)
  r.during_gen = ->(fake) { fake.locked = true }
  m.on_change(["a.rb"])
  assert_equal [[:cancel_build], [:run_gen]], calls_after(r)
  assert_equal 1, r.lines.count(LOCK_LINE)
  m.on_tick
  assert_equal [], calls_after(r)
  r.during_gen = nil
  r.locked = false
  m.on_tick
  assert_equal [[:cancel_build], [:run_gen], [:stop_child], [:start_child, :cruby, 2], [:start_build, 2]], calls_after(r)
  assert_equal 2, m.generation
  assert_equal 1, r.lines.count(LOCK_LINE)
end

test "log lines" do
  r = FakeRunner.new; m = Machine.new(r)
  r.clock = 10.0; m.start
  assert_equal ["=> spinel: building (log: tmp/rebuild.log)"], r.lines
  r.clock = 10.44; m.on_child_ready(:cruby, 1)
  r.clock = 18.1; m.on_build_done(1, true, ""); m.on_child_ready(:binary, 1)
  assert_equal ["=> spinel: building (log: tmp/rebuild.log)", "=> preview: CRuby (0.4s)", "=> spinel: ready in 8.1s; serving the compiled binary"], r.lines
  r.lines.clear
  m.on_change(["a.rb", "b.rb"])
  assert_equal "Changed a.rb, b.rb", r.lines.first
  m.on_build_done(2, false, "x")
  assert_equal "=> spinel: build failed; still serving the CRuby preview (see tmp/rebuild.log)", r.lines.last
  m.on_change(["a.rb"])
  m.on_build_done(3, true, ""); m.on_child_ready(:binary, 3); m.on_child_exit(:binary, 3, "signal 11")
  assert_equal "=> spinel: the binary failed; serving the CRuby preview", r.lines.last
end

test "a ready child of the wrong kind is ignored" do
  r = FakeRunner.new; m = Machine.new(r); m.start; r.lines.clear
  m.on_child_ready(:binary, 1)
  assert_equal [], r.lines
end

test "a state is written whenever one of its four values changes, and only then" do
  r = FakeRunner.new; m = Machine.new(r); m.start
  n = r.states.size
  m.on_tick
  assert_equal n, r.states.size
  m.on_build_done(1, false, "e")
  assert_equal n + 1, r.states.size
end

test "stop from holding releases the hold once" do
  r = FakeRunner.new; r.gen_result = [false, "x"]; m = Machine.new(r); m.start; calls_after(r)
  m.stop
  assert_equal [[:cancel_build], [:stop_child], [:release_hold]], calls_after(r)
end

test "a build that succeeds while a change waits is discarded, not handed over (A)" do
  r = FakeRunner.new; m = Machine.new(r); m.start; calls_after(r)
  r.locked = true
  m.on_change(["a.rb"])
  r.locked = false
  m.on_build_done(1, true, "")
  assert_equal [], calls_after(r)
  assert_equal [1, :cruby, :building], [m.generation, m.serving, m.build]
  m.on_tick
  assert_equal [[:cancel_build], [:run_gen], [:stop_child], [:start_child, :cruby, 2], [:start_build, 2]], calls_after(r)
  m.on_tick
  assert_equal [], calls_after(r)
end

test "a build that succeeded under the lock is dropped when a change arrives before the tick" do
  r = FakeRunner.new; m = Machine.new(r); m.start; calls_after(r)
  r.locked = true
  m.on_build_done(1, true, "")
  m.on_change(["a.rb"])
  r.locked = false
  m.on_tick
  assert_equal [[:cancel_build], [:run_gen], [:stop_child], [:start_child, :cruby, 2], [:start_build, 2]], calls_after(r)
  assert_equal [2, :cruby, :building], [m.generation, m.serving, m.build]
  m.on_tick
  assert_equal [], calls_after(r)
end

test "a failed build while a change waits is discarded too" do
  r = FakeRunner.new; m = Machine.new(r); m.start; calls_after(r)
  r.locked = true
  m.on_change(["a.rb"])
  m.on_build_done(1, false, "late")
  assert_equal [:building, ""], [m.build, m.output]
end

test "the binary dies while the lock is held: hold, then CRuby on the first tick after (B)" do
  r = FakeRunner.new; m = Machine.new(r); m.start; m.on_build_done(1, true, ""); calls_after(r)
  r.locked = true
  m.on_child_exit(:binary, 1, "segv")
  assert_equal [[:hold, "the compiled binary stopped", "segv"]], calls_after(r)
  assert_equal [1, :holding, :binary_failed, "segv"], [m.generation, m.serving, m.build, m.output]
  m.on_tick
  assert_equal [], calls_after(r)
  assert_equal 1, r.lines.count(LOCK_LINE)
  r.locked = false
  m.on_tick
  assert_equal [[:release_hold], [:start_child, :cruby, 1]], calls_after(r)
  assert_equal [1, :cruby, :binary_failed], [m.generation, m.serving, m.build]
  assert_equal [1, "cruby", "binary_failed", "segv"], r.states.last
  m.on_tick
  assert_equal [], calls_after(r)
end

test "the binary dies under the lock with a change pending: the change round runs instead" do
  r = FakeRunner.new; m = Machine.new(r); m.start; m.on_build_done(1, true, ""); calls_after(r)
  r.locked = true
  m.on_change(["a.rb"])
  m.on_child_exit(:binary, 1, "segv")
  assert_equal [[:hold, "the compiled binary stopped", "segv"]], calls_after(r)
  r.locked = false
  m.on_tick
  assert_equal [[:cancel_build], [:run_gen], [:stop_child], [:release_hold], [:start_child, :cruby, 2], [:start_build, 2]], calls_after(r)
  m.on_tick
  assert_equal [], calls_after(r)
end

test "the CRuby child dies while the lock is held: hold, nothing started" do
  r = FakeRunner.new; m = Machine.new(r); m.start; calls_after(r)
  r.locked = true
  m.on_child_exit(:cruby, 1, "boom")
  assert_equal [[:hold, "the CRuby preview stopped", "boom"]], calls_after(r)
  r.locked = false
  m.on_tick
  assert_equal [], calls_after(r)
  m.on_change(["a.rb"])
  assert_equal [[:cancel_build], [:run_gen], [:stop_child], [:release_hold], [:start_child, :cruby, 2], [:start_build, 2]], calls_after(r)
end

test "the child still serving after an interrupted round is still watched (C)" do
  r = FakeRunner.new; m = Machine.new(r); m.start; calls_after(r)
  r.during_gen = ->(fake) { fake.locked = true }
  m.on_change(["a.rb"])
  assert_equal [[:cancel_build], [:run_gen]], calls_after(r)
  m.on_child_exit(:cruby, 1, "boom")
  assert_equal [[:hold, "the CRuby preview stopped", "boom"]], calls_after(r)
  assert_equal [1, :holding], [m.generation, m.serving]
  r.during_gen = nil
  r.locked = false
  m.on_tick
  assert_equal [[:cancel_build], [:run_gen], [:stop_child], [:release_hold], [:start_child, :cruby, 2], [:start_build, 2]], calls_after(r)
  assert_equal [2, :cruby, :building], [m.generation, m.serving, m.build]
end

test "the binary serving through an interrupted round is still watched" do
  r = FakeRunner.new; m = Machine.new(r); m.start; m.on_build_done(1, true, ""); calls_after(r)
  r.during_gen = ->(fake) { fake.locked = true }
  m.on_change(["a.rb"])
  calls_after(r)
  m.on_child_exit(:binary, 1, "segv")
  assert_equal [[:hold, "the compiled binary stopped", "segv"]], calls_after(r)
  r.during_gen = nil
  r.locked = false
  m.on_tick
  assert_equal [[:cancel_build], [:run_gen], [:stop_child], [:release_hold], [:start_child, :cruby, 2], [:start_build, 2]], calls_after(r)
end

test "the serving child's ready is seen after an interrupted round" do
  r = FakeRunner.new; r.clock = 0.0; m = Machine.new(r); m.start
  r.during_gen = ->(fake) { fake.locked = true }
  m.on_change(["a.rb"])
  r.lines.clear
  r.clock = 0.3
  m.on_child_ready(:cruby, 1)
  assert_equal ["=> preview: CRuby (0.3s)"], r.lines
end

test "a build success for the current generation while an interrupted round waits is discarded" do
  r = FakeRunner.new; m = Machine.new(r); m.start; calls_after(r)
  r.during_gen = ->(fake) { fake.locked = true }
  m.on_change(["a.rb"])
  calls_after(r)
  r.during_gen = nil
  r.locked = false
  m.on_build_done(1, true, "")
  assert_equal [], calls_after(r)
  m.on_tick
  assert_equal [[:cancel_build], [:run_gen], [:stop_child], [:start_child, :cruby, 2], [:start_build, 2]], calls_after(r)
end

Cybertrain::Test.run!
