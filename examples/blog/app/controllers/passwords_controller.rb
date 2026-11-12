# Password reset (cybertrain generate authentication): the form that asks
# for an address, the mail with a link (PasswordsMailer.reset), and the
# form behind the link that sets a new password. The link's token
# (User#password_reset_token) is signed, lasts 15 minutes and is bound to
# the password and the address, so it stops working once either changes,
# and every link sent before with it. The address form answers the same
# whether or not the address is registered.
class PasswordsController < ApplicationController
  allow_unauthenticated_access
  # Ten requests per client address every three minutes, as for signing in.
  rate_limit to: 10, within: 3 * 60, only: [:create], with: :rate_limited
  # The link's page carries the token in its address: no Referer for it.
  before_action :no_referrer, only: [:edit, :update]

  # GET /passwords/new
  def new_action
  end

  # POST /passwords
  # An address no user has gets the same answer after the same work (a
  # token, the mail rendered), short of queueing the mail.
  def create
    address = User.normalize_email_address(params[:email_address].to_s)
    user = User.find_by(email_address: address)
    token = user.nil? ? Cybertrain::Token.issue("password_reset", 1, 15 * 60, Cybertrain::Password.dummy_digest) : user.password_reset_token
    url = edit_password_url_for(token)
    unless url.empty?
      mail = PasswordsMailer.reset(user.nil? ? User.new(email_address: address) : user, url)
      queue_reset_mail(mail) unless user.nil?
    end
    flash[:notice] = t(".sent")
    redirect_to new_session_path, status: :see_other
  end

  # GET /passwords/:token/edit
  def edit
    @token = params[:token].to_s
    invalid_link if User.find_by_password_reset_token(@token).nil?
  end

  # PUT /passwords/:token
  # Sets the password, clears a lockout and ends every session of the
  # user (their Session rows): each browser signs in again, with the new
  # password.
  def update
    token = params[:token].to_s
    user = User.find_by_password_reset_token(token)
    if user.nil?
      invalid_link
    else
      user.password = params[:password].to_s
      user.password_confirmation = params[:password_confirmation].to_s
      if user.save
        user.clear_failed_attempts!
        Session.where(user_id: user.id).delete_all
        flash[:notice] = t(".updated")
        redirect_to new_session_path, status: :see_other
      else
        flash[:alert] = user.errors.full_messages.join(" ")
        redirect_to edit_password_path(token), status: :see_other
      end
    end
  end

  private

  # The link in the mail: mail_link_base (the Authentication concern's)
  # and the form's path; "" when there is no safe base, and then no mail
  # is sent.
  def edit_password_url_for(token)
    base = mail_link_base("password reset")
    return "" if base.empty?

    path = edit_password_path(token)
    base + path
  end

  # Queues the mail. An address the mailer refuses (a space or a
  # non-ASCII byte: Cybertrain::Mailer.check_address) is logged, and
  # the answer stays the one every other address gets.
  def queue_reset_mail(mail)
    mail.deliver_later
    nil
  rescue ArgumentError => e
    Cybertrain.logger.error("password reset mail not sent: #{e.message}")
    nil
  end

  # Browsers send no Referer from the link's page, whose address holds
  # the token.
  def no_referrer
    response.set_header("Referrer-Policy", "no-referrer")
    nil
  end

  # A token that is wrong, expired or spent: back to the address form.
  # Not an action, so its key is written in full (edit's).
  def invalid_link
    flash[:alert] = t("passwords.edit.invalid")
    redirect_to new_password_path, status: :see_other
    nil
  end

  # What a client past the rate limit gets (the key is create's).
  def rate_limited
    flash[:alert] = t("passwords.create.rate_limited")
    redirect_to new_password_path, status: :see_other
    nil
  end
end
