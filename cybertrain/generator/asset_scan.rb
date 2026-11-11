require "digest"
require "cybertrain/asset_manifest"

module Cybertrain
  module Gen
    # One asset file (spec section 7.1): its logical path (the path below
    # its root: "logo.svg", "controllers/hello_controller.js"), its source
    # path relative to the application root ("app/assets/images/logo.svg"),
    # its bytes (for a stylesheet, the text with its url()s rewritten), the
    # first 8 hex characters of the SHA-256 of those bytes, and the digested
    # name it is written under in public/assets ("logo-1a2b3c4d.svg").
    class AssetFile
      attr_reader :logical_path, :source_path, :asset_body, :asset_digest, :digested_path

      def initialize(logical_path, source_path, asset_body)
        @logical_path = logical_path
        @source_path = source_path
        @asset_body = asset_body
        @asset_digest = ""
        @digested_path = ""
      end

      def css_asset?
        @logical_path.end_with?(".css")
      end

      # Sets the bytes the file is served with and digests them.
      def assign_body(body)
        @asset_body = body
        @asset_digest = AssetScan.short_digest(body)
        @digested_path = AssetManifest.digested_name(@logical_path, @asset_digest)
        nil
      end
    end

    # One url(...) of a stylesheet: where its target starts and ends in the
    # text, and the target as written (quotes excluded).
    class CssUrl
      attr_reader :url_start, :url_stop, :url_target

      def initialize(url_start, url_stop, url_target)
        @url_start = url_start
        @url_stop = url_stop
        @url_target = url_target
      end
    end

    # Finds the application's assets (spec section 7.1) under
    # app/assets/*/ (each subdirectory a root), app/javascript and
    # vendor/javascript, and digests them. Dotfiles (.keep, .DS_Store) and
    # symlinked directories are skipped (a root that is a symlink stops
    # gen). A logical path found under two roots is refused (plan decision
    # 29; Propshaft silently takes the first). Stylesheets have their url()s rewritten to digested paths
    # before they are digested, each after the stylesheets it names.
    module AssetScan
      URL_SKIPPED = ["data:", "http:", "https:", "//", "#", "%23"].freeze

      def self.scan(root)
        files = Array.new(0) { AssetFile.new("", "", "") }
        asset_roots(root).each { |dir| collect(root, dir, "", files) }
        sorted = files.sort_by { |f| f.logical_path }
        sorted.each { |f| f.assign_body(f.asset_body) unless f.css_asset? }
        done = Array.new(0) { "" }
        sorted.each do |f|
          next unless f.css_asset?

          digest_css(f, sorted, done, Array.new(0) { "" }).each { |w| puts w }
        end
        sorted
      end

      # The roots, relative to root, in lookup order. A root that is itself
      # a symlink (app/assets, app/javascript, vendor/javascript) stops gen,
      # as symlinked directories are never followed; a symlinked
      # app/assets/<dir> is skipped like any other symlinked directory.
      def self.asset_roots(root)
        refuse_linked_root(root, "app/assets")
        refuse_linked_root(root, "app/javascript")
        refuse_linked_root(root, "vendor/javascript")
        roots = Array.new(0) { "" }
        if File.directory?("#{root}/app/assets")
          Dir.children("#{root}/app/assets").sort.each do |entry|
            next if entry.start_with?(".")

            path = "#{root}/app/assets/#{entry}"
            roots << "app/assets/#{entry}" if File.directory?(path) && !File.symlink?(path)
          end
        end
        roots << "app/javascript"
        roots << "vendor/javascript"
        roots
      end

      def self.refuse_linked_root(root, dir)
        return nil unless File.symlink?("#{root}/#{dir}")

        message = "#{dir} is a symlink; asset directories are never followed, so make it a real directory"
        raise ArgumentError, message
      end

      def self.collect(root, dir, prefix, files)
        full = prefix == "" ? "#{root}/#{dir}" : "#{root}/#{dir}/#{prefix}"
        return nil unless File.directory?(full)

        Dir.children(full).sort.each do |entry|
          next if entry.start_with?(".")

          path = "#{full}/#{entry}"
          logical = prefix == "" ? entry : "#{prefix}/#{entry}"
          if File.directory?(path)
            collect(root, dir, logical, files) unless File.symlink?(path)
          else
            add_file(root, "#{dir}/#{logical}", logical, files)
          end
        end
        nil
      end

      def self.add_file(root, source, logical, files)
        check_link(root, source)
        unless AssetManifest.safe_logical?(logical)
          message = "asset #{source}: a name with a space or a control character cannot be served; rename it"
          raise ArgumentError, message
        end
        files.each do |f|
          next unless f.logical_path == logical

          message = "asset #{logical} is both #{f.source_path} and #{source}"
          raise ArgumentError, message
        end
        body = logical.end_with?(".css") ? File.read("#{root}/#{source}") : File.binread("#{root}/#{source}")
        files << AssetFile.new(logical, source, body)
        nil
      end

      # A symlinked file is read only when it resolves inside the tree it
      # was found in (app/assets, app/javascript or vendor/javascript), as
      # symlinked directories are never followed at all; one leading
      # outside, or dangling, stops gen with the path named.
      def self.check_link(root, source)
        path = "#{root}/#{source}"
        return nil unless File.symlink?(path)

        unless File.exist?(path)
          message = "asset #{source} is a symlink to a file that does not exist"
          raise ArgumentError, message
        end
        tree = source.start_with?("app/assets/") ? "app/assets" : source.split("/")[0, 2].to_a.join("/")
        base = "#{File.realpath("#{root}/#{tree}")}/"
        unless File.realpath(path).start_with?(base)
          message = "asset #{source} is a symlink to a file outside #{tree}; copy the file in instead"
          raise ArgumentError, message
        end
        nil
      end

      def self.short_digest(body)
        Digest::SHA256.hexdigest(body)[0, 8].to_s
      end

      # Rewrites stylesheet css (logical path css_logical) after the
      # stylesheets it names, then digests it; returns its warnings.
      def self.digest_css(file, files, done, stack)
        warnings = Array.new(0) { "" }
        return warnings if done.include?(file.logical_path)

        if stack.include?(file.logical_path)
          chain = stack[stack.index(file.logical_path).to_i, stack.size].to_a
          chain << file.logical_path
          message = "CSS url() cycle: #{chain.join(" -> ")}"
          raise ArgumentError, message
        end
        stack << file.logical_path
        url_refs(file.asset_body).each do |ref|
          dep = find(files, url_logical(ref.url_target, file.logical_path))
          next if dep.nil? || !dep.css_asset?

          digest_css(dep, files, done, stack).each { |w| warnings << w }
        end
        stack.pop
        rewritten = rewrite_css(file.asset_body, file.logical_path, files)
        file.assign_body(rewritten[0].to_s)
        rewritten[1].to_a.each { |w| warnings << w.to_s }
        done << file.logical_path
        warnings
      end

      # The rewritten css and its warnings: each url() naming an asset (from
      # css_logical's logical directory, or from the roots with a leading
      # "/") becomes its digested path, its ?query / #fragment kept; data:,
      # http:, https:, //, # and %23 targets are left alone, and so, with a
      # warning, is anything else that is not an asset.
      def self.rewrite_css(css, css_logical, files)
        s = css.to_s
        warnings = Array.new(0) { "" }
        out = +""
        pos = 0
        url_refs(s).each do |ref|
          out << s[pos, ref.url_start - pos].to_s
          target = ref.url_target
          replaced = target
          unless skipped_url?(target)
            cut = suffix_start(target)
            asset = find(files, url_logical(target, css_logical))
            if asset.nil? || asset.digested_path.empty?
              warnings << "warning: #{source_of(files, css_logical)}: url(#{target}) is not an asset; left as written"
            else
              replaced = "/assets/#{asset.digested_path}#{target[cut, target.size - cut]}"
            end
          end
          out << replaced
          pos = ref.url_stop
        end
        out << s[pos, s.size - pos].to_s
        [out, warnings]
      end

      # The logical path a url() target names (its ?query / #fragment cut
      # off), or "" for a skipped target (data:, http:, ...) or one that
      # climbs above the roots. digest_css and rewrite_css both read targets
      # through it, so the dependency order and the rewrite agree.
      def self.url_logical(target, css_logical)
        return "" if skipped_url?(target)

        resolve(target[0, suffix_start(target)].to_s, css_logical)
      end

      def self.skipped_url?(target)
        return true if target.empty?

        lower = target.downcase
        URL_SKIPPED.each { |p| return true if lower.start_with?(p) }
        false
      end

      # Where a target's ?query or #fragment starts (its size without one).
      def self.suffix_start(target)
        q = target.index("?")
        h = target.index("#")
        cut = target.size
        cut = q if !q.nil? && q < cut
        cut = h if !h.nil? && h < cut
        cut
      end

      # The logical path a url() path names: below css_logical's directory,
      # or below the roots with a leading "/"; "" when it climbs above them.
      def self.resolve(path, css_logical)
        parts = Array.new(0) { "" }
        unless path.start_with?("/")
          dir = css_logical.split("/")
          dir.pop
          dir.each { |p| parts << p }
        end
        path.split("/").each do |p|
          next if p.empty? || p == "."

          if p == ".."
            return "" if parts.empty?

            parts.pop
          else
            parts << p
          end
        end
        parts.join("/")
      end

      def self.find(files, logical)
        return nil if logical.empty?

        files.each { |f| return f if f.logical_path == logical }
        nil
      end

      def self.source_of(files, logical)
        f = find(files, logical)
        f.nil? ? logical : f.source_path
      end

      # Every well-formed url(...) of css, in order.
      def self.url_refs(css)
        s = css.to_s
        refs = Array.new(0) { CssUrl.new(0, 0, "") }
        pos = 0
        while (open = s.index("url(", pos))
          i = skip_spaces(s, open + 4)
          quote = s[i, 1].to_s
          if quote == "\"" || quote == "'"
            start = i + 1
            stop = s.index(quote, start)
            close = stop.nil? ? nil : skip_spaces(s, stop + 1)
          else
            start = i
            stop = start
            stop += 1 while stop < s.size && s[stop, 1] != ")" && !space?(s[stop, 1].to_s) && s[stop, 1] != "\"" && s[stop, 1] != "'"
            close = skip_spaces(s, stop)
          end
          if !stop.nil? && !close.nil? && s[close, 1] == ")"
            refs << CssUrl.new(start, stop, s[start, stop - start].to_s)
            pos = close + 1
          else
            pos = open + 4
          end
        end
        refs
      end

      def self.skip_spaces(s, i)
        j = i
        j += 1 while j < s.size && space?(s[j, 1].to_s)
        j
      end

      def self.space?(c)
        c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\f"
      end
    end
  end
end
