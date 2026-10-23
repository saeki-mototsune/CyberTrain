require "cybertrain/middleware"

module Cybertrain
  # Serves files under `root` (the app's public/ directory) for GET and HEAD
  # requests; anything that is not a readable file falls through to the next
  # app. A directory serves its index.html.
  class Static < Middleware
    EXTENSIONS = {
      "html" => "text/html; charset=utf-8",
      "htm" => "text/html; charset=utf-8",
      "css" => "text/css; charset=utf-8",
      "js" => "text/javascript; charset=utf-8",
      "mjs" => "text/javascript; charset=utf-8",
      "png" => "image/png",
      "jpg" => "image/jpeg",
      "jpeg" => "image/jpeg",
      "gif" => "image/gif",
      "webp" => "image/webp",
      "avif" => "image/avif",
      "bmp" => "image/bmp",
      "svg" => "image/svg+xml",
      "ico" => "image/x-icon",
      "txt" => "text/plain; charset=utf-8",
      "csv" => "text/csv; charset=utf-8",
      "xml" => "application/xml; charset=utf-8",
      "json" => "application/json",
      "webmanifest" => "application/manifest+json",
      "map" => "application/json",
      "pdf" => "application/pdf",
      "wasm" => "application/wasm",
      "woff2" => "font/woff2",
      "woff" => "font/woff",
      "ttf" => "font/ttf",
      "otf" => "font/otf",
      "mp3" => "audio/mpeg",
      "ogg" => "audio/ogg",
      "wav" => "audio/wav",
      "mp4" => "video/mp4",
      "webm" => "video/webm"
    }
    # What an extension the table lacks is served as. Every response also
    # carries `X-Content-Type-Options: nosniff` (Response#to_http), so a
    # browser takes this type at its word: scripts, styles and wasm only
    # work from public/ under the types above, and an unknown file is a
    # download. Add the extension here when an app needs it inline.
    DEFAULT_TYPE = "application/octet-stream"
    CACHE_CONTROL = "public, max-age=3600"

    def initialize(app, root = "public")
      super(app)
      @root = root
    end

    def call(ctx)
      request = ctx.request
      if request.get? || request.head?
        file = file_for(request)
        unless file.empty?
          serve(ctx.response, file)
          return nil
        end
      end
      super
    end

    private

    # The file to serve for a request, or "" when there is none. Path
    # segments are percent-decoded first, so "%2e%2e" and "%2f" are seen as
    # the ".." and "/" they stand for and cannot climb out of the root. They
    # come from request.path_segments, which validates and decodes once per
    # request: the Router reads the same cached Array afterwards (read-only
    # here, as there), and an invalid byte sequence in the path is raised from
    # there as the one QueryMalformed (400) decision, by whichever reads
    # first -- this middleware for GET/HEAD.
    def file_for(request)
      segments = request.path_segments
      segments.each do |seg|
        return "" if seg == ".." || seg == "." || seg.include?("/") || seg.include?("\\") || seg.include?("\0")
      end
      file = segments.empty? ? @root : "#{@root}/#{segments.join("/")}"
      file = "#{file}/index.html" if File.directory?(file)
      File.file?(file) ? file : ""
    end

    def serve(response, file)
      response.status = 200
      response.content_type = content_type_for(file)
      response.set_header("Cache-Control", CACHE_CONTROL)
      response.body = File.read(file)
    end

    def content_type_for(file)
      base = File.basename(file)
      dot = base.rindex(".")
      return DEFAULT_TYPE if dot.nil?

      EXTENSIONS[base[(dot + 1)..-1].to_s.downcase] || DEFAULT_TYPE
    end
  end
end
