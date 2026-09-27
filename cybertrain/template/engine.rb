# Cybertrain::Template::Engine -- finds, parses and caches view templates.
#
#   engine = Cybertrain::Template::Engine.new("app/views", cache: false)
#   html = engine.render_with_layout("posts/index", "layouts/application", env, helpers)
#
# Templates are parsed at run time. Two sources:
#   Engine.new("app/views", cache: false)   -- files under a root; with
#     `cache: true` (production) each file is parsed once, with `cache: false`
#     (development) a file is re-parsed whenever its mtime or size changes.
#   Engine.embedded(sources)                -- a Hash of "posts/index.html.erb"
#     => source, generated into the binary by `spin run gen -- --embed-views`;
#     parsed once, never re-read.
require "cybertrain/html"
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
      attr_reader :root

      def initialize(root, cache: true)
        @root = root
        @cache = cache
        # nil: read files under root. A Hash: the embedded table.
        @sources = nil
        # Typed empty Hashes (spikes/NOTES.md rule 9).
        @templates = { "" => Template.new("", INode.list, Array.new(0) { "" }, false, "") }
        @templates.delete("")
        @stamps = { "" => "" }
        @stamps.delete("")
      end

      # An engine over an embedded table (Gen::Views::SOURCES).
      def self.embedded(sources)
        engine = Engine.new("", cache: true)
        engine.sources = sources
        engine
      end

      def sources=(table)
        @sources = table
      end

      # "posts/show" and "posts/show.html.erb" name the same template.
      def template(name)
        key = file_name(name)
        cached = @templates[key]
        sources = @sources
        return embedded_template(key, cached, sources) unless sources.nil?
        return cached if @cache && !cached.nil?

        path = File.join(@root, key)
        raise MissingTemplate, "Missing template #{path}" unless File.exist?(path)

        stamp = file_stamp(path)
        return cached if !cached.nil? && @stamps[key] == stamp

        parsed = Template.parse(File.read(path), key, path)
        @templates[key] = parsed
        @stamps[key] = stamp
        parsed
      end

      def exists?(name)
        key = file_name(name)
        sources = @sources
        return sources.key?(key) unless sources.nil?

        File.exist?(File.join(@root, key))
      end

      def render(name, env, helpers)
        Interpreter.new(helpers).render(template(name), env)
      end

      # Renders name, then the layout around it: the layout's <%= yield %>
      # prints env["__content"], and <%= yield :title %> env["__content_title"]
      # (which the content_for helper sets while the page renders).
      def render_with_layout(name, layout, env, helpers)
        interp = Interpreter.new(helpers)
        page = template(name)
        frame = template(layout)
        env["__content"] = SafeString.new(interp.render(page, env))
        interp.render(frame, env)
      end

      def clear_cache!
        @templates.clear
        @stamps.clear
        nil
      end

      private

      # Embedded sources never change while the process runs: parsed once,
      # whatever `cache` says. The key doubles as source_path so error
      # messages read "posts/show.html.erb:12: ..." exactly as from disk.
      def embedded_template(key, cached, sources)
        return cached unless cached.nil?

        source = sources[key]
        raise MissingTemplate, "Missing template #{key} (embedded)" if source.nil?

        parsed = Template.parse(source, key, key)
        @templates[key] = parsed
        parsed
      end

      def file_name(name)
        name.end_with?(".erb") ? name : "#{name}.html.erb"
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
