require "cybertrain/dev/watcher"

module Cybertrain
  module Dev
    # Remembers what build/bin/gen was compiled from, so that the rebuild loop
    # can run that binary instead of `spin run gen`. spin recompiles an
    # executable when any Ruby file of the package or its path dependencies
    # changed, so an edit to a controller, which gen only reads at run time,
    # costs a compile of gen that produces the same binary.
    #
    # The inputs are the files compiled into gen: bin/gen.rb, db/schema.rb and
    # config/**/*.rb, spin.toml and spin.lock, the spin.toml of every path
    # dependency, and everything those Ruby files reach through their requires.
    # The requires are followed rather than listed because gen compiles
    # whatever they name, wherever it is: app/ or lib/ of the app, or a path
    # dependency that need not be the framework. config/**/*.rb is walked on
    # top, so a file there counts even if nothing is found to require it.
    #
    # `require "x"` is looked for where `spin flags` tells the compiler to look
    # (the app, and every path dependency, followed through their spin.toml),
    # and in vendor/packages/*, where `spin vendor` moves them. A registry or
    # git dependency moves spin.lock, so it needs no walk. A .c or .rbs file of
    # a path dependency, which spin also compiles, is not followed.
    class GenStamp
      def initialize(root)
        @root = root
      end

      # path:mtime:size of every input that exists, one per line, sorted. A
      # file that appears or goes away changes it as an edit does.
      def signature
        lines = []
        inputs.sort.each do |path|
          stamp = Watcher.mtime_stamp(path)
          lines << "#{path}:#{stamp}:#{File.size(path)}" if stamp >= 0
        end
        lines.join("\n")
      end

      # True when build/bin/gen exists and was compiled from the inputs as
      # they stand now.
      def fresh?
        return false unless File.file?(binary_path)
        return false unless File.file?(stamp_path)

        File.read(stamp_path) == signature
      end

      # Records the signature build/bin/gen was compiled from. A failed write
      # only means the next rebuild compiles gen again, so it does not fail
      # the build it follows.
      def record(signature)
        dir = File.dirname(stamp_path)
        Dir.mkdir(dir) unless File.directory?(dir)
        File.write(stamp_path, signature)
        nil
      rescue StandardError
        nil
      end

      private

      def binary_path
        "#{@root}/build/bin/gen"
      end

      def stamp_path
        "#{@root}/tmp/gen-inputs"
      end

      def inputs
        base = File.expand_path(@root)
        roots = require_roots(base)
        entries = ["#{base}/bin/gen.rb", "#{base}/db/schema.rb", "#{base}/spin.toml", "#{base}/spin.lock"]
        roots.each { |root| entries << "#{root}/spin.toml" }
        GenStamp.collect_ruby_files("#{base}/config", entries)
        GenStamp.with_required_files(entries, roots)
      end

      # Where `require "x"` can land: the app, the directories of its vendored
      # packages, and its path dependencies and theirs.
      def require_roots(base)
        roots = [base]
        vendored = "#{base}/vendor/packages"
        if File.directory?(vendored)
          Dir.children(vendored).each { |name| roots << "#{vendored}/#{name}" }
        end
        index = 0
        while index < roots.length
          GenStamp.dependency_dirs(roots[index]).each { |dir| roots << dir unless roots.include?(dir) }
          index += 1
        end
        roots
      end

      # The directory of every `path = "..."` in dir/spin.toml. Read by pattern
      # rather than parsed, which covers both `cybertrain = { path = "..." }`
      # and a [dependencies.cybertrain] table; a commented-out line only adds
      # files to watch.
      def self.dependency_dirs(dir)
        dirs = []
        toml = "#{dir}/spin.toml"
        return dirs unless File.file?(toml)

        text = File.binread(toml)
        pos = 0
        while (m = text.match(PATH_ENTRY, pos))
          dirs << File.expand_path(m[1], dir)
          pos = m.end(0)
        end
        dirs
      end

      PATH_ENTRY = /\bpath\s*=\s*["']([^"']+)["']/

      # A require, then the rest of the line its path is on, past a `(` or a
      # line break. autoload compiles the file it names as well.
      REQUIRE_LINE = /\b(?:require_relative|require|autoload)\b[\s\\(]*([^\n]*)/
      STRING_LITERAL = /["']([^"'\n]+)["']/
      DIR_INTERPOLATION = "\#{__dir__}"

      # entries and every file they reach, each once. Reads source by pattern,
      # as dependency_dirs does: a require in a comment or a string only adds
      # a file to watch, and one gen does not compile costs a compile of gen,
      # while one missed would reuse a stale binary.
      def self.with_required_files(entries, roots)
        seen = { "" => true }
        seen.delete("") # a typed empty Hash (spikes/NOTES.md rule 9)
        found = []
        entries.each do |path|
          next if seen.key?(path)

          seen[path] = true
          found << path
        end
        index = 0
        while index < found.length
          GenStamp.required_files(found[index], roots).each do |path|
            next if seen.key?(path)

            seen[path] = true
            found << path
          end
          index += 1
        end
        found
      end

      # The existing files that path's requires may name. Every string on a
      # require's line counts, so that `File.expand_path("x", __dir__)` and
      # `__dir__ + "/x"`, which the compiler folds, are read like a plain
      # "x"; a path it cannot fold is not compiled either.
      def self.required_files(path, roots)
        files = []
        return files unless path.end_with?(".rb") && File.file?(path)

        text = File.binread(path)
        bases = [File.dirname(path)] + roots
        pos = 0
        while (m = text.match(REQUIRE_LINE, pos))
          pos = m.end(0)
          line = m[1]
          literal_pos = 0
          while (literal = line.match(STRING_LITERAL, literal_pos))
            GenStamp.add_resolved(literal[1], bases, files)
            literal_pos = literal.end(0)
          end
        end
        files
      end

      # Adds to files what name means under each of bases, with or without its
      # .rb. Under more than one base they all count: which one the compiler
      # took does not matter when the cost of an extra one is a compile.
      def self.add_resolved(name, bases, files)
        stem = name.sub(DIR_INTERPOLATION, "")
        relative = stem.start_with?("/") ? ".#{stem}" : stem
        candidates = bases.map { |base| File.expand_path(relative, base) }
        candidates << stem if stem.start_with?("/")
        candidates.each do |candidate|
          ruby = candidate.end_with?(".rb") ? candidate : "#{candidate}.rb"
          files << ruby if File.file?(ruby)
        end
        nil
      end

      # Adds dir/**/*.rb to found. A walk, not Dir.glob: glob reads the path
      # it starts from as a pattern, so `[` or `{` on the way to an app would
      # match nothing and hide every edit underneath, and Spinel's glob does
      # not honour an escaped `\{`.
      def self.collect_ruby_files(dir, found)
        return nil unless File.directory?(dir)

        Dir.children(dir).each do |name|
          next if name.start_with?(".")

          path = "#{dir}/#{name}"
          if File.directory?(path)
            GenStamp.collect_ruby_files(path, found)
          elsif name.end_with?(".rb")
            found << path
          end
        end
        nil
      end
    end
  end
end
