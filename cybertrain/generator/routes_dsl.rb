require "cybertrain/generator/inflector"

module Cybertrain
  module Gen
    # One route as config/routes.rb declared it; RoutesEmitter turns the
    # list into gen/routes.rb.
    class RouteSpec
      # Spinel cannot compile a class that defines an instance method named
      # `new` (it breaks `PostsController.new(ctx)`), so the Rails `new`
      # action is written `def new_action` in controllers.
      ACTION_METHODS = { "new" => "new_action" }

      # helper_args: the *_path helper's parameter names, one per dynamic
      # segment in order (`["indicator"]` for `/indicators/:key`); empty
      # when the pattern has none, or for a spec built outside the Mapper,
      # whose names RoutesEmitter derives from the pattern.
      attr_reader :verb, :pattern, :controller, :action, :name, :helper_args
      # Whether the route matches an optional `.:format` suffix (true unless
      # the route says otherwise).
      attr_accessor :takes_format
      # A redirect route's target (`"/posts/%{id}"`, "" for a route to a
      # controller) and status.
      attr_accessor :redirect_location, :redirect_code

      # method_override: the controller method when it is not the action's
      # own name ("" for that), as for the jobs page, whose `retry` action
      # (a Ruby keyword) is `retry_action`. helper_args: the helper's
      # parameter names joined with "," ("" for none): a String, so the
      # default needs no typed empty Array.
      def initialize(verb, pattern, controller, action, name, method_override = "", helper_args = "")
        @verb = verb
        @pattern = pattern
        @controller = controller
        @action = action
        @name = name
        @method_override = method_override
        @helper_args = helper_args.split(",")
        @takes_format = true
        @redirect_location = ""
        @redirect_code = 0
      end

      # The controller method that implements the action.
      def method_name
        return @method_override unless @method_override.empty?

        ACTION_METHODS.fetch(@action, @action)
      end

      def controller_class
        Inflector.camelize(@controller) + "Controller"
      end

      # 'PostsController.new(ctx).process(:edit) { |c| c.edit }'
      def handler_source
        "#{controller_class}.new(ctx).process(:#{@action}) { |c| c.#{method_name} }"
      end

      # The *_path/*_url helper prefix ("" when the route is unnamed).
      def helper_name
        @name
      end
    end

    # What {Mapper#redirect} returns, for `to:`: the target (`"/posts/%{id}"`)
    # and the status. The accessors have distinctive names (NOTES rule 10).
    # @api public
    class RedirectSpec
      # @return [String]
      # @api public
      attr_reader :redirect_target
      # @return [Integer]
      # @api public
      attr_reader :redirect_status

      def initialize(redirect_target, redirect_status)
        @redirect_target = redirect_target
        @redirect_status = redirect_status
      end
    end

    # The jobs page config/routes.rb asked for with {Mapper#jobs_page}: its
    # path ("" when none was drawn) and the before_action method guarding
    # it ("" for none). The accessors have distinctive names (NOTES rule 10).
    class JobsPageSpec
      attr_reader :jobs_path, :jobs_before_action, :jobs_skip_before_action

      # jobs_skip_before_action: the inherited callback jobs_page's
      # `skip_before_action:` names ("" for none).
      def initialize(jobs_path, jobs_before_action, jobs_skip_before_action = "")
        @jobs_path = jobs_path
        @jobs_before_action = jobs_before_action
        @jobs_skip_before_action = jobs_skip_before_action
      end
    end

    # The receiver of the routes DSL. Routes.draw evaluates its block with
    # the mapper as self; blocks nested inside it (namespace, scope,
    # resources, resource, member, collection) take the mapper as their
    # argument instead (`resources :posts do |posts| posts.resources
    # :comments end`), see Routes.draw for why.
    #
    # The methods available in `config/routes.rb`. They run when
    # `spin run gen` generates `gen/routes.rb`, not in the server, so a
    # mistake is an `ArgumentError` from `spin run gen`. Routes match in the
    # order drawn; HEAD matches GET routes; an unmatched request is a plain
    # `404 Not Found`.
    #
    # Each named route gets a `<name>_path` and a `<name>_url` helper (see
    # {::Gen::UrlHelpers}). Not available: `match`, `constraints`, `mount`,
    # `shallow`, `concerns`, globs and optional segments; `namespace` and
    # `scope` are drawn outside `resources` blocks only.
    # @api public
    class Mapper
      STANDARD_ACTIONS = [:index, :create, :new, :edit, :show, :update, :destroy]
      # A singular resource has no index; Rails draws `new` before `show`.
      SINGULAR_ACTIONS = [:create, :new, :edit, :show, :update, :destroy]
      # A route name must work as the prefix of `def <name>_path`.
      NAME_PATTERN = /\A[a-z_][a-z0-9_]*\z/
      # An action becomes a literal method call in the generated handler.
      ACTION_PATTERN = /\A[a-z_][a-z0-9_]*\z/
      # "posts", "admin/users" (camelized to Admin::UsersController).
      CONTROLLER_PATTERN = /\A[a-z_][a-z0-9_]*(?:\/[a-z_][a-z0-9_]*)*\z/
      # One segment of a jobs_page path.
      JOBS_SEGMENT_PATTERN = /\A[A-Za-z0-9_\-]+\z/
      # resources' param: names a path segment and a params key.
      PARAM_PATTERN = /\A[a-z_][a-z0-9_]*\z/

      def initialize(specs)
        @specs = specs
        # "top" (also inside namespace / scope), "resources", "resource",
        # "member" or "collection"
        @mode = "top"
        @path_prefix = ""        # "/posts/:post_id" inside `resources :posts do`, "/admin" in a namespace
        @name_prefix = ""        # "post_", "admin_"
        @module_prefix = ""      # "admin/" inside `namespace :admin`, prefixed to every controller
        @controller = ""         # "posts", "admin/posts"
        @member_path = ""        # "/posts/:id"
        @member_name = ""        # "post"
        @collection_path = ""    # "/posts" ("" inside a singular resource)
        @collection_name = ""    # "posts"
        # The helper parameter names of the dynamic segments of
        # @path_prefix, @member_path and @collection_path, joined with ","
        # (Strings, like the rest of the saved scope).
        @prefix_args = ""        # "post"
        @member_args = ""        # "post" for /posts/:id
        @collection_args = ""    # ""
      end

      # root "posts#index" -> GET / named "root". Inside a namespace or a
      # scope it takes the prefixes (`namespace :admin do |admin|
      # admin.root "dashboard#index" end`: GET /admin, `admin_root_path`,
      # Admin::DashboardController).
      # @param to [String] `"controller#action"`
      # @param format [Boolean] false: match no `.:format` extension
      # @return [nil]
      # @api public
      def root(to, format: true)
        target = split_to(to)
        path = @path_prefix.empty? ? "/" : @path_prefix
        add_spec("GET", path, @module_prefix + target[0], target[1], "#{@name_prefix}root", @prefix_args, format)
      end

      # A GET route. At the top level `to:` is required; inside a
      # `resources` or `resource` block (or a `member` / `collection`) the
      # controller is the resource's and the action defaults to the path.
      #
      # The name is `as:`, or the path with every character outside
      # `[a-z0-9_]` turned into `_` (`"about-us"` → `about_us`). Inside a
      # `member` block (or with `on: :member`) it gets the resource's
      # singular as a suffix (`preview_post`), inside `collection` (or with
      # `on: :collection`) the plural (`search_posts`), inside `resources`
      # its prefix (`post_...`); a namespace or `scope as:` prefixes it too
      # (`admin_stats`). A derived name that an earlier route already took
      # leaves the route unnamed, as in Rails (`get "/sign_up"` then `post
      # "/sign_up"`: one `sign_up_path`); a duplicate `as:` is an error.
      #
      # Inside a namespace or `scope module:` the controller of `to:` gets
      # the module (`to: "stats#index"` → `admin/stats`).
      # @example
      #   get "/about", to: "pages#about"               # GET /about, about_path
      #   get "/feed", to: "articles#index", as: "feed"   # feed_path
      #   resources :posts do |posts|
      #     posts.get :search, on: :collection          # GET /posts/search, search_posts_path
      #     posts.post :publish, on: :member            # POST /posts/:id/publish, publish_post_path
      #   end
      #   get "/old", to: redirect("/new")                # 301 to /new
      # @param path [String, Symbol] `:name` segments become params (`"/users/:id"`)
      # @param to [String, RedirectSpec] `"controller#action"`, just
      #   `"action"`, or a {#redirect}
      # @param as [String] the route name
      # @param on [Symbol, nil] `:member` (inside `resources` or `resource`)
      #   or `:collection` (inside `resources`): as in a `member` /
      #   `collection` block
      # @param format [Boolean] false: the route matches no `.:format`
      #   extension, so a dot in the last segment is part of it
      #   (`get "/files/:name", to: "files#show", format: false` gives
      #   `params[:name] == "report.v2"`)
      # @return [nil]
      # @raise [ArgumentError] with no controller, an invalid or duplicate
      #   name, an `on:` that does not fit where the route is drawn, or a
      #   redirect whose `%{name}` is not a segment of the path
      # @api public
      def get(path, to: "", as: "", on: nil, format: true)
        add_custom_route("GET", path, to, as, on, format)
      end

      # A POST route; see {#get}.
      # @param path [String, Symbol]
      # @param to [String, RedirectSpec]
      # @param as [String]
      # @param on [Symbol, nil]
      # @param format [Boolean]
      # @return [nil]
      # @api public
      def post(path, to: "", as: "", on: nil, format: true)
        add_custom_route("POST", path, to, as, on, format)
      end

      # A PATCH route; see {#get}.
      # @param path [String, Symbol]
      # @param to [String, RedirectSpec]
      # @param as [String]
      # @param on [Symbol, nil]
      # @param format [Boolean]
      # @return [nil]
      # @api public
      def patch(path, to: "", as: "", on: nil, format: true)
        add_custom_route("PATCH", path, to, as, on, format)
      end

      # A PUT route; see {#get}.
      # @param path [String, Symbol]
      # @param to [String, RedirectSpec]
      # @param as [String]
      # @param on [Symbol, nil]
      # @param format [Boolean]
      # @return [nil]
      # @api public
      def put(path, to: "", as: "", on: nil, format: true)
        add_custom_route("PUT", path, to, as, on, format)
      end

      # A DELETE route; see {#get}.
      # @param path [String, Symbol]
      # @param to [String, RedirectSpec]
      # @param as [String]
      # @param on [Symbol, nil]
      # @param format [Boolean]
      # @return [nil]
      # @api public
      def delete(path, to: "", as: "", on: nil, format: true)
        add_custom_route("DELETE", path, to, as, on, format)
      end

      # A redirect, for `to:`: the route answers `status` with `Location:
      # path`, each `%{name}` in `path` replaced by the route's `:name`
      # segment, escaped, and an empty body. A redirect route is unnamed
      # unless given `as:`. The block form that computes the target is not
      # available (a controller action does that).
      # @example
      #   get "/old", to: redirect("/new")                                   # 301
      #   get "/posts/:id/show", to: redirect("/posts/%{id}", status: 302)
      # @param path [String] the target, a path or URL
      # @param status [Integer] 300 to 308
      # @return [RedirectSpec]
      # @raise [ArgumentError] for a status outside 300-308 (the route
      #   raises for a `%{name}` its path lacks)
      # @api public
      def redirect(path, status: 301)
        code = status.to_i
        unless code >= 300 && code <= 308
          message = "redirect status: must be a 3xx code (got #{code})"
          raise ArgumentError, message
        end
        RedirectSpec.new("#{path}", code)
      end

      # Routes whose paths, helper names and controllers sit under `name`:
      # `scope "/admin", module: "admin", as: "admin"`, as in Rails.
      # Namespaces nest.
      #
      # `namespace :admin do |admin| admin.resources :articles end` draws
      # `/admin/articles` to `Admin::ArticlesController`
      # (`app/controllers/admin/articles_controller.rb`, written `module
      # Admin; class ArticlesController` or `class Admin::ArticlesController`),
      # with `admin_articles_path` and `admin_article_path(article)`; its
      # views are in `app/views/admin/articles/`.
      # @example
      #   namespace :admin do |admin|
      #     admin.resources :articles, only: [:index, :destroy]
      #     admin.jobs_page "/jobs", before_action: :require_admin   # /admin/jobs
      #   end
      # @param name [Symbol] the namespace (`:admin`)
      # @yieldparam mapper [Mapper] the mapper, to call with an explicit
      #   receiver inside the block (`admin.resources`)
      # @return [nil]
      # @raise [ArgumentError] inside `resources` or `resource`
      # @api public
      def namespace(name, &block)
        raise ArgumentError, "namespace must be used outside resources" unless @mode == "top"

        word = "#{name}"
        within_scope(word, word, word, block)
      end

      # Routes under a path prefix, a controller module and a helper-name
      # prefix, each optional, as in Rails: `scope "dashboard"` changes the
      # paths only (`/dashboard/stats`), `scope module: "admin"` the
      # controllers only (`admin/users`, Admin::UsersController), `scope as:
      # "admin"` the helper names only (`admin_stats_path`). They combine
      # (`scope "/x", module: "y", as: "z"`). A `:name` segment in the path
      # becomes a param and a helper argument (`scope "/:locale"`).
      # @example
      #   scope "/v1", as: "v1" do |v|
      #     v.get "/about", to: "pages#about"   # GET /v1/about, v1_about_path
      #   end
      # @param path [String] the path prefix (`"dashboard"` or `"/dashboard"`)
      # @param module [String] the controller module (`"admin"`)
      # @param as [String] the helper-name prefix (`"admin"`)
      # @yieldparam mapper [Mapper]
      # @return [nil]
      # @raise [ArgumentError] inside `resources` or `resource`
      # @api public
      def scope(path = "", module: "", as: "", &block)
        raise ArgumentError, "scope must be used outside resources" unless @mode == "top"

        mod = "#{binding.local_variable_get(:module)}"
        within_scope("#{path}", mod, "#{as}", block)
      end

      # The jobs page ({Cybertrain::JobsPage}): failed, discarded, running
      # and queued jobs, with retry / discard / delete buttons, served by a
      # generated `CybertrainJobsController < ApplicationController`, so the
      # application's layout, CSRF protection and `before_action:` apply.
      # Draws, to that controller:
      #
      # | Verb | Path | Action |
      # | --- | --- | --- |
      # | GET | `path` | `index` (`?page=N`) |
      # | POST | `path/retry_all` | `retry_all` (every failed job) |
      # | POST | `path/discard_all` | `discard_all_failed` |
      # | POST | `path/:id/retry` | `retry` |
      # | POST | `path/:id/discard` | `discard` |
      # | POST | `path/:id/delete` | `delete` |
      #
      # The routes are unnamed (no `*_path` helpers). One jobs page per
      # application, drawn at the top level or inside a namespace or a
      # scope, whose path prefix it takes (`admin.jobs_page "/jobs"` is
      # `/admin/jobs`; the controller stays CybertrainJobsController).
      # Without `before_action:` the page is open to anyone who can reach
      # it, and `spin run gen` prints a warning saying so. The guard runs
      # after the callbacks ApplicationController declares (Rails' order),
      # so with `generate authentication` a visitor is sent to sign in
      # first; `skip_before_action: :require_authentication` leaves that
      # one out, so the guard alone decides (require_admin answers a
      # visitor 404, as if there were no page). Only the callback named is
      # skipped, and only when this option says so.
      # @example
      #   jobs_page "/admin/jobs", before_action: :require_admin
      #   jobs_page "/admin/jobs", before_action: :require_admin, skip_before_action: :require_authentication
      # @param path [String] literal segments (`"/admin/jobs"`)
      # @param before_action [Symbol, String] a method of ApplicationController
      #   that renders or redirects to refuse the visitor (`:require_admin`)
      # @param skip_before_action [Symbol, String] an inherited before
      #   callback the page does not run (`:require_authentication`); needs
      #   a `before_action:` other than itself
      # @return [nil]
      # @raise [ArgumentError] for a second jobs page, one inside
      #   `resources`, a path with dynamic or empty segments, a
      #   before_action or skip_before_action that is not a method name, a
      #   skip_before_action without a before_action or naming the same
      #   method (either would open the page to everyone)
      # @api public
      def jobs_page(path, before_action: "", skip_before_action: "")
        raise ArgumentError, "jobs_page must be used at the top of the routes, not inside resources" unless @mode == "top"

        guard = "#{before_action}"
        full = "#{@path_prefix}#{path}"
        [path, full].each do |candidate|
          next if jobs_page_path?(candidate)

          message = "jobs_page #{candidate.inspect}: the path must start with \"/\" and be literal segments of letters, digits, _ and -"
          raise ArgumentError, message
        end
        unless guard.empty? || guard.match?(ACTION_PATTERN)
          message = "jobs_page #{path.inspect}: before_action: #{guard.inspect} is not a method name"
          raise ArgumentError, message
        end
        skip = "#{skip_before_action}"
        unless skip.empty?
          at = jobs_page_location(path)
          unless skip.match?(ACTION_PATTERN)
            message = "#{at}jobs_page #{path.inspect}: skip_before_action: #{skip.inspect} is not a method name"
            raise ArgumentError, message
          end
          if guard.empty?
            message = "#{at}jobs_page #{path.inspect}: skip_before_action: :#{skip} needs a before_action: that decides " \
                      "who sees the page; without one it would open the page to everyone"
            raise ArgumentError, message
          end
          if guard == skip
            message = "#{at}jobs_page #{path.inspect}: skip_before_action: :#{skip} is the page's own before_action:; " \
                      "skipping it would open the page to everyone"
            raise ArgumentError, message
          end
        end
        Cybertrain::Routes.record_jobs_page(full, guard, skip)
        controller = "cybertrain_jobs"
        add_jobs_route("GET", full, controller, "index", "index")
        add_jobs_route("POST", "#{full}/retry_all", controller, "retry_all", "retry_all_action")
        add_jobs_route("POST", "#{full}/discard_all", controller, "discard_all_failed", "discard_all_failed_action")
        add_jobs_route("POST", "#{full}/:id/retry", controller, "retry", "retry_action")
        add_jobs_route("POST", "#{full}/:id/discard", controller, "discard", "discard_action")
        add_jobs_route("POST", "#{full}/:id/delete", controller, "delete", "delete_action")
        nil
      end

      # The seven standard actions (only:/except: pick some). Routes drawn
      # in the block (nested resources, member, collection) come first, so
      # /posts/search wins over /posts/:id as in Rails.
      #
      # `resources :articles` draws, to `ArticlesController`:
      #
      # | Verb | Path | Action | Helper |
      # | --- | --- | --- | --- |
      # | GET | `/articles` | `index` | `articles_path` |
      # | POST | `/articles` | `create` | |
      # | GET | `/articles/new` | `new` (`def new_action`) | `new_article_path` |
      # | GET | `/articles/:id/edit` | `edit` | `edit_article_path(article)` |
      # | GET | `/articles/:id` | `show` | `article_path(article)` |
      # | PATCH, PUT | `/articles/:id` | `update` | |
      # | DELETE | `/articles/:id` | `destroy` | |
      #
      # A word that is its own plural (`sheep`) names the collection
      # `sheep_index`. Nested resources take the parent's id as
      # `:<singular>_id` and its singular as a name prefix:
      # `article_comments_path(article)`, `article_comment_path(article,
      # comment)`. Their controller is the child's (`CommentsController`).
      # `controller:` names another controller; `param:` another segment
      # than `:id` (`resources :indicators, param: :key`: `/indicators/:key`,
      # `params[:key]`, nested resources under `:indicator_key`); the
      # helpers still take the record (`indicator_path(indicator)`, which
      # reads `indicator.to_param`).
      # @example
      #   resources :articles do |articles|
      #     articles.resources :comments, only: [:create, :destroy]
      #     articles.member { |m| m.get "preview" }        # GET /articles/:id/preview, preview_article_path
      #     articles.collection { |c| c.get "search" }     # GET /articles/search, search_articles_path
      #   end
      # @param name [Symbol] the plural (`:articles`)
      # @param only [Array<Symbol>, nil] draw only these actions
      # @param except [Array<Symbol>, nil] draw all but these
      # @param controller [String] the controller (`"metrics"`), under the
      #   enclosing namespace's module; default the plural
      # @param param [Symbol] the member segment's name (`:key`)
      # @param format [Boolean] false: the seven routes match no
      #   `.:format` extension (the block's routes keep their own)
      # @yieldparam mapper [Mapper] the mapper, to call with an explicit
      #   receiver inside the block (`articles.resources`): Spinel gives a
      #   nested block no implicit self
      # @return [nil]
      # @raise [ArgumentError] for a `param:` that is not a lowercase name
      # @api public
      def resources(name, only: nil, except: nil, controller: "", param: :id, format: true, &block)
        # Interpolated, not name.to_s: in a program that also loads the model
        # runtime, name.to_s came out boxed and widened @controller, which
        # broke the C build of save_scope/restore_scope.
        plural = "#{name}"
        singular = Inflector.singularize(plural)
        key = "#{param}"
        unless key.match?(PARAM_PATTERN)
          message = "param: must be a lowercase name (got #{key.inspect})"
          raise ArgumentError, message
        end
        given = "#{controller}"
        target = @module_prefix + (given.empty? ? plural : given)
        collection_path = "#{@path_prefix}/#{plural}"
        member_path = "#{collection_path}/:#{key}"
        member_name = @name_prefix + singular
        member_args = join_args(@prefix_args, singular)
        collection_args = @prefix_args
        # A word whose singular is itself (sheep, news) would give index and
        # show the same name; Rails names the collection news_index.
        collection_name = @name_prefix + plural + (singular == plural ? "_index" : "")

        unless block.nil?
          saved = save_scope
          @mode = "resources"
          @path_prefix = "#{collection_path}/:#{singular}_#{key}"
          @prefix_args = member_args
          @name_prefix = member_name + "_"
          @controller = target
          @member_path = member_path
          @member_name = member_name
          @member_args = member_args
          @collection_path = collection_path
          @collection_name = collection_name
          @collection_args = collection_args
          block.call(self)
          restore_scope(saved)
        end

        used = []
        STANDARD_ACTIONS.each do |action|
          next unless only.nil? || only.include?(action)
          next if !except.nil? && except.include?(action)

          case action
          when :index then add_standard(used, "GET", collection_path, target, "index", collection_name, collection_args, format)
          when :create then add_standard(used, "POST", collection_path, target, "create", collection_name, collection_args, format)
          when :new then add_standard(used, "GET", "#{collection_path}/new", target, "new", "new_#{member_name}", collection_args, format)
          when :edit then add_standard(used, "GET", "#{member_path}/edit", target, "edit", "edit_#{member_name}", member_args, format)
          when :show then add_standard(used, "GET", member_path, target, "show", member_name, member_args, format)
          when :update
            add_standard(used, "PATCH", member_path, target, "update", member_name, member_args, format)
            add_standard(used, "PUT", member_path, target, "update", member_name, member_args, format)
          when :destroy then add_standard(used, "DELETE", member_path, target, "destroy", member_name, member_args, format)
          end
        end
        nil
      end

      # A singular resource, one the visitor has at most one of (their
      # session, their profile): the six actions without `index`, at a path
      # without an id, handled by the plural controller as in Rails.
      #
      # `resource :session` draws, to `SessionsController`:
      #
      # | Verb | Path | Action | Helper |
      # | --- | --- | --- | --- |
      # | GET | `/session/new` | `new` (`def new_action`) | `new_session_path` |
      # | POST | `/session` | `create` | `session_path` |
      # | GET | `/session/edit` | `edit` | `edit_session_path` |
      # | GET | `/session` | `show` | |
      # | PATCH, PUT | `/session` | `update` | |
      # | DELETE | `/session` | `destroy` | |
      #
      # The order is Rails' (`new` before `show`, so `/session/new` is not
      # read as a member). `controller:` names another controller. A block
      # draws member routes (`get :refresh, on: :member` or a `member`
      # block: `/session/refresh`, `refresh_session_path`) and nested
      # singular or plural resources (`/session/settings/edit`,
      # `edit_session_settings_path`), before the resource's own.
      # @example
      #   resource :session, controller: "auth/sessions" do |session|
      #     session.get :refresh, on: :member
      #     session.resource :settings, only: [:edit, :update]
      #   end
      # @param name [Symbol] the singular (`:session`)
      # @param only [Array<Symbol>, nil] draw only these actions
      # @param except [Array<Symbol>, nil] draw all but these
      # @param controller [String] the controller (`"auth/sessions"`), under
      #   the enclosing namespace's module; default the plural
      # @param format [Boolean] false: the resource's routes match no
      #   `.:format` extension (the block's routes keep their own)
      # @yieldparam mapper [Mapper]
      # @return [nil]
      # @api public
      def resource(name, only: nil, except: nil, controller: "", format: true, &block)
        singular = "#{name}"
        given = "#{controller}"
        target = @module_prefix + (given.empty? ? Inflector.pluralize(singular) : given)
        path = "#{@path_prefix}/#{singular}"
        route_name = @name_prefix + singular
        args = @prefix_args

        unless block.nil?
          saved = save_scope
          @mode = "resource"
          @path_prefix = path
          @name_prefix = route_name + "_"
          @controller = target
          @member_path = path
          @member_name = route_name
          @member_args = args
          @collection_path = ""
          @collection_name = ""
          @collection_args = ""
          block.call(self)
          restore_scope(saved)
        end

        used = []
        SINGULAR_ACTIONS.each do |action|
          next unless only.nil? || only.include?(action)
          next if !except.nil? && except.include?(action)

          case action
          when :create then add_standard(used, "POST", path, target, "create", route_name, args, format)
          when :new then add_standard(used, "GET", "#{path}/new", target, "new", "new_#{route_name}", args, format)
          when :edit then add_standard(used, "GET", "#{path}/edit", target, "edit", "edit_#{route_name}", args, format)
          when :show then add_standard(used, "GET", path, target, "show", route_name, args, format)
          when :update
            add_standard(used, "PATCH", path, target, "update", route_name, args, format)
            add_standard(used, "PUT", path, target, "update", route_name, args, format)
          when :destroy then add_standard(used, "DELETE", path, target, "destroy", route_name, args, format)
          end
        end
        nil
      end

      # Inside resources or resource: get "preview" -> GET /posts/:id/preview
      # as preview_post.
      # @yieldparam mapper [Mapper]
      # @return [nil]
      # @raise [ArgumentError] outside a `resources` or `resource` block
      # @api public
      def member(&block)
        within("member", block)
      end

      # Inside resources: get "search" -> GET /posts/search as search_posts.
      # @yieldparam mapper [Mapper]
      # @return [nil]
      # @raise [ArgumentError] outside a `resources` block
      # @api public
      def collection(&block)
        within("collection", block)
      end

      private

      def within(mode, block)
        raise ArgumentError, "#{mode} must be used inside resources" if @mode == "top" || (mode == "collection" && @collection_path.empty?)

        saved = save_scope
        @mode = mode
        block.call(self)
        restore_scope(saved)
        nil
      end

      # namespace and scope: the prefixes for the routes the block draws.
      def within_scope(path, mod, as, block)
        check_param_names(path)
        saved = save_scope
        trimmed = trim_slashes(path)
        unless trimmed.empty?
          @prefix_args = join_args(@prefix_args, path_args(trimmed, last_literal(@path_prefix)))
          @path_prefix = "#{@path_prefix}/#{trimmed}"
        end
        module_name = trim_slashes(mod)
        @module_prefix = "#{@module_prefix}#{module_name}/" unless module_name.empty?
        @name_prefix = "#{@name_prefix}#{as}_" unless as.empty?
        block.call(self) unless block.nil?
        restore_scope(saved)
        nil
      end

      # The mode a custom route is drawn in: the block's, or the one its
      # `on:` names.
      def route_mode(on)
        where = "#{on}"
        return @mode if where.empty?

        if where == "member"
          raise ArgumentError, "on: :member must be used inside resources or resource" if @mode == "top"

          return "member"
        end
        if where == "collection"
          raise ArgumentError, "on: :collection must be used inside resources" if @mode == "top" || @collection_path.empty?

          return "collection"
        end
        message = "on: must be :member or :collection (got :#{where})"
        raise ArgumentError, message
      end

      # One custom route; its path, controller and name depend on the scope.
      # Not named `match`: Router#match(verb, path_segments) exists, and a
      # shared name made Spinel type `path` here as an Array of segments
      # once the DSL calls came only through instance_eval (NOTES rule 10).
      def add_custom_route(verb, path, to, as, on, format)
        text = "#{path}"
        check_param_names(text)
        segment = text.start_with?("/") ? text[1, text.size - 1] : text
        case to
        when RedirectSpec
          add_redirect_route(verb, segment, to, "#{as}", on, format)
          return nil
        end
        given = "#{to}"
        target = given == "" ? ["", segment] : split_to(given)
        controller = target[0] == "" ? @controller : @module_prefix + target[0]
        action = target[1]
        word = as == "" ? derive_name(segment) : as

        case route_mode(on)
        when "member"
          args = join_args(@member_args, path_args(segment, last_literal(@member_path)))
          add_spec(verb, "#{@member_path}/#{segment}", controller, action, custom_name("#{word}_#{@member_name}", as), args, format)
        when "collection"
          args = join_args(@collection_args, path_args(segment, last_literal(@collection_path)))
          add_spec(verb, "#{@collection_path}/#{segment}", controller, action, custom_name("#{word}_#{@collection_name}", as), args, format)
        else
          pattern = "#{@path_prefix}/#{segment}"
          raise ArgumentError, "#{verb} #{pattern} needs to: \"controller#action\"" if controller == ""

          args = join_args(@prefix_args, path_args(segment, last_literal(@path_prefix)))
          add_spec(verb, pattern, controller, action, custom_name(@name_prefix + word, as), args, format)
        end
      end

      # A custom route whose `to:` is a {#redirect}: its path is drawn as a
      # custom route's, it is unnamed unless `as:` names it (Rails would
      # derive one), and every `%{name}` of the target must be a segment of
      # the path.
      def add_redirect_route(verb, segment, redirect, as, on, format)
        mode = route_mode(on)
        if mode == "member"
          pattern = "#{@member_path}/#{segment}"
          args = join_args(@member_args, path_args(segment, last_literal(@member_path)))
          name = as == "" ? "" : "#{as}_#{@member_name}"
        elsif mode == "collection"
          pattern = "#{@collection_path}/#{segment}"
          args = join_args(@collection_args, path_args(segment, last_literal(@collection_path)))
          name = as == "" ? "" : "#{as}_#{@collection_name}"
        else
          pattern = "#{@path_prefix}/#{segment}"
          args = join_args(@prefix_args, path_args(segment, last_literal(@path_prefix)))
          name = as == "" ? "" : @name_prefix + as
        end
        location = redirect.redirect_target
        missing = missing_redirect_key(location, pattern)
        unless missing.empty?
          message = "redirect(#{location.inspect}): %{#{missing}} is not a segment of #{pattern}"
          raise ArgumentError, message
        end
        check_name(verb, pattern, name)
        spec = RouteSpec.new(verb, pattern, "", "", name, "", distinct_args(args))
        spec.takes_format = format
        spec.redirect_location = location
        spec.redirect_code = redirect.redirect_status
        @specs << spec
        nil
      end

      # The first `%{name}` of a redirect target that is not a `:name`
      # segment of pattern, "" when all are.
      def missing_redirect_key(location, pattern)
        keys = []
        pattern.split("/").each { |seg| keys << seg[1, seg.size - 1] if seg.start_with?(":") }
        i = 0
        while i < location.size
          open = location.index("%{", i)
          break if open.nil?

          close = location.index("}", open + 2)
          break if close.nil?

          key = location[open + 2, close - open - 2].to_s
          return key unless keys.include?(key)

          i = close + 1
        end
        ""
      end

      # The name a custom route gets: `name` as derived, unless no `as:` was
      # given and an earlier route already owns it, in which case the route
      # is unnamed (so `get` and `post` on one path share one helper). An
      # explicit `as:` always goes through, and add_spec rejects a duplicate.
      def custom_name(name, as)
        return name unless as == ""

        @specs.each { |spec| return "" if spec.name == name }
        name
      end

      # A standard resource route; its name goes to the first route that
      # claims it (POST /posts is unnamed next to GET /posts).
      def add_standard(used, verb, pattern, controller, action, name, args, format)
        if used.include?(name)
          add_spec(verb, pattern, controller, action, "", args, format)
        else
          used << name
          add_spec(verb, pattern, controller, action, name, args, format)
        end
      end

      def add_spec(verb, pattern, controller, action, name, args, format)
        unless controller.match?(CONTROLLER_PATTERN)
          raise ArgumentError, "controller '#{controller}' is not a valid controller path (#{verb} #{pattern})"
        end
        unless action.match?(ACTION_PATTERN)
          raise ArgumentError, "action '#{action}' is not a valid method name (#{verb} #{pattern})"
        end
        check_name(verb, pattern, name)
        spec = RouteSpec.new(verb, pattern, controller, action, name, "", distinct_args(args))
        spec.takes_format = format
        @specs << spec
        nil
      end

      # A route name must be a method-name prefix no earlier route has.
      def check_name(verb, pattern, name)
        return nil if name == ""

        unless name.match?(NAME_PATTERN)
          raise ArgumentError, "route name '#{name}' is not a valid method name prefix (#{verb} #{pattern}); " \
                               "pass as: with lowercase letters, digits and _"
        end
        @specs.each do |spec|
          raise ArgumentError, "route name '#{name}' is already in use (#{verb} #{pattern})" if spec.name == name
        end
        nil
      end

      # "a,b" and "c" -> "a,b,c"; either may be "".
      def join_args(first, second)
        return second if first.empty?
        return first if second.empty?

        "#{first},#{second}"
      end

      # The helper names of the dynamic segments of a path drawn as written
      # (a custom route's, a scope's): ":post_id" -> "post", ":id" after
      # "comments" -> "comment" (`previous`, the literal segment before the
      # path, counts for a leading ":id"), ":slug" -> "slug". Joined with ",".
      def path_args(path, previous)
        names = []
        last = previous
        path.split("/").each do |seg|
          next if seg.empty?

          if seg.start_with?(":")
            key = seg[1, seg.size - 1]
            names << if key.end_with?("_id") && key.size > 3
                       key[0, key.size - 3]
                     elsif key == "id" && last != ""
                       Inflector.singularize(last)
                     else
                       key
                     end
          else
            last = seg
          end
        end
        names.join(",")
      end

      # Each `:name` segment of a path as written must name a param
      # (PARAM_PATTERN, as for `resources param:`): an empty or capitalised
      # one would give an empty helper argument or a helper that does not
      # parse in gen/routes.rb.
      def check_param_names(path)
        path.split("/").each do |seg|
          next unless seg.start_with?(":")
          next if seg[1, seg.size - 1].to_s.match?(PARAM_PATTERN)

          message = "route path #{path.inspect}: #{seg.inspect} is not a valid param name (lowercase letters, digits and _)"
          raise ArgumentError, message
        end
        nil
      end

      # A repeated helper name gets its position as a suffix
      # ("post,post" -> "post,post2"), so the helper's parameters differ.
      def distinct_args(args)
        names = []
        args.split(",").each do |name|
          names << (names.include?(name) ? "#{name}#{names.size + 1}" : name)
        end
        names.join(",")
      end

      # "config/routes.rb:N: " for the first uncommented jobs_page line of
      # path in config/routes.rb (gen runs in the app's directory), or ""
      # when there is no such file or line: the DSL has no call locations.
      def jobs_page_location(path)
        file = "config/routes.rb"
        return "" unless File.file?(file)

        quoted = path.inspect
        n = 0
        File.read(file).each_line do |line|
          n += 1
          code = line.strip
          next unless code.start_with?("jobs_page ") || code.include?(".jobs_page ")

          return "#{file}:#{n}: " if code.include?(quoted)
        end
        ""
      end

      # The last literal segment of a path ("" for none).
      def last_literal(path)
        last = ""
        path.split("/").each do |seg|
          last = seg unless seg.empty? || seg.start_with?(":")
        end
        last
      end

      # "/dashboard/" -> "dashboard".
      def trim_slashes(path)
        out = path
        out = out[1, out.size - 1] while out.start_with?("/")
        out = out[0, out.size - 1] while out.end_with?("/")
        out
      end

      # "/admin/jobs": "/" then segments of [A-Za-z0-9_-], no empty one.
      def jobs_page_path?(path)
        return false unless path.start_with?("/") && path.size > 1 && !path.end_with?("/")

        segments = path[1, path.size - 1].split("/")
        segments.each do |seg|
          return false if seg.empty?
          return false unless seg.match?(JOBS_SEGMENT_PATTERN)
        end
        true
      end

      # One unnamed jobs-page route whose action and controller method differ.
      def add_jobs_route(verb, pattern, controller, action, method)
        @specs << RouteSpec.new(verb, pattern, controller, action, "", method)
        nil
      end

      # The route name a path implies: ":" dropped, lowercased, and "/", "-"
      # (as in Rails) and every other character outside [a-z0-9_] turned
      # into "_" ("about-us" -> "about_us", "users/:id/avatar" ->
      # "users_id_avatar", "robots.txt" -> "robots_txt"; Rails would leave
      # the last one unnamed). A result that still is not a valid name (a
      # leading digit) is rejected by add_spec, which asks for as:.
      def derive_name(segment)
        out = +""
        segment.downcase.each_char do |ch|
          next if ch == ":"

          if (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9") || ch == "_"
            out << ch
          else
            out << "_"
          end
        end
        out
      end

      # "pages#about" -> ["pages", "about"]; "about" -> ["", "about"].
      def split_to(to)
        parts = to.split("#", 2)
        return ["", to] if parts.size < 2

        [parts[0], parts[1]]
      end

      def save_scope
        [@mode, @path_prefix, @name_prefix, @controller, @member_path, @member_name,
         @collection_path, @collection_name, @module_prefix, @prefix_args, @member_args,
         @collection_args]
      end

      def restore_scope(saved)
        @mode = saved[0]
        @path_prefix = saved[1]
        @name_prefix = saved[2]
        @controller = saved[3]
        @member_path = saved[4]
        @member_name = saved[5]
        @collection_path = saved[6]
        @collection_name = saved[7]
        @module_prefix = saved[8]
        @prefix_args = saved[9]
        @member_args = saved[10]
        @collection_args = saved[11]
      end
    end
  end

  # The entry point config/routes.rb calls:
  #
  #   Cybertrain::Routes.draw do
  #     root "posts#index"
  #     resources :posts do |posts|
  #       posts.resources :comments, only: [:create, :destroy]
  #       posts.member { |m| m.get "preview" }
  #     end
  #     get "/about", to: "pages#about"
  #   end
  #
  # Spinel compiles `instance_eval(&block)` by splicing the block body into
  # the caller with self rebound to the mapper, so receiverless calls work
  # at the top level of the draw block. A block nested inside it is still
  # compiled as a closure of its own, where that rebound self does not
  # exist: a receiverless `resources` inside `resources :posts do ... end`
  # runs under CRuby but fails the C build under Spinel ("use of undeclared
  # identifier 'self'"). Nested blocks therefore take the mapper as their
  # argument. `draw do |r| r.root ... end` also works (instance_eval passes
  # the receiver as the block argument).
  # @api public
  module Routes
    @specs = Array.new(0) { Gen::RouteSpec.new("", "", "", "", "") }
    # The page {Gen::Mapper#jobs_page} drew; a path of "" for none.
    @jobs_page = Gen::JobsPageSpec.new("", "")

    # Declares the application's routes; the block's methods are those of
    # {Gen::Mapper}. `spin run gen` runs `config/routes.rb` and writes
    # `gen/routes.rb` (re-run it after editing the routes; the development
    # server does).
    # @yieldparam mapper [Gen::Mapper] also the block's self, at its top
    #   level only
    # @return [nil]
    # @api public
    def self.draw(&block)
      Gen::Mapper.new(@specs).instance_eval(&block)
      nil
    end

    def self.specs
      @specs
    end

    # The jobs page drawn (`jobs_path` "" when none).
    # @return [Gen::JobsPageSpec]
    def self.jobs_page_spec
      @jobs_page
    end

    # Called by {Gen::Mapper#jobs_page}: one jobs page per application.
    def self.record_jobs_page(path, before_action, skip_before_action = "")
      first = @jobs_page.jobs_path
      unless first.empty?
        message = "jobs_page #{path.inspect}: the jobs page is already drawn at #{first.inspect} (one per application)"
        raise ArgumentError, message
      end
      @jobs_page = Gen::JobsPageSpec.new(path, before_action, skip_before_action)
      nil
    end

    def self.reset!
      @specs.clear
      @jobs_page = Gen::JobsPageSpec.new("", "")
      nil
    end
  end
end
