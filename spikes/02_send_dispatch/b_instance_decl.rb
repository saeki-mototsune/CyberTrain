# SPIKE (throwaway): alternative 2 - callbacks declared inside an instance method with literal blocks (self is already the controller; no instance_exec)
class Controller
  def log; @log ||= []; end
  def before_action(only: [], except: [])
    return if !only.empty? && !only.include?(@action)
    return if except.include?(@action)
    yield
  end
  def callbacks; end
  def process(action)
    @action = action
    callbacks
    self.send(action)
    log
  end
end
class ApplicationController < Controller
  def callbacks
    before_action { log << "app auth"; @user = "alice" }
  end
end
class PostsController < ApplicationController
  def callbacks
    super
    before_action(only: [:show]) { set_post }
    before_action { log << "posts: @post=#{@post.inspect}" }
  end
  def set_post; @post = "post#1"; end
  def show; log << "show #{@user} #{@post}"; end
  def index; log << "index #{@user} #{@post.inspect}"; end
end
[:show, :index].each { |a| PostsController.new.process(a).each { |l| puts l } }
