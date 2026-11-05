require "cybertrain/dev/watcher"

module Cybertrain
  module Dev
    # Remembers what build/bin/gen was compiled from, so that the rebuild loop
    # can run that binary instead of `spin run gen`. spin recompiles an
    # executable when any Ruby file of the package or its path dependencies
    # changed, so an edit to a controller, which gen only reads at run time,
    # costs a compile of gen that produces the same binary.
    #
    # The inputs are the files compiled into gen: the app's bin/gen.rb,
    # db/schema.rb and config/**/*.rb (wider than what bin/gen.rb requires,
    # because config/routes.rb may require_relative a neighbour), spin.toml,
    # spin.lock, and for each `path = "..."` in spin.toml that directory's
    # cybertrain.rb and cybertrain/**/*.rb. A registry or git dependency moves
    # spin.lock, so it needs no walk.
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
        found = ["#{@root}/bin/gen.rb", "#{@root}/db/schema.rb", "#{@root}/spin.toml", "#{@root}/spin.lock"]
        GenStamp.collect_ruby_files("#{@root}/config", found)
        dependency_dirs.each do |dir|
          found << "#{dir}/cybertrain.rb"
          GenStamp.collect_ruby_files("#{dir}/cybertrain", found)
        end
        found
      end

      # The directory of every `path = "..."` in spin.toml. Read by pattern
      # rather than parsed, which covers both `cybertrain = { path = "..." }`
      # and a [dependencies.cybertrain] table; a commented-out line only adds
      # files to watch.
      def dependency_dirs
        dirs = []
        toml = "#{@root}/spin.toml"
        return dirs unless File.file?(toml)

        text = File.read(toml)
        pos = 0
        while (m = text.match(PATH_ENTRY, pos))
          dirs << File.expand_path(m[1], @root)
          pos = m.end(0)
        end
        dirs
      end

      PATH_ENTRY = /\bpath\s*=\s*["']([^"']+)["']/

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
