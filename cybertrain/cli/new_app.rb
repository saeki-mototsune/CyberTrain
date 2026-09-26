# `cybertrain new blog`: writes the skeleton of an application package.
require "cybertrain/generator/inflector"
require "cybertrain/cli/templates"

module Cybertrain
  module CLI
    module NewApp
      KEEP_DIRS = ["db/migrate", "app/models", "app/helpers", "gen", "storage", "tmp", "test"]

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
          ["README.md", Templates.readme(title)],
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
          ["bin/server.rb", Templates.bin_server],
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
      # gen/ so `spin build` works straight away. Without spin on PATH it
      # only says what to run later. Returns false when a step failed.
      def self.bootstrap(dir)
        unless system("command -v spin > /dev/null 2>&1")
          puts "skip spin lock / spin run gen: `spin` is not on PATH"
          puts "  install Spinel (https://github.com/matz/spinel), then: #{bootstrap_command(dir)}"
          return true
        end

        puts "run    spin lock && spin run gen"
        return true if system(bootstrap_command(dir))

        puts "error: bootstrapping #{dir} failed; fix the cause, then run: #{bootstrap_command(dir)}"
        false
      end

      def self.bootstrap_command(dir)
        "cd #{shell_quote(dir)} && spin lock && spin run gen"
      end

      def self.shell_quote(text)
        "'#{text.gsub("'", "'\\\\''")}'"
      end
    end
  end
end
