# Signs a browser in to the jobs page: the retry, discard and delete
# buttons there are forms, which a browser submits without an
# x-admin-token header, so it carries the admin session instead
# (ApplicationController#require_admin).
class AdminSessionsController < ApplicationController
  # GET /admin/login: the form; 404 while BLOG_ADMIN_TOKEN is unset or empty
  # (named new_action: a `new` method would shadow AdminSessionsController.new)
  def new_action
    render plain: "Not Found", status: :not_found if admin_token.empty?
    nil
  end

  # POST /admin/login
  # 404 when BLOG_ADMIN_TOKEN is unset or empty, or the posted token is not
  # it; otherwise the session is marked admin for this token.
  def create
    token = admin_token
    if token.empty? || !Cybertrain::Crypto.secure_compare(params[:token].to_s, token)
      render plain: "Not Found", status: :not_found
      return
    end
    session["admin"] = admin_session_value(token)
    redirect_to "/admin/jobs", status: :see_other
  end
end
