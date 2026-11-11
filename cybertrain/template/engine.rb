# Cybertrain::Template::Engine -- finds, parses and caches view templates.
#
#   engine = Cybertrain::Template::Engine.new("app/views", cache: false)
#   html = engine.render_with_layout("posts/index", "layouts/application", env, helpers)
#
# Templates are parsed at run time. Two sources:
#   Engine.new("app/views", cache: false)   -- files under a root; with
#     `cache: true` (production) each file is parsed once, with `cache: false`
#     (development) a file is re-parsed whenever its mtime or size changes.
#     That re-parse writes the cache on the request thread, so development
#     serves on one worker (Application.serving_workers, NOTES rule 57).
#   Engine.embedded(sources)                -- a Hash of "posts/index.html.erb"
#     => source, generated into the binary by `spin run gen -- --embed-views`;
#     all parsed when the engine is built, never re-read.
require "cybertrain/html"
require "cybertrain/template/limits"
require "cybertrain/template/lexer"
require "cybertrain/template/parser"
require "cybertrain/template/inode"
require "cybertrain/template/interpreter"

module Cybertrain
  module Template
    class MissingTemplate < StandardError
    end

    # One parsed template: its compiled nodes plus the strict locals its
    # line-1 `<%# locals: (post:) %>` comment declares.
    class Template
      attr_reader :name, :nodes, :locals, :source_path

      def self.parse(source, name, source_path = "")
        tokens = Lexer.tokenize(source, name)
        nodes = Compile.convert(Parser.parse(tokens, name))
        Template.new(name, nodes, Lexer.strict_locals(tokens, name), Lexer.strict_locals?(tokens), source_path)
      end

      def initialize(name, nodes, locals, strict_locals, source_path)
        @name = name
        @nodes = nodes
        @locals = locals
        @strict_locals = strict_locals
        @source_path = source_path
      end

      # True when the template declares its locals (even an empty list).
      def strict_locals?
        @strict_locals
      end
    end

    class Engine
      # The key prefix of a component template ("__components/card_component.html.erb"):
      # one no view under app/views has unless it sits in a directory named
      # "__components", which is reserved. gen/views.rb embeds the component
      # templates under it (Gen::ViewsEmitter), next to the views.
      COMPONENTS_PREFIX = "__components/"

      attr_reader :root, :components_root

      # components_root: where names under COMPONENTS_PREFIX are read from
      # (app/components beside app/views, spec 3.2); "" derives it from root.
      def initialize(root, cache: true, max_render_depth: MAX_RENDER_DEPTH, components_root: "")
        # Views.configure and Views.configure_embedded (Engine.embedded) both
        # end here. A ceiling below 1 would fail `@depth >= @max_depth` at
        # depth 0 and turn every page into a 500, so refuse it at boot. No nil
        # check: the parameter is an Integer (a nil would not compile under
        # Spinel).
        raise ArgumentError, "max_render_depth must be at least 1 (got #{max_render_depth})" if max_render_depth < 1

        @root = root
        @components_root = components_root.empty? ? File.join(File.dirname(root), "components") : components_root
        @cache = cache
        @max_render_depth = max_render_depth
        # nil: read files under root. A Hash: the embedded table.
        @sources = nil
        # Typed empty Hashes (spikes/NOTES.md rule 9).
        # Parsed templates live in a typed Array, found through a
        # key => index Hash: Spinel boxes the values of a Hash of objects,
        # so a Hash<String, Template> lookup comes back polymorphic, and so
        # would every template, node and env the interpreter handles.
        @template_list = Engine.no_templates
        @template_index = { "" => 0 }
        @template_index.delete("")
        @stamps = { "" => "" }
        @stamps.delete("")
      end

      # An engine over an embedded table (Gen::Views::SOURCES).
      # An empty Array<Template>, typed by the block (never called).
      def self.no_templates
        Array.new(0) { Template.new("", INode.list, Array.new(0) { "" }, false, "") }
      end

      # Every template is parsed here, at boot, so requests only read the
      # cache: with SPINEL_WORKERS > 1 two requests rendering a template for
      # the first time would write @template_index and @template_list at once
      # (Spinel has no GVL), and a lock on every render stalled requests for
      # seconds (spikes/NOTES.md rule 57). A template that does not parse
      # therefore fails the boot, not its page. `eager: false` parses each
      # template when it is first rendered instead: for a single-threaded
      # process that may render nothing (a registered command), so a
      # template that does not parse stops only what renders it.
      def self.embedded(sources, max_render_depth: MAX_RENDER_DEPTH, eager: true)
        engine = Engine.new("", cache: true, max_render_depth: max_render_depth)
        engine.sources = sources
        engine.parse_all_embedded if eager
        engine
      end

      def sources=(table)
        @sources = table
      end

      # Parses every template of the embedded table into the cache
      # ({Engine.embedded} calls it once).
      def parse_all_embedded
        table = @sources
        return nil if table.nil?

        table.each { |key, source| store_template(key, Template.parse(source, key, key)) }
        nil
      end

      # "posts/show" and "posts/show.html.erb" name the same template; a
      # name that ends in .erb ("posts/create.turbo_stream.erb") is used as
      # it is.
      def template(name)
        key = file_name(name)
        cached = cached_template(key)
        sources = @sources
        # The cache hit is answered here, not by embedded_template: a
        # nullable Template passed as a parameter is boxed by Spinel.
        unless sources.nil?
          return cached unless cached.nil?

          return embedded_template(key, sources)
        end
        return cached if @cache && !cached.nil?

        path = disk_path(key)
        resolved = resolved_template_path(path, disk_root(key))
        raise MissingTemplate, "Missing template #{path}" if resolved.empty?

        stamp = file_stamp(resolved)
        return cached if !cached.nil? && @stamps[key] == stamp

        parsed = Template.parse(File.read(resolved), key, path)
        store_template(key, parsed)
        @stamps[key] = stamp
        parsed
      end

      def exists?(name)
        key = file_name(name)
        sources = @sources
        return sources.key?(key) unless sources.nil?

        !resolved_template_path(disk_path(key), disk_root(key)).empty?
      end

      # An interpreter with this engine's render-depth ceiling, for callers
      # that render several templates on one (Views.render_component).
      def interpreter(helpers)
        Interpreter.new(helpers, @max_render_depth)
      end

      def render(name, env, helpers)
        Interpreter.new(helpers, @max_render_depth).render(template(name), env)
      end

      # Renders name, then the layout around it: the layout's <%= yield %>
      # prints env["__content"], and <%= yield :title %> env["__content_title"]
      # (which the content_for helper sets while the page renders).
      def render_with_layout(name, layout, env, helpers)
        interp = Interpreter.new(helpers, @max_render_depth)
        page = template(name)
        frame = template(layout)
        env["__content"] = SafeString.of(interp.render(page, env))
        interp.render(frame, env)
      end

      def clear_cache!
        # A fresh Array rather than clear: Array#clear anywhere in the
        # program makes Spinel box that Array's elements (Spinel 2026.09.12).
        @template_list = Engine.no_templates
        @template_index.clear
        @stamps.clear
        nil
      end

      private

      # Embedded sources never change while the process runs: parsed once,
      # whatever `cache` says. The key is passed as the template name, which
      # every error message prefixes, so they read "posts/show.html.erb:12: ..."
      # exactly as from disk; having no file behind it, the key is its
      # source_path too.
      def embedded_template(key, sources)
        source = sources[key]
        raise MissingTemplate, "Missing template #{key} (embedded)" if source.nil?

        parsed = Template.parse(source, key, key)
        store_template(key, parsed)
        parsed
      end

      def cached_template(key)
        i = @template_index[key]
        return nil if i.nil?

        # The case unboxes the Array element into a typed Template.
        found = @template_list[i]
        case found
        when Template then return found
        end
        nil
      end

      # A reparsed file replaces its entry in place.
      def store_template(key, parsed)
        i = @template_index[key]
        if i.nil?
          @template_index[key] = @template_list.size
          @template_list << parsed
        else
          @template_list[i] = parsed
        end
        nil
      end

      # name.to_s: some callers hand in a polymorphic name, and returning it
      # as is made every key, and with it @template_index, polymorphic.
      # to_s types it without copying a String.
      def file_name(name)
        text = name.to_s
        text.end_with?(".erb") ? text : "#{text}.html.erb"
      end

      # "__components/card_component.html.erb" is read from components_root,
      # everything else from root (so app/views/components/, a
      # ComponentsController's views, stays a view directory).
      def component_key?(key)
        key.start_with?(COMPONENTS_PREFIX)
      end

      def disk_root(key)
        component_key?(key) ? @components_root : @root
      end

      def disk_path(key)
        return File.join(@root, key) unless component_key?(key)

        skip = COMPONENTS_PREFIX.size
        rest = key[skip, key.size - skip].to_s
        File.join(@components_root, rest)
      end

      # Resolve symlinks before checking the root boundary, and read this
      # canonical path rather than following the original name again.
      # Keep the caller's path separately for source paths and diagnostics.
      def resolved_template_path(path, base)
        root = File.realpath(base)
        resolved = File.realpath(path)
        prefix = root.end_with?("/") ? root : "#{root}/"
        return "" unless resolved.start_with?(prefix) && File.file?(resolved)

        resolved
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP
        ""
      end

      # mtime alone has one-second resolution on some filesystems; the size
      # catches most same-second rewrites too.
      def file_stamp(path)
        t = File.mtime(path)
        "#{t.to_i}.#{t.nsec}:#{File.size(path)}"
      end
    end
  end
end
