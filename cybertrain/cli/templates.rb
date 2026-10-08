# Cybertrain::CLI::Templates -- the file contents `cybertrain new` and
# `cybertrain generate scaffold` write, embedded in the binary, plus the one
# helper that puts them on disk.
#
# The scaffold templates take a Cybertrain::CLI::Resource (cli/scaffold.rb).
# Generated views stay inside the template language of docs/design.md
# section 7: literals, @ivars, locals, helper calls, `if` and `each do`.
require "cybertrain/ident"

module Cybertrain
  module CLI
    module Templates
      # Writes root/path unless it already exists, creating directories on
      # the way. Returns "create", "identical" (same content already there)
      # or "exist" (different content: left alone, never overwritten), and
      # prints that status with the path.
      def self.write(root, path, content)
        full = File.join(root, path)
        status = "create"
        if File.exist?(full)
          status = File.read(full) == content ? "identical" : "exist"
        else
          mkdir_p(File.dirname(full))
          File.write(full, content)
        end
        puts "#{status} #{path}"
        status
      end

      def self.mkdir_p(dir)
        return if dir == "" || File.directory?(dir)

        path = dir.start_with?("/") ? +"/" : +""
        dir.split("/").each do |part|
          next if part == ""

          path << part
          Dir.mkdir(path) unless File.directory?(path)
          path << "/"
        end
        nil
      end

      # A lowercase Ruby-ish name: "post", "blog_post", "released_on". The
      # snake_case subset of Ident.column? (what the generator accepts),
      # letter-first since it names packages, binaries and files too; one
      # definition of the characters, so the two cannot drift apart.
      def self.identifier?(word)
        Ident.snake_case?(word, false)
      end

      # "blog_posts" -> "Blog posts"
      def self.humanize(word)
        word.tr("_", " ").capitalize
      end

      # ---- cybertrain new ----------------------------------------------

      # framework_dep is the TOML value: `{ path = "..." }` or `"~> 0.1"`.
      def self.spin_toml(package, framework_dep)
        <<~TOML
          [package]
          name = "#{package}"
          version = "0.1.0"
          # jemalloc is a faster malloc for a server: about 1.3x the requests
          # per second on examples/blog (docs/benchmark.md). Building then
          # needs its development package (libjemalloc-dev on Debian/Ubuntu,
          # `brew install jemalloc` on macOS).
          # allocator = "jemalloc"

          [dependencies]
          cybertrain = #{framework_dep}
        TOML
      end

      def self.gitignore
        <<~TEXT
          /build/
          /dist/
          /storage/*.sqlite3*
          /tmp/*
          !/tmp/.keep
          /log/
        TEXT
      end

      def self.readme(title, package)
        <<~MARKDOWN
          # #{title}

          A cybertrain application, compiled to one binary by Spinel.

          ```sh
          cybertrain generate scaffold post title:string body:text
          cybertrain db migrate  # gen, apply db/migrate, gen again
          cybertrain server      # http://127.0.0.1:3000 (`cybertrain server 4000` for another port)
          cybertrain build       # dist/: the binary (views embedded) + public/
          ```

          `spin run gen` (which `db`, `server` and `build` run for you)
          regenerates `gen/` from db/schema.rb, config/routes.rb and app/;
          commit `gen/`. In development views under `app/views/` are read at
          run time: edit them without rebuilding. `cybertrain db status` and
          `cybertrain db rollback 1` reach the other database commands.
          `cybertrain db migrate` runs migrations through `bin/db.rb`; a
          deployed `dist/#{package}` runs them with `./#{package} migrate`.

          To deploy, copy `dist/` to a machine with the same OS and CPU, then
          `cd dist && ./#{package} migrate && ./#{package}` (production by default;
          set CYBERTRAIN_SECRET_KEY_BASE).
        MARKDOWN
      end

      def self.config_app
        <<~RUBY
          # Application settings; see Cybertrain::Config for every option.
          # Environment variables (PORT, CYBERTRAIN_ENV, CYBERTRAIN_DATABASE,
          # CYBERTRAIN_SECRET_KEY_BASE, CYBERTRAIN_HOST, CYBERTRAIN_SESSION_SAME_SITE,
          # CYBERTRAIN_SESSION_PARTITIONED) are read before this block runs.
          Cybertrain.configure do |c|
            # c.port = 3000
            # c.workers = 1

            # Production marks the session cookie Secure (HTTPS only). Turn it
            # off only if production is really served over plain http://.
            # c.session_secure = false
          end
        RUBY
      end

      def self.routes
        "Cybertrain::Routes.draw do\nend\n"
      end

      def self.schema
        "Cybertrain::Schema.define(version: \"0\") do |s|\nend\n"
      end

      def self.application_controller
        <<~RUBY
          class ApplicationController < Cybertrain::Controller
            rescue_from Cybertrain::RecordNotFound, with: :record_not_found

            private

            def record_not_found
              render plain: "Not Found", status: :not_found
            end
          end
        RUBY
      end

      def self.layout(title)
        <<~ERB
          <!DOCTYPE html>
          <html>
            <head>
              <title>#{title}</title>
              <meta name="viewport" content="width=device-width,initial-scale=1">
              <%= csrf_meta_tags %>
              <link rel="stylesheet" href="/style.css">
            </head>
            <body>
              <main>
                <% if flash[:notice] %>
                  <p class="notice"><%= flash[:notice] %></p>
                <% end %>
                <% if flash[:alert] %>
                  <p class="alert"><%= flash[:alert] %></p>
                <% end %>
                <%= yield %>
              </main>
            </body>
          </html>
        ERB
      end

      def self.error_page(status, message)
        <<~HTML
          <!DOCTYPE html>
          <html>
            <head>
              <title>#{message} (#{status})</title>
              <meta name="viewport" content="width=device-width,initial-scale=1">
              <link rel="stylesheet" href="/style.css">
            </head>
            <body>
              <main>
                <h1>#{message}</h1>
                <p>#{status == "404" ? "The page you were looking for doesn't exist." : "Something went wrong on our side."}</p>
              </main>
            </body>
          </html>
        HTML
      end

      def self.style_css
        <<~CSS
          body { font-family: system-ui, sans-serif; line-height: 1.5; margin: 0; color: #222; }
          main { max-width: 48rem; margin: 0 auto; padding: 1rem; }
          a { color: #0b5cad; }
          table { border-collapse: collapse; width: 100%; }
          th, td { text-align: left; padding: 0.25rem 0.5rem; border-bottom: 1px solid #ddd; }
          .notice { color: #166534; background: #dcfce7; padding: 0.5rem; }
          .alert { color: #991b1b; background: #fee2e2; padding: 0.5rem; }
          .field { margin-bottom: 0.75rem; }
          .field label { display: block; font-weight: 600; }
          .field input[type=text], .field input[type=number], .field textarea { width: 100%; padding: 0.25rem; }
          .field_with_errors input, .field_with_errors textarea { border: 1px solid #b91c1c; }
          #error_explanation { color: #991b1b; border: 1px solid #fca5a5; padding: 0.5rem 1rem; margin-bottom: 1rem; }
          form.button_to { display: inline; }
        CSS
      end

      def self.bin_app(package)
        <<~RUBY
          require "cybertrain"
          require_relative "../gen/views"      # embedded build: sets CYBERTRAIN_ENV=production by default
          require_relative "../config/app"     # so it comes before the config
          require_relative "../gen/app"
          require_relative "../gen/migrations"

          exit(Cybertrain::Main.run("#{package}", ARGV,
                                    router: Gen::Routes.build(Cybertrain::Router.new),
                                    url_resolver: Gen::Routes.url_resolver,
                                    views: Gen::Views::SOURCES))
        RUBY
      end

      def self.bin_gen
        <<~RUBY
          require "cybertrain/generator"
          require_relative "../config/routes"
          require_relative "../db/schema"

          exit(Cybertrain::Gen::Runner.run(".", ARGV))
        RUBY
      end

      # Development only, so migrations run before gen/models exist; production uses `./NAME migrate`.
      def self.bin_db
        <<~RUBY
          require "cybertrain"
          require_relative "../config/app"
          require_relative "../gen/migrations"

          exit(Cybertrain::DB::CLI.run(ARGV))
        RUBY
      end

      # ---- cybertrain generate scaffold --------------------------------

      def self.migration(res)
        buf = +""
        buf << "class Create#{res.plural_class} < Cybertrain::Migration::Base\n"
        buf << "  def change\n"
        buf << "    create_table \"#{res.plural}\" do |t|\n"
        res.fields.each { |f| buf << "      #{f.migration_line}\n" }
        buf << "      t.timestamps\n"
        buf << "    end\n"
        buf << "  end\n"
        buf << "end\n"
        buf
      end

      def self.model(res)
        buf = +""
        buf << "# Columns, associations and the Cybertrain::Model superclass come from\n"
        buf << "# gen/models/#{res.singular}.rb, generated from db/schema.rb by `spin run gen`.\n"
        buf << "class #{res.class_name}\n"
        first = res.first_string_field
        buf << "  validates :#{first}, presence: true\n" unless first == ""
        buf << "end\n"
        buf
      end

      def self.controller(res)
        s = res.singular
        p = res.plural
        human = humanize(s)
        permitted = res.fields.map { |f| ":#{f.column_name}" }.join(", ")
        <<~RUBY
          class #{res.plural_class}Controller < ApplicationController
            before_action :set_#{s}, only: [:show, :edit, :update, :destroy]

            # GET /#{p}
            def index
              @#{p} = #{res.class_name}.all.to_a
            end

            # GET /#{p}/1
            def show
            end

            # GET /#{p}/new
            # (named new_action: a `new` method would shadow #{res.plural_class}Controller.new)
            def new_action
              @#{s} = #{res.class_name}.new
            end

            # GET /#{p}/1/edit
            def edit
            end

            # POST /#{p}
            def create
              @#{s} = #{res.class_name}.new(#{s}_params)
              if @#{s}.save
                flash[:notice] = "#{human} was successfully created."
                redirect_to #{s}_path(@#{s}), status: :see_other
              else
                render :new, status: :unprocessable_entity
              end
            end

            # PATCH/PUT /#{p}/1
            def update
              if @#{s}.update(#{s}_params)
                flash[:notice] = "#{human} was successfully updated."
                redirect_to #{s}_path(@#{s}), status: :see_other
              else
                render :edit, status: :unprocessable_entity
              end
            end

            # DELETE /#{p}/1
            def destroy
              @#{s}.destroy
              flash[:notice] = "#{human} was successfully destroyed."
              redirect_to #{res.index_helper}_path, status: :see_other
            end

            private

            def set_#{s}
              @#{s} = #{res.class_name}.find(params[:id])
            end

            def #{s}_params
              params.require(:#{s}).permit(#{permitted})
            end
          end
        RUBY
      end

      def self.index_view(res)
        s = res.singular
        words = s.tr("_", " ")
        buf = +""
        buf << "<h1>#{humanize(res.plural)}</h1>\n\n"
        buf << "<table>\n  <thead>\n    <tr>\n"
        res.fields.each { |f| buf << "      <th>#{f.label}</th>\n" }
        buf << "      <th></th>\n    </tr>\n  </thead>\n  <tbody>\n"
        buf << "    <% @#{res.plural}.each do |#{s}| %>\n"
        buf << "      <tr>\n"
        res.fields.each { |f| buf << "        <td><%= #{s}.#{f.column_name} %></td>\n" }
        buf << "        <td><%= link_to \"Show\", #{s}_path(#{s}) %></td>\n"
        buf << "      </tr>\n"
        buf << "    <% end %>\n"
        buf << "  </tbody>\n</table>\n\n"
        buf << "<p><%= link_to \"New #{words}\", new_#{s}_path %></p>\n"
        buf
      end

      def self.show_view(res)
        s = res.singular
        words = s.tr("_", " ")
        buf = +""
        buf << "<h1>#{humanize(s)}</h1>\n\n"
        res.fields.each do |f|
          buf << "<p>\n  <strong>#{f.label}:</strong>\n  <%= @#{s}.#{f.column_name} %>\n</p>\n\n"
        end
        buf << "<p>\n"
        buf << "  <%= link_to \"Edit this #{words}\", edit_#{s}_path(@#{s}) %> |\n"
        buf << "  <%= link_to \"Back to #{res.plural.tr("_", " ")}\", #{res.index_helper}_path %>\n"
        buf << "</p>\n\n"
        buf << "<%= button_to \"Destroy this #{words}\", #{s}_path(@#{s}), method: :delete %>\n"
        buf
      end

      def self.new_view(res)
        s = res.singular
        buf = +""
        buf << "<h1>New #{s.tr("_", " ")}</h1>\n\n"
        buf << "<%= render \"form\", #{s}: @#{s} %>\n\n"
        buf << "<p><%= link_to \"Back to #{res.plural.tr("_", " ")}\", #{res.index_helper}_path %></p>\n"
        buf
      end

      def self.edit_view(res)
        s = res.singular
        buf = +""
        buf << "<h1>Editing #{s.tr("_", " ")}</h1>\n\n"
        buf << "<%= render \"form\", #{s}: @#{s} %>\n\n"
        buf << "<p>\n"
        buf << "  <%= link_to \"Show this #{s.tr("_", " ")}\", #{s}_path(@#{s}) %> |\n"
        buf << "  <%= link_to \"Back to #{res.plural.tr("_", " ")}\", #{res.index_helper}_path %>\n"
        buf << "</p>\n"
        buf
      end

      def self.form_partial(res)
        s = res.singular
        buf = +""
        buf << "<%# locals: (#{s}:) %>\n"
        buf << "<%= form_with(model: #{s}) do |f| %>\n"
        buf << "  <% if #{s}.errors.any? %>\n"
        buf << "    <div id=\"error_explanation\">\n"
        buf << "      <h2><%= pluralize(#{s}.errors.count, \"error\") %> prohibited this #{s.tr("_", " ")} from being saved:</h2>\n"
        buf << "      <ul>\n"
        buf << "        <% #{s}.errors.full_messages.each do |message| %>\n"
        buf << "          <li><%= message %></li>\n"
        buf << "        <% end %>\n"
        buf << "      </ul>\n"
        buf << "    </div>\n"
        buf << "  <% end %>\n\n"
        res.fields.each do |f|
          buf << "  <div class=\"field\">\n"
          buf << "    <%= f.label :#{f.column_name} %>\n"
          buf << "    <%= f.#{f.form_input} :#{f.column_name} %>\n"
          buf << "  </div>\n\n"
        end
        buf << "  <div class=\"actions\">\n"
        buf << "    <%= f.submit %>\n"
        buf << "  </div>\n"
        buf << "<% end %>\n"
        buf
      end
    end
  end
end
