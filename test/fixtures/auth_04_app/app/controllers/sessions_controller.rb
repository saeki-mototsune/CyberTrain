# Sign in and out (cybertrain generate authentication).
class SessionsController < ApplicationController
  allow_unauthenticated_access only: [:new, :create]
  # Ten sign-in attempts per client address every three minutes, then
  # back to the form until the window closes. Behind a reverse proxy on
  # this host, set CYBERTRAIN_TRUSTED_PROXY=1 so that each visitor is
  # counted rather than the proxy.
  rate_limit to: 10, within: 3 * 60, only: [:create],
             redirect_to: "/session/new", alert: "Try again later."

  # GET /session/new
  # (named new_action: a `new` method would shadow SessionsController.new)
  def new_action
  end

  # POST /session
  def create
    user = User.authenticate_by(email_address: params[:email_address].to_s, password: params[:password].to_s)
    if user.nil?
      flash[:alert] = "Try another email address or password."
      redirect_to new_session_path, status: :see_other
    else
      start_new_session_for(user)
      redirect_to after_authentication_url, status: :see_other
    end
  end

  # DELETE /session
  def destroy
    terminate_session
    flash[:notice] = "You have been signed out."
    redirect_to new_session_path, status: :see_other
  end
end
