# The compact form: gen/controllers.rb has already opened
# `module Admin; class UsersController < ::ApplicationController`, so
# module Admin exists by the time this file loads.
class Admin::UsersController < ApplicationController
  before_action :require_admin

  def index
    render plain: "admin users for #{@viewer} (#{@role}) #{admin_users_path}"
  end

  # resources :users, param: :login: the member segment is :login.
  def show
    login = params[:login].to_s
    render plain: "admin user #{login} (#{@role}) #{admin_user_path(login)}"
  end

  private

  def require_admin
    @role = "admin"
  end
end
