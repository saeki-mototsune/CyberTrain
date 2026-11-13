# Cybertrain::Template::Helpers' stream helpers (turbo-rails' names),
# defined here by reopening the class, for cybertrain/streams: the core's
# helper dispatch (Helpers#helper_call) does not name them, and reaches
# them through StreamsFeature (Feature#feature_helper), which calls
# #streams_helper.
#
#   turbo_stream_from "alerts", @article     a <turbo-stream-source>
#   turbo_stream.replace @comment, ...       the template's builder
#   signed_stream_name @article              the token, for hand-written JS
#   stream_source_path @article, mode: "raw" the endpoint URL with the token
require "cybertrain/html"
require "cybertrain/model"
require "cybertrain/views"
require "cybertrain/stream"
require "cybertrain/template/helpers"
require "cybertrain/template/form_builder"
require "cybertrain/template/turbo_stream_builder"

module Cybertrain
  module Template
    class Helpers
      # The stream helper `name` with the helper dispatch's arguments
      # (StreamsFeature#feature_helper, for the names its feature_helper?
      # answers true for).
      # @return [SafeString, String, TurboStreamBuilder]
      # @api private
      def streams_helper(name, args, kwargs, block, interp, env)
        case name
        when "turbo_stream_from" then turbo_stream_from(args, kwargs)
        when "turbo_stream"
          # The template's builder (`turbo_stream.replace ...`). No method
          # named turbo_stream here: Controller#turbo_stream returns
          # TurboStreams (NAME_HOMES in script/check-reserved-names).
          helper_arity!(name, args, 0, 0)
          helper_no_keywords!(name, kwargs)
          raise CallSyntaxError, "turbo_stream takes no block (turbo_stream.replace \"id\" do ... end does)" unless block.nil?

          TurboStreamBuilder.new(self, interp, env)
        when "signed_stream_name" then signed_stream_name(args)
        when "stream_source_path" then stream_source_path(args, kwargs)
        else raise RuntimeError, "undefined helper '#{name}'"
        end
      end

      private

      # turbo_stream_from "alerts", @article: a <turbo-stream-source> whose
      # src is the stream endpoint with one signed token for all the names
      # (a String as it is, a record as Stream.name_for gives it). Turbo
      # opens it as an EventSource; `ws: true` gives a ws:// (wss:// behind
      # an https proxy) URL instead, built from the request, which Turbo
      # opens as a WebSocket.
      # The token is in the URL, so a proxy's access log sees it (the
      # framework's own request log writes it as [FILTERED]); anyone holding
      # it can read those streams.
      def turbo_stream_from(args, kwargs)
        token = signed_stream_name(args)
        src = +""
        src << stream_ws_base if kwargs["ws"] == true
        src << Helpers.stream_endpoint_path
        src << "?s="
        src << token
        escaped = Html.escape(src)
        SafeString.of("<turbo-stream-source src=\"#{escaped}\"></turbo-stream-source>")
      end

      # The signed token naming the streams, for hand-written JavaScript.
      def signed_stream_name(args)
        raise ArgumentError, "signed_stream_name needs at least one stream" if args.empty?

        names = Array.new(0) { "" }
        i = 0
        while i < args.size
          value = args[i]
          case value
          when Cybertrain::Model then names << Stream.name_for(value)
          else names << FormBuilder.value_text(value)
          end
          i += 1
        end
        Stream.sign(names)
      end

      # The endpoint URL with the token and `mode=json` (or mode: "raw"),
      # for an EventSource or WebSocket written by hand.
      def stream_source_path(args, kwargs)
        mode = kwargs["mode"].nil? ? "json" : lower_text(kwargs["mode"])
        raise ArgumentError, "stream_source_path mode: must be \"json\" or \"raw\", got #{mode.inspect}" unless mode == "json" || mode == "raw"

        token = signed_stream_name(args)
        out = +""
        out << Helpers.stream_endpoint_path
        out << "?s="
        out << token
        out << "&mode="
        out << mode
        out
      end

      def self.stream_endpoint_path
        path = Cybertrain.config.stream_path
        raise ArgumentError, "the stream endpoint is off (Config#stream_path is \"\")" if path.empty?

        path
      end

      # "ws://host" from the request's base URL ("wss://" for https).
      def stream_ws_base
        # Raises OutsideRequest when rendering outside a request (B's rule);
        # the nil check below is the fallback for a bare Helpers.new(nil).
        request_bound!("turbo_stream_from")
        controller = @controller
        raise Views::OutsideRequest, "turbo_stream_from ws: true needs a request" if controller.nil?

        base = controller.request.base_url
        return "wss://#{base.byteslice(8, base.bytesize - 8)}" if base.start_with?("https://")

        "ws://#{base.byteslice(7, base.bytesize - 7)}"
      end
    end
  end
end
