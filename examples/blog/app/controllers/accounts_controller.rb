# The signed-in user's account (cybertrain generate authentication): a new
# email address, a new password, or both, each only with the current
# password; and the account deleted, also only with the password.
#
# Written by the generator; it is yours to change.
class AccountsController < ApplicationController
  # Ten changes or deletions per client address every three minutes, as for
  # signing in, and ten per user whatever the address (account_key): a
  # current password is guessed here no faster than there, from one
  # address or from many.
  rate_limit to: 10, within: 3 * 60, only: [:update, :destroy], with: :rate_limited
  rate_limit to: 10, within: 3 * 60, only: [:update, :destroy], by: :account_key, name: "user", with: :rate_limited
  before_action :set_user

  # GET /account/edit
  def edit
  end

  # PATCH/PUT /account
  # The current password first, for any change.
  # A new address takes effect at once.
  # A new password ends every other session of the user and starts this
  # browser's again (restart_sessions). A new password or address ends
  # every password reset link sent before (they are bound to both).
  def update
    fields = params.expect(user: [:current_password, :email_address, :password, :password_confirmation])
    digest = @user.password_digest
    if @user.authenticate(fields["current_password"].to_s)
      # What authenticate left saved: digest, or a new hash of the same
      # password when the cost was raised (User#authenticate).
      verified = @user.password_digest
      @user.email_address = fields["email_address"].to_s if fields.key?("email_address")
      password = fields["password"].to_s
      unless password.empty?
        @user.password = password
        @user.password_confirmation = fields["password_confirmation"].to_s
      end
      if @user.save
        restart_sessions if @user.password_digest != digest
        flash[:notice] = t(".updated")
        redirect_to edit_account_path, status: :see_other
      else
        # A new hash saved by authenticate stays: this browser's key
        # follows it, or the browser would be signed out next time.
        session[:password_key] = Cybertrain::Password.session_key(verified) if verified != digest
        render :edit, status: :unprocessable_entity
      end
    else
      flash.now[:alert] = t(".wrong_password")
      render :edit, status: :unprocessable_entity
    end
  end

  # DELETE /account
  # With the password: the user's sessions (every browser's) and the user
  # are deleted together, and this browser's cookie session is emptied.
  # When the database refuses (a row of another table still refers to
  # the user), nothing is deleted and the page says so.
  def destroy
    if @user.authenticate(params[:password].to_s)
      if delete_user_and_sessions
        terminate_session
        flash[:notice] = t(".deleted")
        redirect_to "/", status: :see_other
      else
        flash.now[:alert] = t(".not_deleted")
        render :edit, status: :unprocessable_entity
      end
    else
      flash.now[:alert] = t(".wrong_password")
      render :edit, status: :unprocessable_entity
    end
  end

  private

  # A copy of the signed-in user for the forms, so that a change that does
  # not pass leaves @current_user, which the nav shows, as it is.
  def set_user
    @user = User.find(@current_user.id)
  end

  # The second rate limit's key: the signed-in user's id
  # (require_authentication has run first).
  def account_key
    @current_user.id.to_s
  end

  # After a new password: every Session row of the user ends, the other
  # browsers' and this one's, and this browser signs in again at once with
  # the new password key, remembered ("keep me signed in") as it was.
  def restart_sessions
    current = @current_session
    remember = current.nil? ? false : current.remember
    Session.where(user_id: @user.id).delete_all
    start_new_session_for(@user, remember: remember)
    nil
  end

  # The user's Session rows and the user, in one transaction: true once
  # both are gone. When the database refuses the delete (a foreign key
  # from another table: give that association a `dependent:`), both
  # stay, so this browser stays signed in, and the log says why.
  def delete_user_and_sessions
    user = @user
    User.transaction do |c|
      Session.where(user_id: user.id).delete_all
      user.destroy
    end
    true
  rescue Cybertrain::DB::Error => e
    Cybertrain.logger.error("account not deleted: #{e.message}")
    false
  end

  # What a client past the rate limit gets (the key is update's).
  def rate_limited
    flash[:alert] = t("accounts.update.rate_limited")
    redirect_to edit_account_path, status: :see_other
    nil
  end
end
