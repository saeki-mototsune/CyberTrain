# The `cybertrain` command: exe/cybertrain under CRuby (the gem), or
# bin/cybertrain.rb built by spin (`spin install` from a checkout).
#
#   cybertrain new NAME [--path DIR | --version V] [--skip-spin]
#   cybertrain generate scaffold NAME field:type ... [parent:references]
#   cybertrain version | help
require "cybertrain/version"
require "cybertrain/cli/templates"
require "cybertrain/cli/new_app"
require "cybertrain/cli/scaffold"

module Cybertrain
  module CLI
    USAGE = <<~TEXT
      Usage:
        cybertrain new NAME [--path DIR | --version V] [--skip-spin]
            Create an application in NAME, then run `spin lock` and
            `spin run gen` in it (skipped with --skip-spin). Its spin.toml
            depends on this cybertrain's release by default:
              git tag v#{Cybertrain::VERSION} of #{Cybertrain::REPOSITORY}
            --path DIR: the framework checkout at DIR (relative to the
            current directory; written as an absolute path).
            --version V: the index version constraint V.
        cybertrain generate scaffold NAME field:type ... [parent:references]
            Add a resource to the application in the current directory.
            Types: #{Field::TYPES.join(", ")} (default string).
        cybertrain version
        cybertrain help
    TEXT

    # Returns the process exit code.
    def self.run(argv)
      command = argv.empty? ? "" : argv[0]
      case command
      when "new" then run_new(argv)
      when "generate", "g" then run_generate(argv)
      when "version", "--version", "-v"
        puts "cybertrain #{Cybertrain::VERSION}"
        0
      when "help", "--help", "-h"
        puts USAGE
        0
      else
        puts "Unknown command '#{command}'" unless command == ""
        puts USAGE
        1
      end
    rescue InvalidArgument => e
      puts "error: #{e.message}"
      1
    end

    def self.run_new(argv)
      raise InvalidArgument, "usage: cybertrain new NAME [--path DIR | --version V] [--skip-spin]" if argv.size < 2

      dir = argv[1]
      raise InvalidArgument, "'#{File.basename(dir)}' is not a valid app name (lowercase letters, digits and _)" unless Templates.identifier?(File.basename(dir))
      raise InvalidArgument, "#{dir} already exists" if File.exist?(dir)

      NewApp.create(dir, framework_dep(argv))
      return 0 if argv.include?("--skip-spin")

      NewApp.bootstrap(dir) ? 0 : 1
    end

    # The spin.toml value of the `cybertrain =` dependency. By default the
    # release tag matching this CLI, so the templates it just wrote and the
    # framework the app builds against are the same version.
    # A relative --path is expanded against the current directory: spin
    # resolves `path =` from the new app's directory, not from where the
    # command ran.
    def self.framework_dep(argv)
      path = option(argv, "--path")
      version = option(argv, "--version")
      raise InvalidArgument, "pass either --path or --version, not both" unless path == "" || version == ""
      return "\"#{version}\"" unless version == ""
      return "{ path = \"#{File.expand_path(path, Dir.pwd)}\" }" unless path == ""

      "{ git = \"#{Cybertrain::REPOSITORY}\", ref = \"v#{Cybertrain::VERSION}\" }"
    end

    # The value after `--flag`, or "" when the flag is absent.
    def self.option(argv, flag)
      i = argv.index(flag)
      return "" if i.nil?
      raise InvalidArgument, "#{flag} needs a value" if i + 1 >= argv.size

      argv[i + 1]
    end

    def self.run_generate(argv)
      kind = argv.size > 1 ? argv[1] : ""
      raise InvalidArgument, "only `generate scaffold` is supported" unless kind == "scaffold"
      raise InvalidArgument, "usage: cybertrain generate scaffold NAME field:type ..." if argv.size < 3

      Scaffold.generate(".", argv[2], argv[3, argv.size - 3])
      0
    end
  end
end
