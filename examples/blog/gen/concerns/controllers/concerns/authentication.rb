# Sign-in for the whole application (cybertrain generate authentication),
# as Rails 8's generator writes it: ApplicationController includes it, so
# every action needs a signed-in user unless its controller opens it with
# `allow_unauthenticated_access only: [:new, :create]`. resume_session
# sets @current_user (and @current_session), which templates can read;
# require_admin guards the pages only admins may see.
#
# Written by the generator; it is yours to change.
module Authentication
  extend ActiveSupport::Concern







  private

  # Whether this request has a signed-in user.
  def authenticated?
    !@current_user.nil?
  end

  # Loads the Session row the cookie names (and its user); an id with no
  # row is dropped, and an expired row is ended (destroyed, so no later
  # change of the limits revives it). Cookie Max-Age alone cannot stop
  # replay, so the row's own limits end a sign-in: session_limit(remember) seconds
  # after it started (SessionStore enforces the same on the cookie,
  # from the stamp start_new_session_for writes), and auth_idle_timeout
  # seconds (0: no limit) after its last request (last_active_at, or
  # created_at while it has none). A request touches last_active_at at
  # most once a minute. A cookie whose password key no longer matches
  # (the password changed since it signed in) ends its Session row.
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
    now = Time.current.to_i
    if created_at.nil? || created_at.to_i + session_limit(found.remember) <= now
      found.destroy
      session.delete(:session_id)
      return nil
    end
    last_active_at = found.last_active_at
    active = last_active_at.nil? ? created_at.to_i : last_active_at.to_i
    idle = Cybertrain.config.auth_idle_timeout
    if idle > 0 && active + idle <= now
      found.destroy
      session.delete(:session_id)
      return nil
    end
    user = found.user
    if user.nil? || !Cybertrain::Password.session_key_matches?(session[:password_key], user.password_digest)
      found.destroy
      session.delete(:session_id)
      return nil
    end
    found.update_columns(last_active_at: Time.current) if now - active >= 60
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

  # The before_action of the pages only admins may see: anyone but a
  # signed-in admin gets a 404, as if there were no such page. The user
  # command makes a user an admin (`user admin EMAIL`,
  # app/commands/user_command.rb). The jobs page (config/routes.rb)
  # names it with `skip_before_action: :require_authentication`, so it
  # runs alone there and a visitor gets the 404 too; in a controller
  # that declares `before_action :require_admin` itself,
  # require_authentication runs first and sends a visitor to sign in.
  def require_admin
    render plain: "Not Found", status: :not_found unless @current_user && @current_user.admin?
    nil
  end

  # Signs user in: a Session row (remembered or not, active now), its
  # id and the password key resume_session compares in the cookie, and
  # the cookie's lifetime, restarted and then stamped in that order (a
  # restart clears the stamp): session_limit(remember) seconds, with a
  # Max-Age when remembered ("keep me signed in"), else a cookie the
  # browser drops when it closes. After a password change, call
  # `session[:password_key] = Cybertrain::Password.session_key(user.password_digest)`
  # to keep the browser that changed it signed in.
  def start_new_session_for(user, remember: false)
    started = Session.create(user_id: user.id, ip_address: request.client_ip,
                             user_agent: request.header("user-agent").to_s,
                             remember: remember, last_active_at: Time.current)
    session.restart_lifetime!
    session.stamp_lifetime!(session_limit(remember), remember)
    session[:session_id] = started.id
    session[:password_key] = Cybertrain::Password.session_key(user.password_digest)
    @current_session = started
    @current_user = user
    nil
  end

  # How long a sign-in lasts in seconds, however often it is used:
  # auth_remember_for when remembered, else (or when that is not
  # positive) session_absolute_max_age, or with that off (0)
  # session_max_age, or two weeks when that is not positive either.
  # Never 0: a stamp of 0 would leave the cookie with no limit at all.
  def session_limit(remember)
    c = Cybertrain.config
    return c.auth_remember_for if remember && c.auth_remember_for > 0
    return c.session_absolute_max_age if c.session_absolute_max_age > 0
    return c.session_max_age if c.session_max_age > 0

    1_209_600
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

  # Where links in mails start ("https://shop.example.com"): the base_url
  # setting (BLOG_BASE_URL, config/app.rb) when set; else the address this
  # request came to, but only where the Host header is known to be
  # safe: the Host is checked (development, or CYBERTRAIN_HOSTS lists
  # the hosts the app answers to, so any other Host is refused before
  # an action runs), or the app runs its tests. In any other
  # environment (production, staging, ...) "" and an ERROR line: the
  # mail named `mail` is not sent, as a link built from a Host header
  # anyone can forge would carry its token to their site.
  def mail_link_base(mail)
    c = Cybertrain.config
    configured = c.string_setting(:base_url)
    return configured.delete_suffix("/") unless configured.empty?
    return request.base_url if c.host_check? || c.test?

    Cybertrain.logger.error("#{mail} mail not sent: set BLOG_BASE_URL (or CYBERTRAIN_HOSTS)")
    ""
  end
end

# Generated by `spin run gen` from app/controllers/concerns/authentication.rb. Do not edit.
