# cybertrain/streams: Turbo Streams, an optional subsystem (require
# "cybertrain/streams" in bin/NAME.rb, or require "cybertrain";
# docs/superpowers/specs/2026-11-13-optional-subsystems-design.md):
#
#   Stream, its broadcasts and its message table   cybertrain/stream.rb
#   the endpoint (SSE and WebSocket), its poller   cybertrain/stream/*.rb
#   the <turbo-stream> elements                    cybertrain/turbo.rb
#   Controller#turbo_stream (TurboStreams)          cybertrain/turbo_stream_renderer.rb, here
#   turbo_stream_from, turbo_stream, signed_stream_name and
#   stream_source_path in templates                cybertrain/template/stream_helpers.rb,
#                                                  template/turbo_stream_builder.rb
#
# The core never names any of this: Application#build_stack mounts the
# endpoint, the server role starts the poller before its listener and
# stops it at the end, and the template helper dispatch reaches the stream
# helpers, all through StreamsFeature, which this file registers at its
# end (cybertrain/feature.rb). It loads the controller and the template
# helpers it reopens, not the whole core (bin/NAME.rb requires
# cybertrain/core). Requiring it twice, or after require "cybertrain", is a
# no-op.
require "cybertrain/config"
require "cybertrain/feature"
require "cybertrain/middleware"
require "cybertrain/controller"
require "cybertrain/turbo"
require "cybertrain/stream"
require "cybertrain/stream/endpoint"
require "cybertrain/turbo_stream_renderer"
require "cybertrain/template/helpers"
require "cybertrain/template/turbo_stream_builder"
require "cybertrain/template/stream_helpers"

module Cybertrain
  # Defined here, on the core's Controller, by cybertrain/streams.
  class Controller
    # The Turbo Stream builder of an action (turbo-rails' `turbo_stream`):
    # replace, update, append, prepend, before and after (a target and one
    # of `partial:` with `locals:`, or `html:`) and remove (a target), each
    # a `<turbo-stream>` element for `render turbo_stream:`.
    # @example
    #   render turbo_stream: turbo_stream.replace(@comment, partial: "comment", locals: { comment: @comment })
    # @return [TurboStreams]
    # @api public
    def turbo_stream
      TurboStreams.new(self)
    end
  end

  # What streams add to the core, through Feature's hooks: the endpoint in
  # the middleware stack (unless Config#stream_path is ""), the poller
  # started before the server role's listener and stopped with the role,
  # and the stream helpers of templates.
  # @api private
  class StreamsFeature < Feature
    def feature_name
      "streams"
    end

    def feature_rank
      30
    end

    # Its start position (MAX(id)) must come before any subscription, so
    # before the listener; only with the endpoint mounted.
    def start_feature_early(config)
      Stream::Poller.start!(config) unless config.stream_path.empty?
      nil
    end

    # A no-op when it never started.
    def stop_feature
      Stream::Poller.stop!
      nil
    end

    # At its place in the stack (after HealthCheck, before the session):
    # its authorisation is the signed token, and it sets no cookie.
    def feature_middleware(app, config)
      return nil if config.stream_path.empty?

      Stream::Endpoint.new(app, config)
    end

    def feature_helper?(name)
      case name
      when "turbo_stream_from", "turbo_stream", "signed_stream_name", "stream_source_path" then true
      else false
      end
    end

    def feature_helper(helpers, name, args, kwargs, block, interp, env)
      helpers.streams_helper(name, args, kwargs, block, interp, env)
    end
  end
end

Cybertrain::Features.register_feature(Cybertrain::StreamsFeature.new)
