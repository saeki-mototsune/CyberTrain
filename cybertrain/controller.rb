require "json"
require "cybertrain/context"
require "cybertrain/html"
require "cybertrain/http/client_error"
require "cybertrain/http/uploaded_file"
require "cybertrain/logger"
require "cybertrain/callback"
require "cybertrain/rate_limit"
require "cybertrain/views"
require "cybertrain/format_collector"
require "cybertrain/template/helpers"
require "cybertrain/generator/inflector"
require "cybertrain/active_support"

module Cybertrain
  class MissingTemplate < StandardError
  end

  class UnknownCallback < StandardError
  end

  # Base class of every application controller, through the app's
  # `ApplicationController`. One instance handles one request: the router
  # builds it, runs the before callbacks, the action, the implicit render and
  # the after callbacks.
  #
  #     class ArticlesController < ApplicationController
  #       before_action :set_article, only: [:show, :edit, :update, :destroy]
  #
  #       def index
  #         @articles = Article.all.to_a
  #       end
  #
  #       def new_action   # GET /articles/new: a method named `new` would shadow ArticlesController.new
  #         @article = Article.new
  #       end
  #
  #       def create
  #         @article = Article.new(article_params)
  #         if @article.save
  #           flash[:notice] = "Article was successfully created."
  #           redirect_to article_path(@article), status: :see_other
  #         else
  #           render :new, status: :unprocessable_entity
  #         end
  #       end
  #
  #       private
  #
  #       def set_article
  #         @article = Article.find(params[:id])
  #       end
  #
  #       def article_params
  #         params.require(:article).permit(:title, :body)
  #       end
  #     end
  #
  # Rules that differ from Rails, all because Spinel compiles ahead of time
  # with no `send` or `instance_exec`:
  #
  # - Actions are public methods; the `new` action is `def new_action`
  #   (its view is still `new.html.erb`, its action name `"new"`).
  # - Templates see the instance variables assigned (`@x = ...`) in the
  #   controller's file or its parents' files, found by `spin run gen`; re-run
  #   it after adding one (`cybertrain server` does).
  # - A block callback takes the controller as its argument
  #   (`before_action { |c| ... }`), so it can call public methods only.
  # - `skip_before_action :name, only: [...]` leaves out a named callback a
  #   parent declared; there is no `skip_after_action`.
  # - `render` and `redirect_to` do not end the action, and a second one
  #   replaces the first; `return` after them when more code follows.
  # - Every controller also has the route helpers (`article_path(...)`,
  #   see {Gen::UrlHelpers}).
  #
  # Implementation: the router calls
  # `process(:show) { |c| c.show }`, so the action name and
  # the action body both arrive as literals (no send).
  #
  # Callback and rescue declarations are runtime data keyed by class name;
  # symbol callbacks are dispatched through run_callback(name), which
  # gen/controllers.rb overrides in each controller with a case table.
  # @api public
  class Controller
    CALLBACKS = {}   # class name => Array<Callback>
    SKIPS = {}       # class name => Array<Callback> (kind :skip, by name)
    RESCUES = {}     # class name => Array<RescueHandler>
    # While gen/concerns.rb splices a concern's `included` body into a
    # class: class name => the index its next callback / rescue goes to.
    CONCERN_CALLBACK_AT = {}
    CONCERN_RESCUE_AT = {}

    # The Symbols `status:` accepts in {#render}, {#head} and
    # {#redirect_to}: the Rails names of the codes in
    # `Response::STATUS_TEXT`, one Symbol per code there. Any other status
    # must be given as an Integer.
    # @api public
    STATUS_SYMBOLS = {
      ok: 200, created: 201, accepted: 202, no_content: 204,
      reset_content: 205, partial_content: 206,
      multiple_choices: 300, moved_permanently: 301, found: 302, see_other: 303,
      not_modified: 304, temporary_redirect: 307, permanent_redirect: 308,
      bad_request: 400, unauthorized: 401, payment_required: 402, forbidden: 403,
      not_found: 404, method_not_allowed: 405, not_acceptable: 406,
      request_timeout: 408, conflict: 409, gone: 410, length_required: 411,
      precondition_failed: 412, payload_too_large: 413, unsupported_media_type: 415,
      range_not_satisfiable: 416, expectation_failed: 417, unprocessable_entity: 422,
      too_many_requests: 429, request_header_fields_too_large: 431,
      internal_server_error: 500, not_implemented: 501, bad_gateway: 502,
      service_unavailable: 503, gateway_timeout: 504
    }

    # Default statuses for render/head and redirect_to. They are 200 and 302
    # under CRuby, but Spinel types them as polymorphic values (an element
    # of a mixed Integer/Symbol Array), and that is the point: Spinel types a
    # parameter from its direct call sites and its default only, never from
    # calls made inside stored blocks. With a plain `status: 200` default, an
    # app whose only symbolic call is `before_action { |c| c.head :forbidden }`
    # or `rescue_from(X) { |c, e| c.head :not_found }` gets an sp_int
    # parameter and the Symbol's internal id arrives as the status. A
    # polymorphic default keeps the parameter boxed whatever the call-site
    # mix is. (test/controller_status.rb)
    DEFAULT_STATUS = [200, :ok][0]
    DEFAULT_REDIRECT_STATUS = [302, :found][0]
    # render's `layout:` default, `true` (the controller's layout), boxed
    # the same way: one call site passing `false` and another a String must
    # both reach a parameter that can hold either.
    DEFAULT_LAYOUT = [true, ""][0]
    # What run_before_callbacks consults when no controller declared a skip:
    # seeded with the element type and emptied (spikes/NOTES.md rule 9).
    NO_SKIPS = Array.new(0) { Callback.new(:skip, nil, nil, [], [], -1) }

    # Runs a method or a block before the action. The chain runs the
    # parent classes' callbacks first, then each class's in declaration order,
    # and stops at the first callback that renders, redirects or calls
    # {#head}: the action, the implicit render and the after callbacks are
    # then skipped.
    #
    # One method name per call. The method is called without a receiver, so
    # it may be private; it must be named on the same line as
    # `before_action` for `spin run gen` to find it.
    #
    # @example
    #   before_action :set_article, only: [:show, :edit, :update, :destroy]
    #   before_action(except: [:index, :show]) { |c| c.head :forbidden unless c.session[:user_id] }
    # @param name [Symbol, nil] a method of this controller, or nil with a block
    # @param only [Array<Symbol>] run for these actions only (`:new` for
    #   `new_action`)
    # @param except [Array<Symbol>] run for every action but these
    # @yieldparam controller [Controller] the controller (no implicit self)
    # @return [nil]
    # @api public
    def self.before_action(name = nil, only: [], except: [], &block)
      add_callback(Callback.new(:before, name, block, only, except, -1))
    end

    # Runs a method or a block after the action and its implicit render,
    # in the same order as {.before_action} (not reversed). Skipped when a
    # before callback halted or anything raised.
    # @example
    #   after_action { |c| c.response.set_header("Cache-Control", "no-store") }
    # @param name [Symbol, nil]
    # @param only [Array<Symbol>]
    # @param except [Array<Symbol>]
    # @yieldparam controller [Controller]
    # @return [nil]
    # @api public
    def self.after_action(name = nil, only: [], except: [], &block)
      add_callback(Callback.new(:after, name, block, only, except, -1))
    end

    # Limits how often one client may call some actions: at most `to`
    # requests per `within` seconds for each client address, counted in
    # this process before the action runs (a before callback, in
    # declaration order with the others). An exhausted client gets a 429
    # with the body "Too Many Requests" and a `Retry-After` header (the
    # seconds until its window closes), or, with `redirect_to:`, a 303 to
    # that path with `alert:` in the flash. The action does not run either
    # way.
    #
    # The count is kept per declaration, per controller (a limit declared in
    # a parent counts each subclass apart, as Rails' does) and per address:
    # {Request#client_ip} by default, so behind a proxy on the same host set
    # Config#trusted_proxy, or every visitor shares the proxy's address;
    # `by: :remote_addr` counts the connection's peer whatever the
    # configuration. Memory is bounded and counts are lost on restart (see
    # {RateLimit}). Every request to a limited action takes one lock, so
    # name the actions with `only:`.
    #
    # Differences from Rails: `within:` is a number of seconds (`3 * 60`;
    # there is no `3.minutes`), `only:`/`except:` take Arrays, there is no
    # `by:` or `with:` block, and the count lives in the process rather than
    # in a cache store.
    # @example
    #   class SessionsController < ApplicationController
    #     rate_limit to: 10, within: 3 * 60, only: [:create],
    #                redirect_to: "/session/new", alert: "Try again later."
    #   end
    #   rate_limit to: 100, within: 60, only: [:create, :update]   # a 429 with Retry-After
    # @param to [Integer] requests allowed per window, at least 1
    # @param within [Integer] the window, in seconds, at least 1
    # @param only [Array<Symbol>] limit these actions only
    # @param except [Array<Symbol>] limit every action but these
    # @param by [Symbol] `:client_ip` (the default) or `:remote_addr`
    # @param redirect_to [String] a path to redirect an exhausted client to
    #   (`""`, the default: answer 429 instead)
    # @param alert [String] `flash[:alert]` for that redirect (`""`: none)
    # @return [nil]
    # @raise [ArgumentError] for a `to` or `within` below 1 or another `by:`
    # @api public
    def self.rate_limit(to:, within:, only: [], except: [], by: :client_ip, redirect_to: "", alert: "")
      raise ArgumentError, "rate_limit needs to: of at least 1 (got #{to})" if to < 1
      raise ArgumentError, "rate_limit needs within: of at least 1 second (got #{within})" if within < 1

      by_remote_addr = false
      case by
      when :client_ip then by_remote_addr = false
      when :remote_addr then by_remote_addr = true
      else raise ArgumentError, "rate_limit by: must be :client_ip or :remote_addr (got #{by.inspect})"
      end
      id = RateLimit.register(RateLimit.new(to, within, by_remote_addr, redirect_to, alert))
      add_callback(Callback.new(:before, nil, nil, only, except, id))
    end

    def self.add_callback(callback)
      list = (CALLBACKS[self.name] ||= [])
      if CONCERN_CALLBACK_AT.key?(self.name)
        at = CONCERN_CALLBACK_AT[self.name]
        at = list.size if at > list.size
        list.insert(at, callback)
        CONCERN_CALLBACK_AT[self.name] = at + 1
      else
        list << callback
      end
      nil
    end

    # Written by gen/concerns.rb (`spin run gen`) around the `included`
    # body of a concern it splices into this class: until
    # {.concern_insert_done}, the callbacks and `rescue_from` handlers the
    # body declares go to these positions of the class's own lists (the
    # count of declarations above the `include` line), not to the end, so
    # they run where the `include` was written. Not for application code.
    # @param callbacks_index [Integer]
    # @param rescues_index [Integer]
    # @return [nil]
    # @api public
    def self.concern_insert_at(callbacks_index, rescues_index)
      CONCERN_CALLBACK_AT[self.name] = callbacks_index
      CONCERN_RESCUE_AT[self.name] = rescues_index
      nil
    end

    # Ends a {.concern_insert_at} splice: declarations append again.
    # @return [nil]
    # @api public
    def self.concern_insert_done
      CONCERN_CALLBACK_AT.delete(self.name)
      CONCERN_RESCUE_AT.delete(self.name)
      nil
    end

    # Makes controller methods callable from this controller's templates
    # (spec 4.3). A declaration only: `spin run gen` reads the names.
    # @example
    #   helper_method :current_user, :admin?
    # @param names [Array<Symbol>]
    # @return [nil]
    # @api public
    def self.helper_method(*names)
      nil
    end

    # Names this controller's layout. A declaration only: `spin run gen`
    # reads it.
    # @example
    #   layout "admin"
    #   layout false
    # @param name [String, Symbol, false, nil] a layout name, `false` for
    #   none, or a method choosing one
    # @param only [Array<Symbol>]
    # @param except [Array<Symbol>]
    # @return [nil]
    # @api public
    def self.layout(name = nil, only: [], except: [])
      nil
    end

    # Leaves out a named before callback a parent class (or this one)
    # declared, for every action or for `only:` / `except:` some. The
    # usual shape is an `ApplicationController` that requires a signed-in
    # user everywhere and a controller that opens its sign-in actions:
    #
    #     class SessionsController < ApplicationController
    #       skip_before_action :require_authentication, only: [:new, :create]
    #
    # A skip declared in a class applies to it and its subclasses. Block
    # callbacks have no name and cannot be skipped. `cybertrain generate
    # authentication` wraps this as `allow_unauthenticated_access`.
    # @param name [Symbol] the callback's method name
    # @param only [Array<Symbol>] skip it for these actions only
    # @param except [Array<Symbol>] skip it for every action but these
    # @return [nil]
    # @api public
    def self.skip_before_action(name, only: [], except: [])
      (SKIPS[self.name] ||= []) << Callback.new(:skip, name, nil, only, except, -1)
      nil
    end

    # The skips that apply to klass: its own and its ancestors', up to
    # Controller (the class is passed in, as for chain_for).
    def self.skips_for(klass)
      skips = []
      k = klass
      while k
        list = SKIPS[k.name]
        unless list.nil?
          j = 0
          while j < list.size
            skips << list[j]
            j += 1
          end
        end
        break if k == Controller

        k = k.superclass
      end
      skips
    end

    # Whether a skip in `skips` names this callback for this action.
    def self.skipped?(skips, cb, action)
      name = cb.name
      return false if name.nil?

      i = 0
      while i < skips.size
        skip = skips[i]
        return true if skip.name == name && skip.applies?(action)

        i += 1
      end
      false
    end

    # Handles an exception raised by a callback, the action or its render:
    # `rescue_from NotFound, with: :not_found` or
    # `rescue_from(NotFound) { |c, e| c.head :not_found }`.
    #
    # Unlike Rails, the class must match exactly (a subclass does not), and
    # the first handler found wins, looking in this class before its parents.
    # A `with:` method reads the exception from {#rescued_exception}; keep
    # `with:` on the same line as `rescue_from`. A handler that renders
    # nothing leaves an empty 200.
    #
    # Unhandled, a {Params::ParameterMissing} or malformed query answers 400
    # and anything else 500 (a {RecordNotFound} too: the generated
    # ApplicationController rescues it to a 404).
    # @example
    #   rescue_from Cybertrain::RecordNotFound, with: :record_not_found
    #
    #   private
    #
    #   def record_not_found
    #     render plain: "Not Found", status: :not_found
    #   end
    # @param klass [Class] an exception class
    # @param with [Symbol, nil] a method of this controller, or nil with a block
    # @yieldparam controller [Controller]
    # @yieldparam exception [StandardError]
    # @return [nil]
    # @api public
    def self.rescue_from(klass, with: nil, &block)
      list = (RESCUES[self.name] ||= [])
      handler = RescueHandler.new(klass.name, with, block)
      if CONCERN_RESCUE_AT.key?(self.name)
        at = CONCERN_RESCUE_AT[self.name]
        at = list.size if at > list.size
        list.insert(at, handler)
        CONCERN_RESCUE_AT[self.name] = at + 1
      else
        list << handler
      end
      nil
    end

    # The class is passed in rather than read from self: an inherited class
    # method called as self.class.chain_for binds self to the base class
    # under Spinel.
    def self.chain_for(klass)
      names = []
      k = klass
      while k
        names.unshift(k.name)
        break if k == Controller

        k = k.superclass
      end
      chain = []
      i = 0
      while i < names.size
        list = CALLBACKS[names[i]]
        unless list.nil?
          j = 0
          while j < list.size
            chain << list[j]
            j += 1
          end
        end
        i += 1
      end
      chain
    end

    def self.rescues_for(klass)
      handlers = []
      k = klass
      while k
        list = RESCUES[k.name]
        unless list.nil?
          j = 0
          while j < list.size
            handlers << list[j]
            j += 1
          end
        end
        break if k == Controller

        k = k.superclass
      end
      handlers
    end

    # Always returns a plain Integer: the result lands in Response#status,
    # which must stay an unboxed Integer for the rest of the stack.
    def self.status_code(value)
      code = -1
      case value
      when Integer then code = value.to_i
      else code = STATUS_SYMBOLS.fetch(value, -1).to_i
      end
      raise ArgumentError, "unknown status #{value.inspect}" if code < 0

      code
    end

    attr_reader :ctx

    # The request: method, path, headers, raw body.
    # @return [Request]
    # @api public
    attr_reader :request

    # The response being built. {#render}, {#redirect_to} and {#head} fill
    # it; set headers and cookies on it directly.
    # @example
    #   response.set_header("Cache-Control", "no-store")
    # @return [Response]
    # @api public
    attr_reader :response

    # The request parameters: the query string, a urlencoded form body and
    # the route's `:id`-style segments (in that order, later ones winning).
    # @example
    #   params[:id]
    #   params.require(:article).permit(:title, :body)
    # @return [Params]
    # @api public
    attr_reader :params

    # The action being run, by its route name: `"show"`, and `"new"` for
    # `new_action`.
    # @return [String]
    # @api public
    attr_reader :action_name

    # The exception a {.rescue_from} `with:` method is handling.
    # @return [StandardError, nil]
    # @api public
    attr_reader :rescued_exception

    # This visitor's session, kept in a signed cookie.
    #
    # The session and flash installed by SessionStore (nil when the
    # middleware is not in the stack, e.g. in bare unit tests).
    # @return [Session]
    # @api public
    def session
      @ctx.session
    end

    # Messages for the next request (`flash[:notice] = "Saved."` before a
    # redirect) or, through `flash.now`, for this one.
    # @return [Flash]
    # @api public
    def flash
      @ctx.flash
    end

    def initialize(ctx)
      @ctx = ctx
      @request = ctx.request
      @response = ctx.response
      @params = ctx.params
      @action_name = ""
      @rescued_exception = nil
      @controller_path = ""
    end

    # Runs the before callbacks (stopping as soon as one renders or
    # redirects), the action body (the block), the implicit render, then the
    # after callbacks. An exception is handed to the first matching
    # rescue_from handler, or re-raised when there is none.
    #
    # The work happens in run_action, which takes the block as a plain Proc:
    # Spinel inlines a method that yields at every call site with self typed
    # as the subclass, and both `yield self` and a `rescue => e` inside such
    # an inlined body produce C that does not compile.
    def process(action, &body)
      run_action(action, body)
    end

    def run_callback(name)
      raise UnknownCallback, "unknown callback :#{name} in #{self.class.name} (run `spin run gen`)"
    end

    # Whether `name` is one of this controller's helper methods (spec 4.3):
    # gen/controllers.rb overrides it with a `case` over the names of the
    # controller's `helper_method` lines and its concerns', then `super`.
    # Called on self, never through a stored block.
    # @param name [String]
    # @return [Boolean]
    # @api private
    def helper_method?(name)
      false
    end

    # Calls the helper method `name` with a template's arguments (args by
    # position, kwargs by keyword name); gen/controllers.rb overrides it.
    # Template::Helpers#helper_call asks {#helper_method?} first.
    # @param name [String]
    # @param args [Array]
    # @param kwargs [Hash{String => Object}]
    # @return [Object]
    # @api private
    def call_helper_method(name, args, kwargs)
      nil
    end

    # The implicit render after an action that rendered nothing, by the
    # request's format ({Request#format}): for `:html`,
    # app/views/<controller_path>/<action>.html.erb inside the layout; for
    # any other format, <action>.<format>.erb (`create.turbo_stream.erb`,
    # `index.csv.erb`) without a layout when it exists, else `406 Not
    # Acceptable` (a `:json` request with no template and no `render`
    # included). A Turbo request that also accepts HTML gets the html
    # template when there is no turbo_stream one (see #html_fallback?).
    def default_render(action)
      engine = Views.engine
      if engine.nil?
        message = "no template for #{self.class.name}##{action}"
        raise MissingTemplate, message
      end

      wanted = @request.format
      name = action.to_s
      if wanted == :html
        render_template(name)
      elsif wanted != :unknown && engine.exists?(format_template_path(name, wanted))
        render_template(name, format: wanted)
      elsif html_fallback?
        render_template(name)
      else
        head_not_acceptable
      end
    end

    # The instance variables templates can read, as { "post" => @post };
    # gen/controllers.rb overrides it in every controller.
    def view_assigns
      {}
    end

    # What a template sees: view_assigns, then the locals (extra, keyed by
    # String), then flash (a Hash of the current messages), params and the
    # directory partials are looked up in.
    def view_env(extra)
      env = {}
      assigns = view_assigns
      # keys + while: an each_key block is a Proc and closure per request.
      assign_keys = assigns.keys
      i = 0
      while i < assign_keys.size
        env[assign_keys[i]] = assigns[assign_keys[i]]
        i += 1
      end
      extra_keys = extra.keys
      i = 0
      while i < extra_keys.size
        env[extra_keys[i]] = extra[extra_keys[i]]
        i += 1
      end
      env["flash"] = Template::Helpers.flash_messages(flash)
      env["params"] = @params
      path = controller_path
      env["__template_dir"] = path
      env["__controller_path"] = path
      env
    end

    # "posts" for PostsController: the directory under `app/views/` its
    # templates come from.
    # @return [String]
    # @api public
    def controller_path
      known = @controller_path
      return known unless known.empty?

      # Asked for at least three times in a render (view_env, render_template,
      # the layout), each an underscore of the class name: remembered.
      name = Inflector.underscore(self.class.name)
      path = name.end_with?("_controller") ? name[0, name.length - 11] : name
      @controller_path = path
      path
    end

    # The layout an action's HTML renders in: `"layouts/application"` (the
    # configured {Views.layout_name}) here, and in a controller with
    # `layout` lines the one they choose for the action. gen/controllers.rb
    # writes the override from them, in order, the first that applies
    # winning, else `super`:
    #
    #     layout "admin", only: [:index]   # "layouts/admin" for index
    #     layout false                     # "" (no layout)
    #     layout :choose_layout            # its value: a name, false, or nil (inherited)
    #
    # A concern's `included` block may declare one too; it counts at its
    # `include` line.
    # @param action [String] the action's name
    # @return [String] the layout's name, `""` for none
    # @api public
    def controller_layout(action)
      Views.layout_name
    end

    # Renders <controller_path>/<name> with the process-wide Views engine.
    #
    # For `format: :html` (the default) the template is <name>.html.erb,
    # inside `layout` (a layout name such as `"layouts/application"`; `""`
    # for none) when that layout exists. For any other format it is
    # <name>.<format>.erb (`create.turbo_stream.erb`), never in a layout
    # (layouts are HTML), sent as {Request.mime_type}(format).
    # @param name [String] the template's name in this controller's directory
    # @param locals [Hash{Symbol => Object}] extra template variables
    # @param layout [String] the layout's name, `""` for none; by default
    #   the action's ({#controller_layout})
    # @param format [Symbol] the template's format
    # @return [nil]
    # @raise [Template::MissingTemplate] when the template does not exist
    # @api private
    def render_template(name, locals = {}, layout: controller_layout(@action_name), format: :html)
      engine = Views.engine
      if engine.nil?
        message = "no template #{name} for #{self.class.name}"
        raise MissingTemplate, message
      end

      env = view_env(string_keys(locals))
      helpers = Views.helpers_builder.call(self)
      if format == :html
        path = "#{controller_path}/#{name}"
        if !layout.empty? && engine.exists?(layout)
          send_html(engine.render_with_layout(path, layout, env, helpers))
        else
          send_html(engine.render(path, env, helpers))
        end
      else
        send_rendered(engine.render(format_template_path(name, format), env, helpers), Request.mime_type(format))
      end
    end

    # Answers by the request's format ({Request#format}): the block gets a
    # {FormatCollector}, and the first of its declarations that matches the
    # format runs its block at once (the blocks see the action's instance
    # variables and call {#render} as the action would). A matching
    # declaration without a block renders the action's template for that
    # format (`show.html.erb` in the layout, `show.turbo_stream.erb`
    # without one). When no declaration matches, the answer is `406 Not
    # Acceptable` (`text/plain`, body `Not Acceptable`).
    #
    # Turbo submits a form asking for `text/vnd.turbo-stream.html,
    # text/html`: its format is `:turbo_stream`, and an action with no
    # `format.turbo_stream` answers through its `format.html` declaration,
    # as in Rails (a `.turbo_stream` extension asks for that format only).
    # @example
    #   def show
    #     @article = Article.find(params[:id])
    #     respond_to do |format|
    #       format.html
    #       format.json { render json: @article.as_json }
    #       format.turbo_stream
    #     end
    #   end
    # @yieldparam format [FormatCollector]
    # @return [nil]
    # @raise [Template::MissingTemplate] when a declaration without a block
    #   matches and the action has no template for that format
    # @api public
    def respond_to(&block)
      collector = FormatCollector.new(@request.format)
      block.call(collector)
      if collector.matched_format == :none && html_fallback?
        # Nothing ran in the first pass, so running the block again for
        # :html runs at most one declaration's block.
        collector = FormatCollector.new(:html)
        block.call(collector)
      end
      matched = collector.matched_format
      if matched == :none
        head_not_acceptable
      elsif collector.matched_without_block?
        render_template(@action_name, format: matched)
      end
      nil
    end

    # Renders the response from a template, text, HTML or JSON: exactly
    # one of template, plain:, html:, json: or partial:.
    #
    # An action that renders nothing renders its own template
    # (`app/views/<controller_path>/<action>.html.erb`) in the layout, or
    # for another request format `<action>.<format>.erb` without one
    # (`create.turbo_stream.erb`), else answers `406 Not Acceptable`; see
    # {#respond_to} to answer each format differently.
    #
    # - `template`: `app/views/<controller_path>/<template>.html.erb`, always
    #   this controller's directory, inside the controller's layout
    #   ({#controller_layout}: `app/views/layouts/application.html.erb`
    #   unless a `layout` line chooses another), when it exists. `layout:
    #   "admin"` uses `app/views/layouts/admin.html.erb` instead, `layout:
    #   false` none.
    # - `plain:` the String as `text/plain`.
    # - `html:` as `text/html`; a plain String is escaped, a
    #   {SafeString} is sent as it is.
    # - `json:` as `application/json`; a String is sent as it is (taken to be
    #   JSON already), anything else goes through `JSON.generate`. For a
    #   record, pass {Model#as_json} or {Model#to_json}.
    # - `partial:` `_<name>.html.erb` (`"form"` in this controller's
    #   directory, `"comments/comment"` in another), never in a layout.
    #
    # It does not end the action: a later `render` or `redirect_to`
    # replaces it.
    # @example
    #   render :new, status: :unprocessable_entity
    #   render plain: "Not Found", status: :not_found
    #   render :show, layout: "print"
    #   render json: { ok: true }, status: :created
    #   render json: @article.to_json
    # @param template [Symbol, String, nil] an action's template, `:new`
    # @param plain [String, nil]
    # @param html [String, SafeString, nil]
    # @param json [Object, nil]
    # @param partial [String, nil]
    # @param status [Integer, Symbol] see {STATUS_SYMBOLS}; 200 by default
    # @param content_type [String, nil] replaces the content type
    # @param locals [Hash{Symbol => Object}] extra template variables
    # @param layout [Boolean, String] `true` (the default): the
    #   controller's layout; `false`: none; `"x"`: `layouts/x`
    # @return [nil]
    # @raise [ArgumentError] when not exactly one of template, `plain:`,
    #   `html:`, `json:`, `partial:` is given, or the status is unknown
    # @raise [Template::MissingTemplate] when the template does not exist
    # @api public
    def render(template = nil, plain: nil, html: nil, json: nil, status: DEFAULT_STATUS, content_type: nil,
               partial: nil, locals: {}, layout: DEFAULT_LAYOUT)
      given = 0
      given += 1 unless template.nil?
      given += 1 unless plain.nil?
      given += 1 unless html.nil?
      given += 1 unless json.nil?
      given += 1 unless partial.nil?
      raise ArgumentError, "render needs exactly one of template, plain:, html:, json:, partial:" if given != 1

      @response.status = Controller.status_code(status)
      if !plain.nil?
        @response.body = plain
        @response.content_type = "text/plain; charset=utf-8"
      elsif !html.nil?
        @response.body = Html.out(html)
        @response.content_type = "text/html; charset=utf-8"
      elsif !json.nil?
        @response.body = json_body(json)
        @response.content_type = "application/json; charset=utf-8"
      elsif !partial.nil?
        render_partial(partial.to_s, locals)
      else
        chosen = ""
        if layout == true
          chosen = controller_layout(@action_name)
        elsif layout != false
          chosen = "layouts/#{layout}"
        end
        render_template(template.to_s, locals, layout: chosen)
      end
      @response.content_type = content_type unless content_type.nil?
      @response.performed!
      nil
    end

    # Answers with a redirect (302 by default) to a URL String: build it with
    # a route helper. After a form submission use `status: :see_other`
    # (303), as the scaffold does, so the browser follows with a GET. It
    # does not end the action. To show a message on the next page, set
    # {#flash} first.
    # @example
    #   flash[:notice] = "Article was successfully created."
    #   redirect_to article_path(@article), status: :see_other
    # @param location [String] a path or URL (a record is not accepted)
    # @param status [Integer, Symbol] see {STATUS_SYMBOLS}
    # @return [nil]
    # @raise [ArgumentError] when the location holds a CR or LF
    # @api public
    def redirect_to(location, status: DEFAULT_REDIRECT_STATUS)
      @response.redirect(location, Controller.status_code(status))
      nil
    end

    # The longest path {#local_path?} accepts, in bytes.
    MAX_LOCAL_PATH_BYTES = 2048

    # Whether `text` is a path on this site that is safe to redirect to: it
    # starts with `/` but not `//` or `/\` (which browsers read as another
    # host), holds printable ASCII only (no space, control character,
    # backslash or byte above 126: browsers strip or reinterpret those; a
    # path the browser sent is percent-encoded already) and is at most
    # {MAX_LOCAL_PATH_BYTES} bytes. Use it on any destination that came
    # from the request (a `return_to` parameter, a remembered page).
    # @example
    #   local_path?("/articles?page=2")   # => true
    #   local_path?("//evil.example/")    # => false
    # @param text [String, nil]
    # @return [Boolean]
    # @api public
    def local_path?(text)
      Controller.local_path_text?(text)
    end

    # `text` when it is a {#local_path?}, otherwise `fallback`: the
    # destination to give {#redirect_to} for a path that came from the
    # request.
    # @example
    #   redirect_to safe_redirect_path(params[:return_to], root_path), status: :see_other
    # @param text [String, nil]
    # @param fallback [String] where to go instead, such as `"/"`
    # @return [String]
    # @api public
    def safe_redirect_path(text, fallback)
      return fallback unless Controller.local_path_text?(text)

      text.to_s
    end

    # local_path?'s check, a byte scan through a fresh local (NOTES rule 62).
    def self.local_path_text?(text)
      return false if text.nil?

      s = text.to_s
      n = s.bytesize
      return false if n < 1 || n > MAX_LOCAL_PATH_BYTES
      return false unless s.getbyte(0) == 47 # "/"

      i = 1
      while i < n
        b = s.getbyte(i)
        return false if b <= 32 || b >= 127 || b == 92 # control, space, DEL, non-ASCII, "\"
        return false if i == 1 && b == 47 # "//"

        i += 1
      end
      true
    end

    # Answers with a status and an empty body.
    #
    # status defaults to :ok only so that Spinel boxes the parameter (see
    # DEFAULT_STATUS); callers are expected to pass one.
    # @example
    #   head :forbidden
    #   head 401
    # @param status [Integer, Symbol] see {STATUS_SYMBOLS}
    # @return [nil]
    # @api public
    def head(status = DEFAULT_STATUS)
      @response.status = Controller.status_code(status)
      @response.body = ""
      @response.performed!
      nil
    end

    # Answers with a streaming response (Rails' ActionController::Live,
    # without the module): the block runs after the action has returned, on
    # the connection's thread, once the head is sent, and receives the
    # {Sink} to write to. The connection closes when the block returns, or
    # when the client goes away ({Sink#closed?}: end the loop then). The
    # block must not touch the session, flash or response any more: they
    # were sent with the head. Marks the response performed, like {#render}.
    # @example Server-Sent Events
    #   def events
    #     stream do |out|
    #       5.times do |i|
    #         out.write(Cybertrain::SSE.event("tick #{i}"))
    #         break if out.wait_closed(1)
    #       end
    #     end
    #   end
    # @param content_type [String]
    # @param status [Integer, Symbol] see {STATUS_SYMBOLS}
    # @yieldparam out [Sink]
    # @return [nil]
    # @api public
    def stream(content_type: "text/event-stream", status: DEFAULT_STATUS, &block)
      r = @response
      r.status = Controller.status_code(status)
      r.content_type = content_type
      r.set_header("Cache-Control", "no-store")
      # Stored and called later from BlockWriter#write_body, a plain method
      # (spikes/NOTES.md rules 2, 69).
      r.body_writer = BlockWriter.new(block)
      r.performed!
      nil
    end

    # Serves stored bytes that came from a user (an upload), safely. This is
    # the only supported way to send an upload back: never put uploads under
    # `public/`, because {Static} serves them with whatever type their
    # extension implies.
    #
    # The bytes are untrusted, so the response never lets a browser run them:
    #
    # - only PNG, JPEG, GIF and WebP ({UploadedFile::INLINE_SAFE_TYPES}) are
    #   sent `inline` under their own type; every other type (SVG and HTML
    #   included) is an `attachment` typed `application/octet-stream`;
    # - `filename` is sanitized again ({UploadedFile.sanitize_filename}, in
    #   case the stored value was tampered with) and the Content-Disposition
    #   header is ASCII only;
    # - `X-Content-Type-Options: nosniff`, `Content-Security-Policy:
    #   default-src 'none'; sandbox` and `Cache-Control: private,
    #   max-age=3600` are always set. (nosniff and `X-Frame-Options:
    #   SAMEORIGIN` are also the defaults of every response, see
    #   {Response#to_http}; the header set here is the one sent, not a
    #   second copy.)
    #
    # HEAD works as for any action: the Server leaves the body out.
    # @example
    #   def show
    #     avatar = Avatar.find(params[:id])
    #     send_blob avatar.read, filename: avatar.filename, content_type: avatar.content_type
    #   end
    # @param data [String] the bytes, binary
    # @param filename [String] the display name, as stored
    # @param content_type [String] the type detected on the server when the
    #   file was stored ({UploadedFile#detected_content_type}), never the
    #   client's claim
    # @return [nil]
    # @api public
    def send_blob(data, filename:, content_type:)
      inline = UploadedFile.inline_safe?(content_type)
      r = @response
      r.status = 200
      r.content_type = inline ? content_type : "application/octet-stream"
      r.set_header("Content-Disposition",
                   UploadedFile.content_disposition(inline ? "inline" : "attachment", UploadedFile.sanitize_filename(filename)))
      r.set_header("X-Content-Type-Options", "nosniff")
      r.set_header("Content-Security-Policy", "default-src 'none'; sandbox")
      r.set_header("Cache-Control", "private, max-age=3600")
      r.body = data
      r.performed!
      nil
    end

    # @return [Boolean] true once this request has been rendered,
    #   redirected or answered with {#head}
    # @api public
    def performed?
      @response.performed?
    end

    private

    def run_action(action, body)
      @action_name = action.to_s
      # Built once per request and walked by both passes.
      chain = Controller.chain_for(self.class)
      begin
        if run_before_callbacks(chain, action)
          body.call(self)
          default_render(action) unless performed?
          run_after_callbacks(chain, action)
        end
      rescue JSON::NestingError, JSON::ParserError, StandardError => e
        # JSON::ParserError named (NOTES rule 33: not a StandardError under
        # Spinel) so an action's bad JSON.parse goes through
        # rescue_with_handler like any other exception. A `rescue_from
        # JSON::ParserError` handler fires under CRuby; under Spinel the
        # constant cannot be referenced as a value (rule 48), so no app can
        # register one there and the exception goes on to the error pages.
        rescue_with_handler(e)
      end
      nil
    end

    # false when a callback rendered or redirected (the chain halts). A
    # while loop, not `each` with a `return` inside the block: under Spinel
    # a return out of a block costs a setjmp and a Proc on every call.
    def run_before_callbacks(chain, action)
      # The skip list is walked only in a program that declared one: an app
      # without skip_before_action pays nothing here.
      skips = SKIPS.empty? ? NO_SKIPS : Controller.skips_for(self.class)
      i = 0
      n = chain.size
      while i < n
        cb = chain[i]
        if cb.kind == :before && cb.applies?(action) && !Controller.skipped?(skips, cb, action)
          run_one(cb)
          return false if performed?
        end
        i += 1
      end
      true
    end

    def run_after_callbacks(chain, action)
      i = 0
      while i < chain.size
        cb = chain[i]
        run_one(cb) if cb.kind == :after && cb.applies?(action)
        i += 1
      end
      nil
    end

    def run_one(cb)
      limit_id = cb.limit_id
      if limit_id >= 0
        apply_rate_limit(RateLimit.all[limit_id])
        return nil
      end
      name = cb.name
      if name.nil?
        cb.block.call(self)
      else
        run_callback(name)
      end
    end

    # One rate_limit check: counts this request and, when the client is
    # over the limit, answers for the action (a 429 with Retry-After, or
    # the declaration's redirect), which halts the chain. The key carries
    # the controller's path, so a limit inherited from a parent counts
    # each controller apart.
    def apply_rate_limit(limit)
      address = limit.by_remote_addr? ? @request.remote_addr : @request.client_ip
      key = "#{controller_path} #{address}"
      wait = limit.hit(key, RateLimit.current_time)
      return nil if wait == 0

      path = limit.redirect_path
      if path.empty?
        r = @response
        r.status = 429
        r.content_type = "text/plain; charset=utf-8"
        r.set_header("Retry-After", wait.to_s)
        r.body = RateLimit::BODY
        r.performed!
      else
        message = limit.alert_message
        messages = flash
        messages[:alert] = message unless message.empty? || messages.nil?
        @response.redirect(path, 303)
      end
      nil
    end

    # Re-raises e when no rescue_from handler matches its class name.
    def rescue_with_handler(e)
      class_name = e.class.name
      Controller.rescues_for(self.class).each do |h|
        next unless h.class_name == class_name

        @rescued_exception = e
        with = h.with
        if with.nil?
          h.block.call(self, e)
        else
          run_callback(with)
        end
        return nil
      end
      # A client fault raised inside an action (a missing required parameter;
      # a Query.parse of its own past Query's limits) answers 400 with its
      # message in plain text, like Rails' bad-request page, instead of
      # surfacing as a 500. The decision is ClientError's, the same one the
      # error pages use, by class name (NOTES rules 46, 47): comparing the
      # full "Cybertrain::Params::ParameterMissing" here would miss under
      # Spinel, where Class#name is the bare "ParameterMissing". Which
      # headers survive is Response#client_error!'s policy; then performed!
      # so the chain stops. classify also logs the "rejected request" info
      # line, which the error pages write for the same fault one layer up
      # (Cybertrain.logger, as Dev::ErrorPage does), so an answer given here
      # is as visible as one given there. It is called only once status_for
      # has said 400: for anything else classify would log an error line, and
      # this method re-raises that exception to ErrorPages, which classifies
      # (and logs) it again, once, as the 500.
      if ClientError.status_for(e) == 400
        ClientError.classify(e, Cybertrain.logger)
        @response.client_error!(400, e.message)
        @response.performed!
        return nil
      end
      raise e
    end

    def render_partial(name, locals)
      engine = Views.engine
      raise MissingTemplate, "no partial #{name} for #{self.class.name}" if engine.nil?

      path = Template::Helpers.partial_path(controller_path, name)
      given = string_keys(locals)
      Template::Helpers.check_locals(engine.template(path), given.keys)
      send_html(engine.render(path, view_env(given), Views.helpers_builder.call(self)))
    end

    def send_html(body)
      send_rendered(body, "text/html; charset=utf-8")
    end

    def send_rendered(body, content_type)
      @response.body = body
      @response.content_type = content_type
      @response.performed!
      nil
    end

    # "articles/index.csv.erb": the template of a format other than html.
    def format_template_path(name, format)
      "#{controller_path}/#{name}.#{format}.erb"
    end

    # Whether a :turbo_stream request also takes HTML: its Accept (Turbo's
    # "text/vnd.turbo-stream.html, text/html, application/xhtml+xml") lists
    # text/html or */*, and no `.turbo_stream` extension asked for the
    # stream alone. Rails lists both formats for such a request and answers
    # in the first one the action has.
    def html_fallback?
      req = @request
      return false unless req.format == :turbo_stream && req.format_extension.empty?

      accept = req.header("Accept").to_s
      accept.include?("text/html") || accept.include?("*/*")
    end

    # 406 for a format the action does not answer (respond_to with no
    # matching declaration, or an implicit render with no template).
    def head_not_acceptable
      r = @response
      r.status = 406
      r.content_type = "text/plain; charset=utf-8"
      r.body = "Not Acceptable"
      r.performed!
      nil
    end

    # `locals: { post: @post }` comes with Symbol keys; templates look
    # names up by String.
    def string_keys(locals)
      out = {}
      keys = locals.keys
      i = 0
      while i < keys.size
        out[keys[i].to_s] = locals[keys[i]]
        i += 1
      end
      out
    end

    # A String is taken to be JSON already.
    def json_body(value)
      case value
      when String then value
      else JSON.generate(value)
      end
    end
  end
end
