# Phase 5a spike, item 3 (spec sections 5.2 and 16): a hand-written program
# in the shape of Task 10's gen/tests.rb, over the class-form copies in
# gen_test/ (D18's rewritten shape, as Task 9 writes them under gen/test/),
# a top-level-form file, and gen_test/data.rb (Task 8's gen/test/data.rb).
# The stand-ins of Tasks 6, 8, 12 and 13 are spikes/phase5/standins/. A
# record, not a test.
#
# Run (Spinel 2026.11.04.7026, from spikes/phase5/class_app/; a shared
# 4-vCPU cloud machine):
#   spin run gen                       (builds bin/gen.rb, writes gen/; .gitignore'd)
#   mkdir -p build/test storage
#   spinel tests.rb $(spin flags) -I .. -I test -o build/test/tests && ./build/test/tests
# `-I ..` finds the stand-ins (spikes/phase5/standins/); SQLite is linked
# through FFI with no flag of its own. For gen/tests.rb, D7's command is
# `spinel gen/tests.rb $(spin flags) -I gen/test -I test -o build/test/tests`.
# Output (3 min 28 s to 4 min 21 s to compile):
#   == 20261112000000 CreateUsers: migrating
#   done
#   == 20261112000100 CreateArticles: migrating
#   done
#     ok   CardComponentTest: renders the title
#     ok   ArticlesControllerTest: shows an article
#     ok   ArticlesControllerTest: creates an article
#     ok   ArticlesControllerTest: head and delete answer the response
#     ok   the top-level form beside the classes
#   trail: setup,teardown | setup,teardown | setup,teardown
#   TestCase.setup: class-form tests run with `cybertrain test FILE`; `spin test` runs top-level-form files only
#   fixtures :articles: fixtures :all is the only form: every fixture is loaded for every test
#   fixtures :all: nil
#   User#articles beside the accessors: 3 (top-level articles(:two): Second)
#   articles(:three): No fixture named 'three' found for fixture set 'articles'
#   flatten_params: {"article[title]" => "x", "article[tags][a]" => "1"}
# Earlier runs, each an application matter rather than a Spinel one: a post
# answered 403 until config/app.rb set `c.csrf = false if c.test?` (Rails'
# test environment has forgery protection off); `render html:` with a
# String escapes it; `permit` answers a Hash with String keys.
# Verdict: PASS, no fallback (Rails' fixture accessor name, nested params:,
# IntegrationTest#assert_response beside the top-level one, `head` beside
# Controller#head, `delete` beside the other definers, D9's class methods
# beside the instance methods, render_inline in ViewComponent::TestCase).
ENV["CYBERTRAIN_ENV"] = "test"
ENV.delete("CYBERTRAIN_DATABASE")
require "cybertrain"
require "standins/test_case"
require_relative "config/app"
require_relative "gen/app"
require_relative "gen/migrations"
require_relative "gen_test/data"

class ActionDispatch::IntegrationTest
  include ::Gen::UrlHelpers
end

require_relative "test/test_helper"
require_relative "test/legacy_test"
require_relative "gen_test/components/card_component_test"
require_relative "gen_test/controllers/articles_controller_test"

module Gen
  module Tests
    CASE_CLASS = %w[CardComponentTest ArticlesControllerTest ArticlesControllerTest ArticlesControllerTest].freeze
    CASE_NAME = ["renders the title", "shows an article", "creates an article", "head and delete answer the response"].freeze

    def self.run_case(i)
      case i
      when 0
        t = CardComponentTest.new
        if Cybertrain::Test.before_case(t)
          Cybertrain::Test.run_body(t) { t.test_renders_the_title }
        end
        Cybertrain::Test.after_case(t)
      when 1
        t = ArticlesControllerTest.new
        if Cybertrain::Test.before_case(t)
          Cybertrain::Test.run_body(t) { t.test_shows_an_article }
        end
        Cybertrain::Test.after_case(t)
      when 2
        t = ArticlesControllerTest.new
        if Cybertrain::Test.before_case(t)
          Cybertrain::Test.run_body(t) { t.test_creates_an_article }
        end
        Cybertrain::Test.after_case(t)
      when 3
        t = ArticlesControllerTest.new
        if Cybertrain::Test.before_case(t)
          Cybertrain::Test.run_body(t) { t.test_head_and_delete_answer_the_response }
        end
        Cybertrain::Test.after_case(t)
      end
      nil
    end

    def self.dispatcher = ->(i) { run_case(i) }
  end
end

def boot_spike_app
  path = Cybertrain.config.database_path
  [path, "#{path}-wal", "#{path}-shm"].each { |f| File.delete(f) if File.exist?(f) }
  connection = Cybertrain::DB::Connection.new(path)
  Cybertrain::DB::Migrator.new(connection).migrate(Cybertrain::Migration.all)
  connection.close
  app = Cybertrain::Application.new(router: Gen::Routes.build(Cybertrain::Router.new), url_resolver: Gen::Routes.url_resolver)
  app.boot
  Cybertrain::Test.app = app
  nil
end

def report(label)
  puts "  #{Cybertrain::Test.last_status.ljust(4)} #{label}"
  puts "         #{Cybertrain::Test.last_message}" unless Cybertrain::Test.last_status == "ok"
end

boot_spike_app
Cybertrain::Test.before_each_bundled(Gen::TestData.reset_hook)
dispatch = Gen::Tests.dispatcher
Gen::Tests::CASE_CLASS.each_with_index do |klass, i|
  dispatch.call(i)
  report("#{klass}: #{Gen::Tests::CASE_NAME[i]}")
end
Cybertrain::Test.top_level_cases.each do |c|
  t = Cybertrain::Test::Base.new
  if Cybertrain::Test.before_case(t)
    Cybertrain::Test.run_body(t) { c.block.call }
  end
  Cybertrain::Test.after_case(t)
  report(c.name)
end
puts "trail: #{TRAIL.join(" | ")}"

# D9: the class methods beside the instance methods of the same name.
begin
  ActiveSupport::TestCase.setup
rescue ArgumentError => e
  puts "TestCase.setup: #{e.message}"
end
begin
  ActiveSupport::TestCase.fixtures(:articles)
rescue ArgumentError => e
  puts "fixtures :articles: #{e.message}"
end
puts "fixtures :all: #{ActiveSupport::TestCase.fixtures(:all).inspect}"

# The names beside their namesakes, reached outside a test class.
puts "User#articles beside the accessors: #{User.first.articles.count} (top-level articles(:two): #{articles(:two).title})"
begin
  articles(:three)
rescue ArgumentError => e
  puts "articles(:three): #{e.message}"
end
puts "flatten_params: #{Cybertrain::Test.flatten_params({ article: { title: "x", tags: { a: "1" } } }).inspect}"
