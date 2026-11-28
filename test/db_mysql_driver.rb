# The MySQL Connection over a scripted session: no server, no sockets. A
# subclass replaces Connection#open_packet_io, the one place a session's
# stream is opened, with a PacketIO over StallStream, whose answers come one
# chunk per read and where a chunk can be a stall (Net::TimeoutError, the
# read_timeout passed) followed by what the server sends once it recovers.
# Each answer is framed as MySQL frames it, in the layout of the packets
# test/mysql_protocol.rb recorded from a MySQL 8.0 server.
require "cybertrain/db/base"
require "cybertrain/db/mysql"
require "cybertrain/test"

DB = Cybertrain::DB
Wire = Cybertrain::DB::MySQL::Wire

# Binary-tagged, as a socket's bytes are.
def unhex(text)
  s = text.to_s
  out = "0" * (s.bytesize / 2)
  out.force_encoding("BINARY")
  i = 0
  while i < out.bytesize
    out.setbyte(i, s.byteslice(2 * i, 2).to_i(16))
    i += 1
  end
  out
end

def hex(s)
  out = String.new
  i = 0
  while i < s.bytesize
    out << (s.getbyte(i) + 256).to_s(16).byteslice(1, 2)
    i += 1
  end
  out
end

def binary(text)
  out = String.new
  out << text.to_s
  out.force_encoding("BINARY")
  out
end

def frame(seq, payload)
  out = Wire.int_le(payload.bytesize, 3)
  out << Wire.int_le(seq, 1)
  out << payload
  out
end

# An OK packet: no rows changed, no insert id, these status flags
# (0x0002 autocommit, 0x0001 in a transaction), no warnings.
def ok_packet(status)
  out = unhex("000000")
  out << Wire.int_le(status, 2)
  out << Wire.int_le(0, 2)
  out
end

# COM_STMT_PREPARE's OK: statement `id`, no columns, no parameters.
def prepare_ok(id)
  out = unhex("00")
  out << Wire.int_le(id, 4)
  out << Wire.int_le(0, 2)
  out << Wire.int_le(0, 2)
  out << unhex("000000")
  out
end

def err_packet(code, state, message)
  out = unhex("ff")
  out << Wire.int_le(code, 2)
  out << "#"
  out << binary(state)
  out << binary(message)
  out
end

class StallStream < Cybertrain::Net::Stream
  def initialize
    @chunks = Array.new(0) { "" }
    @stalls = Array.new(0) { false }
    @next_chunk = 0
    @sent = String.new
  end

  def answer(bytes)
    @chunks << bytes
    @stalls << false
    nil
  end

  def stall
    @chunks << ""
    @stalls << true
    nil
  end

  def stream_read(max, timer)
    return "" if @next_chunk >= @chunks.size

    i = @next_chunk
    @next_chunk += 1
    raise Cybertrain::Net::TimeoutError, "fake:3306: reading timed out after 30s" if @stalls[i]

    @chunks[i]
  end

  def stream_write(data, timer)
    @sent << data
    nil
  end

  def stream_close
    nil
  end

  def stream_label
    "fake:3306"
  end

  def stall_sent
    @sent
  end

  def chunks_left
    @chunks.size - @next_chunk
  end
end

# The stream the next ScriptedConnection runs over.
module Scripted
  def self.stream
    @stream
  end

  def self.stream=(stream)
    @stream = stream
  end
end

class ScriptedConnection < Cybertrain::DB::Connection
  def open_packet_io(url)
    Cybertrain::DB::MySQL::PacketIO.new(Scripted.stream, 30, 120)
  end
end

URL_TEXT = "mysql://app:s3cret-pw@10.0.0.5:3306/shop?ssl_mode=disabled"

# A stream whose first answer is the session settings' OK.
def session_stream
  stream = StallStream.new
  stream.answer(frame(1, ok_packet(0x0002)))
  Scripted.stream = stream
  stream
end

def failure(conn, sql)
  got = "nothing raised"
  begin
    conn.execute(sql)
  rescue Cybertrain::DB::Error => e
    got = "#{e.class.name}: #{e.message}"
  end
  got
end

# COM_PING as the client frames it.
PING_REQ = "010000000e"

test "a ping that times out after an error inside a transaction closes the connection" do
  stream = session_stream
  stream.answer(frame(1, ok_packet(0x0003))) # BEGIN
  stream.answer(frame(1, prepare_ok(1)))
  stream.answer(frame(1, err_packet(1062, "23000", "Duplicate entry '1' for key 't.PRIMARY'")))
  stream.stall # the ping's answer, past read_timeout
  # What the server sends once it recovers: the ping's OK, late, then what a
  # ROLLBACK would get. None of it may be read as another command's answer.
  stream.answer(frame(1, ok_packet(0x0003)))
  stream.answer(frame(1, ok_packet(0x0002)))
  conn = ScriptedConnection.new(URL_TEXT)
  conn.begin!
  assert_equal "Cybertrain::DB::UniqueViolation: Duplicate entry '1' for key 't.PRIMARY' (MySQL 1062, 23000) " \
               "(sql: INSERT INTO t (id) VALUES (1))",
               failure(conn, "INSERT INTO t (id) VALUES (1)")
  assert_equal true, conn.closed?
  # Nothing was sent after the ping, and the late answers stay unread.
  assert hex(stream.stall_sent).end_with?(PING_REQ), "the ping is the last thing sent"
  assert_equal 2, stream.chunks_left
  # What DB.transaction's rescue and Pool#check_in then do: nothing is open
  # on a closed connection, so nothing is sent.
  assert_nil conn.rollback!
  assert_equal :clean, conn.abandon_transaction!
  assert_equal 2, stream.chunks_left
  assert_equal "Cybertrain::DB::Error: connection closed (sql: SELECT 1)", failure(conn, "SELECT 1")
end

test "a ping that answers OK after an error inside a transaction keeps the connection" do
  stream = session_stream
  stream.answer(frame(1, ok_packet(0x0003))) # BEGIN
  stream.answer(frame(1, prepare_ok(1)))
  stream.answer(frame(1, err_packet(1062, "23000", "Duplicate entry '1' for key 't.PRIMARY'")))
  stream.answer(frame(1, ok_packet(0x0003))) # the ping: the transaction is still open
  stream.answer(frame(1, ok_packet(0x0002))) # ROLLBACK
  conn = ScriptedConnection.new(URL_TEXT)
  conn.begin!
  assert_includes failure(conn, "INSERT INTO t (id) VALUES (1)"), "UniqueViolation"
  assert_equal false, conn.closed?
  assert_equal :rolled_back, conn.abandon_transaction!
  assert_equal 0, stream.chunks_left
end

Cybertrain::Test.run!
