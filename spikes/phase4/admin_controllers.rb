# Phase 4a spike, item 2 (spec section 12): namespaced controllers in both
# spellings, instantiated from route handlers written the way gen/routes.rb
# writes them, and a generated path helper taking braceless keywords into a
# trailing positional `options = {}` (plan decision 13). A record, not a
# test.
#
# Run (Spinel 2026.11.04.7026, from spikes/phase4/; cybertrain/controller
# links SQLite through FFI, so compiled only):
#   spinel $(spin flags) admin_controllers.rb -o /tmp/admin_controllers && /tmp/admin_controllers
# Output (what Rails answers for the same controllers and calls; 57 s to
# compile):
#   /admin/articles: 200 [Admin::ArticlesController] Admin::ArticlesController admin/articles index
#   /admin/articles/3: 200 [Admin::ArticlesController] Admin::ArticlesController admin/articles show 3
#   /admin/reports: 200 [Admin::ReportsController] Admin::ReportsController admin/reports index
#   /admin/articles/3.json?page=2
#   /admin/articles/3?page=2
#   /admin/articles/3
#   /admin/articles/5.csv
#   ancestors: Admin::ReportsController ApplicationController Cybertrain::Controller
require "cybertrain"
require "cybertrain/test/client"
require "cybertrain/generator/url_support"

class ApplicationController < Cybertrain::Controller
  before_action :stamp

  def stamp
    response.set_header("X-Stamp", self.class.name)
  end

  def run_callback(name)
    case name
    when :stamp then stamp
    else super
    end
  end
end

# The nested form.
module Admin
  class ArticlesController < ApplicationController
    def index
      render plain: "#{self.class.name} #{controller_path} index"
    end

    def show
      render plain: "#{self.class.name} #{controller_path} show #{params[:id]}"
    end
  end
end

# The compact form, after `module Admin` exists.
class Admin::ReportsController < ApplicationController
  def index
    render plain: "#{self.class.name} #{controller_path} index"
  end
end

# A record for the path helper (anything answering to_param).
class Article
  def initialize(id)
    @id = id
  end

  def to_param
    @id.to_s
  end
end

module Gen
  module Routes
    def self.build(router)
      router.add("GET", "/admin/articles", "admin_articles") { |ctx| Admin::ArticlesController.new(ctx).process(:index) { |c| c.index } }
      router.add("GET", "/admin/articles/:id", "admin_article") { |ctx| Admin::ArticlesController.new(ctx).process(:show) { |c| c.show } }
      router.add("GET", "/admin/reports", "admin_reports") { |ctx| Admin::ReportsController.new(ctx).process(:index) { |c| c.index } }
      router
    end
  end

  module UrlHelpers
    # The shape of plan decisions 13 and 14: format before the query, keys
    # in the order given.
    def admin_article_path(article, options = {})
      path = "/admin/articles/#{Cybertrain::Gen.segment(article)}"
      format = options[:format]
      path = "#{path}.#{format}" unless format.nil?
      query = []
      options.each do |key, value|
        next if key == :format || value.nil?

        query << "#{key}=#{value}"
      end
      query.empty? ? path : "#{path}?#{query.join("&")}"
    end
  end
end

include Gen::UrlHelpers

Cybertrain.logger = Cybertrain::Logger.new(nil, :error)
client = Cybertrain::Test::Client.new(Cybertrain::App.new(Gen::Routes.build(Cybertrain::Router.new), logging: false))
["/admin/articles", "/admin/articles/3", "/admin/reports"].each do |path|
  res = client.get(path)
  puts "#{path}: #{res.status} [#{res.header("x-stamp")}] #{res.body}"
end
a = Article.new(3)
puts admin_article_path(a, page: 2, format: :json)
puts admin_article_path(a, page: 2)
puts admin_article_path(a)
puts admin_article_path(5, format: :csv)
puts "ancestors: #{Admin::ReportsController.ancestors.take(3).map { |k| k.name }.join(" ")}"
