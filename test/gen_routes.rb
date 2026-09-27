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

# --- Inflector ---------------------------------------------------------

test "camelize turns snake_case into CamelCase" do
  assert_equal "PostsController", Cybertrain::Inflector.camelize("posts_controller")
  assert_equal "CreatePosts", Cybertrain::Inflector.camelize("create_posts")
  assert_equal "Post", Cybertrain::Inflector.camelize("post")
  assert_equal "Admin::Posts", Cybertrain::Inflector.camelize("admin/posts")
end

test "underscore turns CamelCase into snake_case" do
  assert_equal "posts_controller", Cybertrain::Inflector.underscore("PostsController")
  assert_equal "post", Cybertrain::Inflector.underscore("Post")
  assert_equal "html_parser", Cybertrain::Inflector.underscore("HTMLParser")
  assert_equal "admin/posts", Cybertrain::Inflector.underscore("Admin::Posts")
end

test "singularize applies irregulars, then suffix rules" do
  assert_equal "post", Cybertrain::Inflector.singularize("posts")
  assert_equal "comment", Cybertrain::Inflector.singularize("comments")
  assert_equal "person", Cybertrain::Inflector.singularize("people")
  assert_equal "category", Cybertrain::Inflector.singularize("categories")
  assert_equal "box", Cybertrain::Inflector.singularize("boxes")
  assert_equal "status", Cybertrain::Inflector.singularize("statuses")
  assert_equal "address", Cybertrain::Inflector.singularize("addresses")
  assert_equal "news", Cybertrain::Inflector.singularize("news")
  assert_equal "blog_post", Cybertrain::Inflector.singularize("blog_posts")
  assert_equal "sales_person", Cybertrain::Inflector.singularize("sales_people")
  assert_equal "post", Cybertrain::Inflector.singularize("post")
end

test "pluralize is the inverse" do
  assert_equal "posts", Cybertrain::Inflector.pluralize("post")
  assert_equal "people", Cybertrain::Inflector.pluralize("person")
  assert_equal "categories", Cybertrain::Inflector.pluralize("category")
  assert_equal "days", Cybertrain::Inflector.pluralize("day")
  assert_equal "boxes", Cybertrain::Inflector.pluralize("box")
  assert_equal "statuses", Cybertrain::Inflector.pluralize("status")
  assert_equal "addresses", Cybertrain::Inflector.pluralize("address")
  assert_equal "sheep", Cybertrain::Inflector.pluralize("sheep")
  assert_equal "blog_posts", Cybertrain::Inflector.pluralize("blog_post")
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

test "an uncountable resource names its collection <plural>_index" do
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

test "a duplicate route name raises" do
  Cybertrain::Routes.reset!
  message = assert_raises("ArgumentError") do
    Cybertrain::Routes.draw do
      get "/about", to: "pages#about"
      get "/about", to: "pages#other"
    end
  end
  assert_equal "route name 'about' is already in use (GET /about)", message
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

Cybertrain::Test.run!
