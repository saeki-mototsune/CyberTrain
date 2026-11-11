# Phase 4a spike, item 1 (spec section 12): `respond_to` with blocks. A
# record, not a test.
#
# Two collectors, each used from two controllers whose `json` blocks render
# different things from their own instance variables and whose `html` arm
# is blockless (the implicit render then draws the template):
#
# - Cybertrain::FormatCollector (the framework class of plan decision 6):
#   one class for every controller; each arm runs its block at once when it
#   matches the format the collector was built with and no arm matched
#   before, so no block is ever stored.
# - ArticlesFormats / CommentsFormats: what gen would write per controller
#   if the immediate one failed: the arms store their blocks in ivars and
#   `run` calls the matching one after the `respond_to` block has returned.
#
# `turbo_stream` is defined on three receivers with three return types: the
# collector's arm (nil), ArticlesController#turbo_stream (a TurboStreams,
# called inside that arm's block) and TemplateContext#turbo_stream (a
# TurboTags, standing in for the template builder) - one name, three
# return types, against rule 34's "same name, same return type".
#
# Run (Spinel 2026.11.04.7026, from spikes/phase4/; cybertrain/controller
# links SQLite through FFI, so compiled only):
#   spinel $(spin flags) respond_to.rb -o /tmp/respond_to && /tmp/respond_to
# Output (72 s to compile; each line checked by hand against what Rails
# answers for the same controllers):
#   immediate articles json: 200 application/json; charset=utf-8 {"id":7,"title":"Spike"}
#   immediate articles html: 200 text/html; charset=utf-8 <h1>Spike</h1>
#   immediate comments json: 200 application/json; charset=utf-8 ["first","second"]
#   immediate comments html: 200 text/html; charset=utf-8 <ul>first,second</ul>
#   immediate any: 200 text/plain; charset=utf-8 any arm (xml)
#   immediate turbo_stream: 200 text/vnd.turbo-stream.html <turbo-stream action="replace" target="article_7"><template><h1>Spike</h1></template></turbo-stream>
#   immediate turbo html: 200 text/html; charset=utf-8 <h1>Spike</h1>
#   template turbo_stream: <tag replace article_7>
#   immediate unmatched: 406
#   stored articles json: 200 application/json; charset=utf-8 {"id":7,"title":"Spike"}
#   stored articles html: 200 text/html; charset=utf-8 <h1>Spike</h1>
#   stored comments json: 200 application/json; charset=utf-8 ["first","second"]
#   stored comments html: 200 text/html; charset=utf-8 <ul>first,second</ul>
#   ran: articles.json comments.json articles.json comments.json
require "cybertrain"
require "cybertrain/test/client"

module Cybertrain
  # The immediate collector. `@format` is known before the action runs (it
  # comes from the request), so the first matching arm runs as it is
  # declared.
  class FormatCollector
    def initialize(format)
      @format = format
      @matched = false
    end

    def matched?
      @matched
    end

    def html(&block)
      arm(:html, block)
    end

    def json(&block)
      arm(:json, block)
    end

    def turbo_stream(&block)
      arm(:turbo_stream, block)
    end

    # Matches whatever format arrived, if no arm before it did.
    def any(&block)
      arm(@format, block)
    end

    def arm(format, block)
      return nil if @matched
      return nil unless format == @format

      @matched = true
      block&.call
      nil
    end
  end

  class Controller
    # :json when the Accept header asks for JSON, :xml for XML (to reach
    # `any`), else :html: the spike's stand-in for request.format.
    def spike_format
      accept = request.header("accept").to_s
      return :turbo_stream if accept.include?("text/vnd.turbo-stream.html")
      return :json if accept.include?("application/json")
      return :xml if accept.include?("application/xml")

      :html
    end

    def respond_to(&block)
      collector = FormatCollector.new(spike_format)
      block.call(collector)
      head :not_acceptable unless collector.matched?
      nil
    end
  end
end

RAN = []

# `turbo_stream` on three receivers (controller ruling 4): the collector's
# arm (nil, above), the controller's builder (a TurboStreams) and a
# template builder's (a TurboTags).
class TurboStreams
  def initialize
    @parts = []
  end

  def replace(target, html)
    @parts << "<turbo-stream action=\"replace\" target=\"#{target}\"><template>#{html}</template></turbo-stream>"
    self
  end

  def to_html
    @parts.join("\n")
  end
end

class TurboTags
  def initialize(prefix)
    @prefix = prefix
  end

  def replace(target)
    "<#{@prefix} replace #{target}>"
  end
end

class TemplateContext
  def turbo_stream
    TurboTags.new("tag")
  end
end

class ApplicationController < Cybertrain::Controller
end

class ArticlesController < ApplicationController
  def show
    @id = 7
    @title = "Spike"
    respond_to do |format|
      format.html
      format.json do
        RAN << "articles.json"
        render json: { "id" => @id, "title" => @title }
      end
    end
  end

  def show_any
    @title = "Spike"
    respond_to do |format|
      format.html
      format.any { render plain: "any arm (#{spike_format})" }
    end
  end

  def turbo_stream
    TurboStreams.new
  end

  def show_turbo
    @title = "Spike"
    respond_to do |format|
      format.html
      format.turbo_stream do
        render plain: turbo_stream.replace("article_7", "<h1>#{@title}</h1>").to_html, content_type: "text/vnd.turbo-stream.html"
      end
    end
  end

  def show_unmatched
    respond_to do |format|
      format.turbo_stream { render plain: "never" }
    end
  end

  # What gen/controllers.rb would write if the immediate collector failed.
  def show_stored
    @id = 7
    @title = "Spike"
    respond_to_stored do |format|
      format.html
      format.json do
        RAN << "articles.json"
        render json: { "id" => @id, "title" => @title }
      end
    end
  end

  def respond_to_stored(&block)
    collector = ArticlesFormats.new
    block.call(collector)
    head :not_acceptable unless collector.run(spike_format)
    nil
  end

  def view_assigns
    { "title" => @title }
  end
end

class CommentsController < ApplicationController
  def show
    @comments = ["first", "second"]
    respond_to do |format|
      format.html
      format.json do
        RAN << "comments.json"
        render json: @comments
      end
    end
  end

  def show_stored
    @comments = ["first", "second"]
    respond_to_stored do |format|
      format.html
      format.json do
        RAN << "comments.json"
        render json: @comments
      end
    end
  end

  def respond_to_stored(&block)
    collector = CommentsFormats.new
    block.call(collector)
    head :not_acceptable unless collector.run(spike_format)
    nil
  end

  def view_assigns
    { "comments" => @comments }
  end
end

# The storing collectors, one per controller (generated). An arm declared
# without a block is remembered as declared; run answers whether an arm
# matched.
class ArticlesFormats
  def initialize
    @html = false
    @html_block = nil
    @json = false
    @json_block = nil
  end

  def html(&block)
    @html = true
    @html_block = block
    nil
  end

  def json(&block)
    @json = true
    @json_block = block
    nil
  end

  def run(format)
    if format == :html && @html
      b = @html_block
      b&.call
      return true
    end
    if format == :json && @json
      b = @json_block
      b&.call
      return true
    end
    false
  end
end

class CommentsFormats
  def initialize
    @html = false
    @html_block = nil
    @json = false
    @json_block = nil
  end

  def html(&block)
    @html = true
    @html_block = block
    nil
  end

  def json(&block)
    @json = true
    @json_block = block
    nil
  end

  def run(format)
    if format == :html && @html
      b = @html_block
      b&.call
      return true
    end
    if format == :json && @json
      b = @json_block
      b&.call
      return true
    end
    false
  end
end

Cybertrain.logger = Cybertrain::Logger.new(nil, :error)
Cybertrain::Views.configure_embedded({
  "articles/show.html.erb" => "<h1><%= @title %></h1>",
  "articles/show_any.html.erb" => "<h1><%= @title %></h1>",
  "articles/show_turbo.html.erb" => "<h1><%= @title %></h1>",
  "articles/show_stored.html.erb" => "<h1><%= @title %></h1>",
  "comments/show.html.erb" => "<ul><%= @comments.join(\",\") %></ul>",
  "comments/show_stored.html.erb" => "<ul><%= @comments.join(\",\") %></ul>"
})

# Built the way gen/routes.rb builds a router.
module Gen
  module Routes
    def self.build(router)
      router.add("GET", "/articles/7", "") { |ctx| ArticlesController.new(ctx).process(:show) { |c| c.show } }
      router.add("GET", "/articles/7/any", "") { |ctx| ArticlesController.new(ctx).process(:show_any) { |c| c.show_any } }
      router.add("GET", "/articles/7/turbo", "") { |ctx| ArticlesController.new(ctx).process(:show_turbo) { |c| c.show_turbo } }
      router.add("GET", "/articles/7/unmatched", "") { |ctx| ArticlesController.new(ctx).process(:show_unmatched) { |c| c.show_unmatched } }
      router.add("GET", "/articles/7/stored", "") { |ctx| ArticlesController.new(ctx).process(:show_stored) { |c| c.show_stored } }
      router.add("GET", "/comments", "") { |ctx| CommentsController.new(ctx).process(:show) { |c| c.show } }
      router.add("GET", "/comments/stored", "") { |ctx| CommentsController.new(ctx).process(:show_stored) { |c| c.show_stored } }
      router
    end
  end
end

client = Cybertrain::Test::Client.new(Cybertrain::App.new(Gen::Routes.build(Cybertrain::Router.new), logging: false))
JSON_ACCEPT = { "Accept" => "application/json" }

def line(label, res)
  puts "#{label}: #{res.status} #{res.header("content-type")} #{res.body}".rstrip
end

line("immediate articles json", client.get("/articles/7", JSON_ACCEPT))
line("immediate articles html", client.get("/articles/7"))
line("immediate comments json", client.get("/comments", JSON_ACCEPT))
line("immediate comments html", client.get("/comments"))
line("immediate any", client.get("/articles/7/any", { "Accept" => "application/xml" }))
line("immediate turbo_stream", client.get("/articles/7/turbo", { "Accept" => "text/vnd.turbo-stream.html, text/html" }))
line("immediate turbo html", client.get("/articles/7/turbo"))
puts "template turbo_stream: #{TemplateContext.new.turbo_stream.replace("article_7")}"
puts "immediate unmatched: #{client.get("/articles/7/unmatched").status}"
line("stored articles json", client.get("/articles/7/stored", JSON_ACCEPT))
line("stored articles html", client.get("/articles/7/stored"))
line("stored comments json", client.get("/comments/stored", JSON_ACCEPT))
line("stored comments html", client.get("/comments/stored"))
puts "ran: #{RAN.join(" ")}"
