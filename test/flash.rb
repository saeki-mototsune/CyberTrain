require "cybertrain/test"
require "cybertrain/flash"
require "cybertrain/session"

test "value set in request 1 visible in request 2 and gone in request 3" do
  session = Cybertrain::Session.new

  # Request 1: set a flash value, then persist it at the end of the request.
  flash1 = Cybertrain::Flash.load(session)
  assert_nil flash1[:notice]
  flash1[:notice] = "created"
  Cybertrain::Flash.store(flash1, session)

  # Request 2: the value set in request 1 is visible now...
  flash2 = Cybertrain::Flash.load(session)
  assert_equal "created", flash2[:notice]
  Cybertrain::Flash.store(flash2, session)

  # Request 3: ...but gone, since request 2 did not re-queue it.
  flash3 = Cybertrain::Flash.load(session)
  assert_nil flash3[:notice]
end

test "flash.now is visible only in the current request" do
  session = Cybertrain::Session.new
  flash = Cybertrain::Flash.load(session)
  flash.now[:alert] = "careful"
  assert_equal "careful", flash[:alert]
  assert_equal "careful", flash.now[:alert]

  Cybertrain::Flash.store(flash, session)
  next_flash = Cybertrain::Flash.load(session)
  assert_nil next_flash[:alert]
end

test "[]= queues for the next request, not the current one" do
  session = Cybertrain::Session.new
  flash = Cybertrain::Flash.load(session)
  flash[:notice] = "queued"
  assert_nil flash[:notice]

  Cybertrain::Flash.store(flash, session)
  next_flash = Cybertrain::Flash.load(session)
  assert_equal "queued", next_flash[:notice]
end

test "each iterates current values in insertion order" do
  session = Cybertrain::Session.new
  flash = Cybertrain::Flash.load(session)
  flash.now[:a] = "1"
  flash.now[:b] = "2"
  flash.now[:c] = "3"

  seen = []
  flash.each { |k, v| seen << "#{k}=#{v}" }
  assert_equal ["a=1", "b=2", "c=3"], seen
end

test "keys and empty?" do
  session = Cybertrain::Session.new
  flash = Cybertrain::Flash.load(session)
  assert flash.empty?
  assert_equal [], flash.keys

  flash.now[:notice] = "hi"
  refute flash.empty?
  assert_equal ["notice"], flash.keys
end

test "store does not touch the session when nothing was queued" do
  session = Cybertrain::Session.new
  flash = Cybertrain::Flash.load(session)
  flash.now[:alert] = "seen only now"   # now, not queued
  Cybertrain::Flash.store(flash, session)
  refute session.key?("_flash")
end

Cybertrain::Test.run!
