

# Uploads of Article#cover through the full stack: the multipart parser,
# the model's callbacks and the download action. Written by `cybertrain
# generate attachment article cover`; run with `cybertrain test`.
class ArticleCoverAttachmentTest < ActionDispatch::IntegrationTest; def setup; super; setup_article_cover_attachment_test_1; nil; end; def teardown; teardown_article_cover_attachment_test_1; super; nil; end
  # test/fixtures/files/cover.png: a PNG signature, then NUL, 0xFF and CR LF
  # bytes. The server sniffs the signature only; the rest shows that every
  # byte survives the round trip.
  PNG_BYTES = Cybertrain::Test.binary([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF, 0x0D, 0x0A, 0x00, 0x01])
  HTML_BYTES = "<html><script>alert(document.cookie)</script></html>"
  SVG_BYTES = '<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"></svg>'

  def setup_article_cover_attachment_test_1; begin
    # A user signed in through the form: the controller's actions need one.
    sign_in_as users(:one)
    # Uploaded files land here, not in storage/uploads.
    Cybertrain::BlobStore.root = "tmp/test_uploads"
    Dir.glob("tmp/test_uploads/*/*").each { |path| File.delete(path) }
  end; nil; end

  # The configured upload directory again, for the tests after this one.
  def teardown_article_cover_attachment_test_1; begin
    Cybertrain::BlobStore.root = Cybertrain.config.upload_root
  end; nil; end

  def test_a_PNG_upload_is_stored_on_disk_and_served_back_with_safe_headers; begin
    assert_difference(-> { Article.count }, 1) do
      create_article(fixture_file_upload("cover.png", "image/png"))
    end
    assert_response :see_other
    record = Article.last
    assert record.cover_attached?
    assert_equal "cover.png", record.cover_filename
    assert_equal "image/png", record.cover_content_type
    assert_equal PNG_BYTES.bytesize, record.cover_byte_size
    assert Cybertrain::BlobStore.exist?(record.cover_key)
    get "/articles/#{record.id}/cover"
    assert_response :ok
    served = response.body
    assert_equal PNG_BYTES.bytesize, served.bytesize
    name = "copy.png"
    data = served.b
    copy = Cybertrain::UploadedFile.new(name, "", data)
    assert_equal record.cover_checksum, copy.sha256_hex
    assert response.header("content-type").to_s.start_with?("image/png"), "content-type"
    assert_equal "nosniff", response.header("x-content-type-options")
    assert response.header("content-disposition").to_s.start_with?("inline"), "content-disposition"
    assert_equal "default-src 'none'; sandbox", response.header("content-security-policy")
    get "/articles/#{record.id}"
    assert_includes response.body, "/articles/#{record.id}/cover?v="
  end; nil; end

  def test_HTML_and_SVG_bytes_are_refused_even_when_named__png_and_declared_image_png; begin
    assert_no_difference(-> { Article.count }) do
      create_article(file_named("x.png", "image/png", HTML_BYTES))
      assert_response :unprocessable_entity
      assert_includes response.body, "Cover must be a PNG, JPEG, GIF or WebP image"
      create_article(file_named("logo.png", "image/png", SVG_BYTES))
      assert_response :unprocessable_entity
    end
    assert_equal 0, Dir.glob("tmp/test_uploads/*/*").size
  end; nil; end

  def test_a_file_over_the_model_s_limit_is_a_422_with_a_message; begin
    big = +""
    big << PNG_BYTES
    big << ("a" * (Article::COVER_MAX_BYTES + 1))
    assert_no_difference(-> { Article.count }) do
      create_article(file_named("big.png", "image/png", big))
    end
    assert_response :unprocessable_entity
    assert_includes response.body, "Cover is too large (maximum is 2 MB)"
  end; nil; end

  def test_the_client_s_filename_is_a_display_name__it_never_reaches_the_disk_path; begin
    create_article(file_named("../../evil.png", "image/png", PNG_BYTES))
    assert_response :see_other
    record = Article.last
    assert_equal "evil.png", record.cover_filename
    key = record.cover_key
    assert_equal 32, key.bytesize
    assert Cybertrain::BlobStore.valid_key?(key)
    path = Cybertrain::BlobStore.path_for(key)
    refute path.include?("evil"), path
    assert path.start_with?("tmp/test_uploads/"), path
    get "/articles/#{record.id}/cover"
    assert_includes response.header("content-disposition").to_s, "filename=\"evil.png\""
  end; nil; end

  def test_replacing_the_file_deletes_the_old_blob__destroying_the_record_deletes_the_current_one; begin
    create_article(file_named("one.png", "image/png", PNG_BYTES))
    record = Article.last
    old_key = record.cover_key
    update_article(record, file_named("two.png", "image/png", PNG_BYTES))
    assert_response :see_other
    record = Article.find(record.id)
    new_key = record.cover_key
    refute new_key == old_key, "the key changes with the file"
    assert_equal "two.png", record.cover_filename
    refute Cybertrain::BlobStore.exist?(old_key), "the replaced blob is deleted"
    assert Cybertrain::BlobStore.exist?(new_key)
    assert_difference(-> { Article.count }, -1) do
      delete "/articles/#{record.id}"
    end
    assert_response :see_other
    refute Cybertrain::BlobStore.exist?(new_key), "the destroyed record's blob is deleted"
  end; nil; end

  def test_a_record_whose_blob_is_gone_answers_404; begin
    create_article(fixture_file_upload("cover.png", "image/png"))
    record = Article.last
    File.delete(Cybertrain::BlobStore.path_for(record.cover_key))
    get "/articles/#{record.id}/cover"
    assert_response :not_found
  end; nil; end

  # Forgery protection is off in tests unless config/app.rb sets csrf,
  # as in Rails; the block turns it on for its requests.
  def test_a_multipart_POST_without_the_CSRF_token_is_refused; begin
    assert_no_difference(-> { Article.count }) do
      with_forgery_protection do
        create_article(fixture_file_upload("cover.png", "image/png"))
        assert_response :forbidden
      end
    end
  end; nil; end

  # What a browser sends for a file input left empty: filename="" and no
  # bytes. The parser drops it, so a form whose only field is the file
  # arrives without any article[...] key at all.
  def test_an_update_without_a_file_keeps_the_stored_one; begin
    create_article(fixture_file_upload("cover.png", "image/png"))
    record = Article.last
    key = record.cover_key
    update_article(record, file_named("", "application/octet-stream", ""))
    assert_response :see_other
    record = Article.find(record.id)
    assert_equal key, record.cover_key
    assert Cybertrain::BlobStore.exist?(key)
  end; nil; end

  def test_the_download_is_public_like_show__a_visitor_gets_the_file; begin
    create_article(fixture_file_upload("cover.png", "image/png"))
    record = Article.last
    delete "/session"
    get "/articles/#{record.id}/cover"
    assert_response :ok
    assert_equal PNG_BYTES.bytesize, response.body.bytesize
  end; nil; end

  # The blog's own: the JSON of an article names where its cover is served
  # from and keeps the cover_* columns (the storage key and its metadata)
  # to itself.
  def test_an_article_s_JSON_has_the_cover_s_URL_and_none_of_the_cover___columns; begin
    create_article(fixture_file_upload("cover.png", "image/png"))
    assert_response :see_other
    article = Article.last
    assert article.cover_attached?, "expected the cover to be attached"

    get "/articles/#{article.id}.json"
    assert_response :ok
    assert_includes response.body, "\"cover_url\":\"/articles/#{article.id}/cover?v="
    assert_nil response.body.index("cover_key")
    assert_nil response.body.index("cover_checksum")

    get "/articles/#{article.id}"
    assert_includes response.body, "<img src=\"/articles/#{article.id}/cover?v="
    # Whoever may read the article may fetch its cover: a visitor too.
    visitor = open_session
    visitor.get article.cover_url
    visitor.assert_response :ok
    article.destroy
  end; nil; end

  # The messages come from the blog's dictionaries
  # (activerecord.errors.models.article.attributes.cover.*).
  def test_the_cover_s_validation_messages_are_in_the_chosen_language; begin
    get "/articles/new?locale=ja"
    create_article(file_named("x.png", "image/png", HTML_BYTES))
    assert_response :unprocessable_entity
    assert_includes response.body, "<li>カバー画像はPNG、JPEG、GIF、WebPのいずれかの画像にしてください</li>"
    big = +""
    big << PNG_BYTES
    big << ("a" * (Article::COVER_MAX_BYTES + 1))
    create_article(file_named("big.png", "image/png", big))
    assert_response :unprocessable_entity
    assert_includes response.body, "<li>カバー画像は2MB以下にしてください</li>"
    get "/articles/new?locale=en"
    create_article(file_named("x.png", "image/png", HTML_BYTES))
    assert_includes response.body, "<li>Cover must be a PNG, JPEG, GIF or WebP image</li>"
  end; nil; end

  private

  # The form's fields: the file, and the other attributes your Article
  # requires.
  def article_params(file)
    { title: "A article", body: "A article.", cover: file }
  end

  # POST /articles as the new form sends it: the file in article[cover]
  # (multipart/form-data, since a params value is a file).
  def create_article(file)
    post "/articles", params: { article: article_params(file) }
  end

  # PATCH /articles/:id as the edit form sends it.
  def update_article(record, file)
    patch "/articles/#{record.id}", params: { article: article_params(file) }
  end

  # A file with this name, type and bytes, for what no fixture file
  # holds (a disguised type, a hostile name, a file input left empty).
  def file_named(filename, type, data)
    Cybertrain::Test::Upload.new("", filename, type, data)
  end
end
# Generated by `spin run gen` from test/integration/article_cover_attachment_test.rb. Do not edit.
