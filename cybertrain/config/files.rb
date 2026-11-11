# Cybertrain::ConfigFiles -- the file operations a Config needs: the
# development secret key file and the directories for it and for the
# database. Kept apart from Config's checks (cybertrain/config/validation.rb),
# which never touch the file system, so that "is this configuration
# usable" and "prepare the disk for it" are separate steps Application#boot
# orders explicitly (docs/design.md D65).
require "cybertrain/crypto"

module Cybertrain
  # @api private
  module ConfigFiles
    # The secret in the file at `path`, creating the file (and its
    # directory, mode 0700) with a random key of `length` hex digits when
    # it is missing or does not hold one. An existing file is restricted
    # to its owner before it is read or replaced.
    # @param path [String]
    # @param length [Integer] the secret's length in hex digits
    # @return [String]
    def self.load_or_create_secret(path, length)
      exists = File.exist?(path)
      secret = ""
      if exists
        # Restrict older keys before reading or replacing their contents.
        File.chmod(0o600, path)
        secret = File.read(path).strip
      end
      if secret.length != length
        secret = Crypto.random_token(length / 2)
        make_directory(File.dirname(path), 0o700)
        flags = exists ? File::WRONLY | File::TRUNC : File::WRONLY | File::CREAT | File::EXCL
        File.open(path, flags, 0o600) do |file|
          file.write("#{secret}\n")
        end
      end
      secret
    end

    # mkdir -p.
    # @param dir [String]
    # @param mode [Integer]
    # @return [nil]
    def self.make_directory(dir, mode = 0o777)
      return nil if dir == "" || dir == "." || File.directory?(dir)

      make_directory(File.dirname(dir), mode)
      Dir.mkdir(dir, mode)
      # Spinel ignores mkdir's mode argument. Only restrict directories we
      # created for secrets; other callers retain the default umask behavior.
      File.chmod(mode, dir) unless mode == 0o777
      nil
    end
  end
end
