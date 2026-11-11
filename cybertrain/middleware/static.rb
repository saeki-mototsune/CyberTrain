require "cybertrain/middleware"
require "cybertrain/assets"

module Cybertrain
  # Serves files under `root` (the app's public/ directory) for GET and HEAD
  # requests; anything that is not a readable file falls through to the next
  # app. A directory serves its index.html. A file under /assets whose name
  # carries a digest gen wrote (Assets.kept_file?) is cached for a year as
  # immutable (spec 7.4): its name changes with its content, so it is never
  # rewritten in place and needs no ETag. Everything else, an undigested
  # file under public/assets included, is cached for an hour. A file whose
  # realpath leaves the root's (a symlink out of public/) is not served: a
  # deploy that keeps public/assets elsewhere mounts it there instead.
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
    IMMUTABLE_CACHE_CONTROL = "public, max-age=31536000, immutable"

    def initialize(app, root = "public")
      super(app)
      @root = root
      # The root's realpath with a trailing "/", found on the first file
      # served (the root may not exist yet when the stack is built). Two
      # workers finding it at once write the same String.
      @real_root = ""
    end

    def call(ctx)
      request = ctx.request
      if request.get? || request.head?
        file = file_for(request)
        unless file.empty?
          serve(ctx.response, file, immutable?(request))
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
    # first -- this middleware for GET/HEAD. Under /assets a segment that
    # starts with "." is not served: gen's .manifest and the
    # .<name>.<pid>.tmp a crashed gen run leaves are its own files. Dotfiles
    # placed elsewhere in public/ (/.well-known/...) are served.
    def file_for(request)
      segments = request.path_segments
      segments.each do |seg|
        return "" if seg == ".." || seg == "." || seg.include?("/") || seg.include?("\\") || seg.include?("\0")
      end
      if !segments.empty? && segments[0] == "assets"
        segments.each { |seg| return "" if seg.start_with?(".") }
      end
      file = segments.empty? ? @root : "#{@root}/#{segments.join("/")}"
      file = "#{file}/index.html" if File.directory?(file)
      return "" unless File.file?(file)

      inside_root?(file) ? file : ""
    end

    # Whether file, after its symlinks, is still under the root: a symlink
    # in public/ that leads elsewhere is not served (one inside it is).
    def inside_root?(file)
      root = real_root
      return false if root.empty?

      File.realpath(file).start_with?(root)
    rescue SystemCallError
      false
    end

    def real_root
      known = @real_root
      return known unless known.empty?

      found = File.realpath(@root)
      found = "#{found}/" unless found.end_with?("/")
      @real_root = found
      found
    rescue SystemCallError
      ""
    end

    # A digested file under /assets: the segments after "assets" name it.
    def immutable?(request)
      segments = request.path_segments
      return false if segments.size < 2 || segments[0] != "assets"

      Assets.kept_file?(segments[1, segments.size - 1].to_a.join("/"))
    end

    def serve(response, file, immutable)
      response.status = 200
      response.content_type = content_type_for(file)
      response.set_header("Cache-Control", immutable ? IMMUTABLE_CACHE_CONTROL : CACHE_CONTROL)
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
