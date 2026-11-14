# First-run setup (cybertrain generate authentication --invite-only):
# the form that creates the first user and signs them in. It answers
# only while no user exists, only with the one-time token the server
# prints at boot (/setup?token=..., carried back by the form in a
# hidden field), and only to a connection from this machine
# (request.loopback?, the socket's peer address) that did not come
# through a proxy (no X-Forwarded-For header). BLOG_SETUP_OPEN=1
# (config/app.rb) lifts the address check (never the token) while no
# user exists, for a first run behind a proxy on another host; unset
# it again afterwards. Anyone else gets a 404, as if there were no
# such page. Later users are created with `./blog user EMAIL`
# (app/commands/user_command.rb).
class SetupController < ApplicationController
  allow_unauthenticated_access only: [:new, :create]
  before_action :require_first_run

  # The one-time token: 32 random hex characters, made when the
  # program starts and the same until it exits (a restart makes a new
  # one). The address check alone is not enough: a proxy on this host
  # that adds no X-Forwarded-For makes every client a loopback one.
  # Printed only by the boot WARN line (UserCommand.warn_if_no_user) and
  # rendered only into the form's hidden field. A constant, which
  # Spinel keeps alive (a class variable it would not).
  SETUP_TOKEN = Cybertrain::Crypto.random_token(16)

  # The token /setup asks for: the boot warning prints it, the app's
  # test passes it.
  def self.setup_token
    SETUP_TOKEN
  end

  # GET /setup
  def new_action
    @user = User.new
  end

  # POST /setup
  def create
    fields = params.require(:user)
    @user = User.new(fields.permit(:email_address))
    @user.password = fields[:password].to_s
    @user.password_confirmation = fields[:password_confirmation].to_s
    # The no-user check and the insert are one write transaction
    # (BEGIN IMMEDIATE takes the lock first), so two requests that
    # both passed require_first_run cannot both create "the first"
    # account: the second finds a user and saves nothing.
    saved = false
    User.transaction(immediate: true) do |c|
      saved = @user.save unless User.all.exists?
    end
    if saved
      start_new_session_for(@user)
      flash[:notice] = t(".welcome")
      redirect_to "/", status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  # A missing or wrong token is the same 404 as the other refusals;
  # the comparison takes as long however much of it matched.
  def require_first_run
    @setup_token = params[:token].to_s
    head :not_found unless setup_open? && Cybertrain::Crypto.secure_compare(@setup_token, SetupController.setup_token)
    nil
  end

  # A header never opens the page; it can only close it: behind a proxy
  # on this host every request is a loopback one, and the proxy adds
  # X-Forwarded-For.
  def setup_open?
    return false if User.all.exists?
    return true if Cybertrain.config.bool_setting(:setup_open)

    request.loopback? && request.header("x-forwarded-for").nil?
  end
end
