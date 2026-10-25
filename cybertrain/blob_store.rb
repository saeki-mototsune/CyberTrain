# Cybertrain::BlobStore -- stored upload bytes, one file per random key.
#
# SQLite cannot hold binary data here (it binds and reads text, which stops
# at the first NUL), so the bytes of an upload live on disk under a root
# directory (storage/uploads by default, on the persistent storage volume)
# and the model keeps only the key and the metadata.
#
# The path is built from the key alone: 32 lowercase hex characters, which
# {BlobStore.valid_key?} checks byte by byte before any path is made. A
# client filename never reaches the file system, so no "../" or absolute
# path can come in through a name.
require "securerandom"

module Cybertrain
  # Raised for a key that is not 32 lowercase hex characters, and by
  # {BlobStore.write} when the key already has a blob. It is a programmer or
  # tampered-data error, so it answers 500: it is deliberately not in
  # CLIENT_FAULTS.
  # @api public
  class BlobKeyInvalid < StandardError
  end

  # Stores and reads upload bytes by key. Untrusted bytes: serve them only
  # with Controller#send_blob, never through Static.
  # @api public
  module BlobStore
    KEY_BYTES = 32

    # Module-level ivar, not @@root: spikes/NOTES.md rule 18.
    @root = "storage/uploads"

    # Points the store at another directory (Application#boot sets it from
    # Config#upload_root). The directory is created by the first {write},
    # not here, so a read-only deploy still boots.
    # @param path [String]
    # @return [String]
    def self.root=(path)
      @root = path
    end

    # @return [String] the directory blobs are stored under
    def self.root
      @root
    end

    # A fresh key: 32 lowercase hex characters from SecureRandom (128 bits).
    # @return [String]
    def self.new_key
      SecureRandom.hex(16)
    end

    # True when key is exactly 32 bytes of 0-9 / a-f. A while loop over the
    # bytes, not a regexp: the key may come from a tampered database value.
    # @param candidate [String]
    # @return [Boolean]
    def self.valid_key?(candidate)
      # Through a `to_s` local (NOTES rule 62): boxed in a program that also
      # requires the openssl package (test/template_integration.rb).
      key = candidate.to_s
      return false if key.bytesize != KEY_BYTES

      i = 0
      while i < KEY_BYTES
        b = key.getbyte(i)
        return false unless (b >= 48 && b <= 57) || (b >= 97 && b <= 102)

        i += 1
      end
      true
    end

    # The file a key is stored in: "ROOT/ab/abcdef...", sharded by the first
    # two characters so no directory grows without bound.
    # @param key [String]
    # @return [String]
    # @raise [BlobKeyInvalid] when key is not a valid key
    def self.path_for(key)
      raise BlobKeyInvalid, "invalid blob key" unless valid_key?(key)

      shard = key[0, 2]
      "#{@root}/#{shard}/#{key}"
    end

    # Writes data under key: into a private temp file in the shard directory
    # (created exclusively, mode 0600), then renamed into place, so a reader
    # never sees a half-written blob.
    # @param key [String] from {new_key}
    # @param data [String] the bytes; NUL and 0xFF are kept
    # @return [nil]
    # @raise [BlobKeyInvalid] for an invalid key or a key that already exists
    def self.write(key, data)
      final = path_for(key)
      dir = "#{@root}/#{key[0, 2]}"
      make_directory(@root)
      make_directory(dir)
      raise BlobKeyInvalid, "blob key already exists" if File.exist?(final)

      tmp = "#{dir}/.#{key}.#{SecureRandom.hex(4)}.tmp"
      f = File.open(tmp, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o600)
      f.write(data)
      f.close
      # rename replaces silently, so look again: this is the guard that keeps
      # a duplicate key from overwriting a stored blob.
      if File.exist?(final)
        File.delete(tmp)
        raise BlobKeyInvalid, "blob key already exists"
      end
      File.rename(tmp, final)
      nil
    end

    # The stored bytes, or "" when there is no blob for the key.
    # @param key [String]
    # @return [String] binary
    # @raise [BlobKeyInvalid] for an invalid key
    def self.read(key)
      File.binread(path_for(key))
    rescue Errno::ENOENT
      ""
    end

    # True for a regular file stored under a valid key. A symlink is not a
    # blob: the store only ever writes regular files.
    # @param key [String]
    # @return [Boolean]
    def self.exist?(key)
      return false unless valid_key?(key)

      path = path_for(key)
      File.file?(path) && !File.symlink?(path)
    end

    # Removes the blob. Never raises for a missing file or an invalid key
    # (an after_destroy callback must not fail on a record whose upload is
    # already gone).
    # @param key [String]
    # @return [Boolean] true when a file was removed
    def self.delete(key)
      return false unless valid_key?(key)

      File.delete(path_for(key))
      true
    rescue Errno::ENOENT
      false
    end

    # mkdir -p with mode 0700, one level at a time. Another request may
    # create the directory between the check and the mkdir, so EEXIST is not
    # an error.
    def self.make_directory(dir)
      return nil if dir == "" || dir == "." || dir == "/" || File.directory?(dir)

      make_directory(File.dirname(dir))
      begin
        Dir.mkdir(dir, 0o700)
        # Spinel's Dir.mkdir ignores the mode argument (spikes: 755 under a
        # 022 umask), so set it explicitly; only a directory made here is
        # touched, never one that already existed.
        File.chmod(0o700, dir)
      rescue Errno::EEXIST
        nil
      end
      nil
    end
  end
end
