# The `cybertrain` command: exe/cybertrain under CRuby (the gem), or
# bin/cybertrain.rb built by spin (`spin install` from a checkout).
#
#   cybertrain new NAME [--path DIR | --version V | --git URL [--ref R]] [--skip-spin]
#   cybertrain generate scaffold NAME field:type ... [parent:references] [--any]
#   cybertrain generate attachment MODEL FIELD [--any]
#   cybertrain generate authentication [--invite-only] [--confirmable] [--force]
#   cybertrain generate helper NAME [--force] | generate component NAME [attr[:type]...] [--force]
#   cybertrain generate job NAME [--retry Klass:wait:attempts ...] [--force]
#   cybertrain db migrate | db COMMAND... | server [PORT] | build | spin ARGS...
#   cybertrain test [FILE|DIR ...] [-n NAME|-n /TEXT/]
#   cybertrain secret [--hex] | setup [--force] | doctor | version | help
#
# Every command that runs spin first puts a Spinel of the pinned release on
# PATH (Toolchain.ensure!), installing it under ~/.cybertrain the first time.
require "cybertrain/version"
require "cybertrain/crypto"
require "cybertrain/cli/templates"
require "cybertrain/cli/new_app"
require "cybertrain/cli/scaffold"
require "cybertrain/cli/authentication"
require "cybertrain/cli/attachment"
require "cybertrain/cli/helper"
require "cybertrain/cli/component"
require "cybertrain/cli/job"
require "cybertrain/cli/build"
require "cybertrain/cli/toolchain"
require "cybertrain/cli/test_command"

module Cybertrain
  module CLI
    USAGE = <<~TEXT
      Usage:
        cybertrain new NAME [--path DIR | --version V | --git URL [--ref R]] [--skip-spin]
            Create an application in NAME, then run `spin lock` and
            `SPIN_DEBUG=1 spin run gen` in it (skipped with --skip-spin;
            gen and db are built in spin's debug mode). Its spin.toml
            depends on this cybertrain's release by default:
              git tag v#{Cybertrain::VERSION} of #{Cybertrain::REPOSITORY}
            --path DIR: the framework checkout at DIR (relative to the
            current directory; written as an absolute path).
            --version V: the index version constraint V.
            --git URL [--ref R]: the framework at URL, at branch or tag R.
        cybertrain generate scaffold NAME field:type ... [parent:references] [--any]
            Add a resource to the application in the current directory.
            Types: #{Field::TYPES.join(", ")} (default string).
            A field of type attachment (cover:attachment) is an uploaded file:
            see `generate attachment`; --any applies to it.
        cybertrain generate attachment MODEL FIELD [--any]
            Attach an uploaded file to a model of the application in the
            current directory (`generate attachment post cover`): five
            columns in a migration, cover_* methods and callbacks in the model,
            a download action and route, the file input in the scaffold's
            form, and a test. The bytes are kept in storage/uploads/ (back it
            up with the SQLite file). Only PNG, JPEG, GIF and WebP images are
            accepted, unless --any allows any file; the stored type is always
            the one detected from the bytes.
        cybertrain generate authentication [--invite-only] [--confirmable] [--force]
            Add email-and-password sign-in to the application in the current
            directory: users and sessions tables, User and Session models,
            the Authentication concern (included into ApplicationController),
            SessionsController and RegistrationsController with their views
            (their texts in the bundled en and ja dictionaries), the routes,
            the jobs page behind require_admin, and tests. `./NAME user
            EMAIL` creates a user (password from stdin), `./NAME user admin
            EMAIL` makes one an admin, `user unadmin EMAIL` takes it back.
            --invite-only: no sign-up page. The first user is created with
            the user command, or at /setup, which answers only to this
            machine, only with the one-time token the server's boot warning
            prints, and only while no user exists (NAME_SETUP_OPEN=1 lifts
            the address check).
            --confirmable: a new account confirms its address by mail
            before it can sign in (a form sends the link again), and a new
            address on the account page takes effect once its own link is
            opened. Users the user command or /setup creates are confirmed.
            Run again over an application generated before (by 0.4, or
            without --confirmable), it writes the missing files and a
            migration with the missing columns, and prints a diff for each
            file it would change, to apply by hand (patch -p1 applies them).
            --force: overwrite those files instead (and replace 0.4's
            authentication block in ApplicationController, unless edited).
        cybertrain generate helper NAME [--force]
            Add app/helpers/NAME_helper.rb (an empty module NameHelper, which
            `spin run gen` makes callable from every template) and a test.
        cybertrain generate component NAME [attr[:type] ...] [--force]
            Add a view component: app/components/NAME_component.rb (one
            keyword per attribute), its template NAME_component.html.erb and
            a test rendering it. Types: #{Component::TYPES.join(", ")}
            (default string). Templates render it with
            <%= render component: "NAME", attr: value %>.
            --force overwrites files that already exist.
        cybertrain generate job NAME [--retry Klass:wait:attempts ...] [--force]
            Add a background job: app/jobs/NAME_job.rb (a Cybertrain::Job::Base
            with an empty perform(args) and a retry_on line per --retry: wait
            in seconds or polynomially_longer, then the attempts) and a test
            running it. Queue it with NameJob.perform_later("id" => 1) once
            `spin run gen` has written gen/jobs.rb.
        cybertrain db migrate
            Generate, apply pending migrations, generate again
            (SPIN_DEBUG=1 spin run gen; SPIN_DEBUG=1 spin run db -- migrate;
            SPIN_DEBUG=1 spin run gen).
        cybertrain db COMMAND...
            Any other database command, after `SPIN_DEBUG=1 spin run gen`:
            status, rollback [N] (generates again afterwards), schema,
            schema:dump, create.
            `cybertrain migration` is the same as `cybertrain db migrate`.
        cybertrain server [PORT]
            Generate, then start the development server
            (SPIN_DEBUG=1 spin run gen; spin build NAME -- --incremental
            when a Ruby file is newer than build/bin/NAME; spin run NAME
            [-- PORT]; default port 3000).
        cybertrain build
            Build NAME with app/views embedded and assemble dist/
            (the binary, public/, storage/, tmp/).
        cybertrain test [FILE|DIR ...] [-n NAME|-n /TEXT/]
            Run the application's tests (test/**/*_test.rb and test/*.rb)
            as one program: SPIN_DEBUG=1 spin run gen, then gen/tests.rb compiled into
            build/test/tests when a source is newer than it, then run.
            FILE or DIR keeps the tests of those files; -n NAME the test
            named NAME (or its method name, test_...); -n /TEXT/ the tests
            whose name contains TEXT. A filter never recompiles. Exits 1
            when a test failed, 2 for bad arguments.
        cybertrain spin ARGS...
            Run spin with the pinned Spinel, from any directory
            (cybertrain spin test; cybertrain spin run gen -- --check).
        cybertrain secret [--hex]
            Print a new random secret for CYBERTRAIN_SECRET_KEY_BASE (signs
            the session cookie); with --hex, a new key for
            CYBERTRAIN_ENCRYPTION_KEY (encrypts the columns of `encrypts`).
            Both are 64 hex digits (32 random bytes). Keep the encryption
            key: data encrypted with it cannot be read without it.
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
      when "build" then run_in_app { |name| build_app(name) }
      when "test" then run_in_app { |_name| TestCommand.run(".", argv[1, argv.size - 1]) }
      when "spin" then run_spin_passthrough(argv)
      when "secret"
        puts secret_text(argv[1, argv.size - 1])
        0
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

    # `cybertrain secret`: a session secret; `secret --hex`: an encryption
    # key. Both 64 hex digits; kept apart so that each says what it is for.
    def self.secret_text(args)
      return Crypto.random_token(32) if args.empty?
      return Crypto.encryption_key_hex if args == ["--hex"]

      raise InvalidArgument, "usage: cybertrain secret [--hex]"
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

    # The value after `--flag`, or "" when the flag is absent. An empty
    # value, or another option in the value's place, means it is missing.
    def self.option(argv, flag)
      i = argv.index(flag)
      return "" if i.nil?

      value = i + 1 < argv.size ? argv[i + 1] : ""
      raise InvalidArgument, "#{flag} needs a value" if value == "" || value.start_with?("--")

      value
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

    # `cybertrain build`: the one dist/ name check, made before the toolchain
    # is fetched or any spin command runs; Build.run assumes a name that got
    # past it.
    def self.build_app(name)
      Build.require_dist_name!(name)
      Toolchain.ensure! ? Build.run(".", name) : 1
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
        puts "usage: cybertrain db (migrate|rollback [N]|status|schema|schema:dump|create|normalize)"
        return 1
      end
      run_spin(Build.db_commands(args))
    end

    # `cybertrain server [PORT]`: Build.run_server's steps.
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
      return 1 unless Toolchain.ensure!

      Build.run_server(".", name, port)
    end

    # `args` without the (every) `flag` option.
    def self.without_flag(args, flag)
      kept = Array.new(0) { "" }
      args.each { |arg| kept << arg unless arg == flag }
      kept
    end

    def self.run_generate(argv)
      kind = argv.size > 1 ? argv[1] : ""
      case kind
      when "scaffold"
        raise InvalidArgument, "usage: cybertrain generate scaffold NAME field:type ... [--any]" if argv.size < 3

        args = without_flag(argv[2, argv.size - 2], "--any")
        raise InvalidArgument, "usage: cybertrain generate scaffold NAME field:type ... [--any]" if args.empty?

        Scaffold.generate(".", args[0], args[1, args.size - 1], argv.include?("--any"))
      when "attachment"
        args = without_flag(argv[2, argv.size - 2], "--any")
        raise InvalidArgument, "usage: cybertrain generate attachment MODEL FIELD [--any]" unless args.size == 2

        Attachment.generate(".", args[0], args[1], argv.include?("--any"))
        puts Attachment::BACKUP_NOTE
        puts ""
        puts "next:"
        puts "  cybertrain db migrate"
        puts "  cybertrain server"
        puts "  cybertrain test        # test/integration/*_attachment_test.rb among the others"
      when "authentication"
        args = without_flag(without_flag(without_flag(argv[2, argv.size - 2], "--invite-only"), "--confirmable"), "--force")
        raise InvalidArgument, "usage: cybertrain generate authentication [--invite-only] [--confirmable] [--force]" unless args.empty?

        invite_only = argv.include?("--invite-only")
        confirmable = argv.include?("--confirmable")
        result = Authentication.generate_with_result(".", invite_only, confirmable, argv.include?("--force"))
        result.manual.each { |diff| puts diff }
        puts ""
        puts "next:"
        puts "  cybertrain db migrate"
        if invite_only
          app = Build.app_name(".")
          puts "  cybertrain server      # then open the /setup?token=... link it prints, on this machine (or: spin run #{app} -- user EMAIL)"
        else
          puts "  cybertrain server      # then open /sign_up"
        end
        puts "  cybertrain test        # test/controllers/sessions_controller_test.rb and the other authentication tests among the others"
        base_url_env = Authentication.base_url_env(Build.app_name("."))
        mails = confirmable ? "password reset and confirmation mails" : "password reset mails"
        puts "  # #{mails}: set #{base_url_env} and CYBERTRAIN_SMTP_* (config/app.rb, Cybertrain::Config)"
        unless result.manual.empty?
          # The warnings above a diff (with --confirmable, what the sessions
          # and registrations controllers leave out until theirs is
          # applied), once more at the end.
          result.manual.each do |diff|
            lines = diff.lines
            next if lines.size < 2 || !lines[1].start_with?("IMPORTANT: ")

            path = lines[0].delete_prefix("manual  ")
            path = path[0, path.index(":").to_i].to_s
            puts "IMPORTANT: #{path}: #{lines[1].strip.delete_prefix("IMPORTANT: ")}"
          end
          puts ""
          puts "next: apply the diffs above, or re-run with --force for files you never edited"
          puts "  # the app may not build until these diffs are applied: the files written now need them"
        end
      when "helper"
        args = without_flag(argv[2, argv.size - 2], "--force")
        raise InvalidArgument, "usage: cybertrain generate helper NAME [--force]" unless args.size == 1

        Helper.generate(".", args[0], argv.include?("--force"))
        puts ""
        puts "next:"
        puts "  spin run gen           # includes the module into the app's helpers"
        puts "  cybertrain test        # test/helpers/#{Inflector.underscore(args[0]).delete_suffix("_helper")}_helper_test.rb among the others"
      when "component"
        args = without_flag(argv[2, argv.size - 2], "--force")
        raise InvalidArgument, "usage: cybertrain generate component NAME [attr[:type] ...] [--force]" if args.empty?

        Component.generate(".", args[0], args[1, args.size - 1], argv.include?("--force"))
        puts ""
        puts "next:"
        puts "  spin run gen           # writes gen/components.rb"
        puts "  cybertrain test        # test/components/#{Inflector.underscore(args[0]).delete_suffix("_component")}_component_test.rb among the others"
      when "job"
        rest = argv[2, argv.size - 2]
        args = Job.positional(rest)
        raise InvalidArgument, Job::USAGE unless args.size == 1

        Job.generate(".", args[0], Job.retry_specs(rest), argv.include?("--force"))
        puts ""
        puts "next:"
        puts "  spin run gen           # writes gen/jobs.rb (perform_later and the retry arms)"
        puts "  cybertrain test        # test/jobs/#{Inflector.underscore(args[0]).delete_suffix("_job")}_job_test.rb among the others"
      else
        raise InvalidArgument, "only `generate scaffold`, `generate attachment`, `generate authentication`, `generate helper`, `generate component` and `generate job` are supported"
      end
      0
    end
  end
end
