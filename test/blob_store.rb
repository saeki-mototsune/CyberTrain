require "tmpdir"
require "digest"
require "cybertrain/test"
require "cybertrain/blob_store"

# Cybertrain::BlobStore against a temporary root: a binary round-trip, file
# modes, the shard directory, key validation and the symlink rule. Data is
# compared by bytesize, getbyte and SHA-256, never with == (the bytes are
# binary; spikes/NOTES.md rule 60 and the file-upload spec section 7).

ROOT = Dir.mktmpdir("cybertrain-blob-store")
Cybertrain::BlobStore.root = "#{ROOT}/uploads/nested"

def rm_tree(path)
  if File.symlink?(path)
    File.delete(path)
  elsif File.directory?(path)
    Dir.children(path).each { |child| rm_tree("#{path}/#{child}") }
    Dir.rmdir(path)
  else
    File.delete(path)
  end
end

at_exit do
  rm_tree(ROOT)
end

# Every byte value 0..255 twice, with a run of NULs, built from byteslices
# of a table (never n.chr appended to a UTF-8 buffer).
def sample_bytes
  table = (0..255).map { |n| n.chr }.join.b
  out = "".b
  i = 0
  while i < 512
    out << table.byteslice(i % 256, 1)
    i += 1
  end
  out << ("\0".b * 40)
  out << "\xFF\xFE\xFF".b
  out
end

def sha(data)
  Digest::SHA256.hexdigest(data)
end

def mode_of(path)
  format("%o", File.stat(path).mode & 0o777)
end

test "new_key is 32 lowercase hex characters and valid" do
  key = Cybertrain::BlobStore.new_key
  assert_equal 32, key.bytesize
  assert Cybertrain::BlobStore.valid_key?(key)
  other = Cybertrain::BlobStore.new_key
  refute key == other
end

test "valid_key? accepts only 32 bytes of 0-9 a-f" do
  assert Cybertrain::BlobStore.valid_key?("0123456789abcdef0123456789abcdef")
  assert Cybertrain::BlobStore.valid_key?("a" * 32)
  refute Cybertrain::BlobStore.valid_key?("")
  refute Cybertrain::BlobStore.valid_key?("../x")
  refute Cybertrain::BlobStore.valid_key?("../../../../etc/passwd/../../../x")
  refute Cybertrain::BlobStore.valid_key?("0123456789ABCDEF0123456789abcdef")
  refute Cybertrain::BlobStore.valid_key?("a" * 31)
  refute Cybertrain::BlobStore.valid_key?("a" * 33)
  refute Cybertrain::BlobStore.valid_key?("g" * 32)
  refute Cybertrain::BlobStore.valid_key?("a" * 31 + "/")
  refute Cybertrain::BlobStore.valid_key?("a" * 31 + "\0")
  refute Cybertrain::BlobStore.valid_key?("a" * 30 + "é")
  refute Cybertrain::BlobStore.valid_key?("0123456789abcdef0123456789abcde ")
end

test "path_for shards by the first two characters" do
  key = "ab" + "c" * 30
  assert_equal "#{ROOT}/uploads/nested/ab/#{key}", Cybertrain::BlobStore.path_for(key)
end

test "path_for raises BlobKeyInvalid for an invalid key" do
  ["", "../x", "A" * 32, "a" * 31].each do |bad|
    raised = false
    message = ""
    begin
      Cybertrain::BlobStore.path_for(bad)
    rescue Cybertrain::BlobKeyInvalid => e
      raised = true
      message = e.message
    end
    assert raised
    assert_equal "invalid blob key", message
  end
end

test "write then read round-trips binary data with NUL and 0xFF" do
  data = sample_bytes
  key = Cybertrain::BlobStore.new_key
  refute Cybertrain::BlobStore.exist?(key)
  assert_nil Cybertrain::BlobStore.write(key, data)
  assert Cybertrain::BlobStore.exist?(key)
  back = Cybertrain::BlobStore.read(key)
  assert_equal data.bytesize, back.bytesize
  assert_equal sha(data), sha(back)
  assert_equal 0, back.getbyte(0)
  assert_equal 255, back.getbyte(255)
  assert_equal 255, back.getbyte(back.bytesize - 1)
  puts "bytesize=#{back.bytesize} sha256=#{sha(back)}"
end

test "an empty blob round-trips" do
  key = Cybertrain::BlobStore.new_key
  Cybertrain::BlobStore.write(key, "")
  assert Cybertrain::BlobStore.exist?(key)
  assert_equal 0, Cybertrain::BlobStore.read(key).bytesize
end

test "the file is mode 0600 inside a 0700 shard directory" do
  key = Cybertrain::BlobStore.new_key
  Cybertrain::BlobStore.write(key, "mode")
  path = Cybertrain::BlobStore.path_for(key)
  assert_equal "600", mode_of(path)
  shard = "#{Cybertrain::BlobStore.root}/#{key[0, 2]}"
  assert File.directory?(shard)
  assert_equal "700", mode_of(shard)
  assert_equal "700", mode_of(Cybertrain::BlobStore.root)
  assert_equal shard, File.dirname(path)
  assert_equal key, File.basename(path)
end

test "write leaves no temp file behind" do
  key = Cybertrain::BlobStore.new_key
  Cybertrain::BlobStore.write(key, "tidy")
  shard = "#{Cybertrain::BlobStore.root}/#{key[0, 2]}"
  stray = 0
  Dir.children(shard).each do |name|
    stray += 1 if name.end_with?(".tmp")
  end
  assert_equal 0, stray
end

test "write refuses an existing key and keeps the first blob" do
  key = Cybertrain::BlobStore.new_key
  Cybertrain::BlobStore.write(key, "first")
  raised = false
  begin
    Cybertrain::BlobStore.write(key, "second")
  rescue Cybertrain::BlobKeyInvalid
    raised = true
  end
  assert raised
  assert_equal "first", Cybertrain::BlobStore.read(key)
end

test "write rejects an invalid key before touching the disk" do
  raised = false
  begin
    Cybertrain::BlobStore.write("../escape", "x")
  rescue Cybertrain::BlobKeyInvalid
    raised = true
  end
  assert raised
  refute File.exist?("#{ROOT}/escape")
end

test "read of a missing blob is empty and of an invalid key raises" do
  assert_equal 0, Cybertrain::BlobStore.read("f" * 32).bytesize
  raised = false
  begin
    Cybertrain::BlobStore.read("../x")
  rescue Cybertrain::BlobKeyInvalid
    raised = true
  end
  assert raised
end

test "exist? is false for missing, invalid and symlinked keys" do
  refute Cybertrain::BlobStore.exist?("e" * 32)
  refute Cybertrain::BlobStore.exist?("")
  refute Cybertrain::BlobStore.exist?("../x")

  target = "#{ROOT}/outside.txt"
  File.write(target, "secret")
  key = "d" * 32
  shard = "#{Cybertrain::BlobStore.root}/dd"
  Dir.mkdir(shard) unless File.directory?(shard)
  File.symlink(target, "#{shard}/#{key}")
  assert File.file?("#{shard}/#{key}")
  refute Cybertrain::BlobStore.exist?(key)
end

test "a directory in the blob's place is not a blob" do
  key = "c" * 32
  shard = "#{Cybertrain::BlobStore.root}/cc"
  Dir.mkdir(shard) unless File.directory?(shard)
  Dir.mkdir("#{shard}/#{key}")
  refute Cybertrain::BlobStore.exist?(key)
end

test "delete removes a blob and is false for missing or invalid keys" do
  key = Cybertrain::BlobStore.new_key
  Cybertrain::BlobStore.write(key, "bye")
  assert Cybertrain::BlobStore.delete(key)
  refute Cybertrain::BlobStore.exist?(key)
  refute Cybertrain::BlobStore.delete(key)
  refute Cybertrain::BlobStore.delete("")
  refute Cybertrain::BlobStore.delete("../x")
  refute Cybertrain::BlobStore.delete("A" * 32)
end

test "root= moves the store and write creates the directories lazily" do
  fresh = "#{ROOT}/other/deeper"
  Cybertrain::BlobStore.root = fresh
  refute File.exist?("#{ROOT}/other")
  key = Cybertrain::BlobStore.new_key
  Cybertrain::BlobStore.write(key, "moved")
  assert_equal "#{fresh}/#{key[0, 2]}/#{key}", Cybertrain::BlobStore.path_for(key)
  assert_equal "moved", Cybertrain::BlobStore.read(key)
  Cybertrain::BlobStore.root = "#{ROOT}/uploads/nested"
end

Cybertrain::Test.run!
