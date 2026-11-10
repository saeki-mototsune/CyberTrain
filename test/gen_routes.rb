require "cybertrain/test"
require "cybertrain/generator"
require "cybertrain/generator/url_support"

# The blog routes from the Rails Getting Started guide, in the form
# config/routes.rb uses: receiverless calls at the top of the draw block,
# an explicit receiver inside nested blocks.
def draw_blog
  Cybertrain::Routes.reset!
  Cybertrain::Routes.draw do
    root "posts#index"
    resources :posts do |posts|
      posts.resources :comments, only: [:create, :destroy]
    end
    get "/about", to: "pages#about"
  end
  Cybertrain::Routes.specs
end

# One "VERB /pattern controller#action name" line per spec.
def route_lines(specs)
  specs.map { |s| "#{s.verb} #{s.pattern} #{s.controller}##{s.action} #{s.name}".rstrip }
end

# --- Routes DSL --------------------------------------------------------

test "blog routes come out in Rails order" do
  expected = [
    "GET / posts#index root",
    "POST /posts/:post_id/comments comments#create post_comments",
    "DELETE /posts/:post_id/comments/:id comments#destroy post_comment",
    "GET /posts posts#index posts",
    "POST /posts posts#create",
    "GET /posts/new posts#new new_post",
    "GET /posts/:id/edit posts#edit edit_post",
    "GET /posts/:id posts#show post",
    "PATCH /posts/:id posts#update",
    "PUT /posts/:id posts#update",
    "DELETE /posts/:id posts#destroy",
    "GET /about pages#about about"
  ]
  assert_equal expected, route_lines(draw_blog)
end

test "resources only: and except: pick actions" do
  Cybertrain::Routes.reset!
  Cybertrain::Routes.draw do
    resources :photos, only: [:index, :show]
    resources :tags, except: [:new, :edit, :update, :destroy]
  end
  expected = [
    "GET /photos photos#index photos",
    "GET /photos/:id photos#show photo",
    "GET /tags tags#index tags",
    "POST /tags tags#create",
    "GET /tags/:id tags#show tag"
  ]
  assert_equal expected, route_lines(Cybertrain::Routes.specs)
end

test "member and collection routes precede the standard ones" do
  Cybertrain::Routes.reset!
  Cybertrain::Routes.draw do
    resources :posts, only: [:show] do |posts|
      posts.member do |m|
        m.get "preview"
        m.patch "publish", to: "posts#release"
      end
      posts.collection { |c| c.get "search" }
    end
  end
  expected = [
    "GET /posts/:id/preview posts#preview preview_post",
    "PATCH /posts/:id/publish posts#release publish_post",
    "GET /posts/search posts#search search_posts",
    "GET /posts/:id posts#show post"
  ]
  assert_equal expected, route_lines(Cybertrain::Routes.specs)
end

test "nested resources prefix paths, params and names" do
  Cybertrain::Routes.reset!
  Cybertrain::Routes.draw do
    resources :posts, only: [] do |posts|
      posts.resources :comments, only: [:index, :show] do |comments|
        comments.member { |m| m.post "like" }
      end
    end
  end
  expected = [
    "POST /posts/:post_id/comments/:id/like comments#like like_post_comment",
    "GET /posts/:post_id/comments comments#index post_comments",
    "GET /posts/:post_id/comments/:id comments#show post_comment"
  ]
  assert_equal expected, route_lines(Cybertrain::Routes.specs)
end

test "the draw block may also take the mapper as an argument" do
  Cybertrain::Routes.reset!
  Cybertrain::Routes.draw do |r|
    r.root "pages#home"
    r.resources :posts, only: [:index] do |posts|
      posts.collection { |c| c.get "search" }
    end
  end
  expected = [
    "GET / pages#home root",
    "GET /posts/search posts#search search_posts",
    "GET /posts posts#index posts"
  ]
  assert_equal expected, route_lines(Cybertrain::Routes.specs)
end

test "an empty draw block draws nothing" do
  Cybertrain::Routes.reset!
  Cybertrain::Routes.draw do
  end
  assert_equal 0, Cybertrain::Routes.specs.size
end

test "verb helpers default as: from the path" do
  Cybertrain::Routes.reset!
  Cybertrain::Routes.draw do
    get "/about", to: "pages#about"
    post "/contact/send", to: "pages#deliver"
    patch "/settings", to: "settings#update", as: "save_settings"
    put "/users/:id/avatar", to: "avatars#update"
    delete "/session", to: "sessions#destroy", as: "logout"
  end
  expected = [
    "GET /about pages#about about",
    "POST /contact/send pages#deliver contact_send",
    "PATCH /settings settings#update save_settings",
    "PUT /users/:id/avatar avatars#update users_id_avatar",
    "DELETE /session sessions#destroy logout"
  ]
  assert_equal expected, route_lines(Cybertrain::Routes.specs)
end

test "names derived from a path become method-name prefixes" do
  Cybertrain::Routes.reset!
  Cybertrain::Routes.draw do
    get "/about-us", to: "pages#about"
    get "/robots.txt", to: "pages#robots"
    get "/Legal/Terms-Of-Use", to: "pages#terms"
    resources :posts, only: [] do |posts|
      posts.member { |m| m.get "print-view", to: "posts#print_view" }
      posts.collection { |c| c.get "feed.xml", to: "posts#feed" }
    end
  end
  expected = [
    "GET /about-us pages#about about_us",
    "GET /robots.txt pages#robots robots_txt",
    "GET /Legal/Terms-Of-Use pages#terms legal_terms_of_use",
    "GET /posts/:id/print-view posts#print_view print_view_post",
    "GET /posts/feed.xml posts#feed feed_xml_posts"
  ]
  assert_equal expected, route_lines(Cybertrain::Routes.specs)
  source = Cybertrain::Gen::RoutesEmitter.emit(Cybertrain::Routes.specs)
  assert_includes source, "    def about_us_path\n"
  assert_includes source, "    def robots_txt_url\n"
end

test "a name that is not a method-name prefix raises" do
  Cybertrain::Routes.reset!
  message = assert_raises("ArgumentError") do
    Cybertrain::Routes.draw do
      get "/about", to: "pages#about", as: "about-us"
    end
  end
  assert_equal "route name 'about-us' is not a valid method name prefix (GET /about); pass as: with lowercase letters, digits and _", message
  Cybertrain::Routes.reset!
  message = assert_raises("ArgumentError") do
    Cybertrain::Routes.draw do
      get "/2026/report", to: "reports#show"
    end
  end
  assert_equal "route name '2026_report' is not a valid method name prefix (GET /2026/report); pass as: with lowercase letters, digits and _", message
  Cybertrain::Routes.reset!
  message = assert_raises("ArgumentError") do
    Cybertrain::Routes.draw do
      get "/home", to: "pages#home", as: "Home"
    end
  end
  assert_equal "route name 'Home' is not a valid method name prefix (GET /home); pass as: with lowercase letters, digits and _", message
end

test "an action or controller that is not a Ruby name raises" do
  Cybertrain::Routes.reset!
  message = assert_raises("ArgumentError") do
    Cybertrain::Routes.draw do
      get "/all", to: "pages#show-all"
    end
  end
  assert_equal "action 'show-all' is not a valid method name (GET /all)", message
  Cybertrain::Routes.reset!
  message = assert_raises("ArgumentError") do
    Cybertrain::Routes.draw do
      resources :posts, only: [] do |posts|
        posts.member { |m| m.get "print-view" }
      end
    end
  end
  assert_equal "action 'print-view' is not a valid method name (GET /posts/:id/print-view)", message
  Cybertrain::Routes.reset!
  message = assert_raises("ArgumentError") do
    Cybertrain::Routes.draw do
      get "/x", to: "Pages#x"
    end
  end
  assert_equal "controller 'Pages' is not a valid controller path (GET /x)", message
end

test "a resource whose singular is its plural names its collection <plural>_index" do
  Cybertrain::Routes.reset!
  Cybertrain::Routes.draw do
    resources :news do |news|
      news.collection { |c| c.get "archive" }
      news.resources :comments, only: [:index]
    end
  end
  expected = [
    "GET /news/archive news#archive archive_news_index",
    "GET /news/:news_id/comments comments#index news_comments",
    "GET /news news#index news_index",
    "POST /news news#create",
    "GET /news/new news#new new_news",
    "GET /news/:id/edit news#edit edit_news",
    "GET /news/:id news#show news",
    "PATCH /news/:id news#update",
    "PUT /news/:id news#update",
    "DELETE /news/:id news#destroy"
  ]
  assert_equal expected, route_lines(Cybertrain::Routes.specs)
end

test "a duplicate as: raises" do
  Cybertrain::Routes.reset!
  message = assert_raises("ArgumentError") do
    Cybertrain::Routes.draw do
      get "/about", to: "pages#about"
      get "/about-us", to: "pages#other", as: "about"
    end
  end
  assert_equal "route name 'about' is already in use (GET /about-us)", message
  Cybertrain::Routes.reset!
  message = assert_raises("ArgumentError") do
    Cybertrain::Routes.draw do
      resources :posts
      get "/all", to: "pages#all", as: "posts"
    end
  end
  assert_equal "route name 'posts' is already in use (GET /all)", message
end

test "a derived name an earlier route owns leaves the later route unnamed, as in Rails" do
  Cybertrain::Routes.reset!
  Cybertrain::Routes.draw do
    get "/sign_up", to: "registrations#new", as: "sign_up"
    post "/sign_up", to: "registrations#create"
    get "/about", to: "pages#about"
    get "/about", to: "pages#other"
    resources :posts do |posts|
      posts.member do |m|
        m.get "preview"
        m.post "preview"
      end
    end
  end
  expected = [
    "GET /sign_up registrations#new sign_up",
    "POST /sign_up registrations#create",
    "GET /about pages#about about",
    "GET /about pages#other",
    "GET /posts/:id/preview posts#preview preview_post",
    "POST /posts/:id/preview posts#preview",
    "GET /posts posts#index posts",
    "POST /posts posts#create",
    "GET /posts/new posts#new new_post",
    "GET /posts/:id/edit posts#edit edit_post",
    "GET /posts/:id posts#show post",
    "PATCH /posts/:id posts#update",
    "PUT /posts/:id posts#update",
    "DELETE /posts/:id posts#destroy"
  ]
  assert_equal expected, route_lines(Cybertrain::Routes.specs)
end

test "resource draws a singular resource without an index or an id" do
  Cybertrain::Routes.reset!
  Cybertrain::Routes.draw do
    resource :session, only: [:new, :create, :destroy]
    resource :profile
    resource :settings, except: [:new, :create, :destroy]
  end
  expected = [
    "POST /session sessions#create session",
    "GET /session/new sessions#new new_session",
    "DELETE /session sessions#destroy",
    "POST /profile profiles#create profile",
    "GET /profile/new profiles#new new_profile",
    "GET /profile/edit profiles#edit edit_profile",
    "GET /profile profiles#show",
    "PATCH /profile profiles#update",
    "PUT /profile profiles#update",
    "DELETE /profile profiles#destroy",
    "GET /settings/edit settings#edit edit_settings",
    "GET /settings settings#show settings",
    "PATCH /settings settings#update",
    "PUT /settings settings#update"
  ]
  assert_equal expected, route_lines(Cybertrain::Routes.specs)
  # The emitted helpers: a path for the named routes only.
  source = Cybertrain::Gen::RoutesEmitter.emit(Cybertrain::Routes.specs)
  assert_includes source, "def new_session_path"
  assert_includes source, "def session_path"
  assert_includes source, "SessionsController.new(ctx).process(:new) { |c| c.new_action }"
  assert_includes source, "SessionsController.new(ctx).process(:destroy) { |c| c.destroy }"
end

test "a route outside resources needs to:" do
  Cybertrain::Routes.reset!
  message = assert_raises("ArgumentError") do
    Cybertrain::Routes.draw { get "/about" }
  end
  assert_equal "GET /about needs to: \"controller#action\"", message
end

test "reset! forgets drawn routes" do
  draw_blog
  Cybertrain::Routes.reset!
  assert_equal 0, Cybertrain::Routes.specs.size
end

test "RouteSpec builds the dispatch source" do
  spec = Cybertrain::Gen::RouteSpec.new("GET", "/posts/:id/edit", "posts", "edit", "edit_post")
  assert_equal "PostsController.new(ctx).process(:edit) { |c| c.edit }", spec.handler_source
  assert_equal "edit_post", spec.helper_name
  unnamed = Cybertrain::Gen::RouteSpec.new("PATCH", "/posts/:id", "posts", "update", "")
  assert_equal "", unnamed.helper_name
end

test "the new action dispatches to new_action" do
  spec = Cybertrain::Gen::RouteSpec.new("GET", "/posts/new", "posts", "new", "new_post")
  assert_equal "PostsController.new(ctx).process(:new) { |c| c.new_action }", spec.handler_source
  assert_equal "new_action", spec.method_name
  assert_equal "show", Cybertrain::Gen::RouteSpec.new("GET", "/p/:id", "posts", "show", "").method_name
end

# --- Emitter -----------------------------------------------------------

test "emitted source registers one handler per route" do
  source = Cybertrain::Gen::RoutesEmitter.emit(draw_blog)
  assert_includes source, %(    router.add("GET", "/", "root") { |ctx| PostsController.new(ctx).process(:index) { |c| c.index } }\n)
  assert_includes source, %(    router.add("GET", "/posts/new", "new_post") { |ctx| PostsController.new(ctx).process(:new) { |c| c.new_action } }\n)
  assert_includes source, %(    router.add("GET", "/posts/:id/edit", "edit_post") { |ctx| PostsController.new(ctx).process(:edit) { |c| c.edit } }\n)
  assert_includes source, %(    router.add("PUT", "/posts/:id", "") { |ctx| PostsController.new(ctx).process(:update) { |c| c.update } }\n)
  assert_includes source, %(    router.add("DELETE", "/posts/:post_id/comments/:id", "post_comment") { |ctx| CommentsController.new(ctx).process(:destroy) { |c| c.destroy } }\n)
end

test "emitted source defines path and url helpers" do
  source = Cybertrain::Gen::RoutesEmitter.emit(draw_blog)
  assert_includes source, "    def posts_path\n      \"/posts\"\n    end\n"
  assert_includes source, "    def edit_post_path(post)\n      \"/posts/\#{Cybertrain::Gen.segment(post)}/edit\"\n    end\n"
  assert_includes source, "    def post_comments_path(post)\n      \"/posts/\#{Cybertrain::Gen.segment(post)}/comments\"\n    end\n"
  assert_includes source, "    def post_comment_path(post, comment)\n"
  assert_includes source, "    def post_url(post)\n      Cybertrain.url_root + post_path(post)\n    end\n"
  assert_includes source, "    def root_path\n      \"/\"\n    end\n"
  assert_includes source, "class Cybertrain::Controller\n  include ::Gen::UrlHelpers\nend\n"
end

test "emitted path_for resolves helper names with positional args" do
  source = Cybertrain::Gen::RoutesEmitter.emit(draw_blog)
  assert_includes source, "      when \"post_path\" then \"/posts/\#{Cybertrain::Gen.segment(args[0])}\"\n"
  assert_includes source, "      when \"post_comment_url\" then Cybertrain.url_root + \"/posts/\#{Cybertrain::Gen.segment(args[0])}/comments/\#{Cybertrain::Gen.segment(args[1])}\"\n"
  assert_includes source, "      else raise ArgumentError, \"unknown route helper '\#{name}'\"\n"
end

test "emitted source for a small route set" do
  Cybertrain::Routes.reset!
  Cybertrain::Routes.draw do
    root "pages#home"
    get "/users/:id", to: "users#show", as: "user"
  end
  expected = <<~'RUBY'
    # Generated by `spin run gen` from config/routes.rb. Do not edit.
    require "cybertrain/generator/url_support"

    module Gen
      module Routes
        def self.build(router)
          router.add("GET", "/", "root") { |ctx| PagesController.new(ctx).process(:home) { |c| c.home } }
          router.add("GET", "/users/:id", "user") { |ctx| UsersController.new(ctx).process(:show) { |c| c.show } }
          router
        end

        # The helper named by a String, for templates: path_for("user_path", [user]).
        def self.path_for(name, args)
          case name
          when "root_path" then "/"
          when "root_url" then Cybertrain.url_root + "/"
          when "user_path" then "/users/#{Cybertrain::Gen.segment(args[0])}"
          when "user_url" then Cybertrain.url_root + "/users/#{Cybertrain::Gen.segment(args[0])}"
          else raise ArgumentError, "unknown route helper '#{name}'"
          end
        end

        # Pass this to Cybertrain::Application.new(url_resolver: Gen::Routes.url_resolver).
        def self.url_resolver
          ->(name, args) { path_for(name, args) }
        end
      end

      module UrlHelpers
        def root_path
          "/"
        end

        def root_url
          Cybertrain.url_root + root_path
        end

        def user_path(user)
          "/users/#{Cybertrain::Gen.segment(user)}"
        end

        def user_url(user)
          Cybertrain.url_root + user_path(user)
        end
      end
    end

    class Cybertrain::Controller
      include ::Gen::UrlHelpers
    end
  RUBY
  assert_equal expected, Cybertrain::Gen::RoutesEmitter.emit(Cybertrain::Routes.specs)
end

test "emitted source with no named routes still parses" do
  Cybertrain::Routes.reset!
  source = Cybertrain::Gen::RoutesEmitter.emit(Cybertrain::Routes.specs)
  assert_includes source, "    def self.build(router)\n      router\n    end\n"
  assert_includes source, "    def self.path_for(name, args)\n      raise ArgumentError, \"unknown route helper '\#{name}'\"\n    end\n"
end

test "Gen.param and Gen.segment turn helper arguments into path segments" do
  assert_equal "7", Cybertrain::Gen.param(7)
  assert_equal "abc", Cybertrain::Gen.param("abc")
  assert_equal "a%20b%2Fc", Cybertrain::Gen.segment("a b/c")
  assert_equal "12", Cybertrain::Gen.segment(12)
  assert_equal "missing route parameter", assert_raises("ArgumentError") { Cybertrain::Gen.segment(nil) }
end

# --- jobs_page -----------------------------------------------------------

test "jobs_page draws the six jobs routes to CybertrainJobsController" do
  Cybertrain::Routes.reset!
  Cybertrain::Routes.draw do
    root "posts#index"
    jobs_page "/admin/jobs", before_action: :require_admin
  end
  expected = [
    "GET / posts#index root",
    "GET /admin/jobs cybertrain_jobs#index",
    "POST /admin/jobs/retry_all cybertrain_jobs#retry_all",
    "POST /admin/jobs/discard_all cybertrain_jobs#discard_all_failed",
    "POST /admin/jobs/:id/retry cybertrain_jobs#retry",
    "POST /admin/jobs/:id/discard cybertrain_jobs#discard",
    "POST /admin/jobs/:id/delete cybertrain_jobs#delete"
  ]
  assert_equal expected, route_lines(Cybertrain::Routes.specs)
  handlers = Cybertrain::Routes.specs.map { |s| s.handler_source }
  assert_equal "CybertrainJobsController.new(ctx).process(:index) { |c| c.index }", handlers[1]
  assert_equal "CybertrainJobsController.new(ctx).process(:retry_all) { |c| c.retry_all_action }", handlers[2]
  assert_equal "CybertrainJobsController.new(ctx).process(:discard_all_failed) { |c| c.discard_all_failed_action }", handlers[3]
  assert_equal "CybertrainJobsController.new(ctx).process(:retry) { |c| c.retry_action }", handlers[4]
  assert_equal "CybertrainJobsController.new(ctx).process(:discard) { |c| c.discard_action }", handlers[5]
  assert_equal "CybertrainJobsController.new(ctx).process(:delete) { |c| c.delete_action }", handlers[6]
  page = Cybertrain::Routes.jobs_page_spec
  assert_equal "/admin/jobs", page.jobs_path
  assert_equal "require_admin", page.jobs_before_action
  source = Cybertrain::Gen::RoutesEmitter.emit(Cybertrain::Routes.specs)
  assert_includes source, "      router.add(\"POST\", \"/admin/jobs/:id/retry\", \"\") { |ctx| CybertrainJobsController.new(ctx).process(:retry) { |c| c.retry_action } }\n"
  refute source.include?("admin_jobs"), "the jobs routes are unnamed: no helpers"
end

test "jobs_page without before_action: records an open page" do
  Cybertrain::Routes.reset!
  assert_equal "", Cybertrain::Routes.jobs_page_spec.jobs_path
  Cybertrain::Routes.draw do
    jobs_page "/ops/queue"
  end
  page = Cybertrain::Routes.jobs_page_spec
  assert_equal "/ops/queue", page.jobs_path
  assert_equal "", page.jobs_before_action
  assert_equal 6, Cybertrain::Routes.specs.size
  assert_equal "/ops/queue/:id/delete", Cybertrain::Routes.specs.last.pattern
  Cybertrain::Routes.reset!
  assert_equal "", Cybertrain::Routes.jobs_page_spec.jobs_path
end

test "a second jobs_page raises naming the first path" do
  Cybertrain::Routes.reset!
  message = assert_raises("ArgumentError") do
    Cybertrain::Routes.draw do
      jobs_page "/admin/jobs"
      jobs_page "/ops/jobs"
    end
  end
  assert_equal "jobs_page \"/ops/jobs\": the jobs page is already drawn at \"/admin/jobs\" (one per application)", message
end

test "jobs_page refuses a path it cannot route and a before_action that is not a method name" do
  Cybertrain::Routes.reset!
  ["admin/jobs", "/", "/admin/jobs/", "/admin/:id", "/admin jobs"].each do |path|
    message = assert_raises("ArgumentError") do
      Cybertrain::Routes.draw do |r|
        r.jobs_page path
      end
    end
    assert_equal "jobs_page #{path.inspect}: the path must start with \"/\" and be literal segments of letters, digits, _ and -", message
  end
  message = assert_raises("ArgumentError") do
    Cybertrain::Routes.draw do
      jobs_page "/admin/jobs", before_action: "require admin"
    end
  end
  assert_equal "jobs_page \"/admin/jobs\": before_action: \"require admin\" is not a method name", message
  message = assert_raises("ArgumentError") do
    Cybertrain::Routes.draw do
      resources :posts do |posts|
        posts.jobs_page "/admin/jobs"
      end
    end
  end
  assert_equal "jobs_page must be used at the top of the routes, not inside resources", message
  Cybertrain::Routes.reset!
end

# --- namespace, scope, resource blocks, controller:, on:, param: --------

test "namespace prefixes path, helper and controller, and nests" do
  Cybertrain::Routes.reset!
  Cybertrain::Routes.draw do
    namespace :admin do |admin|
      admin.resources :articles, only: [:index, :destroy]
      admin.namespace :reports do |reports|
        reports.get "/daily", to: "daily#show"
      end
      admin.jobs_page "/jobs", before_action: :require_admin
    end
  end
  lines = route_lines(Cybertrain::Routes.specs)
  assert_includes lines, "GET /admin/articles admin/articles#index admin_articles"
  assert_includes lines, "DELETE /admin/articles/:id admin/articles#destroy admin_article"
  assert_includes lines, "GET /admin/reports/daily admin/reports/daily#show admin_reports_daily"
  assert_includes lines, "POST /admin/jobs/:id/retry cybertrain_jobs#retry"
  assert_equal "/admin/jobs", Cybertrain::Routes.jobs_page_spec.jobs_path
  assert_equal "Admin::ArticlesController", Cybertrain::Routes.specs[0].controller_class
  assert_equal "Admin::Reports::DailyController", Cybertrain::Routes.specs[2].controller_class
  assert_equal ["article"], Cybertrain::Routes.specs[1].helper_args
  source = Cybertrain::Gen::RoutesEmitter.emit(Cybertrain::Routes.specs)
  assert_includes source, %(      router.add("DELETE", "/admin/articles/:id", "admin_article") { |ctx| Admin::ArticlesController.new(ctx).process(:destroy) { |c| c.destroy } }\n)
  assert_includes source, "    def admin_article_path(article)\n      \"/admin/articles/\#{Cybertrain::Gen.segment(article)}\"\n    end\n"
  assert_includes source, "    def admin_reports_daily_path\n"
end

test "namespace draws root and a nested resource under its prefix" do
  Cybertrain::Routes.reset!
  Cybertrain::Routes.draw do
    namespace :admin do |admin|
      admin.root "dashboard#index"
      admin.resources :posts, only: [:show] do |posts|
        posts.resources :comments, only: [:index]
        posts.get "stats"
      end
      admin.get "/report", to: "reports#show", as: "report"
    end
    get "/about", to: "pages#about"
  end
  expected = [
    "GET /admin admin/dashboard#index admin_root",
    "GET /admin/posts/:post_id/comments admin/comments#index admin_post_comments",
    "GET /admin/posts/:post_id/stats admin/posts#stats admin_post_stats",
    "GET /admin/posts/:id admin/posts#show admin_post",
    "GET /admin/report admin/reports#show admin_report",
    "GET /about pages#about about"
  ]
  assert_equal expected, route_lines(Cybertrain::Routes.specs)
end

test "scope path, module and as each change one thing and combine" do
  Cybertrain::Routes.reset!
  Cybertrain::Routes.draw do
    scope("dashboard") { |s| s.get "/stats", to: "stats#index" }
    scope(module: "admin") { |s| s.resources :users, only: [:index] }
    scope(as: "admin") { |s| s.get "/stats", to: "stats#index" }
    scope("/x", module: "y", as: "z") { |s| s.get "/a", to: "p#a" }
  end
  expected = [
    "GET /dashboard/stats stats#index stats",
    "GET /users admin/users#index users",
    "GET /stats stats#index admin_stats",
    "GET /x/a y/p#a z_a"
  ]
  assert_equal expected, route_lines(Cybertrain::Routes.specs)
  assert_equal "Admin::UsersController", Cybertrain::Routes.specs[1].controller_class
end

test "a scope path with a dynamic segment gives the helpers an argument" do
  Cybertrain::Routes.reset!
  Cybertrain::Routes.draw do
    scope "/:locale" do |s|
      s.resources :posts, only: [:show]
    end
  end
  assert_equal ["GET /:locale/posts/:id posts#show post"], route_lines(Cybertrain::Routes.specs)
  assert_equal ["locale", "post"], Cybertrain::Routes.specs[0].helper_args
  source = Cybertrain::Gen::RoutesEmitter.emit(Cybertrain::Routes.specs)
  assert_includes source, "    def post_path(locale, post)\n"
end

test "resource takes controller: and a block with member routes and nested resources" do
  Cybertrain::Routes.reset!
  Cybertrain::Routes.draw do
    resource :session, controller: "auth/sessions" do |s|
      s.get :refresh, on: :member
      s.resource :settings, only: [:edit, :update]
      s.resources :devices, only: [:index]
    end
  end
  expected = [
    "GET /session/refresh auth/sessions#refresh refresh_session",
    "GET /session/settings/edit settings#edit edit_session_settings",
    "PATCH /session/settings settings#update session_settings",
    "PUT /session/settings settings#update",
    "GET /session/devices devices#index session_devices",
    "POST /session auth/sessions#create session",
    "GET /session/new auth/sessions#new new_session",
    "GET /session/edit auth/sessions#edit edit_session",
    "GET /session auth/sessions#show",
    "PATCH /session auth/sessions#update",
    "PUT /session auth/sessions#update",
    "DELETE /session auth/sessions#destroy"
  ]
  assert_equal expected, route_lines(Cybertrain::Routes.specs)
  assert_equal "Auth::SessionsController", Cybertrain::Routes.specs[0].controller_class
  source = Cybertrain::Gen::RoutesEmitter.emit(Cybertrain::Routes.specs)
  assert_includes source, "    def edit_session_settings_path\n      \"/session/settings/edit\"\n    end\n"
  assert_includes source, "    def session_devices_path\n"
end

test "resources controller: and param:" do
  Cybertrain::Routes.reset!
  Cybertrain::Routes.draw do
    resources :indicators, param: :key, controller: "metrics" do |i|
      i.resources :points, only: [:index]
    end
  end
  expected = [
    "GET /indicators/:indicator_key/points points#index indicator_points",
    "GET /indicators metrics#index indicators",
    "POST /indicators metrics#create",
    "GET /indicators/new metrics#new new_indicator",
    "GET /indicators/:key/edit metrics#edit edit_indicator",
    "GET /indicators/:key metrics#show indicator",
    "PATCH /indicators/:key metrics#update",
    "PUT /indicators/:key metrics#update",
    "DELETE /indicators/:key metrics#destroy"
  ]
  specs = Cybertrain::Routes.specs
  assert_equal expected, route_lines(specs)
  assert_equal ["indicator"], specs[0].helper_args
  assert_equal ["indicator"], specs[5].helper_args
  assert_equal "MetricsController", specs[5].controller_class
  source = Cybertrain::Gen::RoutesEmitter.emit(specs)
  assert_includes source, "    def indicator_points_path(indicator)\n      \"/indicators/\#{Cybertrain::Gen.segment(indicator)}/points\"\n    end\n"
  assert_includes source, "    def indicator_path(indicator)\n      \"/indicators/\#{Cybertrain::Gen.segment(indicator)}\"\n    end\n"
  assert_includes source, "      when \"edit_indicator_path\" then \"/indicators/\#{Cybertrain::Gen.segment(args[0])}/edit\"\n"
end

test "on: :collection and on: :member inside resources" do
  Cybertrain::Routes.reset!
  Cybertrain::Routes.draw do
    resources :posts, only: [:show] do |p|
      p.get :search, on: :collection
      p.post :publish, on: :member
    end
  end
  expected = [
    "GET /posts/search posts#search search_posts",
    "POST /posts/:id/publish posts#publish publish_post",
    "GET /posts/:id posts#show post"
  ]
  assert_equal expected, route_lines(Cybertrain::Routes.specs)
  assert_equal ["post"], Cybertrain::Routes.specs[1].helper_args
  assert_equal 0, Cybertrain::Routes.specs[0].helper_args.size
end

test "RouteSpec takes a format by default" do
  Cybertrain::Routes.reset!
  Cybertrain::Routes.draw { get "/about", to: "pages#about" }
  assert Cybertrain::Routes.specs[0].takes_format
end

test "misuse is refused with a message" do
  Cybertrain::Routes.reset!
  message = assert_raises("ArgumentError") do
    Cybertrain::Routes.draw do
      resources :posts do |posts|
        posts.namespace :admin do |admin|
          admin.get "/x", to: "x#y"
        end
      end
    end
  end
  assert_equal "namespace must be used outside resources", message
  Cybertrain::Routes.reset!
  message = assert_raises("ArgumentError") do
    Cybertrain::Routes.draw do
      resources :posts do |posts|
        posts.scope("/v1") { |s| s.get "/x", to: "x#y" }
      end
    end
  end
  assert_equal "scope must be used outside resources", message
  Cybertrain::Routes.reset!
  message = assert_raises("ArgumentError") do
    Cybertrain::Routes.draw do
      get :refresh, to: "sessions#refresh", on: :member
    end
  end
  assert_equal "on: :member must be used inside resources or resource", message
  Cybertrain::Routes.reset!
  message = assert_raises("ArgumentError") do
    Cybertrain::Routes.draw do
      resource :session do |s|
        s.get :recent, on: :collection
      end
    end
  end
  assert_equal "on: :collection must be used inside resources", message
  Cybertrain::Routes.reset!
  message = assert_raises("ArgumentError") do
    Cybertrain::Routes.draw do
      resources :posts do |posts|
        posts.get :recent, on: :new
      end
    end
  end
  assert_equal "on: must be :member or :collection (got :new)", message
  Cybertrain::Routes.reset!
  message = assert_raises("ArgumentError") do
    Cybertrain::Routes.draw do
      resources :indicators, param: "Key"
    end
  end
  assert_equal "param: must be a lowercase name (got \"Key\")", message
  Cybertrain::Routes.reset!
  message = assert_raises("ArgumentError") do
    Cybertrain::Routes.draw do
      jobs_page "/ops/jobs"
      namespace :admin do |admin|
        admin.jobs_page "/jobs"
      end
    end
  end
  assert_equal "jobs_page \"/admin/jobs\": the jobs page is already drawn at \"/ops/jobs\" (one per application)", message
  Cybertrain::Routes.reset!
end

Cybertrain::Test.run!
