require "cybertrain/generator/asset_scan"

module Cybertrain
  module Gen
    # One pin of config/importmap.rb: the module name, its target (a
    # logical asset path, or a URL as written), and whether
    # javascript_importmap_tags preloads it.
    class ImportmapPin
      attr_reader :pin_name, :pin_target, :pin_preload

      def initialize(pin_name, pin_target, pin_preload)
        @pin_name = pin_name
        @pin_target = pin_target
        @pin_preload = pin_preload
      end

      # Whether the target is a URL rather than a logical asset path.
      def pin_url?
        ImportmapReader.url?(@pin_target)
      end
    end

    # Reads config/importmap.rb lexically (spec section 7.3), never running
    # it:
    #
    #   pin "application"                                  # application.js
    #   pin "chart", to: "chart.js", preload: false
    #   pin "@hotwired/turbo", to: "https://cdn.jsdelivr.net/..."
    #   pin_all_from "app/javascript/controllers", under: "controllers"
    #
    # Comments and blank lines are skipped; any other line is refused. A
    # `to:` without a scheme (and a pin without `to:`, which names
    # "<name>.js") must be an asset. `preload:` defaults to true, as in
    # importmap-rails. A name pinned twice keeps its first place and its
    # last target.
    module ImportmapReader
      PATH = "config/importmap.rb"

      def self.read(text, files)
        pins = Array.new(0) { ImportmapPin.new("", "", false) }
        number = 0
        text.to_s.each_line do |raw|
          number += 1
          line = raw.strip
          next if line.empty? || line.start_with?("#")

          if line.start_with?("pin_all_from ")
            pin_all_from(line.delete_prefix("pin_all_from "), number, files).each { |p| add(pins, p) }
          elsif line.start_with?("pin ")
            add(pins, pin(line.delete_prefix("pin "), number, files))
          else
            refuse(number)
          end
        end
        pins
      end

      def self.url?(target)
        target.start_with?("https://") || target.start_with?("http://") || target.start_with?("//")
      end

      def self.add(pins, pin)
        pins.each_with_index do |p, i|
          next unless p.pin_name == pin.pin_name

          pins[i] = pin
          return nil
        end
        pins << pin
        nil
      end

      def self.refuse(number)
        message = "#{PATH}:#{number}: only pin and pin_all_from lines are read"
        raise ArgumentError, message
      end

      def self.pin(rest, number, files)
        args = arguments(rest, number)
        name = args[0]
        target = "#{name}.js"
        preload = true
        option_pairs(args, number).each do |key, value|
          if key == "to" && string_value?(value)
            target = value[1, value.size - 1].to_s
          elsif key == "preload" && !string_value?(value)
            preload = value == "true"
          else
            refuse(number)
          end
        end
        if !url?(target) && AssetScan.find(files, target).nil?
          message = "#{PATH}:#{number}: pin #{name.inspect}: #{target} is not an asset"
          raise ArgumentError, message
        end
        ImportmapPin.new(name, target, preload)
      end

      # The .js files below dir (relative to the application root, one of
      # the asset roots or a directory under one), each pinned as its path
      # below dir without ".js", under `under:` when given ("index" names
      # the directory itself).
      def self.pin_all_from(rest, number, files)
        args = arguments(rest, number)
        dir = args[0].delete_suffix("/")
        under = ""
        preload = true
        option_pairs(args, number).each do |key, value|
          if key == "under" && string_value?(value)
            under = value[1, value.size - 1].to_s.delete_suffix("/")
          elsif key == "preload" && !string_value?(value)
            preload = value == "true"
          else
            refuse(number)
          end
        end
        pins = Array.new(0) { ImportmapPin.new("", "", false) }
        files.each do |f|
          next unless f.source_path.start_with?("#{dir}/") && f.logical_path.end_with?(".js")

          rel = f.source_path[dir.size + 1, f.source_path.size - dir.size - 1].to_s.delete_suffix(".js")
          name = if under.empty? then rel
                 elsif rel == "index" then under
                 else "#{under}/#{rel}"
                 end
          pins << ImportmapPin.new(name, f.logical_path, preload)
        end
        pins
      end

      def self.string_value?(value)
        value.start_with?("\"")
      end

      # [key, value] for each `key: value` after the first argument.
      def self.option_pairs(args, number)
        pairs = Array.new(0) { ["", ""] }
        i = 1
        while i < args.size
          refuse(number) if i + 1 >= args.size
          pairs << [args[i], args[i + 1]]
          i += 2
        end
        pairs
      end

      # The first argument (a string literal's text), then key and value per
      # `, key: value` (a string value keeps its opening `"` as a marker;
      # true and false are bare). A trailing comment is allowed; anything
      # else is refused.
      def self.arguments(rest, number)
        s = rest.to_s
        out = Array.new(0) { "" }
        pos = 0
        first = string_end(s, pos)
        refuse(number) if first < 0
        out << s[pos + 1, first - pos - 2].to_s
        pos = first
        loop do
          pos = skip_spaces(s, pos)
          break if pos >= s.size || s[pos, 1] == "#"

          refuse(number) unless s[pos, 1] == ","
          pos = skip_spaces(s, pos + 1)
          key_end = pos
          key_end += 1 while key_end < s.size && key_char?(s[key_end, 1].to_s)
          refuse(number) if key_end == pos || s[key_end, 1] != ":"
          out << s[pos, key_end - pos].to_s
          pos = skip_spaces(s, key_end + 1)
          value = string_end(s, pos)
          if value >= 0
            out << "\"#{s[pos + 1, value - pos - 2]}"
            pos = value
          elsif s[pos, 4] == "true"
            out << "true"
            pos += 4
          elsif s[pos, 5] == "false"
            out << "false"
            pos += 5
          else
            refuse(number)
          end
        end
        out
      end

      # The position after the closing quote of the "..." or '...' literal
      # at pos (no escapes, no interpolation), or -1.
      def self.string_end(s, pos)
        quote = s[pos, 1].to_s
        return -1 unless quote == "\"" || quote == "'"

        stop = s.index(quote, pos + 1)
        return -1 if stop.nil?

        text = s[pos + 1, stop - pos - 1].to_s
        return -1 if text.include?("\\") || (quote == "\"" && text.include?("\#{"))

        stop + 1
      end

      def self.key_char?(c)
        (c >= "a" && c <= "z") || c == "_"
      end

      def self.skip_spaces(s, i)
        j = i
        j += 1 while j < s.size && (s[j, 1] == " " || s[j, 1] == "\t")
        j
      end
    end
  end
end
