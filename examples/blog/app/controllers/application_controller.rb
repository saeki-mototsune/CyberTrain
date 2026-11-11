class ApplicationController < Cybertrain::Controller
  rescue_from Cybertrain::RecordNotFound, with: :record_not_found

  private

  def record_not_found
    render plain: "Not Found", status: :not_found
  end

  # The before_action of the admin namespace: the jobs page's
  # (config/routes.rb) and AdminGate's (Admin::ArticlesController). The
  # blog has no user accounts, so the gate is one shared secret,
  # BLOG_ADMIN_TOKEN; anything but a visitor who proves it (#admin?) gets
  # 404, as if the page did not exist.
  def require_admin
    render plain: "Not Found", status: :not_found unless admin?
    nil
  end

  # Whether this request proves BLOG_ADMIN_TOKEN: the variable is set to a
  # non-empty value and the request carries either the admin session
  # /admin/login signs a browser in with (AdminSessionsController) or an
  # `x-admin-token` header with the token (curl). With the variable unset
  # or empty, nothing does. A helper method of AdminGate's controllers and
  # of ArticlesController (the article page's admin link).
  def admin?
    token = admin_token
    return false if token.empty?
    return true if Cybertrain::Crypto.secure_compare(session["admin"].to_s, admin_session_value(token))

    # Compared as HMACs, of one length, so the time taken does not give
    # away the token's length.
    header = request.header("x-admin-token").to_s
    Cybertrain::Crypto.secure_compare(admin_session_value(header), admin_session_value(token))
  end

  # BLOG_ADMIN_TOKEN as it is now; "" when it is unset.
  def admin_token
    ENV["BLOG_ADMIN_TOKEN"].to_s
  end

  # What the admin session holds: derived from the current token, so a new
  # token signs out every browser signed in with the old one, and the
  # token itself is never in the cookie (which the browser can read).
  def admin_session_value(token)
    Cybertrain::Crypto.hmac_hex(Cybertrain.config.secret_key_base, token)
  end
end
