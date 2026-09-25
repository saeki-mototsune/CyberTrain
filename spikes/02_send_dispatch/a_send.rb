# SPIKE (throwaway): does non-literal self.send(sym) dispatch symbol-form callbacks declared by subclass macros, from a base-class method?
module Cybertrain
  class Controller
    CALLBACKS = {}   # class name => Array<Symbol>

    def self.before_action(name)
      CALLBACKS[self.name] ||= []
      CALLBACKS[self.name] << name
    end

    def self.callbacks_for(klass_name)
      CALLBACKS[klass_name] || []
    end

    def log
      @log ||= []
    end

    def run_callback(cb)
      self.send(cb)          # explicit self: required
    end

    def process(action)
      Controller.callbacks_for(self.class.name).each do |cb|
        r = self.send(cb)
        log << "cb #{cb} -> #{r.inspect} (#{r.class})"
        log << "  int+1=#{r + 1}" if r.is_a?(Integer)
        log << "  str.upcase=#{r.upcase}" if r.is_a?(String)
      end
      self.send(action)
      log
    end
  end
end

class ApplicationController < Cybertrain::Controller
  def authenticate; "auth ok"; end
end

class PostsController < ApplicationController
  before_action :authenticate
  before_action :set_post
  before_action :count_it

  def set_post
    @post = "post#1"
    42
  end

  def count_it
    "counted"
  end

  def show
    log << "show sees @post=#{@post}"
  end

  def post
    @post
  end
end

class CommentsController < ApplicationController
  before_action :load_comment
  def load_comment; @c = "c1"; nil; end
  def index; log << "index @c=#{@c}"; end
end

c = PostsController.new
c.process(:show).each { |l| puts l }
puts "post after: #{c.post}"
CommentsController.new.process(:index).each { |l| puts l }

# runtime-built symbol that is not a literal anywhere
bad = ["no", "such"].join("_").to_sym
begin
  c.run_callback(bad)
  puts "no error?!"
rescue NoMethodError => e
  puts "NoMethodError(runtime name): #{e.message}"
end

# a literal name that exists elsewhere (CommentsController#index) but not on PostsController
begin
  c.run_callback([:index, :load_comment][1])
  puts "no error?!"
rescue NoMethodError => e
  puts "NoMethodError(other class's method): #{e.message}"
end

# string name
p c.run_callback("count_it")
