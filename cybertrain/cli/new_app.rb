# `cybertrain new blog`: writes the skeleton of an application package.
require "cybertrain/generator/inflector"
require "cybertrain/cli/templates"
require "cybertrain/cli/build"
require "cybertrain/cli/toolchain"

module Cybertrain
  module CLI
    module NewApp
      # dir is the directory to create ("blog" or "path/to/blog"; its last
      # component names the package). framework_dep is the TOML value that
      # spin.toml's `cybertrain =` line gets: `{ path = "/abs/cybertrain" }` or
      # a version constraint such as `"~> 0.1"`. Returns the created paths,
      # relative to dir.
      def self.create(dir, framework_dep)
        package = File.basename(dir)
        title = Inflector.camelize(package)
        files = [
          ["spin.toml", Templates.spin_toml(package, framework_dep)],
          [".gitignore", Templates.gitignore],
          ["README.md", Templates.readme(title, package)],
          ["config/app.rb", Templates.config_app],
          ["config/routes.rb", Templates.routes],
          ["db/schema.rb", Templates.schema],
          ["db/migrate/.keep", ""],
          ["app/controllers/application_controller.rb", Templates.application_controller],
          ["app/models/.keep", ""],
          ["app/helpers/.keep", ""],
          ["app/views/layouts/application.html.erb", Templates.layout(title)],
          ["public/404.html", Templates.error_page("404", "Not Found")],
          ["public/500.html", Templates.error_page("500", "Internal Server Error")],
          ["public/style.css", Templates.style_css],
          ["bin/#{package}.rb", Templates.bin_app(package)],
          ["bin/gen.rb", Templates.bin_gen],
          ["bin/db.rb", Templates.bin_db],
          ["gen/.keep", ""],
          ["storage/.keep", ""],
          ["tmp/.keep", ""],
          ["test/.keep", ""]
        ]
        created = Array.new(0) { "" }
        files.each do |entry|
          created << entry[0] if Templates.write(dir, entry[0], entry[1]) == "create"
        end
        created
      end

      # What `rails new` does with `bundle install`: resolve and lock the
      # framework (fetching it into spin's cache, ~/.cache/spin), then write
      # gen/ so `spin build` works straight away. Installs Spinel first when
      # this machine has none of the pinned release (Toolchain.ensure!).
      # Returns false when a step failed.
      def self.bootstrap(dir)
        unless Toolchain.ensure!
          puts "skip spin lock / spin run gen: Spinel #{Cybertrain::SPINEL_TAG} is not available"
          puts "  fix the problem above (`cybertrain doctor` lists the checks), then: cybertrain setup && #{recovery_command(dir)}"
          return false
        end

        puts "run    spin lock && spin run gen"
        return true if system(bootstrap_command(dir))

        puts "error: bootstrapping #{dir} failed; fix the cause, then run: #{recovery_command(dir)}"
        false
      end

      # Run by bootstrap once Toolchain.ensure! has put spin on this
      # process's PATH.
      def self.bootstrap_command(dir)
        "cd #{Build.shell_quote(dir)} && spin lock && spin run gen"
      end

      # The same steps for the user to run by hand: through `cybertrain
      # spin`, since the Spinel cybertrain installed is not on their PATH.
      def self.recovery_command(dir)
        "cd #{Build.shell_quote(dir)} && cybertrain spin lock && cybertrain spin run gen"
      end
    end
  end
end
