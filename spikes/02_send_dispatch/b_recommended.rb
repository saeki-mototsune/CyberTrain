# SPIKE (throwaway): recommended callback shape - class-level macros storing (a) Symbol names or (b) Procs taking the controller, with only:/except:, run from base process()
module Cybertrain
  class Callback
    attr_reader :name, :blk, :only, :except
    def initialize(name, blk, only, except)
      @name = name; @blk = blk; @only = only; @except = except
    end
    def applies?(action)
      return false if !@only.empty? && !@only.include?(action)
      !@except.include?(action)
    end
  end

  class Controller
    CALLBACKS = {}   # class name => Array<Callback>

    def self.before_action(name = nil, only: [], except: [], &blk)
      (CALLBACKS[self.name] ||= []) << Callback.new(name, blk, only, except)
    end

    # NOTE: take the class as an argument; self.class.inherited_cmethod binds self to the base (miscompile)
    def self.chain_for(klass)
      names = []
      k = klass
      while k
        names.unshift(k.name)
        break if k == Cybertrain::Controller
        k = k.superclass
      end
      out = []
      names.each { |n| (CALLBACKS[n] || []).each { |cb| out << cb } }
      out
    end

    def log; @log ||= []; end
    def performed?; @performed == true; end
    def redirect_to(path); log << "redirect #{path}"; @performed = true; end
    def run_symbol(n); self.send(n); end   # keep self.send in a 1-line helper

    def process(action)
      Controller.chain_for(self.class).each do |cb|
        next unless cb.applies?(action)
        if cb.name
          run_symbol(cb.name)
        else
          cb.blk.call(self)
        end
        return log if performed?
      end
      run_symbol(action)
      log
    end
  end
end

class ApplicationController < Cybertrain::Controller
  attr_accessor :user
  before_action :authenticate
  before_action { |c| c.log << "app block: user=#{c.user}" }
  private
  def authenticate; log << "authenticate"; @user = "alice"; end
end

class PostsController < ApplicationController
  attr_accessor :post
  before_action :set_post, only: [:show, :edit]
  before_action(only: [:show]) { |c| c.log << "show-only block sees post=#{c.post}" }
  before_action(except: [:index, :show]) { |c| c.redirect_to "/login" }

  def index; log << "index user=#{@user} post=#{@post.inspect}"; end
  def show;  log << "show user=#{@user} post=#{@post}"; end
  def edit;  log << "edit (must not reach)"; end
  private
  def set_post; @post = "post#1"; end
end

class CommentsController < ApplicationController
  def index; log << "comments#index user=#{@user}"; end
end

[:index, :show, :edit].each do |a|
  puts "-- posts##{a}"
  PostsController.new.process(a).each { |l| puts l }
end
puts "-- comments#index"
CommentsController.new.process(:index).each { |l| puts l }
