# Uploads of Article#cover through the full stack: the multipart parser, CSRF,
# method override, the model's callbacks and the download action. Written
# by `cybertrain generate attachment article cover`. Run with
# `cybertrain spin test`; its snapshot comes from the compiled binary (the
# database is FFI), `script/regen-snapshot`-style.
require_relative "support/app_test"

# Uploaded files land here, not in storage/uploads.
Cybertrain::BlobStore.root = "tmp/test_uploads"

# A PNG signature, then NUL, 0xFF and CR LF bytes: the server sniffs the
# signature only, the rest shows that every byte survives the round trip.
PNG_BYTES = Cybertrain::Test.binary([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF, 0x0D, 0x0A, 0x00, 0x01])
HTML_BYTES = "<html><script>alert(document.cookie)</script></html>"
SVG_BYTES = '<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"></svg>'

# The text fields of the form besides the file, and the CSRF token. Add the
# other attributes your Article requires.
def article_fields(token)
  fields = { "authenticity_token" => token }
  fields["article[title]"] = "A article"
  fields["article[body]"] = "A article."
  fields
end

def new_client
  Article.all.delete_all
  Session.all.delete_all
  User.all.delete_all
  Dir.glob("tmp/test_uploads/*/*").each { |path| File.delete(path) }
  client = Cybertrain::Test::Client.new(APP)
  AppTest.user
  AppTest.sign_in(client)
  client
end

# POST /articles with one file in article[cover], as the new form sends it.
def create_article(client, filename, type, data)
  client.get("/articles/new")
  token = AppTest.form_token(client)
  field = "article[cover]"
  upload = Cybertrain::Test::Upload.new(field, filename, type, data)
  client.post_multipart("/articles", article_fields(token), [upload])
end

test "a PNG upload is stored on disk and served back with safe headers" do
  client = new_client
  res = create_article(client, "cover.png", "image/png", PNG_BYTES)
  assert_response res, :see_other
  assert_equal 1, Article.count
  record = Article.first
  assert record.cover_attached?
  assert_equal "cover.png", record.cover_filename
  assert_equal "image/png", record.cover_content_type
  assert_equal PNG_BYTES.bytesize, record.cover_byte_size
  assert Cybertrain::BlobStore.exist?(record.cover_key)
  res = client.get("/articles/#{record.id}/cover")
  assert_response res, :ok
  served = res.body
  assert_equal PNG_BYTES.bytesize, served.bytesize
  name = "copy.png"
  data = served.b
  copy = Cybertrain::UploadedFile.new(name, "", data)
  assert_equal record.cover_checksum, copy.sha256_hex
  assert res.header("content-type").to_s.start_with?("image/png"), "content-type"
  assert_equal "nosniff", res.header("x-content-type-options")
  assert res.header("content-disposition").to_s.start_with?("inline"), "content-disposition"
  assert_equal "default-src 'none'; sandbox", res.header("content-security-policy")
  res = client.get("/articles/#{record.id}")
  assert_includes res.body, "/articles/#{record.id}/cover?v="
end

test "HTML and SVG bytes are refused even when named .png and declared image/png" do
  client = new_client
  res = create_article(client, "x.png", "image/png", HTML_BYTES)
  assert_response res, :unprocessable_entity
  assert_includes res.body, "Cover must be a PNG, JPEG, GIF or WebP image"
  res = create_article(client, "logo.png", "image/png", SVG_BYTES)
  assert_response res, :unprocessable_entity
  assert_equal 0, Article.count
  assert_equal 0, Dir.glob("tmp/test_uploads/*/*").size
end

test "a file over the model's limit is a 422 with a message" do
  client = new_client
  big = +""
  big << PNG_BYTES
  big << ("a" * (Article::COVER_MAX_BYTES + 1))
  res = create_article(client, "big.png", "image/png", big)
  assert_response res, :unprocessable_entity
  assert_includes res.body, "Cover is too large (maximum is 2 MB)"
  assert_equal 0, Article.count
end

test "the client's filename is a display name: it never reaches the disk path" do
  client = new_client
  res = create_article(client, "../../evil.png", "image/png", PNG_BYTES)
  assert_response res, :see_other
  record = Article.first
  assert_equal "evil.png", record.cover_filename
  key = record.cover_key
  assert_equal 32, key.bytesize
  assert Cybertrain::BlobStore.valid_key?(key)
  path = Cybertrain::BlobStore.path_for(key)
  refute path.include?("evil"), path
  assert path.start_with?("tmp/test_uploads/"), path
  res = client.get("/articles/#{record.id}/cover")
  assert_includes res.header("content-disposition").to_s, "filename=\"evil.png\""
end

test "replacing the file deletes the old blob; destroying the record deletes the current one" do
  client = new_client
  create_article(client, "one.png", "image/png", PNG_BYTES)
  record = Article.first
  old_key = record.cover_key
  client.get("/articles/#{record.id}/edit")
  token = AppTest.form_token(client)
  field = "article[cover]"
  upload = Cybertrain::Test::Upload.new(field, "two.png", "image/png", PNG_BYTES)
  res = client.patch_multipart("/articles/#{record.id}", article_fields(token), [upload])
  assert_response res, :see_other
  record = Article.find(record.id)
  new_key = record.cover_key
  refute new_key == old_key, "the key changes with the file"
  assert_equal "two.png", record.cover_filename
  refute Cybertrain::BlobStore.exist?(old_key), "the replaced blob is deleted"
  assert Cybertrain::BlobStore.exist?(new_key)
  client.get("/articles/#{record.id}")
  res = client.post("/articles/#{record.id}", { "_method" => "delete", "authenticity_token" => AppTest.form_token(client) })
  assert_response res, :see_other
  assert_equal 0, Article.count
  refute Cybertrain::BlobStore.exist?(new_key), "the destroyed record's blob is deleted"
end

test "a record whose blob is gone answers 404" do
  client = new_client
  create_article(client, "cover.png", "image/png", PNG_BYTES)
  record = Article.first
  File.delete(Cybertrain::BlobStore.path_for(record.cover_key))
  res = client.get("/articles/#{record.id}/cover")
  assert_response res, :not_found
end

test "a multipart POST without the CSRF token is refused" do
  client = new_client
  client.get("/articles/new")
  field = "article[cover]"
  upload = Cybertrain::Test::Upload.new(field, "cover.png", "image/png", PNG_BYTES)
  fields = article_fields("unused")
  fields.delete("authenticity_token")
  res = client.post_multipart("/articles", fields, [upload])
  assert_response res, :forbidden
  assert_equal 0, Article.count
end

# What a browser sends for a file input left empty: filename="" and no
# bytes. The parser drops it, so a form whose only field is the file
# arrives without any article[...] key at all.
test "an update without a file keeps the stored one" do
  client = new_client
  create_article(client, "cover.png", "image/png", PNG_BYTES)
  record = Article.first
  key = record.cover_key
  client.get("/articles/#{record.id}/edit")
  field = "article[cover]"
  empty = Cybertrain::Test::Upload.new(field, "", "application/octet-stream", "")
  res = client.patch_multipart("/articles/#{record.id}", article_fields(AppTest.form_token(client)), [empty])
  assert_response res, :see_other
  record = Article.find(record.id)
  assert_equal key, record.cover_key
  assert Cybertrain::BlobStore.exist?(key)
end

Cybertrain::Test.run!
