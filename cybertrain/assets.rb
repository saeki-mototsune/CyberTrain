# Cybertrain::Assets -- the asset manifest an application runs with (spec
# section 7). `spin run gen` digests app/assets, app/javascript and
# vendor/javascript into public/assets and writes gen/assets.rb, whose last
# line installs its tables here:
#
#   Cybertrain::Assets.install(Gen::Assets.resolver, Gen::Assets.importmap_json, Gen::Assets.preload_paths)
#
# Until then (an application with no gen/assets.rb) the table is empty:
# every name is unknown, the import map has no imports and nothing is
# preloaded. Module-level instance variables rather than @@class_variables
# (spikes/NOTES.md rule 18).
require "cybertrain/logger"

module Cybertrain
  # The digested asset paths and the import map gen/assets.rb installs:
  # read by the asset helpers and the static file server.
  # @api public
  module Assets
    # A logical name that is not an asset, in development and test
    # ({Assets.path}).
    # @api public
    class UnknownAsset < StandardError
    end

    # The resolver of an application with no assets: every name unknown.
    # Returned by a method, not written as a literal into the ivar below:
    # a lambda literal assigned to a module-level ivar never learns its call
    # sites' argument types (spikes/NOTES.md rule 82). The empty answer is
    # name's first zero characters, so the parameter is used (and typed as
    # a String) rather than ignored.
    # @api private
    def self.empty_resolver
      ->(name) { name[0, 0].to_s }
    end

    @resolver = empty_resolver
    @importmap_json = "{\"imports\":{}}"
    @preload_paths = Array.new(0) { "" }
    # The digested names below /assets that public/assets/.manifest keeps
    # (load_kept), name => true. Typed empty Hash (rule 9).
    @kept = { "" => true }
    @kept.delete("")
    # false in production (Application#boot): an unknown name is logged
    # once and written undigested instead of raising.
    @raise_on_unknown = true
    # The unknown names production has logged, name => true.
    @logged = { "" => true }
    @logged.delete("")
    UNKNOWN_LOCK = Mutex.new

    # Installs gen/assets.rb's tables; gen/assets.rb calls it when the
    # application loads.
    # @param resolver [Proc] logical path => digested path ("" when unknown),
    #   `Gen::Assets.resolver`; pass it positionally (spikes/NOTES.md rule 42)
    # @param importmap_json [String] the import map, compact JSON
    # @param preload_paths [Array<String>] the paths and URLs to preload
    # @return [nil]
    # @api public
    def self.install(resolver, importmap_json, preload_paths)
      @resolver = resolver
      @importmap_json = importmap_json
      @preload_paths = preload_paths
      nil
    end

    # @example
    #   Cybertrain::Assets.digest_path("logo.svg") # => "/assets/logo-1a2b3c4d.svg"
    # @param logical [String] the path below an asset root
    # @return [String] the digested path under /assets, "" for a name that
    #   is not an asset
    # @api public
    def self.digest_path(logical)
      @resolver.call(logical)
    end

    # The digested path of a logical one, what asset_path and the tag
    # helpers write.
    # @example
    #   Cybertrain::Assets.path("logo.svg") # => "/assets/logo-1a2b3c4d.svg"
    # @param logical [String] the path below an asset root
    # @return [String] the digested path; for an unknown name in production
    #   `/assets/<logical>` (logged once per name)
    # @raise [UnknownAsset] for an unknown name in development and test
    # @api public
    def self.path(logical)
      name = logical.to_s
      digested = @resolver.call(name)
      return digested unless digested.empty?

      message = "asset \"#{name}\" is not in app/assets, app/javascript or vendor/javascript (run spin run gen)"
      raise UnknownAsset, message if @raise_on_unknown

      log_unknown(name, message)
      "/assets/#{name}"
    end

    # Logs message once per name (requests on several workers may ask at
    # once; Spinel has no GVL, so the set is guarded).
    # @api private
    def self.log_unknown(name, message)
      first = false
      UNKNOWN_LOCK.synchronize do
        unless @logged.key?(name)
          @logged[name] = true
          first = true
        end
      end
      Cybertrain.logger.warn(message) if first
      nil
    end

    # Whether an unknown name raises (true, development and test) or is
    # logged once and written undigested (false, production).
    # @param value [Boolean]
    # @api public
    def self.raise_on_unknown=(value)
      @raise_on_unknown = value
    end

    # Reads public_root/assets/.manifest (written by `spin run gen`): the
    # digests it keeps for each logical path, so that a page served before
    # a deploy still fetches its files as immutable. Application#boot calls
    # it once; a missing file keeps none. A line naming a path that could
    # leave public/assets, or a digest that is not 8 hex characters, is
    # skipped.
    # @param public_root [String]
    # @return [nil]
    # @api public
    def self.load_kept(public_root)
      kept = { "" => true }
      kept.delete("")
      file = "#{public_root}/assets/.manifest"
      if File.file?(file)
        File.read(file).each_line do |line|
          parts = line.strip.split(" ")
          next if parts.size < 2

          logical = parts[0].to_s
          next unless safe_logical?(logical)

          parts.each_with_index do |d, i|
            digest = d.to_s
            kept[digested_name(logical, digest)] = true if i > 0 && digest?(digest)
          end
        end
      end
      @kept = kept
      nil
    end

    # Whether file_name (the path below /assets) carries a digest gen
    # wrote: the current one of gen/assets.rb, or one .manifest keeps.
    # Only such a file is served immutable (Static).
    # @example
    #   Cybertrain::Assets.kept_file?("logo-1a2b3c4d.svg") # => true
    # @param file_name [String]
    # @return [Boolean]
    # @api public
    def self.kept_file?(file_name)
      name = file_name.to_s
      return true if @kept.key?(name)

      logical = logical_of(name)
      return false if logical.empty?

      @resolver.call(logical) == "/assets/#{name}"
    end

    # "logo-1a2b3c4d.svg" -> "logo.svg", the inverse of digested_name; ""
    # for a name with no digest where gen puts one.
    # @api private
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

    # "logo.svg" + digest -> "logo-<digest>.svg", as gen names the file
    # (Gen::AssetScan.digested_name): before the file name's first dot, at
    # the end of a name with none or that starts with one.
    # @api private
    def self.digested_name(logical, digest)
      slash = logical.rindex("/")
      dir = slash.nil? ? "" : logical[0, slash + 1].to_s
      base = slash.nil? ? logical : logical[slash + 1, logical.size - slash - 1].to_s
      dot = base.index(".")
      named = dot.nil? || dot == 0 ? "#{base}-#{digest}" : "#{base[0, dot]}-#{digest}#{base[dot, base.size - dot]}"
      "#{dir}#{named}"
    end

    # 8 lowercase hex characters.
    # @api private
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

    # A .manifest path that stays below public/assets: relative, no empty
    # or dot-led segment, no backslash, space or control character.
    # @api private
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

    # @return [String] the import map of config/importmap.rb as compact
    #   JSON (`{"imports":{...}}`), `</` written `\u003c/` so it can sit
    #   inside a <script> element
    # @api public
    def self.importmap_json
      @importmap_json
    end

    # @return [Array<String>] the paths (and URLs) of the pins to preload,
    #   in config/importmap.rb's order
    # @api public
    def self.preload_paths
      @preload_paths
    end
  end
end
