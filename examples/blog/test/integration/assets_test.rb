require "test_helper"

# The digested stylesheet and logo (app/assets, digested by `spin run gen`),
# the import map that pins Turbo, and the Content Security Policy with its
# per-response nonce (config/app.rb).
class AssetsTest < ActionDispatch::IntegrationTest
  test "the layout links the digested stylesheet, which is served immutable with its url() digested" do
    get "/articles"
    digest = BlogTestHelper.text_after(response.body, "<link rel=\"stylesheet\" href=\"/assets/application-", ".css\">")
    assert BlogTestHelper.hex8?(digest), "expected /assets/application-<8 hex>.css in the layout, got #{digest.inspect}"
    assert_nil response.body.index("/style.css")

    get "/assets/application-#{digest}.css"
    css = response
    assert_response :ok
    assert_equal "text/css; charset=utf-8", css.header("Content-Type").to_s
    assert_equal "public, max-age=31536000, immutable", css.header("Cache-Control").to_s
    assert_includes css.body, "form.button_to { display: inline; }"
    logo = BlogTestHelper.text_after(css.body, "url(\"/assets/logo-", ".svg\")")
    assert BlogTestHelper.hex8?(logo), "expected the logo's url() digested, got #{logo.inspect}"
    get "/assets/logo-#{logo}.svg"
    svg = response
    assert_response :ok
    assert_equal "public, max-age=31536000, immutable", svg.header("Cache-Control").to_s
    assert_includes svg.body, "<svg"
  end

  test "the import map pins Turbo and the application entry point, with the CSP nonce" do
    get "/articles"
    page = response
    turbo = "https://cdn.jsdelivr.net/npm/@hotwired/turbo@8.0.12/dist/turbo.es2017-esm.js"
    assert_includes page.body, "\"@hotwired/turbo\":\"#{turbo}\""
    assert_includes page.body, "<link rel=\"modulepreload\" href=\"#{turbo}\""
    app = BlogTestHelper.text_after(page.body, "\"application\":\"/assets/application-", ".js\"")
    assert BlogTestHelper.hex8?(app), "expected the application entry point digested, got #{app.inspect}"
    get "/assets/application-#{app}.js"
    assert_response :ok
    assert_includes response.body, "import \"@hotwired/turbo\""

    nonce = BlogTestHelper.text_after(page.body, "<meta name=\"csp-nonce\" content=\"", "\"")
    refute nonce.empty?, "expected a csp-nonce meta tag"
    assert_includes page.body, "<script type=\"importmap\" data-turbo-track=\"reload\" nonce=\"#{nonce}\">"
    assert_includes page.body, "<script type=\"module\" nonce=\"#{nonce}\">import \"application\"</script>"
    csp = page.header("Content-Security-Policy").to_s
    assert_includes csp, "default-src 'self'"
    assert_includes csp, "script-src 'self' https://cdn.jsdelivr.net/npm/@hotwired/turbo@8.0.12/ 'nonce-#{nonce}'"
    assert_includes csp, "style-src 'self' 'nonce-#{nonce}'"
    assert_includes csp, "img-src 'self' data:"

    get "/articles"
    again = BlogTestHelper.text_after(response.body, "<meta name=\"csp-nonce\" content=\"", "\"")
    refute again == nonce, "a new nonce per response"
  end
end
