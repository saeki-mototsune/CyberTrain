# Cybertrain::Request's format: the extension the router split off the
# path and the format the client asked for (Rails' `request.format`).
#
# A cybertrain concept, so spinel-http's Request does not carry it
# (docs/design.md D91): this file reopens the class through its alias
# (cybertrain/http/request.rb, `Cybertrain::Request = SpinelHttp::Request`)
# and adds methods only (a constant added that way is defined nowhere under
# the fork: spikes/spinel-http/step3/README.md, 3d). The router, the
# controller, rendering and the HTTP cache require it, and so does the
# request shim, which this file requires back (whichever loads first, the
# alias exists before the reopening below).
#
# The layer's `initialize` cannot be added to, so the three ivars start
# unset on every Request: `@format_extension` reads as `""` until the router
# sets it, `@format_known` as false (unset is falsy under CRuby and false
# under Spinel, where it only ever holds a Bool), and `@format_symbol` is
# read only once `@format_known` is true, so always after it was set.
# `@format_extension` is only ever assigned a String (a nullable pointer
# under Spinel, the same C type with or without nil: spikes/NOTES.md rule
# 109).
require "cybertrain/http/request"

module Cybertrain
  class Request
    # The extension a router split off the last path segment (`"json"` for
    # `/articles/3.json`), `""` for none or before routing.
    # @return [String]
    # @api public
    def format_extension
      ext = @format_extension
      return "" if ext.nil?

      ext
    end

    # Set by a router for the route that matched; forgets a {#format}
    # worked out earlier.
    def format_extension=(ext)
      @format_extension = ext
      @format_known = false
    end

    # The format the client asked for, as a Symbol: the extension's
    # registered name ({Request.format_for_extension}: `:json` for
    # `/articles/3.json`, `:unknown` for one that is not registered), else
    # from `Accept`, read in order: `:turbo_stream` when it lists
    # `text/vnd.turbo-stream.html`, `:json` when it lists
    # `application/json` and not `text/html` before it, else `:html` (also
    # for `*/*` and no `Accept` at all). An entry with `q=0` is ignored;
    # other q-values do not reorder the list.
    # @example
    #   request.format   # => :json for GET /articles/3.json
    # @return [Symbol]
    # @api public
    def format
      return @format_symbol if @format_known

      ext = format_extension
      found = if ext.empty?
                Request.format_for_accept(header("Accept").to_s)
              else
                Request.format_for_extension(ext)
              end
      @format_symbol = found
      @format_known = true
      found
    end

    # The format an `Accept` header names (see {#format}).
    def self.format_for_accept(value)
      accept = value.to_s # a fresh String for the scan
      turbo = false
      json_at = -1
      html_at = -1
      position = 0
      accept.split(",").each do |entry|
        parts = entry.split(";")
        next if parts.empty?

        media = parts[0].to_s.strip.downcase
        next if Request.entry_quality(parts) == 0

        turbo = true if media == "text/vnd.turbo-stream.html"
        json_at = position if media == "application/json" && json_at < 0
        html_at = position if media == "text/html" && html_at < 0
        position += 1
      end
      return :turbo_stream if turbo
      return :json if json_at >= 0 && (html_at < 0 || html_at > json_at)

      :html
    end

    # The registered format of an extension, Rails' MIME table (`"json"` ->
    # `:json`, `"jpg"` -> `:jpeg`, `"txt"` -> `:text`), `:unknown` for any
    # other: a fixed table, so request input never becomes a new Symbol.
    # @param ext [String] without the dot, as written (case matters)
    # @return [Symbol]
    # @api public
    def self.format_for_extension(ext)
      case ext
      when "html", "htm" then :html
      when "text", "txt" then :text
      when "js" then :js
      when "css" then :css
      when "ics" then :ics
      when "csv" then :csv
      when "vcf" then :vcf
      when "vtt" then :vtt
      when "png" then :png
      when "jpeg", "jpg" then :jpeg
      when "gif" then :gif
      when "bmp" then :bmp
      when "tiff" then :tiff
      when "svg" then :svg
      when "webp" then :webp
      when "mpeg" then :mpeg
      when "mp3" then :mp3
      when "ogg" then :ogg
      when "m4a" then :m4a
      when "webm" then :webm
      when "mp4" then :mp4
      when "otf" then :otf
      when "ttf" then :ttf
      when "woff" then :woff
      when "woff2" then :woff2
      when "xml" then :xml
      when "rss" then :rss
      when "atom" then :atom
      when "yaml" then :yaml
      when "multipart_form" then :multipart_form
      when "url_encoded_form" then :url_encoded_form
      when "json" then :json
      when "pdf" then :pdf
      when "zip" then :zip
      when "gzip" then :gzip
      when "turbo_stream" then :turbo_stream
      else :unknown
      end
    end

    # The Content-Type a response in `format` is sent with (`:json` ->
    # `"application/json; charset=utf-8"`); `"application/octet-stream"`
    # for a format without a text type here.
    # @param format [Symbol]
    # @return [String]
    # @api public
    def self.mime_type(format)
      case format
      when :html then "text/html; charset=utf-8"
      when :json then "application/json; charset=utf-8"
      when :turbo_stream then "text/vnd.turbo-stream.html; charset=utf-8"
      when :csv then "text/csv; charset=utf-8"
      when :xml then "application/xml; charset=utf-8"
      when :text then "text/plain; charset=utf-8"
      when :js then "text/javascript; charset=utf-8"
      when :css then "text/css; charset=utf-8"
      else "application/octet-stream"
      end
    end
  end
end
