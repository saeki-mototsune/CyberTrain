# Phase 5a spike: minimal stand-ins of Task 6's lifecycle and base classes,
# Task 8's database steps, Task 12's ActionDispatch::IntegrationTest and
# Task 13's render_inline / ViewComponent::TestCase, written only far enough
# to compile spec section 5.2's program (class_app/tests.rb). A record, not
# the framework's code.
require "cybertrain/test"
require "cybertrain/test/client"
require "cybertrain/test/views"
require "standins/clock"

module Cybertrain
  module Test
    # D9: the class methods a class-form file reaches only when it was not
    # rewritten, beside the instance methods of the same name.
    class Base
      NOT_REWRITTEN = "class-form tests run with `cybertrain test FILE`; `spin test` runs top-level-form files only"

      def self.test(name)
        raise ArgumentError, NOT_REWRITTEN
      end

      def self.setup
        raise ArgumentError, NOT_REWRITTEN
      end

      def self.teardown
        raise ArgumentError, NOT_REWRITTEN
      end

      def setup = nil
      def teardown = nil
    end

    @app = nil
    @status = ""
    @message = ""
    @last_html = ""
    @before_each = Array.new(0) { -> { nil } }

    # The top-level form's registered cases (cybertrain/test.rb's @cases).
    def self.top_level_cases = @cases

    def self.app = @app
    def self.app=(app)
      @app = app
    end

    def self.last_status = @status
    def self.last_message = @message
    def self.last_html = @last_html
    def self.last_html=(html)
      @last_html = html
    end

    # D3 steps 1-2 (the bundle registers the clear and the fixture load).
    def self.before_each_bundled(callable)
      @before_each << callable
      nil
    end

    # D3 steps 1-4. False when one of them raised (the case is ERR).
    def self.before_case(t)
      @status = ""
      @message = ""
      begin
        @before_each.each(&:call)
        t.setup
        true
      rescue StandardError => e
        @status = "ERR"
        text = "in setup: #{e.class.name}: #{e.message}"
        @message = text
        false
      end
    end

    # D3 step 5.
    def self.run_body(t)
      begin
        yield
        @status = "ok"
      rescue AssertionFailed => e
        @status = "FAIL"
        @message = e.message
      rescue StandardError => e
        @status = "ERR"
        text = "#{e.class.name}: #{e.message}"
        @message = text
      end
      nil
    end

    # D3 steps 6-7: a plain method's ensure, never a yielding one.
    def self.after_case(t)
      t.teardown
      nil
    rescue StandardError => e
      @status = "ERR"
      text = "in teardown: #{e.class.name}: #{e.message}"
      @message = text
      nil
    ensure
      Cybertrain::Clock.travel_back
    end

    # Task 12: nested params: to the bracketed keys Client#post sends.
    def self.flatten_params(params)
      out = { "" => "" }
      out.delete("")
      flatten_into(out, "", params)
      out
    end

    def self.flatten_into(out, prefix, params)
      params.each do |k, v|
        key = prefix == "" ? k.to_s : "#{prefix}[#{k}]"
        case v
        when Hash then flatten_into(out, key, v)
        else out[key] = v.to_s
        end
      end
      nil
    end

    # R17: one helper per assertion, called by the instance form and the
    # top-level form alike.
    def self.check_response(response, expected)
      count_assertion
      status = response.status
      case expected
      when Integer
        flunk("expected response #{expected}, got #{status}") unless status == expected
      else
        range = Client.status_range(expected)
        unless status >= range[0] && status <= range[1]
          flunk("expected response #{expected.inspect}, got #{status}")
        end
      end
      nil
    end
  end
end

module ActiveSupport
  class TestCase < Cybertrain::Test::Base
    def self.fixtures(name)
      raise ArgumentError, "fixtures :all is the only form: every fixture is loaded for every test" unless name == :all

      nil
    end
  end
end

module ActionDispatch
  class IntegrationTest < ActiveSupport::TestCase
    def initialize
      @client = Cybertrain::Test::Client.new(Cybertrain::Test.app)
    end

    def get(path, params: {}, headers: {})
      query = Cybertrain::Test.flatten_params(params)
      target = query.empty? ? path : "#{path}?#{Cybertrain::Query.encode(query)}"
      keep(@client.get(target, headers))
    end

    def post(path, params: {}, headers: {})
      keep(@client.post(path, Cybertrain::Test.flatten_params(params), headers))
    end

    def delete(path, params: {}, headers: {})
      keep(@client.delete(path, Cybertrain::Test.flatten_params(params), headers))
    end

    def head(path, params: {}, headers: {})
      keep(@client.request("HEAD", path, "", headers))
    end

    def follow_redirect! = keep(@client.follow_redirect!)
    def response = @client.response

    def assert_response(expected)
      Cybertrain::Test.check_response(@client.response, expected)
    end

    private

    def keep(res)
      Cybertrain::Test.last_html = res.body
      res
    end
  end
end

module ViewComponent
  class TestCase < ActiveSupport::TestCase
  end
end

# Task 13: one method for both forms (rule 34).
def render_inline(component = nil, content: "", partial: "", locals: {})
  html = partial == "" ? Cybertrain::Views.render_component(component, content).to_s : Cybertrain::Views.render_partial(partial, locals).to_s
  Cybertrain::Test.last_html = html
  html
end
