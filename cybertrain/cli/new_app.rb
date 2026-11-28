# `cybertrain new blog`: writes the skeleton of an application package.
require "cybertrain/generator/inflector"
require "cybertrain/cli/templates"
require "cybertrain/cli/build"
require "cybertrain/cli/toolchain"
require "cybertrain/shell"

module Cybertrain
  module CLI
    module NewApp
      # dir is the directory to create ("blog" or "path/to/blog"; its last
      # component names the package). framework_dep is the TOML value that
      # spin.toml's `cybertrain =` line gets: `{ path = "/abs/cybertrain" }` or
      # a version constraint such as `"~> 0.1"`. Returns the created paths,
      # relative to dir. database is the adapter, "sqlite" (the default) or
      # "mysql" (`--database=mysql`): bin/NAME.rb and bin/db.rb then require
      # "cybertrain/mysql", config/app.rb explains DATABASE_URL and
      # .env.example has development's; the Dockerfile, config/deploy.yml,
      # .kamal/secrets and the CI workflow pass DATABASE_URL (the workflow
      # with a MySQL service); every other file is the same.
      def self.create(dir, framework_dep, database = "sqlite")
        package = File.basename(dir)
        # Before anything is written: `public`, `storage` and `tmp` are valid
        # identifiers but collide with dist/ entries (Build.dist_name_problem).
        problem = Build.dist_name_problem(package)
        raise InvalidArgument, "'#{package}' is not a valid app name: it #{problem}" unless problem.empty?

        title = Inflector.camelize(package)
        files = [
          ["spin.toml", Templates.spin_toml(package, framework_dep)],
          [".gitignore", Templates.gitignore],
          [".env.example", Templates.env_example(package, database)],
          ["README.md", Templates.readme(title, package, database)],
          ["AGENTS.md", Templates.agents_md(title, package, database)],
          ["CLAUDE.md", Templates.claude_md],
          ["config/app.rb", Templates.config_app(package, database)],
          ["config/routes.rb", Templates.routes],
          ["config/locales/en.yml", Templates.locales_en_yml],
          ["db/schema.rb", Templates.schema],
          ["db/migrate/.keep", ""],
          ["app/controllers/application_controller.rb", Templates.application_controller],
          ["app/models/.keep", ""],
          ["app/helpers/.keep", ""],
          ["app/jobs/.keep", ""],
          ["app/assets/stylesheets/application.css", Templates.style_css],
          ["app/assets/images/.keep", ""],
          ["app/javascript/application.js", Templates.application_js],
          ["config/importmap.rb", Templates.importmap],
          ["app/views/layouts/application.html.erb", Templates.layout(title)],
          ["public/404.html", Templates.error_page("404", "Not Found")],
          ["public/500.html", Templates.error_page("500", "Internal Server Error")],
          ["public/up.html", Templates.up_html],
          ["bin/#{package}.rb", Templates.bin_app(package, database)],
          ["bin/gen.rb", Templates.bin_gen],
          ["bin/db.rb", Templates.bin_db(database)],
          ["Dockerfile", Templates.dockerfile(package, database)],
          [".dockerignore", Templates.dockerignore],
          ["config/deploy.yml", Templates.deploy_yml(package, database)],
          [".kamal/secrets", Templates.kamal_secrets(database)],
          [".github/workflows/ci.yml", Templates.ci_workflow(package, database)],
          ["gen/.keep", ""],
          ["storage/.keep", ""],
          ["tmp/.keep", ""],
          ["test/test_helper.rb", Templates.test_helper],
          ["test/integration/health_test.rb", Templates.health_test],
          ["test/fixtures/.keep", ""],
          ["test/support/.keep", ""]
        ]
        created = Array.new(0) { "" }
        files.each do |entry|
          created << entry[0] if Templates.write(dir, entry[0], entry[1]) == "create"
        end
        created
      end

      # What `rails new` does with `bundle install`: resolve and lock the
      # framework (fetching it into spin's cache, ~/.cache/spin), then write
      # gen/ so `spin build` works straight away: gen through Build.run_tool,
      # which records what the binary was built from, so the next command
      # runs it as it is (without the record spin would build it again:
      # this run of gen wrote gen/**/*.rb). Installs Spinel first when
      # this machine has none of the pinned release (Toolchain.ensure!).
      # Returns false when a step failed.
      def self.bootstrap(dir)
        unless Toolchain.ensure!
          puts "skip spin lock / #{Shell::TOOL_SPIN} run gen: Spinel #{Cybertrain::SPINEL_TAG} is not available"
          puts "  fix the problem above (`cybertrain doctor` lists the checks), then: cybertrain setup && #{recovery_command(dir)}"
          return false
        end

        puts "run    spin lock"
        return true if system(lock_command(dir)) && Build.run_tool(dir, "gen", "", Build::Runner.new)

        puts "error: bootstrapping #{dir} failed; fix the cause, then run: #{recovery_command(dir)}"
        false
      end

      # Run by bootstrap once Toolchain.ensure! has put spin on this
      # process's PATH; gen follows it, in debug mode as every CLI command
      # builds it (Build.run_tool).
      def self.lock_command(dir)
        "cd #{Shell.quote(dir)} && spin lock"
      end

      # The same steps for the user to run by hand: through `cybertrain
      # spin`, since the Spinel cybertrain installed is not on their PATH.
      def self.recovery_command(dir)
        "cd #{Shell.quote(dir)} && cybertrain spin lock && SPIN_DEBUG=1 cybertrain spin run gen"
      end
    end
  end
end
