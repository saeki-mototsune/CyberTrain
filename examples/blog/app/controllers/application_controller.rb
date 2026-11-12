class ApplicationController < Cybertrain::Controller
  # The language comes first, so that the sign-in page a visitor is sent
  # to (require_authentication) is in the language the link asked for.
  before_action :set_locale

  include Authentication

  rescue_from Cybertrain::RecordNotFound, with: :record_not_found

  # The layout's <html lang> and language links, and the article page's
  # admin link.
  helper_method :admin?, :html_lang, :path_in_locale

  private

  def record_not_found
    render plain: "Not Found", status: :not_found
  end

  # This request's language (I18n.locale, which the framework resets to
  # the default before every action): `?locale=en` or `?locale=ja`,
  # which is then kept in the `locale` cookie, so that the plain links of
  # the next pages stay in it; else the cookie's; else the best match of
  # the browser's Accept-Language (English when nothing matches). A value
  # that is not one of config.i18n_available_locales, in the parameter or
  # in the cookie, is ignored, and never written to the cookie.
  def set_locale
    param = params[:locale]
    if I18n.locale_available?(param)
      I18n.locale = param
      cookies[:locale] = param.to_s
      return nil
    end

    stored = cookies[:locale]
    if I18n.locale_available?(stored)
      I18n.locale = stored
      return nil
    end

    I18n.locale = request.preferred_locale(I18n.available_locales)
    nil
  end

  # The layout's `<html lang="...">`: "en" or "ja".
  def html_lang
    I18n.locale.to_s
  end

  # This page's path in another language, for the layout's language
  # links: `/articles/1?locale=ja`.
  def path_in_locale(locale)
    "#{request.path}?locale=#{locale}"
  end

  # Whether a signed-in admin made this request (User#admin?, set with
  # `./blog user admin EMAIL`): the article page shows its "Manage
  # articles" link then. The pages themselves are guarded by the
  # Authentication concern's require_admin.
  def admin?
    authenticated? && @current_user.admin?
  end
end
