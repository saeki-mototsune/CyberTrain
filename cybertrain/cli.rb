# The `cybertrain` command (bin/cybertrain.rb):
#
#   cybertrain new NAME [--path DIR | --version V]
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
        cybertrain new NAME [--path DIR | --version V]
            Create an application in NAME. Its spin.toml depends on the
            framework at DIR (relative to the current directory; written as
            an absolute path; default: this cybertrain's own checkout) or on
            the index version constraint V.
        cybertrain generate scaffold NAME field:type ... [parent:references]
            Add a resource to the application in the current directory.
            Types: #{Field::TYPES.join(", ")} (default string).
        cybertrain version
        cybertrain help
    TEXT

    # The framework checkout `cybertrain new` points apps at when neither
    # --path nor --version is given. bin/cybertrain.rb sets it from its own
    # __dir__: under Spinel __dir__ is always the *main* file's directory, so
    # this file cannot compute it itself. A module ivar, not a @@class
    # variable (spikes/NOTES.md rule 18).
    @framework_root = ""

    def self.framework_root
      @framework_root
    end

    def self.framework_root=(dir)
      @framework_root = dir
    end

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
      raise InvalidArgument, "usage: cybertrain new NAME [--path DIR | --version V]" if argv.size < 2

      dir = argv[1]
      raise InvalidArgument, "'#{File.basename(dir)}' is not a valid app name (lowercase letters, digits and _)" unless Templates.identifier?(File.basename(dir))
      raise InvalidArgument, "#{dir} already exists" if File.exist?(dir)

      NewApp.create(dir, framework_dep(argv))
      0
    end

    # The spin.toml value of the `cybertrain =` dependency.
    # A relative --path is expanded against the current directory: spin
    # resolves `path =` from the new app's directory, not from where the
    # command ran.
    def self.framework_dep(argv)
      path = option(argv, "--path")
      version = option(argv, "--version")
      raise InvalidArgument, "pass either --path or --version, not both" unless path == "" || version == ""
      return "\"#{version}\"" unless version == ""
      return "{ path = \"#{File.expand_path(path, Dir.pwd)}\" }" unless path == ""
      raise InvalidArgument, "cannot tell where the framework is: pass --path DIR" if @framework_root == ""

      "{ path = \"#{@framework_root}\" }"
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
