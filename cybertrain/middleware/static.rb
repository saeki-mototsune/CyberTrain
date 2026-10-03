require "cybertrain/middleware"

module Cybertrain
  # Serves files under `root` (the app's public/ directory) for GET and HEAD
  # requests; anything that is not a readable file falls through to the next
  # app. A directory serves its index.html.
  class Static < Middleware
    EXTENSIONS = {
      "html" => "text/html; charset=utf-8",
      "css" => "text/css; charset=utf-8",
      "js" => "text/javascript; charset=utf-8",
      "png" => "image/png",
      "jpg" => "image/jpeg",
      "jpeg" => "image/jpeg",
      "gif" => "image/gif",
      "svg" => "image/svg+xml",
      "ico" => "image/x-icon",
      "txt" => "text/plain; charset=utf-8",
      "json" => "application/json",
      "woff2" => "font/woff2",
      "map" => "application/json"
    }
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
    # the ".." and "/" they stand for and cannot climb out of the root. They come from request.path_segments,
    # which decodes once per request: the Router reads the same cached Array
    # afterwards (read-only here, as there), and an invalid byte sequence in a
    # decoded segment is raised from there as the one QueryMalformed (400)
    # decision, by whichever reads first -- this middleware for GET/HEAD.
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
