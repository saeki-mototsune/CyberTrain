module Cybertrain
  # The registry of client faults defined outside the layer, the part of
  # ClientError a library that defines one needs at load. A file of its own,
  # loading nothing, so that library can register its class without loading
  # Query, Response or the rest of the layer: cybertrain/http/client_error.rb
  # requires it and matches these names as it matches CLIENT_FAULTS.
  module ClientError
    # The client faults the layer does not define: full class names,
    # matched exactly as CLIENT_FAULTS' are. Registering one is the job of
    # the library that defines the class, at load (a framework's
    # missing-required-parameter error, say); a program that never loads
    # that library never raises the class. A module-level ivar with a
    # literal default (the Params.max_page shape, spikes/NOTES.md rule 18).
    @extra_faults = Array.new(0) { "" }

    # The client faults registered on top of CLIENT_FAULTS, empty until a
    # library adds one with {.extra_faults=}.
    # @return [Array<String>] full class names
    # @api public
    def self.extra_faults
      @extra_faults
    end

    # Installs the client faults added to CLIENT_FAULTS, replacing the
    # earlier ones (a copy of `names` is kept): add to them with
    # `ClientError.extra_faults = ClientError.extra_faults + [name]`.
    # Called at load, before any thread starts. Requiring
    # cybertrain/http/extra_faults is enough to call it.
    # @example
    #   require "cybertrain/http/extra_faults"
    #   ClientError.extra_faults = ClientError.extra_faults + ["MyLib::MissingInput"]
    # @param names [Array<String>] full class names
    # @return [nil]
    # @api public
    def self.extra_faults=(names)
      full = Array.new(0) { "" }
      i = 0
      while i < names.length
        full << names[i]
        i += 1
      end
      @extra_faults = full
      nil
    end
  end
end
