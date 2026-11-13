# Sign in and out (cybertrain generate authentication).
class SessionsController < ApplicationController
  allow_unauthenticated_access only: [:new, :create]
  # Ten sign-in attempts per client address every three minutes, then
  # back to the form (rate_limited) until the window closes. Behind a
  # reverse proxy on this host, set CYBERTRAIN_TRUSTED_PROXY=1 so that
  # each visitor is counted rather than the proxy.
  rate_limit to: 10, within: 3 * 60, only: [:create], with: :rate_limited

  # GET /session/new
  # (named new_action: a `new` method would shadow SessionsController.new)
  def new_action
  end

  # POST /session
  def create
    user = User.authenticate_by(email_address: params[:email_address].to_s, password: params[:password].to_s)
    if user.nil?
      flash[:alert] = t(".invalid")
      redirect_to new_session_path, status: :see_other
    else
      start_new_session_for(user, remember: params[:remember_me] == "1")
      redirect_to after_authentication_url, status: :see_other
    end
  end

  # DELETE /session
  def destroy
    terminate_session
    flash[:notice] = t(".signed_out")
    redirect_to new_session_path, status: :see_other
  end

  private

  # What a client past the rate limit gets: the form again, with a
  # message. Not an action, so its key is written in full (the
  # action it answers for is create).
  def rate_limited
    flash[:alert] = t("sessions.create.rate_limited")
    redirect_to new_session_path, status: :see_other
    nil
  end
end
