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
module Cybertrain
  # The digested asset paths and the import map gen/assets.rb installs:
  # read by the asset helpers and the static file server.
  # @api public
  module Assets
    # The resolver of an application with no assets: every name unknown.
    # Returned by a method, not written as a literal into the ivar below:
    # a lambda literal assigned to a module-level ivar never learns its call
    # sites' argument types (spikes/NOTES.md rule 82); `name.empty?` types
    # its parameter as a String.
    # @api private
    def self.empty_resolver
      ->(name) { name.empty? ? "" : "" }
    end

    @resolver = empty_resolver
    @importmap_json = "{\"imports\":{}}"
    @preload_paths = Array.new(0) { "" }

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

    # @return [String] the import map of config/importmap.rb as compact
    #   JSON (`{"imports":{...}}`), `</` written `</`
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
