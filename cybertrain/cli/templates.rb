# Cybertrain::CLI::Templates -- the file contents `cybertrain new` and
# `cybertrain generate scaffold` write, embedded in the binary, plus the one
# helper that puts them on disk.
#
# The scaffold templates take a Cybertrain::CLI::Resource (cli/scaffold.rb).
# Generated views stay inside the template language of docs/design.md
# section 7: literals, @ivars, locals, helper calls, `if` and `each do`.
require "cybertrain/ident"
require "cybertrain/version"

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
          # jemalloc is a faster malloc for a server: 1.1 to 1.4 times the
          # requests per second on examples/blog (docs/benchmark.md). Building then
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
          /storage/uploads/
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

          Or deploy with [Kamal](https://kamal-deploy.org): fill in the values
          marked CHANGE ME in `config/deploy.yml`, export
          KAMAL_REGISTRY_PASSWORD and CYBERTRAIN_SECRET_KEY_BASE (read by
          `.kamal/secrets`), commit, then `kamal setup` once and `kamal deploy`
          after that. The `Dockerfile` builds the binary inside the image.

          On GitHub, `.github/workflows/ci.yml` installs the toolchain the
          framework commit in `spin.lock` pins and checks that `spin.lock` and
          `gen/` are committed and current, then runs `spin test`.
        MARKDOWN
      end

      def self.config_app
        <<~RUBY
          # Application settings; see Cybertrain::Config for every option.
          # Environment variables (PORT, CYBERTRAIN_ENV, CYBERTRAIN_DATABASE,
          # CYBERTRAIN_SECRET_KEY_BASE, CYBERTRAIN_HOST, CYBERTRAIN_SESSION_SAME_SITE,
          # CYBERTRAIN_SESSION_PARTITIONED, CYBERTRAIN_ALLOWED_HOSTS) are read before this block runs.
          Cybertrain.configure do |c|
            # c.port = 3000
            # c.workers = 1

            # Development accepts localhost, 127.0.0.1 and [::1]. Add an exact
            # forwarding hostname here or via CYBERTRAIN_ALLOWED_HOSTS (comma-separated).
            # c.allowed_hosts << "my-preview.example.com"

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

          # Operational commands: `./#{package} NAME ARGS...` runs the block with
          # Cybertrain::DB connected (pool of 1) and exits with its value;
          # `./#{package} help` lists them.
          #   Cybertrain::Main.command("prune", "delete old comments") do |argv|
          #     Cybertrain::DB.with { |c| c.execute("DELETE FROM comments WHERE created_at < date('now', '-30 days')") }
          #     0
          #   end

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

      # ---- Kamal (docs/deploy.md, "Kamal でデプロイする") ------------------
      #
      # The image compiles the app inside the build stage, so the binary
      # links the same libc and SQLite as the runtime stage: both stages are
      # the same Ubuntu release (its apt Ruby is 3.2, what the CLI needs).
      # The gem is pinned to this CLI's version, the release `new` writes into
      # spin.toml, so the generator that runs in the image matches the
      # framework spin.lock fixes.

      def self.dockerfile(package)
        <<~DOCKERFILE
          # syntax=docker/dockerfile:1
          # The production image `kamal deploy` builds and runs (config/deploy.yml).
          # To try it by hand:
          #   docker build -t #{package} .
          #   docker run --rm -p 127.0.0.1:3000:3000 -e CYBERTRAIN_SECRET_KEY_BASE=$(openssl rand -hex 32) \\
          #     -v #{package}_storage:/app/storage #{package}
          # then open http://localhost:3000 (the session cookie is Secure in
          # production; Chrome and Firefox accept it from localhost over http).
          #
          # The framework is fetched by spin from what spin.toml names (a git tag
          # by default); an app created with --path needs a git or version
          # dependency before it can be built here.

          ARG UBUNTU_VERSION=24.04

          # ---- build: Spinel, then `cybertrain build` -> /src/dist ----------------
          FROM docker.io/library/ubuntu:$UBUNTU_VERSION AS build

          # ruby-dev and the prism gem: Spinel's build runs a Ruby generator that
          # requires prism, which 24.04's Ruby 3.2 does not bundle.
          RUN apt-get update -qq && \\
              apt-get install --no-install-recommends -y build-essential git curl ca-certificates \\
                ruby ruby-dev libsqlite3-dev zlib1g-dev libjemalloc-dev && \\
              rm -rf /var/lib/apt/lists/* && \\
              gem install --no-document prism -v 1.9.0

          # The cybertrain command, then the Spinel release it pins: a few minutes,
          # cached as a layer until the version changes.
          RUN gem install cybertrain -v #{Cybertrain::VERSION} --no-document && cybertrain setup

          WORKDIR /src
          COPY . .
          RUN cybertrain build

          # ---- runtime: the binary, public/ and the libraries it links ----------
          FROM docker.io/library/ubuntu:$UBUNTU_VERSION

          RUN apt-get update -qq && \\
              apt-get install --no-install-recommends -y libsqlite3-0 zlib1g libjemalloc2 && \\
              rm -rf /var/lib/apt/lists/*

          RUN useradd --system --create-home --shell /bin/bash app

          WORKDIR /app
          COPY --from=build --chown=app:app /src/dist/ /app/

          # storage/ holds the SQLite database (storage/production.sqlite3); mount
          # a volume there so it outlives the container.
          USER app
          ENV CYBERTRAIN_ENV=production \\
              CYBERTRAIN_HOST=0.0.0.0 \\
              PORT=3000
          EXPOSE 3000

          # Apply pending migrations, then serve. exec hands SIGTERM to the server,
          # which finishes the requests in flight before it exits.
          CMD ["sh", "-c", "./#{package} migrate && exec ./#{package}"]
        DOCKERFILE
      end

      def self.dockerignore
        <<~TEXT
          # What the image build does not need (see Dockerfile).
          /.git/
          /.kamal/
          /build/
          /dist/
          /log/
          /storage/*
          !/storage/.keep
          /tmp/*
          !/tmp/.keep
        TEXT
      end

      def self.deploy_yml(package)
        <<~YAML
          # Kamal 2 (https://kamal-deploy.org): `kamal setup` the first time,
          # `kamal deploy` after that. Replace every value marked CHANGE ME.

          # Name of the application; names its containers.
          service: #{package}

          # The image to build and push. CHANGE ME: your registry user.
          image: your-user/#{package}

          # The servers to deploy to. CHANGE ME: the server's address. One
          # server: the database is a SQLite file on that server's volume.
          servers:
            web:
              - 192.168.0.1

          # kamal-proxy terminates TLS (a Let's Encrypt certificate for host)
          # and forwards to the app on port 3000. Keep ssl on: in production the
          # session cookie is Secure, so forms only work over HTTPS. CHANGE ME:
          # host, with a DNS record pointing at the server.
          proxy:
            ssl: true
            host: #{package}.example.com
            app_port: 3000
            healthcheck:
              # public/up.html, served by the app itself.
              path: /up.html

          # How long kamal-proxy polls /up.html on a new container before giving
          # up (Kamal's default, written out). If the new container does not
          # answer 200 in time, the deploy fails and traffic stays on the old one.
          deploy_timeout: 30

          # Credentials for the registry the image is pushed to. CHANGE ME:
          # the user; the password comes from .kamal/secrets.
          registry:
            # server: ghcr.io
            username: your-user
            password:
              - KAMAL_REGISTRY_PASSWORD

          # The app's settings (cybertrain/config.rb). Secrets come from
          # .kamal/secrets.
          env:
            clear:
              # kamal-proxy runs in its own container and connects from its address
              # on the Docker network (Docker hands those out of 172.16.0.0/12 by
              # default): trust the X-Forwarded-For it sets, so that
              # request.client_ip, what rate_limit counts, is each visitor rather
              # than the proxy. Change it if your Docker networks use another range.
              CYBERTRAIN_TRUSTED_PROXIES: 172.16.0.0/12
              # SPINEL_WORKERS: 2
            secret:
              - CYBERTRAIN_SECRET_KEY_BASE

          # The SQLite database lives in storage/: keep it on the server across
          # deploys. Back it up from there (docs/deploy.md).
          volumes:
            - "#{package}_storage:/app/storage"

          # `kamal db_status` (pending migrations) and `kamal shell`.
          aliases:
            db_status: app exec --reuse "./#{package} db status"
            shell: app exec --interactive --reuse "bash"

          # The image compiles the app (and Spinel, once) inside Docker. Build for
          # the server's CPU; building another architecture under emulation is
          # slow, so on an arm64 Mac either build on the server
          # (remote: ssh://root@192.168.0.1) or set arch to arm64 for an arm64
          # server.
          builder:
            arch: amd64
            # remote: ssh://root@192.168.0.1
        YAML
      end

      def self.kamal_secrets
        <<~TEXT
          # Secrets for config/deploy.yml, read from the environment of the
          # machine running kamal (or a password manager:
          # https://kamal-deploy.org/docs/commands/secrets/). Never write the
          # values themselves here: this file is committed.

          # A token that can push to the registry (Docker Hub access token, or a
          # GitHub token with write:packages for ghcr.io).
          KAMAL_REGISTRY_PASSWORD=$KAMAL_REGISTRY_PASSWORD

          # Signs the session cookie; changing it signs everyone out. Generate it
          # once with `openssl rand -hex 32` and keep it somewhere safe.
          CYBERTRAIN_SECRET_KEY_BASE=$CYBERTRAIN_SECRET_KEY_BASE
        TEXT
      end

      # "saeki-mototsune/cybertrain/.github/actions/setup-cybertrain@v0.2.1":
      # the composite action in this repository, at this CLI's release tag.
      # `uses:` takes no expressions, so the pin is static; the action itself
      # reads the framework commit out of spin.lock and installs the
      # toolchain that commit pins (docs/design.md D32).
      def self.setup_action_ref
        slug = Cybertrain::REPOSITORY.sub("https://github.com/", "")
        "#{slug}/.github/actions/setup-cybertrain@v#{Cybertrain::VERSION}"
      end

      # .github/workflows/ci.yml: the toolchain from the setup-cybertrain
      # action, then the checks an app's CI needs: spin.lock and gen/ are
      # committed and current, and the tests pass.
      def self.ci_workflow
        action = setup_action_ref
        <<~YAML
          name: CI

          on:
            push:
              branches: [main]
            pull_request:

          jobs:
            test:
              runs-on: ubuntu-latest
              steps:
                - uses: actions/checkout@v4

                # SQLite, zlib and OpenSSL headers, Ruby, and Spinel (cached),
                # installed by the cybertrain CLI of the framework commit in
                # spin.lock: that commit is read from spin.lock, so the
                # spin.toml dependency must be a git one (the default). With a
                # path dependency, check the framework out yourself and pass
                # `with: { framework-path: ... }`.
                - uses: #{action}

                # spin.lock is committed and matches spin.toml.
                - name: spin.lock is current
                  run: spin lock && git diff --exit-code spin.lock

                # gen/ is committed and fresh (nothing is written).
                - name: gen/ is current
                  run: spin run gen -- --check

                # `spin test` fails when there is no test/*.rb; a new app has none.
                - name: Tests
                  run: |
                    if ls test/*.rb > /dev/null 2>&1; then
                      spin test
                    else
                      echo "no test/*.rb yet"
                    fi
        YAML
      end

      # What kamal-proxy polls before it sends traffic to a new container.
      def self.up_html
        "<!DOCTYPE html>\n<html><body>OK</body></html>\n"
      end

      # ---- cybertrain generate attachment / scaffold FIELD:attachment ----

      # The accept= attribute of the file input: the four raster types
      # Cybertrain::UploadedFile serves inline (the generator's default).
      ATTACHMENT_ACCEPT = "image/png,image/jpeg,image/gif,image/webp"

      # The columns an attachment field adds to its table, as [suffix, type,
      # SQL default]: `cover` -> cover_key, cover_filename, cover_content_type,
      # cover_byte_size, cover_checksum. NOT NULL with "" / 0 as the "nothing
      # attached" value, because nullable columns cost Spinel its type
      # inference (NOTES rules 7/11).
      ATTACHMENT_COLUMNS = [
        ["key", "string", "''"],
        ["filename", "string", "''"],
        ["content_type", "string", "''"],
        ["byte_size", "integer", "0"],
        ["checksum", "string", "''"]
      ]

      # Names an attachment field may not have: the generator adds `def
      # <field>` to the owner controller as the download action, so the field
      # must not redefine anything that controller already answers to. A
      # field named `params` would make every action (the download's own
      # `params[:id]` included) recurse; `head` would turn the download's
      # `head 404` into a call to itself. Three groups:
      # - the scaffold's actions;
      # - every instance method and reader of Cybertrain::Controller,
      #   public or private (cybertrain/controller.rb);
      # - the methods the generators write into ApplicationController
      #   (Templates.application_controller and the authentication block).
      # Names ending in ? or ! are left out: a field name cannot have them.
      # script/check-reserved-names fails when Controller or those templates
      # gain a method this list lacks. The per-model helpers (set_<model>,
      # <model>_params) are checked by attachment_action_clash?.
      ATTACHMENT_RESERVED_ACTIONS = %w[
        index show new new_action edit create update destroy
        ctx request response params action_name rescued_exception session flash
        initialize process run_callback default_render view_assigns view_env
        controller_path render_template render redirect_to head send_blob
        run_action run_before_callbacks run_after_callbacks run_one
        rescue_with_handler render_partial send_html string_keys json_body
        safe_redirect_path

        apply_rate_limit
        record_not_found resume_session require_authentication
        start_new_session_for terminate_session after_authentication_url
      ]

      # Whether `field` as the name of the download action `def <field>` on
      # the controller of `singular` would redefine one of its methods: the
      # list above, or the scaffold's private set_<model> / <model>_params.
      def self.attachment_action_clash?(field, singular)
        ATTACHMENT_RESERVED_ACTIONS.include?(field) || field == "set_#{singular}" || field == "#{singular}_params"
      end

      # ["cover_key", "cover_filename", ...] for the attachment field `field`.
      def self.attachment_column_names(field)
        names = Array.new(0) { "" }
        ATTACHMENT_COLUMNS.each { |col| names << "#{field}_#{col[0]}" }
        names
      end

      # The schema DSL lines of those columns, as a create_table block writes
      # them: `t.string "cover_key", null: false, default: "''"`.
      def self.attachment_table_lines(field)
        lines = Array.new(0) { "" }
        ATTACHMENT_COLUMNS.each do |col|
          lines << "t.#{col[1]} \"#{field}_#{col[0]}\", null: false, default: \"#{col[2]}\""
        end
        lines
      end

      # ---- cybertrain generate scaffold --------------------------------

      def self.migration(res)
        buf = +""
        buf << "class Create#{res.plural_class} < Cybertrain::Migration::Base\n"
        buf << "  def change\n"
        buf << "    create_table \"#{res.plural}\" do |t|\n"
        res.fields.each { |f| f.migration_lines.each { |line| buf << "      #{line}\n" } }
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
        # An attachment is not a column and never goes through permit: the
        # create and update actions hand it to `<field>_file=` as an
        # UploadedFile (cli/attachment.rb), so a file can never be mass-assigned.
        permit_list = Array.new(0) { "" }
        res.fields.each { |f| permit_list << ":#{f.column_name}" unless f.attachment? }
        permitted = permit_list.join(", ")
        # A form whose only fields are files sends no `#{s}[...]` key at all
        # when no file is chosen (the parser drops an empty file input), so
        # `require` would make such an edit a 400: `nested` reads the absent
        # key as empty, and the update keeps the stored file.
        lookup = permit_list.empty? && res.attachments? ? "nested" : "require"
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
              params.#{lookup}(:#{s}).permit(#{permitted})
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
        res.fields.each do |f|
          if f.attachment?
            # A link to the file, not an <img>: a list of full-size images is heavy.
            buf << "        <td><% if #{s}.#{f.field_name}_attached? %><a href=\"<%= #{s}.#{f.field_name}_url %>\"><%= #{s}.#{f.field_name}_filename %></a><% end %></td>\n"
          else
            buf << "        <td><%= #{s}.#{f.column_name} %></td>\n"
          end
        end
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
          if f.attachment?
            buf << attachment_show_paragraph(s, f, res.any)
          else
            buf << "<p>\n  <strong>#{f.label}:</strong>\n  <%= @#{s}.#{f.column_name} %>\n</p>\n\n"
          end
        end
        buf << "<p>\n"
        buf << "  <%= link_to \"Edit this #{words}\", edit_#{s}_path(@#{s}) %> |\n"
        buf << "  <%= link_to \"Back to #{res.plural.tr("_", " ")}\", #{res.index_helper}_path %>\n"
        buf << "</p>\n\n"
        buf << "<%= button_to \"Destroy this #{words}\", #{s}_path(@#{s}), method: :delete %>\n"
        buf
      end

      # The show page's paragraph for an attachment field: the image itself
      # for the raster-image default, a download link with --any.
      def self.attachment_show_paragraph(s, f, any)
        name = f.field_name
        buf = +""
        buf << "<p>\n  <strong>#{f.label}:</strong>\n"
        buf << "  <% if @#{s}.#{name}_attached? %>\n"
        if any
          buf << "    <a href=\"<%= @#{s}.#{name}_url %>\"><%= @#{s}.#{name}_filename %></a>\n"
        else
          buf << "    <img src=\"<%= @#{s}.#{name}_url %>\" alt=\"<%= @#{s}.#{name}_filename %>\">\n"
        end
        buf << "  <% end %>\n</p>\n\n"
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
        multipart = res.attachments?
        buf << (multipart ? "<%= form_with(model: #{s}, multipart: true) do |f| %>\n" : "<%= form_with(model: #{s}) do |f| %>\n")
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
          if f.attachment?
            accept = res.any ? "" : ", accept: \"#{ATTACHMENT_ACCEPT}\""
            buf << "    <%= f.file_field :#{f.field_name}#{accept} %>\n"
          else
            buf << "    <%= f.#{f.form_input} :#{f.column_name} %>\n"
          end
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
