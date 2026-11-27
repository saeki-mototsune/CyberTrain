module Cybertrain
  module Gen
    # Cybertrain::Gen::Dialect -- which DB adapter the application is built
    # with, as far as the generator needs to know (docs/design.md D96). The
    # adapter is chosen when the application is built, by the first
    # `require "cybertrain..."` line of bin/NAME.rb (NAME is spin.toml's
    # [package] name, as in ViewRequires):
    #
    #   require "cybertrain"              SQLite
    #   require "cybertrain/mysql"        MySQL
    #   require "cybertrain/core"         SQLite, the core alone
    #   require "cybertrain/core/mysql"   MySQL, the core alone
    #
    # The last two are the first line of every `cybertrain new` application
    # (D85: the core and the subsystem lines it adds), so they pick the same
    # adapter as the whole-framework entries they stand beside.
    #
    # Anything else after `require "cybertrain` (`require "cybertrain/foo"`),
    # or no such line in a bin/NAME.rb that exists, is refused: detect raises
    # ArgumentError with the message and Runner prints it and stops. An
    # application with no spin.toml name or no bin/NAME.rb (a fixture tree)
    # has nothing to read and is SQLite, as ViewRequires lets it pass.
    #
    # `for(name)` answers the Spec the emitters take, so that what is spelled
    # differently per adapter (the identifier quote, the entry require) is
    # spelled once, here. Generated code never branches on the adapter at
    # run time: each program is built for one.
    module Dialect
      SQLITE = "sqlite".freeze
      MYSQL = "mysql".freeze
      REQUIRE_PREFIX = "require \"cybertrain".freeze

      # What one adapter spells for the generator.
      class Spec
        def initialize(name)
          @name = name
        end

        # "sqlite" or "mysql".
        # @return [String]
        def name
          @name
        end

        # The require that loads the adapter ("cybertrain" is SQLite's).
        # @return [String]
        def entry
          @name == "mysql" ? "cybertrain/mysql" : "cybertrain"
        end

        # The test bundle the adapter's gen/tests.rb requires.
        # @return [String]
        def test_bundle
          @name == "mysql" ? "cybertrain/test/bundle_mysql" : "cybertrain/test/bundle"
        end

        # `ident` quoted as an SQL identifier: "x" for SQLite, `x` for MySQL,
        # the quote character doubled where the name holds one.
        # @param ident [String]
        # @return [String]
        def quote_ident(ident)
          if @name == "mysql"
            "`" + ident.gsub("`", "``") + "`"
          else
            "\"" + ident.gsub("\"", "\"\"") + "\""
          end
        end

        def mysql?
          @name == "mysql"
        end
      end

      # The Spec of "sqlite" or "mysql".
      # @param name [String]
      # @return [Cybertrain::Gen::Dialect::Spec]
      def self.for(name)
        raise ArgumentError, "unknown adapter #{name}: sqlite or mysql" unless name == SQLITE || name == MYSQL

        Spec.new(name)
      end

      # The adapter the application at `root` is built with: "sqlite" or
      # "mysql". Raises ArgumentError when the first require of
      # "cybertrain..." in bin/NAME.rb is neither. NAME is read by
      # ViewRequires.package_name, which the caller has loaded (Runner and the
      # tests do; this file requires nothing, since the CLI loads it too and
      # the gem ships only the files the CLI needs).
      # @param root [String]
      # @return [String]
      def self.detect(root)
        name = ViewRequires.package_name(root)
        return SQLITE if name.empty?

        bin = "#{root}/bin/#{name}.rb"
        return SQLITE unless File.file?(bin)

        in_source(name, File.read(bin))
      end

      # The adapter bin/`name`.rb's `source` is built with, as detect says it.
      # @param name [String] the package name
      # @param source [String] the text of bin/NAME.rb
      # @return [String]
      def self.in_source(name, source)
        source.split("\n").each do |raw|
          line = raw.strip
          next unless line.start_with?(REQUIRE_PREFIX)
          return SQLITE if line == "require \"cybertrain\"" || line == "require \"cybertrain/core\""
          return MYSQL if line == "require \"cybertrain/mysql\"" || line == "require \"cybertrain/core/mysql\""

          break
        end
        raise ArgumentError, "bin/#{name}.rb: the first require must be \"cybertrain\" or \"cybertrain/mysql\""
      end

      # The Spec of the application at `root`.
      # @param root [String]
      # @return [Cybertrain::Gen::Dialect::Spec]
      def self.of(root)
        self.for(detect(root))
      end
    end
  end
end
