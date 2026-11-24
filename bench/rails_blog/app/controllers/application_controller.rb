class ApplicationController < ActionController::Base
  # The language comes first, so that the sign-in page a visitor is sent
  # to (require_authentication) is in the language the link asked for.
  around_action :switch_locale

  include Authentication

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found

  # The layout's language links, and the article page's admin link.
  helper_method :admin?, :path_in_locale

  private

  def record_not_found
    render plain: "Not Found", status: :not_found
  end

  # This request's language, as examples/blog's set_locale picks it:
  # `?locale=en` or `?locale=ja`, which is then kept in the `locale` cookie
  # (until the browser is closed); else the cookie's; else the best match
  # of the browser's Accept-Language (English when nothing matches). A value
  # that is not an available locale is ignored, and never written to the
  # cookie.
  def switch_locale(&action)
    I18n.with_locale(request_locale, &action)
  end

  def request_locale
    param = params[:locale].to_s
    if locale_available?(param)
      cookies[:locale] = param
      return param
    end

    stored = cookies[:locale].to_s
    return stored if locale_available?(stored)

    accepted_locale
  end

  def locale_available?(name)
    !name.empty? && I18n.available_locales.any? { |locale| locale.name == name }
  end

  # The available locale with the highest q in Accept-Language ("ja,en;q=0.8"),
  # matched on the primary language ("ja-JP" is ja); the default without one.
  def accepted_locale
    best = nil
    best_q = 0.0
    request.headers["Accept-Language"].to_s.split(",").each do |range|
      tag, *options = range.split(";")
      q = 1.0
      options.each do |option|
        name, value = option.strip.split("=", 2)
        q = value.to_f if name == "q"
      end
      language = tag.to_s.strip.downcase.split("-").first.to_s
      locale = I18n.available_locales.find { |l| l.name == language }
      if locale && q > best_q
        best = locale
        best_q = q
      end
    end
    best || I18n.default_locale
  end

  # This page's path in another language, for the layout's language links:
  # `/articles/1?locale=ja`, with the path's leading slashes made one.
  def path_in_locale(locale)
    "/#{request.path.sub(%r{\A/+}, "")}?locale=#{locale}"
  end

  # Whether a signed-in admin made this request: the article page shows its
  # "Manage articles" link then.
  def admin?
    authenticated? && Current.user.admin?
  end
end
