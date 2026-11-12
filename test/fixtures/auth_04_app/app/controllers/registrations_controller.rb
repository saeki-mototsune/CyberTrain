# Sign up (cybertrain generate authentication). Rails' generator has no
# sign-up page and expects the first user to be created in the console;
# cybertrain has no console, so this is how the first user gets in.
# Delete it (and its routes) for an invitation-only application.
class RegistrationsController < ApplicationController
  allow_unauthenticated_access only: [:new, :create]

  # GET /sign_up
  def new_action
    @user = User.new
  end

  # POST /sign_up
  def create
    fields = params.require(:user)
    @user = User.new(fields.permit(:email_address))
    @user.password = fields[:password].to_s
    @user.password_confirmation = fields[:password_confirmation].to_s
    if @user.save
      start_new_session_for(@user)
      flash[:notice] = "Welcome! You have signed up."
      redirect_to after_authentication_url, status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end
end
