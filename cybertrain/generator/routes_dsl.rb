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

      attr_reader :verb, :pattern, :controller, :action, :name

      # method_override: the controller method when it is not the action's
      # own name ("" for that), as for the jobs page, whose `retry` action
      # (a Ruby keyword) is `retry_action`.
      def initialize(verb, pattern, controller, action, name, method_override = "")
        @verb = verb
        @pattern = pattern
        @controller = controller
        @action = action
        @name = name
        @method_override = method_override
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

    # The jobs page config/routes.rb asked for with {Mapper#jobs_page}: its
    # path ("" when none was drawn) and the before_action method guarding
    # it ("" for none). The accessors have distinctive names (NOTES rule 10).
    class JobsPageSpec
      attr_reader :jobs_path, :jobs_before_action

      def initialize(jobs_path, jobs_before_action)
        @jobs_path = jobs_path
        @jobs_before_action = jobs_before_action
      end
    end

    # The receiver of the routes DSL. Routes.draw evaluates its block with
    # the mapper as self; blocks nested inside it (resources, member,
    # collection) take the mapper as their argument instead
    # (`resources :posts do |posts| posts.resources :comments end`), see
    # Routes.draw for why.
    #
    # The methods available in `config/routes.rb`. They run when
    # `spin run gen` generates `gen/routes.rb`, not in the server, so a
    # mistake is an `ArgumentError` from `spin run gen`. Routes match in the
    # order drawn; HEAD matches GET routes; an unmatched request is a plain
    # `404 Not Found`.
    #
    # Each named route gets a `<name>_path` and a `<name>_url` helper (see
    # {::Gen::UrlHelpers}). Not available: `match`, `namespace`, `scope`,
    # `constraints`, `mount`, formats, globs, optional segments and
    # nesting under a singular `resource`.
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

      def initialize(specs)
        @specs = specs
        @mode = "top"            # "top", "resources", "member" or "collection"
        @path_prefix = ""        # "/posts/:post_id" inside `resources :posts do`
        @name_prefix = ""        # "post_"
        @controller = ""         # "posts"
        @member_path = ""        # "/posts/:id"
        @member_name = ""        # "post"
        @collection_path = ""    # "/posts"
        @collection_name = ""    # "posts"
      end

      # root "posts#index" -> GET / named "root".
      # @param to [String] `"controller#action"`
      # @return [nil]
      # @api public
      def root(to)
        target = split_to(to)
        add_spec("GET", "/", target[0], target[1], "root")
      end

      # A GET route. At the top level `to:` is required; inside a
      # `resources` block (or its `member` / `collection`) the controller is
      # the resource's and the action defaults to the path.
      #
      # The name is `as:`, or the path with every character outside
      # `[a-z0-9_]` turned into `_` (`"about-us"` → `about_us`). Inside a
      # `member` block it gets the resource's singular as a suffix
      # (`preview_post`), inside `collection` the plural (`search_posts`),
      # inside `resources` its prefix (`post_...`). A derived name that an
      # earlier route already took leaves the route unnamed, as in Rails
      # (`get "/sign_up"` then `post "/sign_up"`: one `sign_up_path`); a
      # duplicate `as:` is an error.
      # @example
      #   get "/about", to: "pages#about"               # GET /about, about_path
      #   get "/feed", to: "articles#index", as: "feed"   # feed_path
      # @param path [String] `:name` segments become params (`"/users/:id"`)
      # @param to [String] `"controller#action"`, or just `"action"`
      # @param as [String] the route name
      # @return [nil]
      # @raise [ArgumentError] with no controller, an invalid or duplicate name
      # @api public
      def get(path, to: "", as: "")
        add_custom_route("GET", path, to, as)
      end

      # A POST route; see {#get}.
      # @param path [String]
      # @param to [String]
      # @param as [String]
      # @return [nil]
      # @api public
      def post(path, to: "", as: "")
        add_custom_route("POST", path, to, as)
      end

      # A PATCH route; see {#get}.
      # @param path [String]
      # @param to [String]
      # @param as [String]
      # @return [nil]
      # @api public
      def patch(path, to: "", as: "")
        add_custom_route("PATCH", path, to, as)
      end

      # A PUT route; see {#get}.
      # @param path [String]
      # @param to [String]
      # @param as [String]
      # @return [nil]
      # @api public
      def put(path, to: "", as: "")
        add_custom_route("PUT", path, to, as)
      end

      # A DELETE route; see {#get}.
      # @param path [String]
      # @param to [String]
      # @param as [String]
      # @return [nil]
      # @api public
      def delete(path, to: "", as: "")
        add_custom_route("DELETE", path, to, as)
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
      # application, drawn at the top level. Without `before_action:` the
      # page is open to anyone who can reach it, and `spin run gen` prints
      # a warning saying so.
      # @example
      #   jobs_page "/admin/jobs", before_action: :require_admin
      # @param path [String] literal segments (`"/admin/jobs"`)
      # @param before_action [Symbol, String] a method of ApplicationController
      #   that renders or redirects to refuse the visitor (`:require_admin`)
      # @return [nil]
      # @raise [ArgumentError] for a second jobs page, one inside
      #   `resources`, a path with dynamic or empty segments, or a
      #   before_action that is not a method name
      # @api public
      def jobs_page(path, before_action: "")
        raise ArgumentError, "jobs_page must be used at the top of the routes, not inside resources" unless @mode == "top"

        guard = "#{before_action}"
        unless jobs_page_path?(path)
          message = "jobs_page #{path.inspect}: the path must start with \"/\" and be literal segments of letters, digits, _ and -"
          raise ArgumentError, message
        end
        unless guard.empty? || guard.match?(ACTION_PATTERN)
          message = "jobs_page #{path.inspect}: before_action: #{guard.inspect} is not a method name"
          raise ArgumentError, message
        end
        Cybertrain::Routes.record_jobs_page(path, guard)
        controller = "cybertrain_jobs"
        add_jobs_route("GET", path, controller, "index", "index")
        add_jobs_route("POST", "#{path}/retry_all", controller, "retry_all", "retry_all_action")
        add_jobs_route("POST", "#{path}/discard_all", controller, "discard_all_failed", "discard_all_failed_action")
        add_jobs_route("POST", "#{path}/:id/retry", controller, "retry", "retry_action")
        add_jobs_route("POST", "#{path}/:id/discard", controller, "discard", "discard_action")
        add_jobs_route("POST", "#{path}/:id/delete", controller, "delete", "delete_action")
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
      # @example
      #   resources :articles do |articles|
      #     articles.resources :comments, only: [:create, :destroy]
      #     articles.member { |m| m.get "preview" }        # GET /articles/:id/preview, preview_article_path
      #     articles.collection { |c| c.get "search" }     # GET /articles/search, search_articles_path
      #   end
      # @param name [Symbol] the plural (`:articles`)
      # @param only [Array<Symbol>, nil] draw only these actions
      # @param except [Array<Symbol>, nil] draw all but these
      # @yieldparam mapper [Mapper] the mapper, to call with an explicit
      #   receiver inside the block (`articles.resources`): Spinel gives a
      #   nested block no implicit self
      # @return [nil]
      # @api public
      def resources(name, only: nil, except: nil, &block)
        # Interpolated, not name.to_s: in a program that also loads the model
        # runtime, name.to_s came out boxed and widened @controller, which
        # broke the C build of save_scope/restore_scope.
        plural = "#{name}"
        singular = Inflector.singularize(plural)
        collection_path = "#{@path_prefix}/#{plural}"
        member_path = "#{collection_path}/:id"
        member_name = @name_prefix + singular
        # A word whose singular is itself (sheep, news) would give index and
        # show the same name; Rails names the collection news_index.
        collection_name = @name_prefix + plural + (singular == plural ? "_index" : "")

        unless block.nil?
          saved = save_scope
          @mode = "resources"
          @path_prefix = "#{collection_path}/:#{singular}_id"
          @name_prefix = member_name + "_"
          @controller = plural
          @member_path = member_path
          @member_name = member_name
          @collection_path = collection_path
          @collection_name = collection_name
          block.call(self)
          restore_scope(saved)
        end

        used = []
        STANDARD_ACTIONS.each do |action|
          next unless only.nil? || only.include?(action)
          next if !except.nil? && except.include?(action)

          case action
          when :index then add_standard(used, "GET", collection_path, plural, "index", collection_name)
          when :create then add_standard(used, "POST", collection_path, plural, "create", collection_name)
          when :new then add_standard(used, "GET", "#{collection_path}/new", plural, "new", "new_#{member_name}")
          when :edit then add_standard(used, "GET", "#{member_path}/edit", plural, "edit", "edit_#{member_name}")
          when :show then add_standard(used, "GET", member_path, plural, "show", member_name)
          when :update
            add_standard(used, "PATCH", member_path, plural, "update", member_name)
            add_standard(used, "PUT", member_path, plural, "update", member_name)
          when :destroy then add_standard(used, "DELETE", member_path, plural, "destroy", member_name)
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
      # read as a member). There is no nesting under a singular resource.
      # @example
      #   resource :session, only: [:new, :create, :destroy]
      # @param name [Symbol] the singular (`:session`)
      # @param only [Array<Symbol>, nil] draw only these actions
      # @param except [Array<Symbol>, nil] draw all but these
      # @return [nil]
      # @api public
      def resource(name, only: nil, except: nil)
        singular = "#{name}"
        controller = Inflector.pluralize(singular)
        path = "#{@path_prefix}/#{singular}"
        route_name = @name_prefix + singular
        used = []
        SINGULAR_ACTIONS.each do |action|
          next unless only.nil? || only.include?(action)
          next if !except.nil? && except.include?(action)

          case action
          when :create then add_standard(used, "POST", path, controller, "create", route_name)
          when :new then add_standard(used, "GET", "#{path}/new", controller, "new", "new_#{route_name}")
          when :edit then add_standard(used, "GET", "#{path}/edit", controller, "edit", "edit_#{route_name}")
          when :show then add_standard(used, "GET", path, controller, "show", route_name)
          when :update
            add_standard(used, "PATCH", path, controller, "update", route_name)
            add_standard(used, "PUT", path, controller, "update", route_name)
          when :destroy then add_standard(used, "DELETE", path, controller, "destroy", route_name)
          end
        end
        nil
      end

      # Inside resources: get "preview" -> GET /posts/:id/preview as preview_post.
      # @yieldparam mapper [Mapper]
      # @return [nil]
      # @raise [ArgumentError] outside a `resources` block
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
        raise ArgumentError, "#{mode} must be used inside resources" if @mode == "top"

        saved = save_scope
        @mode = mode
        block.call(self)
        restore_scope(saved)
        nil
      end

      # One custom route; its path, controller and name depend on the scope.
      # Not named `match`: Router#match(verb, path_segments) exists, and a
      # shared name made Spinel type `path` here as an Array of segments
      # once the DSL calls came only through instance_eval (NOTES rule 10).
      def add_custom_route(verb, path, to, as)
        segment = path.start_with?("/") ? path[1, path.size - 1] : path
        target = to == "" ? ["", segment] : split_to(to)
        controller = target[0] == "" ? @controller : target[0]
        action = target[1]
        word = as == "" ? derive_name(segment) : as

        case @mode
        when "member"
          add_spec(verb, "#{@member_path}/#{segment}", controller, action, custom_name("#{word}_#{@member_name}", as))
        when "collection"
          add_spec(verb, "#{@collection_path}/#{segment}", controller, action, custom_name("#{word}_#{@collection_name}", as))
        when "resources"
          add_spec(verb, "#{@path_prefix}/#{segment}", controller, action, custom_name(@name_prefix + word, as))
        else
          raise ArgumentError, "#{verb} /#{segment} needs to: \"controller#action\"" if controller == ""

          add_spec(verb, "/#{segment}", controller, action, custom_name(word, as))
        end
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
      def add_standard(used, verb, pattern, controller, action, name)
        if used.include?(name)
          add_spec(verb, pattern, controller, action, "")
        else
          used << name
          add_spec(verb, pattern, controller, action, name)
        end
      end

      def add_spec(verb, pattern, controller, action, name)
        unless controller.match?(CONTROLLER_PATTERN)
          raise ArgumentError, "controller '#{controller}' is not a valid controller path (#{verb} #{pattern})"
        end
        unless action.match?(ACTION_PATTERN)
          raise ArgumentError, "action '#{action}' is not a valid method name (#{verb} #{pattern})"
        end
        if name != ""
          unless name.match?(NAME_PATTERN)
            raise ArgumentError, "route name '#{name}' is not a valid method name prefix (#{verb} #{pattern}); " \
                                 "pass as: with lowercase letters, digits and _"
          end
          @specs.each do |spec|
            raise ArgumentError, "route name '#{name}' is already in use (#{verb} #{pattern})" if spec.name == name
          end
        end
        @specs << RouteSpec.new(verb, pattern, controller, action, name)
        nil
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
         @collection_path, @collection_name]
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
    def self.record_jobs_page(path, before_action)
      first = @jobs_page.jobs_path
      unless first.empty?
        message = "jobs_page #{path.inspect}: the jobs page is already drawn at #{first.inspect} (one per application)"
        raise ArgumentError, message
      end
      @jobs_page = Gen::JobsPageSpec.new(path, before_action)
      nil
    end

    def self.reset!
      @specs.clear
      @jobs_page = Gen::JobsPageSpec.new("", "")
      nil
    end
  end
end
