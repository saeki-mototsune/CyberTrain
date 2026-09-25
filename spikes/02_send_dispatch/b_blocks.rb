# SPIKE (throwaway): block-form before_action stored per class, run later with instance_exec(&blk) from the base class
module Cybertrain
  class Controller
    CALLBACKS = {}   # class name => Array<Proc>

    def self.before_action(&blk)
      (CALLBACKS[self.name] ||= []) << blk
    end

    def self.chain_for(klass)
      names = []
      k = klass
      while k
        names.unshift(k.name)
        break if k.name == "Cybertrain::Controller"
        k = k.superclass
      end
      out = []
      names.each { |n| (CALLBACKS[n] || []).each { |b| out << b } }
      out
    end

    def log; @log ||= []; end

    def process(action)
      Controller.chain_for(self.class).each { |blk| instance_exec(&blk) }
      self.send(action)
      log
    end
  end
end

class ApplicationController < Cybertrain::Controller
  before_action { log << "app: authenticate"; @user = "alice" }
end

class PostsController < ApplicationController
  before_action { set_post }
  before_action { log << "posts: second, @post=#{@post}" }

  def set_post
    @post = "post#1"
  end

  def show
    log << "show: user=#{@user} post=#{@post}"
  end
end

PostsController.new.process(:show).each { |l| puts l }
