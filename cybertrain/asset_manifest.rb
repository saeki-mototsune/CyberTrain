# Cybertrain::AssetManifest -- how digested asset files are named and how
# public/assets/.manifest is read, shared by `spin run gen` (which names the
# files and writes the manifest: Gen::AssetScan, Gen::AssetsEmitter) and the
# server (which reads the manifest at boot and serves those names immutable:
# Cybertrain::Assets, Static). One copy, so the two cannot drift. Plain
# String code with no requires: Static's program stays small. Byte scans read
# their parameter through a fresh local (spikes/NOTES.md rule 62).
module Cybertrain
  # @api private
  module AssetManifest
    # The file under public/assets that lists the kept digests.
    FILE = ".manifest"

    # "logo.svg" -> "logo-<digest>.svg"; the digest goes before the first
    # dot of the file name ("app.js.map" -> "app-<digest>.js.map"), at the
    # end of a name with none or that starts with one ("LICENSE-<digest>").
    def self.digested_name(logical, digest)
      slash = logical.rindex("/")
      dir = slash.nil? ? "" : logical[0, slash + 1].to_s
      base = slash.nil? ? logical : logical[slash + 1, logical.size - slash - 1].to_s
      dot = base.index(".")
      named = dot.nil? || dot == 0 ? "#{base}-#{digest}" : "#{base[0, dot]}-#{digest}#{base[dot, base.size - dot]}"
      "#{dir}#{named}"
    end

    # The inverse of digested_name: "logo-1a2b3c4d.svg" -> "logo.svg"; ""
    # for a name with no digest where digested_name puts one.
    def self.logical_of(name)
      slash = name.rindex("/")
      dir = slash.nil? ? "" : name[0, slash + 1].to_s
      base = slash.nil? ? name : name[slash + 1, name.size - slash - 1].to_s
      dot = base.index(".")
      stop = dot.nil? || dot == 0 ? base.size : dot
      return "" if stop < 10

      digest = base[stop - 8, 8].to_s
      return "" unless base[stop - 9] == "-" && digest?(digest)

      "#{dir}#{base[0, stop - 9]}#{base[stop, base.size - stop]}"
    end

    # 8 lowercase hex characters (SHA-256's first 8, as Propshaft's short
    # digest).
    def self.digest?(text)
      s = text.to_s
      return false unless s.bytesize == 8

      i = 0
      while i < 8
        b = s.getbyte(i)
        return false unless (b >= 48 && b <= 57) || (b >= 97 && b <= 102)

        i += 1
      end
      true
    end

    # A logical path that stays below its root once written under
    # public/assets: relative, no empty or dot-led segment, no backslash,
    # space or control character.
    def self.safe_logical?(logical)
      s = logical.to_s
      return false if s.empty? || s.start_with?("/")

      i = 0
      n = s.bytesize
      while i < n
        b = s.getbyte(i)
        return false if b == 92 || b == 32 || b < 32 || b == 127

        i += 1
      end
      s.split("/", -1).each do |part|
        return false if part.empty? || part.start_with?(".")
      end
      true
    end

    # logical => digests, typed and empty (spikes/NOTES.md rule 9).
    def self.empty_kept
      kept = { "" => Array.new(0) { "" } }
      kept.delete("")
      kept
    end

    # logical => digests (newest first), from a .manifest's text: one
    # `<logical> <digest> <digest> ...` line per logical path. A malformed
    # line (a path that could leave public/assets, any digest that is not 8
    # hex characters, no digest at all) is dropped whole.
    def self.read_kept(text)
      kept = empty_kept
      text.to_s.each_line do |line|
        parts = line.strip.split(" ")
        next if parts.size < 2

        logical = parts[0].to_s
        next unless safe_logical?(logical)

        digests = Array.new(0) { "" }
        valid = true
        parts.each_with_index do |d, i|
          next if i == 0

          digest = d.to_s
          valid = false unless digest?(digest)
          digests << digest
        end
        kept[logical] = digests if valid
      end
      kept
    end
  end
end
