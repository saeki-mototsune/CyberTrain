# The first run of an invitation-only application (cybertrain generate
# authentication --invite-only): /setup, the first user's page, only from
# this machine and with the token the boot warning prints, while no user
# exists; then `./blog user`.
require "test_helper"
require_relative "../../app/commands/user_command"

class FirstRunTest < ActionDispatch::IntegrationTest
  # /setup answers only while no user exists: these tests start without
  # the fixtures' users.
  setup do
    User.all.delete_all
  end

  test "GET /setup with the token shows the form to this machine while no user exists" do
    get setup_link
    assert_response :ok
    assert_includes response.body, "<h1>Set up</h1>"
    assert_includes response.body, "<form action=\"/setup\" method=\"post\">"
    assert_includes response.body, "<input type=\"hidden\" name=\"token\" value=\"#{SetupController.setup_token}\">"
    assert_includes response.body, "name=\"user[password_confirmation]\""
  end

  test "/setup without the token, or with a wrong one, is a 404" do
    assert_equal 32, SetupController.setup_token.size
    get "/setup"
    assert_response :not_found
    get "/setup?token="
    assert_response :not_found
    get "/setup?token=0123456789abcdef0123456789abcdef"
    assert_response :not_found
    get "/setup?token=#{SetupController.setup_token}x"
    assert_response :not_found
    refute response.body.include?(SetupController.setup_token)
  end

  test "/setup is a 404 to another machine, through a proxy, and once a user exists" do
    res = browser_at("203.0.113.7").get(setup_link)
    assert_equal 404, res.status
    get setup_link, headers: { "x-forwarded-for" => "203.0.113.7" }
    assert_response :not_found
    get setup_link
    assert_response :ok
    create_user
    get setup_link
    assert_response :not_found
  end

  test "POST /setup from another machine, or without the token, creates nothing" do
    res = browser_at("203.0.113.7").post("/setup", Cybertrain::Test.flatten_params(setup_form("s3cr3t-s3cr3t", "s3cr3t-s3cr3t")))
    assert_equal 404, res.status
    user = { email_address: " Ann@Example.com ", password: "s3cr3t-s3cr3t", password_confirmation: "s3cr3t-s3cr3t" }
    post "/setup", params: { token: "0123456789abcdef0123456789abcdef", user: user }
    assert_response :not_found
    post "/setup", params: { user: user }
    assert_response :not_found
    assert_equal 0, User.count
  end

  test "BLOG_SETUP_OPEN opens /setup to any address with the token until a user exists" do
    browser = browser_at("203.0.113.7")
    Cybertrain.config.set_bool_setting(:setup_open, true)
    res = browser.get(setup_link)
    without = browser.get("/setup")
    Cybertrain.config.set_bool_setting(:setup_open, false)
    assert_equal 200, res.status
    assert_equal 404, without.status
    create_user
    Cybertrain.config.set_bool_setting(:setup_open, true)
    res = browser.get(setup_link)
    Cybertrain.config.set_bool_setting(:setup_open, false)
    assert_equal 404, res.status
  end

  # With forgery protection on, the page's own token is accepted.
  test "POST /setup with the token creates the first user and signs them in" do
    with_forgery_protection do
      get setup_link
      post "/setup", params: { authenticity_token: authenticity_token_in(response.body), token: SetupController.setup_token,
                               user: { email_address: " Ann@Example.com ", password: "s3cr3t-s3cr3t", password_confirmation: "s3cr3t-s3cr3t" } }
      assert_redirected_to "/"
    end
    assert_equal 1, User.count
    assert_equal "ann@example.com", User.first.email_address
    assert_equal 1, Session.count
    get "/session/new"
    assert_includes response.body, "<span>ann@example.com</span>"
    get setup_link
    assert_response :not_found
  end

  test "POST /setup with a short or mismatched password re-renders the form" do
    post "/setup", params: setup_form("short", "other")
    assert_response :unprocessable_entity
    assert_includes response.body, "<li>Password is too short (minimum is 8 characters)</li>"
    assert_includes response.body, "<li>Password confirmation doesn&#39;t match Password</li>"
    assert_includes response.body, "<input type=\"hidden\" name=\"token\" value=\"#{SetupController.setup_token}\">"
    assert_equal 0, User.count
  end

  test "./blog user creates a user, then sets its password" do
    assert_equal 0, run_command(["user", "Bob@Example.com", "s3cr3t-s3cr3t"])
    assert_equal 1, User.count
    assert_equal "bob@example.com", User.first.email_address
    assert User.first.authenticate("s3cr3t-s3cr3t")
    assert_equal 0, run_command(["user", "bob@example.com", "another-s3cr3t"])
    assert_equal 1, User.count
    assert User.first.authenticate("another-s3cr3t")
    refute User.first.authenticate("s3cr3t-s3cr3t")
  end

  test "POST /setup and ./blog user refuse an address list or a malformed address" do
    post "/setup", params: { token: SetupController.setup_token,
                             user: { email_address: "ann@example.com,eve@evil.example", password: "s3cr3t-s3cr3t", password_confirmation: "s3cr3t-s3cr3t" } }
    assert_response :unprocessable_entity
    assert_includes response.body, "<li>Email address is invalid</li>"
    assert_equal 0, User.count
    assert_equal 1, run_command(["user", "ann@example.com,eve@evil.example", "s3cr3t-s3cr3t"])
    assert_equal 1, run_command(["user", "ann", "s3cr3t-s3cr3t"])
    assert_equal 0, User.count
  end

  test "./blog user refuses bad arguments and an empty or short password" do
    assert_equal 1, run_command(["user"])
    assert_equal 1, run_command(["user", "ann@example.com", "s3cr3t-s3cr3t", "extra"])
    assert_equal 1, run_command(["user", "--help"])
    assert_equal 1, run_command(["user", "ann@example.com", ""])
    assert_equal 1, run_command(["user", "ann@example.com", "short"])
    assert_equal 0, User.count
  end

  test "a password read from standard input loses one trailing newline" do
    assert_equal "s3cr3t s3cr3t", UserCommand.password_from("s3cr3t s3cr3t\n")
    assert_equal "s3cr3t", UserCommand.password_from("s3cr3t\r\n")
    assert_equal "s3cr3t\n", UserCommand.password_from("s3cr3t\n\n")
    assert_equal "", UserCommand.password_from("")
  end

  test "the boot warning is due while no user exists" do
    assert UserCommand.no_user?
    reconnect
    create_user
    refute UserCommand.no_user?
    reconnect
  end

  private

  # The form /setup posts, filled in, with the page's one-time token in
  # its hidden field.
  def setup_form(password, confirmation)
    { token: SetupController.setup_token,
      user: { email_address: " Ann@Example.com ", password: password, password_confirmation: confirmation } }
  end

  # The authenticity_token of the first form in a page.
  def authenticity_token_in(body)
    marker = "name=\"authenticity_token\" value=\""
    at = body.index(marker)
    raise "no authenticity_token in the page" if at.nil?

    start = at + marker.size
    stop = body.index("\"", start).to_i
    body[start, stop - start].to_s
  end

  # /setup with this process's token, the link the boot warning prints.
  def setup_link
    "/setup?token=#{SetupController.setup_token}"
  end

  # A browser on another machine: the test's own requests come from
  # 127.0.0.1, and an integration test cannot change that, so this one
  # is a Cybertrain::Test::Client (its responses are checked by status).
  def browser_at(address)
    browser = Cybertrain::Test::Client.new(Cybertrain::Test.app)
    browser.peer_address = address
    browser
  end

  # The first user, made as the user command makes one.
  def create_user
    user = User.new(email_address: "ann@example.com")
    user.password = "s3cr3t-s3cr3t"
    user.save!
    nil
  end

  # `./blog ARGS...` in-process. Main.run connects a pool of one for
  # the command and disconnects it, so the tests' pool is connected
  # again afterwards (the database file is the same).
  def run_command(argv)
    status = Cybertrain::Main.run("blog", argv, router: Gen::Routes.build(Cybertrain::Router.new),
                                               url_resolver: Gen::Routes.url_resolver,
                                               views: Cybertrain::Application.no_views)
    reconnect
    status
  end

  def reconnect
    Cybertrain::DB.connect(Cybertrain.config.database_path, size: Cybertrain.config.pool_size)
    nil
  end
end
