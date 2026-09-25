# SPIKE (throwaway): symbol-form before_action with only:/except:, inheritance (superclass walk), private targets, halting via performed?
module Cybertrain
  class Callback
    attr_reader :name, :only, :except
    def initialize(name, only, except)
      @name = name
      @only = only
      @except = except
    end
    def applies?(action)
      return false if !@only.empty? && !@only.include?(action)
      return false if @except.include?(action)
      true
    end
  end

  class Controller
    CALLBACKS = {}   # class name => Array<Callback>

    def self.before_action(name, only: [], except: [])
      (CALLBACKS[self.name] ||= []) << Callback.new(name, only, except)
    end

    def self.callback_chain_for(klass)
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
    def run_callback(n); self.send(n); end
    def redirect_to(path); log << "redirect #{path}"; @performed = true; end

    def process(action)
      Controller.callback_chain_for(self.class).each do |cb|
        next unless cb.applies?(action)
        run_callback(cb.name)   # inline self.send(cb.name) -> compile error, see notes
        return log if performed?
      end
      self.send(action)
      log
    end
  end
end

class ApplicationController < Cybertrain::Controller
  before_action :authenticate
  private
  def authenticate; log << "app: authenticate (private)"; @user = "alice"; end
end

class PostsController < ApplicationController
  before_action :set_post, only: [:show, :edit]
  before_action :require_admin, except: [:index, :show]

  def index; log << "index user=#{@user} post=#{@post.inspect}"; end
  def show; log << "show user=#{@user} post=#{@post}"; end
  def edit; log << "edit (should not reach)"; end

  private
  def set_post; @post = "post#1"; end
  def require_admin; redirect_to "/login"; end
end

[:index, :show, :edit].each do |a|
  puts "-- #{a}"
  PostsController.new.process(a).each { |l| puts l }
end
p Cybertrain::Controller.callback_chain_for(PostsController).map { |c| c.name }
