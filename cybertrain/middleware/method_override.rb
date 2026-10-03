require "cybertrain/middleware"
require "cybertrain/http/query"

module Cybertrain
  # HTML forms can only GET or POST, so Rails-style forms send
  # `_method=patch|put|delete` in the body (or the query string) and this
  # middleware rewrites the request method before the Router sees it.
  class MethodOverride < Middleware
    ALLOWED = ["PATCH", "PUT", "DELETE"]

    def call(ctx)
      request = ctx.request
      if request.post?
        wanted = override_from(request)
        request.override_method!(wanted) unless wanted.empty?
      end
      super
    end

    private

    # The requested method upper-cased, or "" when there is none (or it is
    # not one of ALLOWED). The form body wins over the query string. One
    # Query.value_of scan each (Request#form_value / #query_value), not the
    # whole parsed tree: this runs before any auth or CSRF check on every POST.
    def override_from(request)
      value = ""
      value = request.form_value("_method") if request.form?
      value = request.query_value("_method") if value.empty?
      value = value.upcase
      ALLOWED.include?(value) ? value : ""
    end
  end
end
