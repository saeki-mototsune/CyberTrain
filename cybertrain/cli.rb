# The `cybertrain` command: exe/cybertrain under CRuby (the gem), or
# bin/cybertrain.rb built by spin (`spin install` from a checkout).
#
#   cybertrain new NAME [--path DIR | --version V | --git URL [--ref R]] [--skip-spin]
#   cybertrain generate scaffold NAME field:type ... [parent:references]
#   cybertrain db migrate | db COMMAND... | server [PORT] | build | spin ARGS...
#   cybertrain setup [--force] | doctor | version | help
#
# Every command that runs spin first puts a Spinel of the pinned release on
# PATH (Toolchain.ensure!), installing it under ~/.cybertrain the first time.
require "cybertrain/version"
require "cybertrain/cli/templates"
require "cybertrain/cli/new_app"
require "cybertrain/cli/scaffold"
require "cybertrain/cli/build"
require "cybertrain/cli/toolchain"

module Cybertrain
  module CLI
    USAGE = <<~TEXT
      Usage:
        cybertrain new NAME [--path DIR | --version V | --git URL [--ref R]] [--skip-spin]
            Create an application in NAME, then run `spin lock` and
            `spin run gen` in it (skipped with --skip-spin). Its spin.toml
            depends on this cybertrain's release by default:
              git tag v#{Cybertrain::VERSION} of #{Cybertrain::REPOSITORY}
            --path DIR: the framework checkout at DIR (relative to the
            current directory; written as an absolute path).
            --version V: the index version constraint V.
            --git URL [--ref R]: the framework at URL, at branch or tag R.
        cybertrain generate scaffold NAME field:type ... [parent:references]
            Add a resource to the application in the current directory.
            Types: #{Field::TYPES.join(", ")} (default string).
        cybertrain db migrate
            Generate, apply pending migrations, generate again
            (spin run gen; spin run db -- migrate; spin run gen).
        cybertrain db COMMAND...
            Any other database command, after `spin run gen`: status,
            rollback [N] (generates again afterwards), schema:dump, create.
            `cybertrain migration` is the same as `cybertrain db migrate`.
        cybertrain server [PORT]
            Generate, then start the development server
            (spin run gen; spin run NAME [-- PORT]; default port 3000).
        cybertrain build
            Build NAME with app/views embedded and assemble dist/
            (the binary, public/, storage/, tmp/).
        cybertrain spin ARGS...
            Run spin with the pinned Spinel, from any directory
            (cybertrain spin test; cybertrain spin run gen -- --check).
        cybertrain setup [--force]
            Install Spinel #{Cybertrain::SPINEL_TAG} into ~/.cybertrain (CYBERTRAIN_HOME)
            unless a spinel of that release is already on PATH, and print
            the PATH line for ~/.cybertrain/bin. The commands above do the
            install by themselves the first time they need spin.
        cybertrain doctor
            Check the C toolchain, the SQLite headers and the Spinel install.
        cybertrain version
        cybertrain help
    TEXT

    # Returns the process exit code.
    def self.run(argv)
      command = argv.empty? ? "" : argv[0]
      case command
      when "new" then run_new(argv)
      when "generate", "g" then run_generate(argv)
      when "migration" then run_in_app { |_name| run_spin(Build.db_commands(["migrate"])) }
      when "db" then run_in_app { |_name| run_db(argv) }
      when "server" then run_in_app { |name| run_server(name, argv) }
      when "build" then run_in_app { |name| Toolchain.ensure! ? Build.run(".", name) : 1 }
      when "spin" then run_spin_passthrough(argv)
      when "setup" then Toolchain.setup(argv[1, argv.size - 1])
      when "doctor" then run_doctor(argv)
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
      raise InvalidArgument, "usage: cybertrain new NAME [--path DIR | --version V | --git URL [--ref R]] [--skip-spin]" if argv.size < 2

      dir = argv[1]
      raise InvalidArgument, "'#{File.basename(dir)}' is not a valid app name (lowercase letters, digits and _)" unless Templates.identifier?(File.basename(dir))
      raise InvalidArgument, "#{dir} already exists" if File.exist?(dir)

      NewApp.create(dir, framework_dep(argv))
      return 0 if argv.include?("--skip-spin")
      return 1 unless NewApp.bootstrap(dir)

      puts ""
      puts "next:"
      puts "  cd #{Build.quote_arg(dir)}"
      puts "  cybertrain generate scaffold article title:string body:text"
      puts "  cybertrain db migrate"
      puts "  cybertrain server"
      0
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
      git = option(argv, "--git")
      ref = option(argv, "--ref")
      given = 0
      given += 1 unless path == ""
      given += 1 unless version == ""
      given += 1 unless git == ""
      raise InvalidArgument, "pass only one of --path, --version and --git" if given > 1
      raise InvalidArgument, "--ref needs --git" if ref != "" && git == ""
      return toml_string(version) unless version == ""
      return "{ path = #{toml_string(File.expand_path(path, Dir.pwd))} }" unless path == ""
      return "{ git = #{toml_string(git)} }" if git != "" && ref == ""
      return "{ git = #{toml_string(git)}, ref = #{toml_string(ref)} }" unless git == ""

      "{ git = \"#{Cybertrain::REPOSITORY}\", ref = \"v#{Cybertrain::VERSION}\" }"
    end

    # `value` as a TOML basic string: `\` and `"` escaped. Control
    # characters are refused rather than encoded: no path, URL or git ref
    # needs one, and spin.toml stays readable.
    def self.toml_string(value)
      raise InvalidArgument, "control characters are not allowed in --path, --version, --git or --ref" unless value.bytes.all? { |b| b >= 32 && b != 127 }

      "\"#{value.gsub("\\", "\\\\\\\\").gsub("\"", "\\\"")}\""
    end

    # The value after `--flag`, or "" when the flag is absent.
    def self.option(argv, flag)
      i = argv.index(flag)
      return "" if i.nil?
      raise InvalidArgument, "#{flag} needs a value" if i + 1 >= argv.size

      argv[i + 1]
    end

    # Commands that need the app: its name comes from ./spin.toml.
    def self.run_in_app
      name = Build.app_name(".")
      if name == ""
        puts "error: no spin.toml with a [package] name here; run this inside a cybertrain application"
        return 1
      end
      yield name
    end

    # Runs spin commands in turn once a Spinel of the pinned release is on
    # PATH; stops at the first failure.
    def self.run_spin(commands)
      return 1 unless Toolchain.ensure!

      run_all(commands)
    end

    def self.run_all(commands)
      status = 0
      commands.each do |command|
        puts "run    #{command}"
        unless system(command)
          status = 1
          break
        end
      end
      status
    end

    # `cybertrain spin ARGS...`: spin from the pinned toolchain, wherever
    # the command runs (an application directory or not).
    def self.run_spin_passthrough(argv)
      args = argv[1, argv.size - 1]
      if args.empty?
        puts "usage: cybertrain spin ARGS... (for example: cybertrain spin test)"
        return 1
      end
      return 1 unless Toolchain.ensure!

      system((["spin"] + args.map { |arg| Build.quote_arg(arg) }).join(" ")) ? 0 : 1
    end

    def self.run_doctor(argv)
      if argv.size > 1
        puts "usage: cybertrain doctor"
        return 1
      end
      Toolchain.doctor
    end

    # `cybertrain db COMMAND...`.
    def self.run_db(argv)
      args = argv[1, argv.size - 1]
      if args.empty?
        puts "usage: cybertrain db (migrate|rollback [N]|status|schema:dump|create)"
        return 1
      end
      run_spin(Build.db_commands(args))
    end

    # `cybertrain server [PORT]`.
    def self.run_server(name, argv)
      port = argv.size > 1 ? argv[1] : ""
      unless port == "" || Build.port?(port)
        puts "error: PORT must be a number"
        return 1
      end
      if argv.size > 2
        puts "error: unexpected argument '#{argv[2]}'"
        return 1
      end
      run_spin(Build.server_commands(name, port))
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
