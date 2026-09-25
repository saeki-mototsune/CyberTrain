# SPIKE (throwaway): alternative 1 - class-level block callbacks that take the controller as an explicit arg, run via blk.call(self)
module Cybertrain
  class Controller
    CALLBACKS = {}   # class name => Array<Proc>
    def self.before_action(&blk)
      (CALLBACKS[self.name] ||= []) << blk
    end
    def log; @log ||= []; end
    def process(action)
      names = []
      k = self.class
      while k
        names.unshift(k.name)
        break if k.name == "Cybertrain::Controller"
        k = k.superclass
      end
      names.each { |n| (CALLBACKS[n] || []).each { |blk| blk.call(self) } }
      self.send(action)
      log
    end
  end
end

class ApplicationController < Cybertrain::Controller
  attr_accessor :user
  before_action { |c| c.log << "app: authenticate"; c.user = "alice" }
end

class PostsController < ApplicationController
  attr_accessor :post
  before_action { |c| c.set_post }
  before_action { |c| c.log << "posts: second, post=#{c.post}" }
  def set_post; @post = "post#1"; end
  def show; log << "show: user=#{@user} post=#{@post}"; end
end

class CommentsController < ApplicationController
  def index; log << "comments#index user=#{@user}"; end
end

PostsController.new.process(:show).each { |l| puts l }
CommentsController.new.process(:index).each { |l| puts l }
