# Cybertrain::Assets -- the asset manifest an application runs with (spec
# section 7). `spin run gen` digests app/assets, app/javascript and
# vendor/javascript into public/assets and writes gen/assets.rb, whose last
# line installs its tables here:
#
#   Cybertrain::Assets.install(Gen::Assets.resolver, Gen::Assets.importmap_json, Gen::Assets.preload_paths,
#                              "<build digest>")
#
# Until then (an application with no gen/assets.rb) the table is empty:
# every name is unknown, the import map has no imports and nothing is
# preloaded. Module-level instance variables rather than @@class_variables
# (spikes/NOTES.md rule 18).
require "cybertrain/asset_manifest"
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
    @build_digest = ""
    # The digested names below /assets that public/assets/.manifest keeps
    # (load_kept), name => true. Typed empty Hash (rule 9).
    @kept = { "" => true }
    @kept.delete("")
    # false in production (Application#boot): an unknown name is logged
    # once and written undigested instead of raising.
    @raise_on_unknown = true
    # The unknown names production has logged, name => true: at most
    # MAX_LOGGED_UNKNOWN (names can come from requests), then no new name
    # is logged.
    @logged = { "" => true }
    @logged.delete("")
    UNKNOWN_LOCK = Mutex.new
    MAX_LOGGED_UNKNOWN = 1000

    # Installs gen/assets.rb's tables; gen/assets.rb calls it when the
    # application loads.
    # @param resolver [Proc] logical path => digested path ("" when unknown),
    #   `Gen::Assets.resolver`; pass it positionally (spikes/NOTES.md rule 42)
    # @param importmap_json [String] the import map, compact JSON
    # @param preload_paths [Array<String>] the paths and URLs to preload
    # @param build_digest [String] a digest of this build's assets (and,
    #   in a `cybertrain build` binary, its embedded views), {.build_digest}
    # @return [nil]
    # @api public
    def self.install(resolver, importmap_json, preload_paths, build_digest = "")
      @resolver = resolver
      @importmap_json = importmap_json
      @preload_paths = preload_paths
      @build_digest = build_digest
      nil
    end

    # A digest gen writes into gen/assets.rb: of the digested assets and
    # the import map, and in a binary `cybertrain build` made, of the views
    # and components embedded in it too. It changes when a deploy changes
    # what a page renders, so {Controller#fresh_when} mixes it into every
    # ETag; `""` until gen/assets.rb installs one.
    # @return [String]
    # @api public
    def self.build_digest
      @build_digest
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

      if @raise_on_unknown
        message = "asset \"#{name}\" is not in app/assets, app/javascript or vendor/javascript (run spin run gen)"
        raise UnknownAsset, message
      end

      # name.inspect: a name from a request cannot write a line of its own.
      log_unknown(name, "asset #{name.inspect} is not in app/assets, app/javascript or vendor/javascript (run spin run gen)")
      "/assets/#{name}"
    end

    # Logs message once per name, for the first MAX_LOGGED_UNKNOWN names
    # (requests on several workers may ask at once; Spinel has no GVL, so
    # the set is guarded).
    # @api private
    def self.log_unknown(name, message)
      first = false
      UNKNOWN_LOCK.synchronize do
        if !@logged.key?(name) && @logged.size < MAX_LOGGED_UNKNOWN
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

    # @return [Boolean] whether an unknown name raises
    # @api public
    def self.raise_on_unknown
      @raise_on_unknown
    end

    # Reads public_root/assets/.manifest (written by `spin run gen`): the
    # digests it keeps for each logical path, so that a page served before
    # a deploy still fetches its files as immutable. Application#boot calls
    # it once; a missing file keeps none. A malformed line is skipped
    # whole, as gen skips it (AssetManifest.read_kept).
    # @param public_root [String]
    # @return [nil]
    # @api public
    def self.load_kept(public_root)
      kept = { "" => true }
      kept.delete("")
      file = "#{public_root}/assets/#{AssetManifest::FILE}"
      if File.file?(file)
        lines = AssetManifest.read_kept(File.read(file))
        lines.each_key do |logical|
          lines[logical].each { |digest| kept[AssetManifest.digested_name(logical, digest)] = true }
        end
      end
      @kept = kept
      nil
    end

    # Keeps no digest, as before the first {.load_kept} (Runtime.reset!).
    # @return [nil]
    # @api private
    def self.forget_kept
      kept = { "" => true }
      kept.delete("")
      @kept = kept
      nil
    end

    # @return [Integer] how many digested names {.load_kept} keeps
    # @api private
    def self.kept_count
      @kept.size
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

      logical = AssetManifest.logical_of(name)
      return false if logical.empty?

      @resolver.call(logical) == "/assets/#{name}"
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
