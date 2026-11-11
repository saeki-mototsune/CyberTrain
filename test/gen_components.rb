require "tmpdir"
require "cybertrain/test"
require "cybertrain/generator/component_scan"
require "cybertrain/generator/components_emitter"

# Gen::ComponentScan reads app/components lexically; Gen::ComponentsEmitter
# writes gen/components.rb from it. Text only: CRuby-portable.
CARD = <<~'RUBY'
  class CardComponent < Cybertrain::Component
    def initialize(title:, value: 0)
      @title = title
      @value = value
    end

    def value_text = @value.to_s

    def title
      @title.to_s.upcase
    end

    def tone(x)
      x
    end

    private

    def secret = 1
  end
RUBY

def scan(source, rel = "card_component.rb")
  Cybertrain::Gen::ComponentScan.scan_source("app/components/#{rel}", rel, source)
end

def scan_error(source, rel = "card_component.rb")
  msg = ""
  begin
    scan(source, rel)
  rescue Cybertrain::Gen::ComponentScan::Error => e
    msg = e.message
  end
  msg
end

test "the scan finds the class, its ivars, view methods and keywords" do
  info = scan(CARD)
  assert_equal "CardComponent", info.class_name
  assert_equal "Cybertrain::Component", info.superclass_name
  assert_equal ["title", "value"], info.ivars
  assert_equal ["value_text", "title"], info.view_methods
  assert_equal ["title"], info.keywords_required
  assert_equal ["value"], info.keywords_optional
  assert_equal "__components/card_component.html.erb", info.template
  assert_equal "card", info.component_name
end

test "a class that is not a component is skipped, and so is ApplicationComponent" do
  assert_nil scan("class Card < Struct\nend\n")
  assert_nil scan("class ApplicationComponent < Cybertrain::Component\nend\n", "application_component.rb")
  assert_equal "ApplicationComponent", scan("class RowComponent < ApplicationComponent\nend\n").superclass_name
end

test "a positional initialize parameter is an error" do
  assert_equal "app/components/card_component.rb:2: component parameters must be keywords (render component: passes them by name)",
               scan_error("class CardComponent < Cybertrain::Component\n  def initialize(title, value: 0)\n  end\nend\n")
end

test "a content keyword or @content ivar is an error: content is the block's output" do
  assert_equal "app/components/card_component.rb:2: 'content' is reserved in a component (it is what the render block printed, Component#content); give the keyword another name",
               scan_error("class CardComponent < Cybertrain::Component\n  def initialize(title:, content: \"\")\n    @title = title\n  end\nend\n")
  assert_equal "app/components/card_component.rb:4: '@content' is reserved in a component (rendering sets it to what the render block printed, Component#content); give the instance variable another name",
               scan_error("class CardComponent < Cybertrain::Component\n  def initialize(body:)\n    @title = body\n    @content = body\n  end\nend\n")
  # On a continued line of the signature (a default that assigns), and in
  # ApplicationComponent, whose methods every child runs.
  assert_equal "app/components/card_component.rb:3: '@content' is reserved in a component (rendering sets it to what the render block printed, Component#content); give the instance variable another name",
               scan_error("class CardComponent < Cybertrain::Component\n  def initialize(\n    body: (@content = \"fallback\")\n  )\n    @title = body\n  end\nend\n")
  assert_equal "app/components/application_component.rb:3: '@content' is reserved in a component (rendering sets it to what the render block printed, Component#content); give the instance variable another name",
               scan_error("class ApplicationComponent < Cybertrain::Component\n  def fallback\n    @content = \"x\"\n  end\nend\n", "application_component.rb")
  assert_nil scan("class ApplicationComponent < Cybertrain::Component\n  def helper\n    @note = \"x\"\n  end\nend\n", "application_component.rb")
end

test "component names follow the class, namespaces included" do
  info = scan("module Admin\n  class UserRowComponent < Cybertrain::Component\n    def initialize(user:)\n      @user = user\n    end\n  end\nend\n", "admin/user_row_component.rb")
  assert_equal "Admin::UserRowComponent", info.class_name
  assert_equal "admin/user_row", info.component_name
  assert_equal "__components/admin/user_row_component.html.erb", info.template
  assert_equal "admin/user_row", scan("class Admin::UserRowComponent < Cybertrain::Component\nend\n").component_name
end

test "a component without its template is an error naming the expected path" do
  dir = Dir.mktmpdir("cybertrain-gen-components")
  File.write("#{dir}/card_component.rb", CARD)
  msg = ""
  begin
    Cybertrain::Gen::ComponentScan.scan_dir(dir)
  rescue Cybertrain::Gen::ComponentScan::Error => e
    msg = e.message
  end
  File.write("#{dir}/card_component.html.erb", "<%= title %>")
  found = Cybertrain::Gen::ComponentScan.scan_dir(dir)
  File.delete("#{dir}/card_component.rb")
  File.delete("#{dir}/card_component.html.erb")
  Dir.rmdir(dir)
  assert_equal "#{dir}/card_component.rb: no template; expected #{dir}/card_component.html.erb", msg
  assert_equal ["CardComponent"], found.map { |i| i.class_name }
end

test "two classes with the same component name are an error naming both files" do
  dir = Dir.mktmpdir("cybertrain-gen-components-twice")
  File.write("#{dir}/card_component.rb", "class CardComponent < Cybertrain::Component\nend\n")
  File.write("#{dir}/card_component.html.erb", "")
  File.write("#{dir}/zcard.rb", "class Card < Cybertrain::Component\nend\n")
  File.write("#{dir}/zcard.html.erb", "")
  msg = ""
  begin
    Cybertrain::Gen::ComponentScan.scan_dir(dir)
  rescue Cybertrain::Gen::ComponentScan::Error => e
    msg = e.message
  end
  ["card_component.rb", "card_component.html.erb", "zcard.rb", "zcard.html.erb"].each { |f| File.delete("#{dir}/#{f}") }
  Dir.rmdir(dir)
  assert_equal "component 'card' is defined twice: #{dir}/card_component.rb (CardComponent) and #{dir}/zcard.rb (Card)", msg
end

EXPECTED_CARD = <<~'RUBY'
  # Generated by `spin run gen` from app/components. Do not edit.

  class CardComponent < Cybertrain::Component
    def view_assigns
      { "value" => @value }
    end

    def call_view_method(name)
      case name
      when :value_text then value_text
      when :title then title
      else nil
      end
    end

    def view_method?(name)
      case name
      when "value_text", "title" then true
      else false
      end
    end

    def component_name
      "card"
    end

    def component_template
      "__components/card_component.html.erb"
    end
  end

  module Admin
    class BadgeComponent < ::ApplicationComponent
      def view_assigns
        super
      end

      def call_view_method(name)
        nil
      end

      def view_method?(name)
        false
      end

      def component_name
        "admin/badge"
      end

      def component_template
        "__components/admin/badge_component.html.erb"
      end
    end
  end

  module Gen
    module Components
      # kwargs: Hash<String, polymorphic> from the template.
      def self.build(name, kwargs)
        case name
        when "card"
          Cybertrain::Component.check_keywords!(name, kwargs, ["title", "value"], 1)
          if kwargs.key?("value") then ::CardComponent.new(title: kwargs["title"], value: kwargs["value"])
          else ::CardComponent.new(title: kwargs["title"])
          end
        when "admin/badge"
          Cybertrain::Component.check_keywords!(name, kwargs, Array.new(0) { "" }, 0)
          ::Admin::BadgeComponent.new
        else
          raise Cybertrain::Component::Unknown, "no component '#{name}' (app/components/#{name}_component.rb, then `spin run gen`)"
        end
      end
    end
  end

  Cybertrain::Views.component_builder = ->(name, kwargs) { Gen::Components.build(name, kwargs) }
RUBY

test "the emitter writes the per-class tables and the construction arms" do
  infos = [scan(CARD), scan("module Admin\n  class BadgeComponent < ApplicationComponent\n  end\nend\n", "admin/badge_component.rb")]
  assert_equal EXPECTED_CARD, Cybertrain::Gen::ComponentsEmitter.emit(infos)
end

test "two optional keywords give four arms, the most complete first" do
  info = scan("class TagComponent < Cybertrain::Component\n  def initialize(a: 1, b: 2)\n  end\nend\n", "tag_component.rb")
  source = Cybertrain::Gen::ComponentsEmitter.emit([info])
  arms = <<~'RUBY'
    if kwargs.key?("a") && kwargs.key?("b") then ::TagComponent.new(a: kwargs["a"], b: kwargs["b"])
    elsif kwargs.key?("a") then ::TagComponent.new(a: kwargs["a"])
    elsif kwargs.key?("b") then ::TagComponent.new(b: kwargs["b"])
    else ::TagComponent.new
    end
  RUBY
  assert_includes source, arms.lines.map { |l| "        #{l}" }.join
end

test "no components: build always raises" do
  assert_equal <<~'RUBY', Cybertrain::Gen::ComponentsEmitter.emit(Cybertrain::Gen::ComponentScan.scan_dir("/nonexistent/app/components"))
    # Generated by `spin run gen` from app/components. Do not edit.

    module Gen
      module Components
        # kwargs: Hash<String, polymorphic> from the template.
        def self.build(name, kwargs)
          raise Cybertrain::Component::Unknown, "no component '#{name}' (app/components/#{name}_component.rb, then `spin run gen`)"
        end
      end
    end

    Cybertrain::Views.component_builder = ->(name, kwargs) { Gen::Components.build(name, kwargs) }
  RUBY
end

test "a component named after its only required keyword gets with_collection and a collection: arm" do
  comment = scan("class CommentComponent < Cybertrain::Component\n  def initialize(comment:, comment_counter: 0)\n    @comment = comment\n  end\nend\n", "comment_component.rb")
  row = scan("module Admin\n  class RowComponent < ApplicationComponent\n    def initialize(row:)\n    end\n  end\nend\n", "admin/row_component.rb")
  source = Cybertrain::Gen::ComponentsEmitter.emit([comment, row])
  assert_includes source, <<~'RUBY'

      def self.with_collection(items)
        Cybertrain::ComponentCollection.new("comment", "comment", items, true)
      end
    end
  RUBY
  assert_includes source, <<~'RUBY'

        def self.with_collection(items)
          Cybertrain::ComponentCollection.new("admin/row", "row", items, false)
        end
      end
    end
  RUBY
  arm = <<~'RUBY'
    when "comment"
      return ::CommentComponent.with_collection(kwargs["collection"]) if kwargs.key?("collection")

      Cybertrain::Component.check_keywords!(name, kwargs, ["comment", "comment_counter"], 1)
  RUBY
  assert_includes source, arm.lines.map { |l| l == "\n" ? l : "      #{l}" }.join
  arm = <<~'RUBY'
    when "admin/row"
      return ::Admin::RowComponent.with_collection(kwargs["collection"]) if kwargs.key?("collection")

      Cybertrain::Component.check_keywords!(name, kwargs, ["row"], 1)
  RUBY
  assert_includes source, arm.lines.map { |l| l == "\n" ? l : "      #{l}" }.join
  # Not for a keyword named otherwise, a second required keyword, or none.
  card = Cybertrain::Gen::ComponentsEmitter.emit([scan(CARD)])
  refute card.include?("with_collection")
  pair = scan("class PairComponent < Cybertrain::Component\n  def initialize(pair:, other:)\n  end\nend\n", "pair_component.rb")
  refute Cybertrain::Gen::ComponentsEmitter.emit([pair]).include?("with_collection")
end

test "an app's own self.with_collection is an error: gen writes it" do
  source = "class CommentComponent < Cybertrain::Component\n  def initialize(comment:)\n  end\n\n  def self.with_collection(items)\n    items\n  end\nend\n"
  msg = scan_error(source, "comment_component.rb")
  assert_equal "app/components/comment_component.rb:5: 'self.with_collection' is written by `spin run gen` (gen/components.rb) for a component whose only required keyword is named after it; remove this definition (render component: \"x\", collection: items, or X.with_collection(items))", msg
  # Elsewhere, the name is just text.
  assert_equal "CommentComponent", scan("class CommentComponent < Cybertrain::Component\n  def note = \"self.with_collection\"\nend\n", "comment_component.rb").class_name
end

test "the output always ends with the component_builder line" do
  line = "Cybertrain::Views.component_builder = ->(name, kwargs) { Gen::Components.build(name, kwargs) }\n"
  assert Cybertrain::Gen::ComponentsEmitter.emit([scan(CARD)]).end_with?(line)
  assert Cybertrain::Gen::ComponentsEmitter.emit([]).end_with?(line)
end

Cybertrain::Test.run!
