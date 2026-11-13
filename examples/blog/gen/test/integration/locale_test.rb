

# English and Japanese (config/locales/en.yml, ja.yml), picked by
# ApplicationController#set_locale: ?locale=, kept in the `locale` cookie;
# else that cookie; else Accept-Language; else English. Each browser's
# `cookies["locale"]` is that cookie (nil when it has none).
class LocaleTest < ActionDispatch::IntegrationTest
  # One article, so the count is in its singular form: articles(:two) is
  # deleted first.
  def test__locale_ja_renders_Japanese; begin
    articles(:two).destroy
    get "/articles?locale=ja"
    assert_response :ok
    assert_includes response.body, "<html lang=\"ja\">"
    assert_includes response.body, "<title>ブログ</title>"
    assert_includes response.body, "<h1>記事</h1>"
    assert_includes response.body, "<p class=\"article-count\">1件の記事</p>"
    assert_includes response.body, "<label for=\"from\">開始日</label>"
    assert_includes response.body, "<option selected=\"selected\" value=\"new\">新しい順</option>"
    assert_includes response.body, "<th>タイトル</th>"
    assert_includes response.body, "<a href=\"/articles/new\">記事を書く</a>"
    # The generated nav partial, from the framework's dictionary.
    assert_includes response.body, "<a href=\"/session/new\">ログイン</a>"
    assert_nil response.body.index("<h1>Articles</h1>")
    assert_nil response.body.index("New article")
    assert_equal "ja", cookies["locale"]

    # And English, with ?locale=en, on another browser.
    other = open_session
    other.get "/articles?locale=en"
    other.assert_response :ok
    assert_includes other.response.body, "<html lang=\"en\">"
    assert_includes other.response.body, "<title>Blog</title>"
    assert_includes other.response.body, "<h1>Articles</h1>"
    assert_includes other.response.body, "<p class=\"article-count\">1 article</p>"
    assert_includes other.response.body, "<a href=\"/articles/new\">New article</a>"
    assert_includes other.response.body, "<a href=\"/session/new\">Sign in</a>"
    assert_nil other.response.body.index("記事を書く")
    assert_equal "en", other.cookies["locale"]
  end; nil; end

  # articles(:one) is dated 2024-03-10 09:00 UTC.
  def test_after__locale_ja__a_plain_link_stays_Japanese__cookie_; begin
    article = articles(:one)
    get "/?locale=ja"
    assert_equal "ja", cookies["locale"]
    get "/articles/#{article.id}"
    assert_response :ok
    assert_includes response.body, "<html lang=\"ja\">"
    assert_includes response.body, "<p class=\"dates\">投稿日時 <time datetime=\"2024-03-10T09:00:00Z\">2024/03/10 09:00</time></p>"
    assert_includes response.body, "<h2>コメントを書く</h2>"
    assert_includes response.body, "<button type=\"submit\">この記事を削除</button>"
    assert_includes response.body, "<label for=\"comment_commenter\">名前</label>"
    assert_includes response.body, "value=\"登録する\""
    refute BlogTestHelper.sets_locale_cookie?(response), "a plain link leaves the cookie as it is"

    # A fresh browser, with no cookie, gets the same page in English.
    fresh = open_session
    fresh.get "/articles/#{article.id}"
    assert_includes fresh.response.body, "<html lang=\"en\">"
    assert_includes fresh.response.body, "<p class=\"dates\">Written <time datetime=\"2024-03-10T09:00:00Z\">March 10, 2024 09:00</time></p>"
    assert_includes fresh.response.body, "<h2>Add a comment:</h2>"
    assert_includes fresh.response.body, "value=\"Create Comment\""
    assert_nil fresh.response.body.index("コメントを書く")
    assert_nil fresh.cookies["locale"]

    # ?locale=en switches the first browser back, for its next links too.
    get "/articles/#{article.id}?locale=en"
    assert_equal "en", cookies["locale"]
    get "/articles/#{article.id}"
    assert_includes response.body, "<html lang=\"en\">"
    assert_includes response.body, "<h2>Add a comment:</h2>"
  end; nil; end

  def test_the_language_links_keep_the_current_path; begin
    article = articles(:one)
    get "/articles/#{article.id}"
    assert_includes response.body, "<a href=\"/articles/#{article.id}?locale=en\">English</a>"
    assert_includes response.body, "<a href=\"/articles/#{article.id}?locale=ja\">日本語</a>"
    get "/articles?order=old&locale=ja"
    assert_includes response.body, "<a href=\"/articles?locale=en\">English</a>"
    assert_includes response.body, "<a href=\"/articles?locale=ja\">日本語</a>"
    get "/"
    assert_includes response.body, "<a href=\"/?locale=en\">English</a>"
    # A path with doubled slashes routes as the plain one; its links stay on
    # this site (no protocol-relative //articles, which names another host).
    get "//articles"
    assert_response :ok
    assert_includes response.body, "<a href=\"/articles?locale=en\">English</a>"
    assert_includes response.body, "<a href=\"/articles?locale=ja\">日本語</a>"
    assert_nil response.body.index("href=\"//")
  end; nil; end

  def test_Accept_Language__ja_renders_Japanese; begin
    get "/articles", headers: { "Accept-Language" => "ja-JP,ja;q=0.9,en;q=0.8" }
    assert_includes response.body, "<html lang=\"ja\">"
    assert_includes response.body, "<h1>記事</h1>"
    # The header is asked every time; it writes no cookie.
    refute BlogTestHelper.sets_locale_cookie?(response), "Accept-Language writes no cookie"
    assert_nil cookies["locale"]

    get "/articles", headers: { "Accept-Language" => "en-US,en;q=0.9" }
    assert_includes response.body, "<html lang=\"en\">"
    assert_includes response.body, "<h1>Articles</h1>"
    get "/articles", headers: { "Accept-Language" => "fr-FR, de;q=0.8" }
    assert_includes response.body, "<h1>Articles</h1>"
    get "/articles", headers: { "Accept-Language" => "en;q=0.5, ja;q=0.8" }
    assert_includes response.body, "<h1>記事</h1>"

    # ?locale= wins over the header, and its cookie does too afterwards.
    get "/articles?locale=en", headers: { "Accept-Language" => "ja" }
    assert_includes response.body, "<h1>Articles</h1>"
    get "/articles", headers: { "Accept-Language" => "ja" }
    assert_includes response.body, "<h1>Articles</h1>"
  end; nil; end

  def test_an_invalid_locale_param_falls_back_to_English; begin
    hostile = "x" * 5000
    ["fr", "", "JA", "ja-JP", "ja%00", "..%2F..%2Fetc", "../../etc", "%3Cscript%3E", hostile].each do |value|
      get "/articles?locale=#{value}"
      assert_response :ok
      assert_includes response.body, "<html lang=\"en\">"
      assert_includes response.body, "<h1>Articles</h1>"
      refute BlogTestHelper.sets_locale_cookie?(response), "?locale=#{value[0, 20]} is not written to the cookie"
      assert_nil cookies["locale"]
      # Nor is it written into the page: the language links name the path
      # and a supported locale only (a link ends at its closing quote).
      assert_includes response.body, "<a href=\"/articles?locale=en\">English</a>"
      assert_nil response.body.index("locale=#{value}\"")
    end
    get "/articles?locale=#{hostile}"
    assert_nil response.body.index("x" * 100)
    get "/articles?locale=../../etc"
    assert_nil response.body.index("../../etc")
    get "/articles?locale[]=ja"
    assert_includes response.body, "<h1>Articles</h1>"
    assert_nil cookies["locale"]

    # It falls back to the rest of the chain: the browser's language...
    get "/articles?locale=xx", headers: { "Accept-Language" => "ja" }
    assert_includes response.body, "<h1>記事</h1>"
    assert_nil cookies["locale"]
    # ...and a choice made before, which it does not overwrite.
    get "/articles?locale=ja"
    get "/articles?locale=../../etc"
    assert_includes response.body, "<h1>記事</h1>"
    assert_equal "ja", cookies["locale"]
  end; nil; end

  def test_a_tampered_locale_cookie_is_ignored; begin
    ["xx", "", "JA", "..%2F..%2Fetc", "x" * 3000].each do |value|
      cookies["locale"] = value
      get "/articles"
      assert_response :ok
      assert_includes response.body, "<html lang=\"en\">"
      assert_includes response.body, "<h1>Articles</h1>"
      refute BlogTestHelper.sets_locale_cookie?(response), "the cookie is left as it is"
    end
    cookies["locale"] = "xx"
    get "/articles", headers: { "Accept-Language" => "ja" }
    assert_includes response.body, "<h1>記事</h1>"
    # A valid cookie still counts.
    cookies["locale"] = "ja"
    get "/articles"
    assert_includes response.body, "<h1>記事</h1>"
  end; nil; end

  # users(:two) writes articles; every fixture user's password is "password".
  def test_the_sign_in_page_and_its_messages_are_in_the_chosen_language; begin
    get "/articles/new?locale=ja"
    assert_redirected_to "/session/new"
    follow_redirect!
    assert_includes response.body, "<html lang=\"ja\">"
    assert_includes response.body, "<title>ブログ</title>"
    assert_includes response.body, "<h1>ログイン</h1>"
    assert_includes response.body, "<label for=\"email_address\">メールアドレス</label>"
    assert_includes response.body, "<a href=\"/session/new?locale=en\">English</a>"
    post "/session", params: { email_address: users(:two).email_address, password: "wrong-password" }
    follow_redirect!
    assert_includes response.body, "<p class=\"alert\">メールアドレスかパスワードが違います。</p>"
    get "/session/new?locale=en"
    assert_includes response.body, "<html lang=\"en\">"
    assert_includes response.body, "<h1>Sign in</h1>"
    assert_includes response.body, "<label for=\"email_address\">Email address</label>"

    # Signed in, the notices of the blog's own actions too.
    sign_in_as users(:two)
    get "/articles/new?locale=ja"
    post "/articles", params: { article: { title: "こんにちは", body: "日本語で書いた最初の記事です。" } }
    follow_redirect!
    assert_includes response.body, "<p class=\"notice\">記事を作成しました。</p>"
    assert_includes response.body, "<h1>こんにちは</h1>"
    assert_includes response.body, "<span>two@example.com</span>"
    assert_includes response.body, "<button type=\"submit\">ログアウト</button>"
  end; nil; end

  def test_validation_errors_in_Japanese; begin
    sign_in_as users(:two)
    before = Article.count
    get "/articles/new?locale=ja"
    get "/articles/new"
    assert_includes response.body, "<h1>新しい記事</h1>"
    assert_includes response.body, "<label for=\"article_title\">タイトル</label>"
    assert_includes response.body, "<label for=\"article_body\">本文</label>"
    assert_includes response.body, "value=\"登録する\""
    post "/articles", params: { article: { title: "", body: "短い" } }
    assert_response :unprocessable_entity
    assert_includes response.body, "<h2>2件のエラーがあるため、記事を保存できませんでした:</h2>"
    assert_includes response.body, "<li>タイトルを入力してください</li>"
    assert_includes response.body, "<li>本文は10文字以上で入力してください</li>"
    assert_nil response.body.index("can&#39;t be blank")
    assert_equal before, Article.count

    # The same form in English.
    get "/articles/new?locale=en"
    post "/articles", params: { article: { title: "", body: "Too short" } }
    assert_response :unprocessable_entity
    assert_includes response.body, "<h2>2 errors prohibited this article from being saved:</h2>"
    assert_includes response.body, "<li>Title can&#39;t be blank</li>"
    assert_includes response.body, "<li>Body is too short (minimum is 10 characters)</li>"
    assert_nil response.body.index("を入力してください")

    # The edit form, and a duplicate title, in Japanese.
    article = articles(:one)
    taken = articles(:two)
    get "/articles/#{article.id}/edit?locale=ja"
    patch "/articles/#{article.id}", params: { article: { title: taken.title, body: "A body that is long enough." } }
    assert_response :unprocessable_entity
    assert_includes response.body, "<h1>記事の編集</h1>"
    assert_includes response.body, "<h2>1件のエラーがあるため、記事を保存できませんでした:</h2>"
    assert_includes response.body, "<li>タイトルはすでに存在します</li>"
    assert_includes response.body, "value=\"更新する\""
  end; nil; end
end
# Generated by `spin run gen` from test/integration/locale_test.rb. Do not edit.
