require "cybertrain/generator/locale_yaml"

module Cybertrain
  module Gen
    # The application's dictionaries: every config/locales/**/*.yml read
    # with LocaleYaml, merged across files (plan decision D4). Files are read
    # sorted by their path, and a later file's key replaces an earlier
    # one's (a text or a list alike, kept at the earlier one's place); a key
    # that is a mapping in one file and a value in another is refused,
    # ArgumentError "path:line: key is a mapping in other_path:line" (or
    # "is a scalar in", "is a list in"), naming the later file first.
    # script/bundle-locales merges cybertrain/locales/*.yml the same way.
    module LocaleScan
      DIR = "config/locales"

      # The merged entries of root/config/locales (none without it).
      def self.scan(root)
        LocaleScan.merge_files(root, LocaleScan.locale_files(root, DIR))
      end

      # The merged entries of `files` (paths relative to root, in the order
      # given), which name themselves relative to root in entries and
      # refusals.
      def self.merge_files(root, files)
        out = Array.new(0) { LocaleEntry.new("", "", Array.new(0) { "" }, false, "", 0) }
        at = { "" => 0 }
        at.delete("")
        mapping_at = { "" => "" }
        mapping_at.delete("")
        files.each do |rel|
          mappings = { "" => 0 }
          mappings.delete("")
          entries = LocaleYaml.parse_recording(File.read("#{root}/#{rel}"), rel, mappings)
          mappings.each do |key, line|
            next unless at.key?(key)

            earlier = out[at[key]]
            kind = earlier.entry_is_list ? "list" : "scalar"
            message = "#{rel}:#{line}: #{key} is a #{kind} in #{earlier.entry_file}:#{earlier.entry_line}"
            raise ArgumentError, message
          end
          entries.each do |e|
            key = e.entry_key
            if mapping_at.key?(key)
              message = "#{rel}:#{e.entry_line}: #{key} is a mapping in #{mapping_at[key]}"
              raise ArgumentError, message
            end
            if at.key?(key)
              out[at[key]] = e
            else
              at[key] = out.size
              out << e
            end
          end
          mappings.each { |key, line| mapping_at[key] = "#{rel}:#{line}" unless mapping_at.key?(key) }
        end
        out
      end

      # The *.yml files under root/dir, relative to root, sorted by path.
      def self.locale_files(root, dir)
        files = Array.new(0) { "" }
        LocaleScan.collect_yml(root, dir, files)
        files.sort
      end

      def self.collect_yml(root, rel, files)
        path = "#{root}/#{rel}"
        return nil unless File.directory?(path)

        Dir.children(path).each do |entry|
          child = "#{rel}/#{entry}"
          if File.directory?("#{root}/#{child}")
            LocaleScan.collect_yml(root, child, files)
          elsif entry.end_with?(".yml") && !entry.start_with?(".")
            files << child
          end
        end
        nil
      end
    end
  end
end
