class ApplicationController < Cybertrain::Controller
  # ---- Authentication (cybertrain generate authentication) -------------
  # Every action needs a signed-in user unless its controller opens it:
  # `allow_unauthenticated_access only: [:new, :create]`. resume_session
  # sets @current_user (and @current_session), which templates can read.
  before_action :resume_session
  before_action :require_authentication

  def self.allow_unauthenticated_access(only: [], except: [])
    skip_before_action(:require_authentication, only: only, except: except)
  end

  # @return [Boolean] whether this request has a signed-in user
  def authenticated?
    !@current_user.nil?
  end

  # Loads the Session row the cookie names (and its user); a stale or
  # expired id is dropped. Cookie Max-Age alone cannot stop replay:
  # authentication expires session_absolute_max_age seconds after
  # sign-in (SessionStore enforces the same on the cookie). A cookie
  # whose password key no longer matches (the password changed since
  # it signed in) ends its Session row.
  def resume_session
    @current_session = nil
    @current_user = nil
    id = session[:session_id]
    return nil if id.nil? || id.empty? || id.size > 18

    found = Session.find_by(id: id.to_i)
    if found.nil?
      session.delete(:session_id)
      return nil
    end
    created_at = found.created_at
    lifetime = Cybertrain.config.session_absolute_max_age
    if created_at.nil? || (lifetime > 0 && created_at.to_i + lifetime <= Time.now.to_i)
      session.delete(:session_id)
      return nil
    end
    user = found.user
    if user.nil? || !Cybertrain::Password.session_key_matches?(session[:password_key], user.password_digest)
      found.destroy
      session.delete(:session_id)
      return nil
    end
    @current_session = found
    @current_user = user
    nil
  end

  # Sends a visitor to the sign-in page, remembering a GET to come back to.
  def require_authentication
    return nil if authenticated?

    session[:return_to_after_authenticating] = request.path if request.method == "GET"
    redirect_to new_session_path, status: :see_other
    nil
  end

  # Also stores the password key resume_session compares, and restarts
  # the cookie's absolute lifetime. After a password change, call
  # `session[:password_key] = Cybertrain::Password.session_key(user.password_digest)`
  # to keep the browser that changed it signed in.
  def start_new_session_for(user)
    started = Session.create(user_id: user.id, ip_address: request.client_ip,
                             user_agent: request.header("user-agent").to_s)
    session.restart_lifetime!
    session[:session_id] = started.id
    session[:password_key] = Cybertrain::Password.session_key(user.password_digest)
    @current_session = started
    @current_user = user
    nil
  end

  # Deletes the Session row and empties the cookie session (the CSRF
  # token with it, so forms rendered before no longer submit).
  def terminate_session
    current = @current_session
    current.destroy unless current.nil?
    session.clear
    @current_session = nil
    @current_user = nil
    nil
  end

  # Where to go after signing in: the page that asked for it, if it is a
  # local path (Cybertrain::Controller#safe_redirect_path), or /.
  def after_authentication_url
    safe_redirect_path(session.delete(:return_to_after_authenticating), "/")
  end
  # ---- end of authentication ------------------------------------------

  rescue_from Cybertrain::RecordNotFound, with: :record_not_found

  private

  def record_not_found
    render plain: "Not Found", status: :not_found
  end
end
