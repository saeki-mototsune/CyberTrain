# Cybertrain::GzipDecoder -- where the HTTP client finds its gzip support.
#
# The client (cybertrain/http_client.rb) and the inflater
# (cybertrain/http/gzip_ffi.rb, which links the system zlib) both require
# this file and nothing of each other: a program with only the client
# links no zlib, and a server that inflates request bodies with GzipFFI
# carries no client. This base has no gzip: {#gzip_ready?} is false, so
# the client sends no `Accept-Encoding` and refuses a gzip response.
# Requiring cybertrain/http/gzip_ffi installs its subclass as
# {GzipDecoder.installed} (what {HttpClient.gzip=} sets and
# {HttpClient.gzip_decoder} reads), the way cybertrain/net/tls installs the
# TLS connector.
#
# One decoder object inflates one body: the installed one is a factory
# ({#gzip_open}). A failure is a status ({#gzip_status}), never an
# exception, so the client raises its own errors and names no class of the
# inflater's file, which may not be in the program (spikes/NOTES.md
# rule 89).
module Cybertrain
  # The gzip support the HTTP client calls ({HttpClient.gzip_decoder});
  # this base is the one without gzip. Only {#gzip_ready?} is for
  # applications; the rest is the client's.
  # @api public
  class GzipDecoder
    # {#gzip_status} values.
    GZIP_OK = 0
    GZIP_UNDECODABLE = 1
    GZIP_TOO_LARGE = 2

    # @return [Integer] GZIP_OK, or why the last step failed
    attr_reader :gzip_status

    def initialize
      @gzip_status = 0
    end

    # @return [Boolean] true once `require "cybertrain/http/gzip_ffi"` has
    #   installed the zlib decoder
    # @api public
    def gzip_ready?
      false
    end

    # A decoder for one body.
    # @return [GzipDecoder]
    def gzip_open
      GzipDecoder.new
    end

    # The whole of `data` inflated, at most `limit` bytes; "" with
    # {#gzip_status} set when it fails.
    def gzip_whole(data, limit)
      @gzip_status = GzipDecoder::GZIP_UNDECODABLE
      ""
    end

    # Hands the next compressed bytes of a streamed body to the decoder.
    def gzip_push(data)
      @gzip_status = GzipDecoder::GZIP_UNDECODABLE
      nil
    end

    # The next inflated piece of what was pushed, "" once it is all
    # inflated (or {#gzip_status} is set).
    def gzip_pull
      ""
    end

    # True when the bytes pushed so far end with a complete gzip stream.
    def gzip_done?
      false
    end

    # Frees what the decoder holds; safe to call more than once.
    def gzip_close
      nil
    end

    # Module-level ivar, not a class variable (spikes/NOTES.md rules 18, 64).
    @installed = GzipDecoder.new

    # The decoder the HTTP client uses.
    # @return [GzipDecoder]
    def self.installed
      @installed
    end

    def self.installed=(decoder)
      @installed = decoder
    end
  end
end
