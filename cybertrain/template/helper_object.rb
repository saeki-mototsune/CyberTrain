module Cybertrain
  module Template
    # The base of an object a subsystem's template helper answers and the
    # template then calls methods on (with cybertrain/streams,
    # TurboStreamBuilder: `turbo_stream.replace ...`). The interpreter hands
    # `obj.x` to Helpers#call_object_method, which hands it here for any
    # HelperObject, so the core's helpers never name the subsystem's class
    # (docs/superpowers/specs/2026-11-13-optional-subsystems-design.md,
    # section 4). A block is rendered by the helpers before the call and
    # arrives as its output, so the object never holds one (spikes/NOTES.md
    # rule 88).
    #
    # A subclass overrides both methods (the stubs raise, as calling an
    # undefined method on a template object does: NOTES rule 3 wants the
    # stub for a directly dispatched method).
    # @api private
    class HelperObject
      # `obj.name(args, kwargs)` without a block.
      # @param name_sym [Symbol]
      # @param args [Array]
      # @param kwargs [Hash{String => Object}]
      # @return [SafeString]
      def helper_object_call(name_sym, args, kwargs)
        raise RuntimeError, "undefined method '#{name_sym}' for #{self.class.name}"
      end

      # The same with a block, whose output is `content`.
      # @param content [String]
      # @return [SafeString]
      def helper_object_call_with_block(name_sym, args, kwargs, content)
        raise RuntimeError, "undefined method '#{name_sym}' for #{self.class.name}"
      end
    end
  end
end
