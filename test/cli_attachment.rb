require "tmpdir"
require "cybertrain/cli"
require "cybertrain/template"
require "cybertrain/test"
require "cybertrain/generator/crc32"

# `cybertrain generate attachment MODEL FIELD` and the scaffold type
# `FIELD:attachment` on fresh `cybertrain new` trees: the files they write, the
# edits they make, that a second run changes nothing, and that every view
# parses with the template engine. What the generated app does when compiled
# (uploads through the full stack) is script/generators-e2e: the app's own
# test/integration/post_cover_attachment_test.rb, run by `cybertrain test`.
TMP = Dir.mktmpdir("cybertrain-cli-attachment")
Dir.chdir(TMP)

def rm_tree(path)
  if File.directory?(path)
    Dir.children(path).each { |child| rm_tree(File.join(path, child)) }
    Dir.rmdir(path)
  else
    File.delete(path)
  end
end

at_exit do
  Dir.chdir("/")
  rm_tree(TMP)
end

ENV["CYBERTRAIN_TIMESTAMP"] = "20260925120000"
Cybertrain::CLI::NewApp.create("shop", "{ path = \"../cybertrain\" }")
Cybertrain::CLI::Scaffold.generate("shop", "post", ["title:string", "body:text"])

def read(path)
  File.read(path)
end

# Inserts text after the controller's class line. The replacement is made
# before the file is read: written as one expression, read's result was held
# only by a C temporary while the interpolation allocated, and a collection
# there freed it (spikes/NOTES.md rule 65).
def add_after_class(path, text)
  replacement = "ApplicationController\n#{text}"
  source = read(path)
  File.write(path, source.sub("ApplicationController\n", replacement))
end

def count_of(text, piece)
  n = 0
  at = text.index(piece)
  until at.nil?
    n += 1
    at = text.index(piece, at + piece.size)
  end
  n
end

# Refusal must precede migration, model, view, controller and route writes.
def attachment_tree(path)
  out = +""
  Dir.children(path).sort.each do |name|
    child = File.join(path, name)
    out << child << "\n"
    out << (File.directory?(child) ? attachment_tree(child) : File.read(child))
  end
  out
end

def refuse_download(app, model, field)
  before = attachment_tree(app)
  message = assert_raises("InvalidArgument") { Cybertrain::CLI::Attachment.generate(app, model, field, false) }
  assert_includes message, "cannot preserve show's authorization"
  assert_equal before, attachment_tree(app)
end

ATTACH_FILES = [
  "db/migrate/20260925120001_add_cover_to_posts.rb",
  "test/fixtures/files/cover.png",
  "test/integration/post_cover_attachment_test.rb"
]

test "generate attachment writes the migration and the app test, and edits the rest" do
  created = Cybertrain::CLI::Attachment.generate("shop", "post", "cover", false)
  assert_equal ATTACH_FILES, created
  ATTACH_FILES.each { |f| assert(File.exist?("shop/#{f}"), "missing #{f}") }
end

test "the migration adds the five NOT NULL columns with '' and 0 as not attached" do
  assert_equal <<~RUBY, read("shop/db/migrate/20260925120001_add_cover_to_posts.rb")
    class AddCoverToPosts < Cybertrain::Migration::Base
      def change
        add_column "posts", "cover_key", :string, null: false, default: "''"
        add_column "posts", "cover_filename", :string, null: false, default: "''"
        add_column "posts", "cover_content_type", :string, null: false, default: "''"
        add_column "posts", "cover_byte_size", :integer, null: false, default: "0"
        add_column "posts", "cover_checksum", :string, null: false, default: "''"
      end
    end
  RUBY
end

test "the model block is inserted after the class line with prefixed names and callbacks" do
  model = read("shop/app/models/post.rb")
  assert_includes model, "class Post\n  # cybertrain:attachment cover -- written by `cybertrain generate attachment`"
  assert_includes model, "  COVER_TYPES = [\"image/png\", \"image/jpeg\", \"image/gif\", \"image/webp\"]\n"
  assert_includes model, "  COVER_MAX_BYTES = 2_097_152\n"
  assert_includes model, "  before_validation { |post| post.validate_cover_upload }\n"
  assert_includes model, "  before_save { |post| post.store_cover_upload }\n"
  assert_includes model, "  after_save { |post| post.delete_replaced_cover }\n"
  assert_includes model, "  after_destroy { |post| post.purge_cover }\n"
  ["cover_attached?", "cover_url", "validate_cover_upload", "store_cover_upload",
   "delete_replaced_cover", "purge_cover", "cover_pending_upload"].each do |name|
    assert_includes model, "  def #{name}\n"
  end
  assert_includes model, "  def cover_file=(upload)\n    @cover_upload = upload.nil? ? Cybertrain::UploadedFile.blank : upload\n"
  assert_includes model, "\"/posts/\#{id}/cover?v=\#{cover_checksum.to_s[0, 12]}\""
  assert_includes model, "errors.add(:cover, \"is too large (maximum is 2 MB)\") if pending.byte_size > COVER_MAX_BYTES"
  assert_includes model, "errors.add(:cover, \"must be a PNG, JPEG, GIF or WebP image\") unless COVER_TYPES.empty? || COVER_TYPES.include?(pending.detected_content_type)"
  assert_includes model, "Cybertrain::BlobStore.write(key, pending.body_bytes)"
  assert_includes model, "self.cover_content_type = pending.detected_content_type"
  assert_includes model, "self.cover_checksum = pending.sha256_hex"
  assert_includes model, "Cybertrain::BlobStore.delete(old) unless old.empty?"
  # The scaffold's own line is intact below the block.
  assert_includes model, "\n  validates :title, presence: true\nend\n"
  # Never a client-supplied name in a path or a declared type in a decision.
  refute model.include?("declared_content_type"), "the declared type must not be used"
  refute model.include?("File.join"), "no path built from a filename"
end

test "the controller gets the download action and the file assignment in create and update" do
  controller = read("shop/app/controllers/posts_controller.rb")
  # The download loads @post through set_post, so it is scoped like show.
  assert_includes controller, "class PostsController < ApplicationController\n" \
                              "  before_action :set_post, only: [:show, :edit, :update, :destroy, :cover]\n\n" \
                              "  # GET /posts/1/cover -- @post comes from before_action :set_post"
  assert_includes controller, "  def cover\n    if @post.cover_attached? && Cybertrain::BlobStore.exist?(@post.cover_key)\n"
  assert_includes controller, "      send_blob(Cybertrain::BlobStore.read(@post.cover_key), filename: @post.cover_filename, content_type: @post.cover_content_type)\n"
  assert_includes controller, "    else\n      head 404\n    end\n  end\n\n  # GET /posts\n"
  refute controller.include?("Post.find(params[:id])\n    if"), "no unscoped lookup of its own"
  assignment = "@post.cover_file = params.nested(:post).upload(:cover)"
  assert_includes controller, "    @post = Post.new(post_params)\n    #{assignment}\n    if @post.save\n"
  assert_includes controller, "  def update\n    #{assignment}\n    if @post.update(post_params)\n"
  assert_equal 2, count_of(controller, assignment)
  # permit is untouched: a file can only arrive through the assignment.
  assert_includes controller, "params.require(:post).permit(:title, :body)"
  assert controller.end_with?("end\n")
end

test "the route is added before the resource" do
  assert_equal <<~RUBY, read("shop/config/routes.rb")
    Cybertrain::Routes.draw do
      get "/posts/:id/cover", to: "posts#cover", as: "post_cover"
      resources :posts
      # jobs_page "/admin/jobs", before_action: :require_admin
    end
  RUBY
end

test "the form is multipart with a file input, and the show page shows the image" do
  form = read("shop/app/views/posts/_form.html.erb")
  assert_includes form, "<%= form_with(model: post, multipart: true) do |f| %>"
  assert_includes form, "  <div class=\"field\">\n    <%= f.label :cover %>\n    <%= f.file_field :cover, accept: \"image/png,image/jpeg,image/gif,image/webp\" %>\n  </div>\n\n  <div class=\"actions\">"
  show = read("shop/app/views/posts/show.html.erb")
  assert_includes show, "<h1>Post</h1>\n<% if @post.cover_attached? %><p><img src=\"<%= @post.cover_url %>\" alt=\"<%= @post.cover_filename %>\"></p><% end %>\n"
end

test "the .gitignore of a new app ignores the uploads" do
  assert_includes read("shop/.gitignore"), "/storage/uploads/\n"
end

# The chunk types of a PNG, in order, after checking the signature, each
# chunk's length and its CRC-32 (over the type and data); [] when any of
# them is wrong.
def png_chunks(png)
  types = Array.new(0) { "" }
  signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
  i = 0
  while i < 8
    return Array.new(0) { "" } unless png.getbyte(i).to_i == signature[i]

    i += 1
  end
  at = 8
  while at + 12 <= png.bytesize
    length = png_u32(png, at)
    return Array.new(0) { "" } if at + 12 + length > png.bytesize

    typed = png.byteslice(at + 4, 4 + length).to_s
    return Array.new(0) { "" } unless Cybertrain::Gen::Crc32.crc32(typed) == png_u32(png, at + 8 + length)

    types << typed.byteslice(0, 4).to_s
    at += 12 + length
  end
  return Array.new(0) { "" } unless at == png.bytesize

  types
end

# The big-endian 32-bit number at byte at.
def png_u32(png, at)
  (png.getbyte(at).to_i << 24) | (png.getbyte(at + 1).to_i << 16) | (png.getbyte(at + 2).to_i << 8) | png.getbyte(at + 3).to_i
end

test "the generated test covers the security behaviour" do
  spec = read("shop/test/integration/post_cover_attachment_test.rb")
  assert spec.start_with?("require \"test_helper\"\n\n"), spec
  assert_includes spec, "\nclass PostCoverAttachmentTest < ActionDispatch::IntegrationTest\n"
  assert spec.end_with?("\n  end\nend\n"), "the class closes the file"
  assert_includes spec, "  setup do\n    # Uploaded files land here, not in storage/uploads.\n    Cybertrain::BlobStore.root = \"tmp/test_uploads\"\n"
  # T16-N2: the bytes are the fixture file's, read from it, not a copy.
  assert_includes spec, "  PNG_BYTES = File.binread(\"test/fixtures/files/cover.png\")\n"
  assert spec.index("Cybertrain::Test.binary").nil?
  assert_includes spec, "  def post_params(file)\n    { title: \"A post\", cover: file }\n  end\n"
  # Uploads are params: values of the integration test's own requests, in
  # Rails' shape (multipart/form-data because a value is a file): no
  # reaching into its client.
  assert_includes spec, "  def create_post(file)\n    post \"/posts\", params: { post: post_params(file) }\n  end\n"
  assert_includes spec, "  def update_post(record, file)\n    patch \"/posts/\#{record.id}\", params: { post: post_params(file) }\n  end\n"
  assert_includes spec, "  def file_named(filename, type, data)\n    Cybertrain::Test::Upload.new(\"\", filename, type, data)\n  end\n"
  refute spec.include?("integration_client"), "no private state of IntegrationTest"
  # The fixture file the upload reads, where Rails keeps them: a real 1x1
  # PNG (T16-N2), its chunks whole and their CRCs right.
  png = File.binread("shop/test/fixtures/files/cover.png")
  assert_equal Cybertrain::CLI::Attachment::TEST_PNG_FILE, png
  assert_equal ["IHDR", "IDAT", "IEND"], png_chunks(png)
  # 1x1, 8-bit RGBA; the pixel's bytes are zlib-compressed in IDAT.
  assert_equal [1, 1, 8, 6], [png_u32(png, 16), png_u32(png, 20), png.getbyte(24).to_i, png.getbyte(25).to_i]
  assert_equal 0x78, png.getbyte(41).to_i
  assert_includes spec, "assert_equal \"nosniff\", response.header(\"x-content-type-options\")"
  assert_includes spec, "start_with?(\"inline\")"
  assert_includes spec, "assert_equal \"default-src 'none'; sandbox\", response.header(\"content-security-policy\")"
  assert_includes spec, "create_post(file_named(\"x.png\", \"image/png\", HTML_BYTES))"
  assert_includes spec, "create_post(file_named(\"logo.png\", \"image/png\", SVG_BYTES))"
  assert_includes spec, "create_post(file_named(\"../../evil.png\", \"image/png\", PNG_BYTES))"
  assert_includes spec, "assert_equal \"evil.png\", record.cover_filename"
  assert_includes spec, "refute Cybertrain::BlobStore.exist?(old_key)"
  assert_includes spec, "refute Cybertrain::BlobStore.exist?(new_key)"
  # Forgery protection is off in tests (as in Rails): the CSRF test turns it on.
  assert_includes spec, "      with_forgery_protection do\n        create_post(fixture_file_upload(\"cover.png\", \"image/png\"))\n        assert_response :forbidden\n      end\n"
  assert_includes spec, "    get \"/posts/\#{record.id}\"\n    assert_includes response.body, \"/posts/\#{record.id}/cover?v=\"\n  end\n"
  assert_includes spec, "  test \"an update without a file keeps the stored one\" do"
  # Fixtures may hold rows: counts are differences, the new record is last.
  assert_includes spec, "    assert_difference(-> { Post.count }, 1) do\n      create_post(fixture_file_upload(\"cover.png\", \"image/png\"))\n    end\n"
  assert_includes spec, "    assert_no_difference(-> { Post.count }) do\n"
  assert_includes spec, "    record = Post.last\n"
  assert_includes spec, "    assert_difference(-> { Post.count }, -1) do\n      delete \"/posts/\#{record.id}\"\n    end\n"
  refute spec.include?("Post.first"), "fixture rows come first"
  # The top-level form's pieces are gone: no new_client, AppTest, APP or run!.
  ["new_client", "AppTest", "APP", "Cybertrain::Test.run!", "require_relative", "Cybertrain::Test::Client.new"].each do |piece|
    refute spec.include?(piece), "still has #{piece}"
  end
  # No authentication in this app: no sign-in.
  refute spec.include?("/session"), "no sign-in without authentication"
  ["<<Model>>", "<<model>>", "<<plural>>", "<<field>>", "<<Field>>", "<<FIELD>>", "<<fields_hash>>",
   "<<TestClass>>", "<<sign_in>>", "<<show_check>>"].each { |holder| refute spec.include?(holder), "unfilled #{holder}" }
end

test "no generator writes test/support/app_test.rb" do
  refute File.exist?("shop/test/support/app_test.rb")
end

test "running the generator again writes and edits nothing" do
  files = ATTACH_FILES + ["config/routes.rb", "app/models/post.rb", "app/controllers/posts_controller.rb",
                          "app/views/posts/_form.html.erb", "app/views/posts/show.html.erb", ".gitignore"]
  before = {}
  files.each { |f| before[f] = read("shop/#{f}") }
  status = Dir.chdir("shop") { Cybertrain::CLI.run(["generate", "attachment", "post", "cover"]) }
  assert_equal 0, status
  before.each { |f, content| assert_equal content, read("shop/#{f}") }
  assert_equal 2, Dir.children("shop/db/migrate").select { |f| f.end_with?(".rb") }.size
end

test "the views the generator edited parse with the template engine" do
  ["posts/_form", "posts/show", "posts/index"].each do |name|
    template = Cybertrain::Template::Template.parse(read("shop/app/views/#{name}.html.erb"), "#{name}.html.erb")
    assert template.nodes.size > 0, name
  end
end

test "a second field, and an existing CamelCase or plural model name, work" do
  created = Cybertrain::CLI::Attachment.generate("shop", "Posts", "avatar", false)
  assert_includes created, "db/migrate/20260925120002_add_avatar_to_posts.rb"
  assert_includes created, "test/integration/post_avatar_attachment_test.rb"
  assert_includes created, "test/fixtures/files/avatar.png"
  # Each test class keeps its constants: two attachment tests define no
  # top-level name twice (the bundle refuses that).
  assert_includes read("shop/test/integration/post_avatar_attachment_test.rb"), "class PostAvatarAttachmentTest < ActionDispatch::IntegrationTest\n  # test/fixtures/files/avatar.png: a 1x1 PNG"
  model = read("shop/app/models/post.rb")
  assert_includes model, "# cybertrain:attachment avatar -- "
  assert_includes model, "  def avatar_file=(upload)\n"
  assert_equal 1, count_of(model, "# cybertrain:attachment cover -- ")
  controller = read("shop/app/controllers/posts_controller.rb")
  assert_includes controller, "  def avatar\n"
  assert_includes controller, "before_action :set_post, only: [:show, :edit, :update, :destroy, :cover, :avatar]\n"
  assert_includes controller, "    @post.avatar_file = params.nested(:post).upload(:avatar)\n"
  assert_includes controller, "    @post.cover_file = params.nested(:post).upload(:cover)\n"
  form = read("shop/app/views/posts/_form.html.erb")
  assert_equal 1, count_of(form, "multipart: true")
  assert_includes form, "<%= f.file_field :avatar, accept:"
  assert_includes read("shop/config/routes.rb"), "  get \"/posts/:id/avatar\", to: \"posts#avatar\", as: \"post_avatar\"\n"
end

# The avatar line now sits between `@post = Post.new(post_params)` and the
# cover line: a re-run must still find the cover line in create and update.
test "with two fields, running the generator for either again changes nothing" do
  files = ["app/models/post.rb", "app/controllers/posts_controller.rb", "app/views/posts/_form.html.erb",
           "app/views/posts/show.html.erb", "config/routes.rb"]
  before = {}
  files.each { |f| before[f] = read("shop/#{f}") }
  ["cover", "avatar"].each do |field|
    assert_equal 0, Dir.chdir("shop") { Cybertrain::CLI.run(["generate", "attachment", "post", field]) }
  end
  before.each { |f, content| assert_equal content, read("shop/#{f}") }
  controller = read("shop/app/controllers/posts_controller.rb")
  assert_equal 2, count_of(controller, "@post.cover_file = ")
  assert_equal 2, count_of(controller, "@post.avatar_file = ")
  assert_includes controller, "only: [:show, :edit, :update, :destroy, :cover, :avatar]\n"
  assert_equal 1, count_of(controller, "\n  before_action :set_post")
end

test "a field whose name starts another field's name still gets its file input" do
  Cybertrain::CLI::NewApp.create("press", "{ path = \"../cybertrain\" }")
  Cybertrain::CLI::Scaffold.generate("press", "post", ["title:string"])
  Cybertrain::CLI::Attachment.generate("press", "post", "cover_url", false)
  Cybertrain::CLI::Attachment.generate("press", "post", "cover", false)
  form = read("press/app/views/posts/_form.html.erb")
  assert_includes form, "<%= f.file_field :cover_url, accept:"
  assert_includes form, "<%= f.file_field :cover, accept:"
  show = read("press/app/views/posts/show.html.erb")
  assert_equal 1, count_of(show, "@post.cover_url %>")
  assert_equal 1, count_of(show, "@post.cover_url_url %>")
  assert_includes read("press/test/integration/post_cover_attachment_test.rb"), "/posts/\#{record.id}/cover?v="
  assert_equal 1, count_of(form, ":cover,")
end

# db migrate has run: schema.rb has posts.cover_key. Another table may use
# the same name, and a re-run of the same attachment is not an error.
test "the schema check looks at the owner's table, and a re-run after db migrate is identical" do
  File.write("press/db/schema.rb", "Cybertrain::Schema.define(version: \"20260925120002\") do |s|\n" \
                                   "  s.create_table \"posts\" do |t|\n    t.string \"cover_key\", null: false, default: \"''\"\n  end\n\n" \
                                   "  s.create_table \"tags\" do |t|\n    t.string \"name\"\n  end\nend\n")
  model = read("press/app/models/post.rb")
  assert_equal 0, Dir.chdir("press") { Cybertrain::CLI.run(["generate", "attachment", "post", "cover"]) }
  assert_equal model, read("press/app/models/post.rb")
  Cybertrain::CLI::Scaffold.generate("press", "tag", ["name:string"])
  created = Cybertrain::CLI::Attachment.generate("press", "tag", "cover", false)
  assert_includes created, "test/integration/tag_cover_attachment_test.rb"
  assert_includes read("press/app/models/tag.rb"), "# cybertrain:attachment cover -- "
  # posts.cover_key with no attachment block in Post is someone else's column.
  File.write("press/app/models/post.rb", "class Post\nend\n")
  message = assert_raises("InvalidArgument") { Cybertrain::CLI::Attachment.generate("press", "post", "cover", false) }
  assert_includes message, "already has a \"cover_key\" column in \"posts\""
end

test "--any allows any file: no accept, no type check, a link instead of an image" do
  Cybertrain::CLI::NewApp.create("docs", "{ path = \"../cybertrain\" }")
  Cybertrain::CLI::Scaffold.generate("docs", "report", ["title:string"])
  status = Dir.chdir("docs") { Cybertrain::CLI.run(["generate", "attachment", "report", "file_upload", "--any"]) }
  assert_equal 0, status
  model = read("docs/app/models/report.rb")
  assert_includes model, "  FILE_UPLOAD_TYPES = Array.new(0) { \"\" }\n"
  refute model.include?("must be a PNG"), "no type message with --any"
  assert_includes model, "    errors.add(:file_upload, \"is too large (maximum is 2 MB)\") if pending.byte_size > FILE_UPLOAD_MAX_BYTES\n    nil\n"
  form = read("docs/app/views/reports/_form.html.erb")
  assert_includes form, "    <%= f.file_field :file_upload %>\n"
  show = read("docs/app/views/reports/show.html.erb")
  assert_includes show, "<h1>Report</h1>\n<% if @report.file_upload_attached? %><p><a href=\"<%= @report.file_upload_url %>\"><%= @report.file_upload_filename %></a></p><% end %>\n"
  spec = read("docs/test/integration/report_file_upload_attachment_test.rb")
  assert_includes spec, "class ReportFileUploadAttachmentTest < ActionDispatch::IntegrationTest\n"
  assert_includes spec, "test \"any file is accepted, stored as a download and never served inline\" do"
  assert_includes spec, "assert response.header(\"content-disposition\").to_s.start_with?(\"attachment\"), \"content-disposition\""
  refute spec.include?("HTML and SVG bytes are refused"), "no refusal test with --any"
  assert_includes read("docs/db/migrate/20260925120001_add_file_upload_to_reports.rb"), "class AddFileUploadToReports < Cybertrain::Migration::Base"
end

test "with authentication the generated test signs in first" do
  Cybertrain::CLI::NewApp.create("club", "{ path = \"../cybertrain\" }")
  Cybertrain::CLI::Authentication.generate("club")
  Cybertrain::CLI::Scaffold.generate("club", "post", ["title:string"])
  Cybertrain::CLI::Attachment.generate("club", "post", "cover", false)
  spec = read("club/test/integration/post_cover_attachment_test.rb")
  # The fixture user `one` signed in through the form in setup
  # (SessionTestHelper#sign_in_as), before the upload directory is emptied;
  # the integration test's own client keeps the cookie.
  assert_includes spec, "  setup do\n" \
                        "    # A user signed in through the form: the controller's actions need one.\n" \
                        "    sign_in_as users(:one)\n" \
                        "    # Uploaded files land here, not in storage/uploads.\n"
  refute spec.include?("confirmed_at"), "not --confirmable"
  refute spec.include?("User.new"), "the fixture's user"
  refute spec.include?("AppTest"), "no AppTest"
  assert_includes spec, "    delete \"/session\"\n    get \"/posts/\#{record.id}/cover\"\n    assert_redirected_to \"/session/new\"\n"
end

test "with --confirmable authentication the signed-in user is the fixtures' confirmed one" do
  Cybertrain::CLI::NewApp.create("guard", "{ path = \"../cybertrain\" }")
  Cybertrain::CLI::Authentication.generate("guard", false, true)
  Cybertrain::CLI::Scaffold.generate("guard", "post", ["title:string"])
  Cybertrain::CLI::Attachment.generate("guard", "post", "cover", false)
  spec = read("guard/test/integration/post_cover_attachment_test.rb")
  assert_includes spec, "    sign_in_as users(:one)\n"
  assert_includes read("guard/test/fixtures/users.yml"), "  confirmed_at: 2026-11-11 12:00:00\n"
end

# The tutorial's blog at step 14: step 05 gave the body a minimum length and
# step 13 opened index and show to visitors. The cover is on the show page,
# so its download opens with it, and the test's body is long enough.
test "where show is public the download joins it, and the test's values meet the length rules" do
  Cybertrain::CLI::NewApp.create("blog", "{ path = \"../cybertrain\" }")
  Cybertrain::CLI::Scaffold.generate("blog", "article", ["title:string", "body:text"])
  Cybertrain::CLI::Authentication.generate("blog")
  model = read("blog/app/models/article.rb").sub("  validates :title, presence: true\n", "  validates :title, presence: true\n  validates :body, presence: true, length: { minimum: 10 }\n")
  File.write("blog/app/models/article.rb", model)
  controller_path = "blog/app/controllers/articles_controller.rb"
  open_line = "  allow_unauthenticated_access only: [:index, :show]\n"
  add_after_class(controller_path, open_line)
  Cybertrain::CLI::Attachment.generate("blog", "article", "cover", false)
  controller = read(controller_path)
  assert_includes controller, "  allow_unauthenticated_access only: [:index, :show, :cover]\n"
  assert_includes controller, "  before_action :set_article, only: [:show, :edit, :update, :destroy, :cover]\n"
  spec = read("blog/test/integration/article_cover_attachment_test.rb")
  assert_includes spec, "  def article_params(file)\n    { title: \"A article\", body: \"A article.\", cover: file }\n  end\n"
  assert_includes spec, "test \"the download is public like show: a visitor gets the file\" do"
  refute spec.include?("/session/new"), "no sign-in redirect expected"
  Cybertrain::CLI::Attachment.generate("blog", "article", "cover", false)
  assert_equal controller, read(controller_path)
  assert_equal spec, read("blog/test/integration/article_cover_attachment_test.rb")
end

test "a download stays private where show is, and a maximum length cuts the value" do
  Cybertrain::CLI::NewApp.create("desk", "{ path = \"../cybertrain\" }")
  Cybertrain::CLI::Scaffold.generate("desk", "memo", ["title:string"])
  Cybertrain::CLI::Authentication.generate("desk")
  model = read("desk/app/models/memo.rb").sub("validates :title, presence: true\n", "validates :title, presence: true, length: { maximum: 3 }\n")
  File.write("desk/app/models/memo.rb", model)
  controller_path = "desk/app/controllers/memos_controller.rb"
  File.write(controller_path, read(controller_path).sub("ApplicationController\n", "ApplicationController\n  allow_unauthenticated_access only: [:index]\n"))
  Cybertrain::CLI::Attachment.generate("desk", "memo", "scan", true)
  assert_includes read(controller_path), "  allow_unauthenticated_access only: [:index]\n"
  spec = read("desk/test/integration/memo_scan_attachment_test.rb")
  assert_includes spec, "    { title: \"A m\", scan: file }\n"
  assert_includes spec, "assert_redirected_to \"/session/new\""
end

# except: wins over only: (Callback#applies?), so this show needs a sign-in;
# and a download without shared authorization is refused before any writes.
test "show restrictions are preserved or attachment generation is refused" do
  Cybertrain::CLI::NewApp.create("yard", "{ path = \"../cybertrain\" }")
  Cybertrain::CLI::Scaffold.generate("yard", "plan", ["title:string"])
  Cybertrain::CLI::Authentication.generate("yard")
  controller_path = "yard/app/controllers/plans_controller.rb"
  closed_line = "  allow_unauthenticated_access only: [:index, :show], except: [:show]\n"
  add_after_class(controller_path, closed_line)
  Cybertrain::CLI::Attachment.generate("yard", "plan", "photo", false)
  assert_includes read(controller_path), closed_line
  assert_includes read("yard/test/integration/plan_photo_attachment_test.rb"), "assert_redirected_to \"/session/new\""

  Cybertrain::CLI::NewApp.create("barn", "{ path = \"../cybertrain\" }")
  Cybertrain::CLI::Scaffold.generate("barn", "plan", ["title:string"])
  Cybertrain::CLI::Authentication.generate("barn")
  controller_path = "barn/app/controllers/plans_controller.rb"
  source = read(controller_path).sub("ApplicationController\n", "ApplicationController\n  allow_unauthenticated_access only: [:index, :show]\n")
  File.write(controller_path, source.sub("  before_action :set_plan, only: [:show, :edit, :update, :destroy]\n", ""))
  refuse_download("barn", "plan", "photo")

  # A shared lookup alone does not preserve a separate show-only policy.
  public_line = "  allow_unauthenticated_access only: [:index, :show]\n"
  Cybertrain::CLI::NewApp.create("loft", "{ path = \"../cybertrain\" }")
  Cybertrain::CLI::Scaffold.generate("loft", "plan", ["title:string"])
  Cybertrain::CLI::Authentication.generate("loft")
  controller_path = "loft/app/controllers/plans_controller.rb"
  add_after_class(controller_path, "#{public_line}  before_action :hide_drafts, only: [:show]\n")
  refuse_download("loft", "plan", "photo")

  Cybertrain::CLI::NewApp.create("shed", "{ path = \"../cybertrain\" }")
  Cybertrain::CLI::Scaffold.generate("shed", "plan", ["title:string"])
  Cybertrain::CLI::Authentication.generate("shed")
  controller_path = "shed/app/controllers/plans_controller.rb"
  add_after_class(controller_path, public_line)

  # A callback it cannot read prevents generation too: a before_action
  # continued on the next line, a list it cannot parse.
  [
    ["coop", "  before_action :hide_drafts,\n                only: [:show]\n"],
    ["hive", "  before_action :hide_drafts, only: %i[show]\n"]
  ].each do |app, callback|
    Cybertrain::CLI::NewApp.create(app, "{ path = \"../cybertrain\" }")
    Cybertrain::CLI::Scaffold.generate(app, "plan", ["title:string"])
    Cybertrain::CLI::Authentication.generate(app)
    controller_path = "#{app}/app/controllers/plans_controller.rb"
    add_after_class(controller_path, "#{public_line}#{callback}")
    refuse_download(app, "plan", "photo")
  end
end

# Code inside def show cannot be read for what it checks, so it is accepted
# with a warning (the lines are in the snapshot), and the download is not
# made public with show: it keeps the sign-in until the application says so.
test "a show with a body is accepted, warned about, and its download stays private" do
  public_line = "  allow_unauthenticated_access only: [:index, :show]\n"
  [
    ["shed", "  def show\n    head 404 if @plan.title.empty?\n  end\n"],
    ["nook", "  def show\n    @note = Note.new\n    respond_to do |format|\n      format.html\n      format.json { render json: @plan.as_json }\n    end\n  end\n"],
    ["pen", "  def show; end\n"]
  ].each do |app, show|
    Cybertrain::CLI::NewApp.create(app, "{ path = \"../cybertrain\" }")
    Cybertrain::CLI::Scaffold.generate(app, "plan", ["title:string"])
    Cybertrain::CLI::Authentication.generate(app)
    controller_path = "#{app}/app/controllers/plans_controller.rb"
    add_after_class(controller_path, public_line)
    File.write(controller_path, read(controller_path).sub("  def show\n  end\n", show))
    Cybertrain::CLI::Attachment.generate(app, "plan", "photo", false)
    controller = read(controller_path)
    assert_includes controller, "  def photo\n"
    assert_includes controller, show
    assert_includes controller, public_line
    assert_includes controller, "  before_action :set_plan, only: [:show, :edit, :update, :destroy, :photo]\n"
    assert_includes read("#{app}/test/integration/plan_photo_attachment_test.rb"), "assert_redirected_to \"/session/new\""

    # A second run edits nothing and does not warn again about an action
    # it did not add.
    before = attachment_tree(app)
    Cybertrain::CLI::Attachment.generate(app, "plan", "photo", false)
    assert_equal before, attachment_tree(app)
  end
end

# Without authentication nothing keeps the download closed: the warning is
# all there is, so it is printed here too.
test "a show with a body is accepted without authentication as well" do
  Cybertrain::CLI::NewApp.create("open", "{ path = \"../cybertrain\" }")
  Cybertrain::CLI::Scaffold.generate("open", "plan", ["title:string"])
  controller_path = "open/app/controllers/plans_controller.rb"
  File.write(controller_path, read(controller_path).sub("  def show\n  end\n", "  def show\n    @note = Note.new\n  end\n"))
  Cybertrain::CLI::Attachment.generate("open", "plan", "photo", false)
  assert_includes read(controller_path), "  def photo\n"
  assert_includes read(controller_path), "  def show\n    @note = Note.new\n  end\n"
end

# Authentication is independent of record/role authorization. These checks
# apply even when no authentication generator (or public-access list) exists.
test "a show-only policy is refused for authenticated users too" do
  Cybertrain::CLI::NewApp.create("restricted", "{ path = \"../cybertrain\" }")
  Cybertrain::CLI::Scaffold.generate("restricted", "plan", ["title:string"])
  Cybertrain::CLI::Authentication.generate("restricted")
  path = "restricted/app/controllers/plans_controller.rb"
  source = read(path).sub("ApplicationController\n", "ApplicationController\n  before_action :require_owner, only: [:show]\n")
  File.write(path, source)
  refuse_download("restricted", "plan", "photo")

  # Sharing the explicit callback permits generation without changing it.
  File.write(path, source.sub("only: [:show]", "only: [:show, :photo]"))
  Cybertrain::CLI::Attachment.generate("restricted", "plan", "photo", false)
  assert_includes read(path), "before_action :require_owner, only: [:show, :photo]"
  assert_includes read(path), "def photo\n"

  # Existing actions are left alone: preflight must not assume add_action
  # will extend their lookup callback when it will actually skip the edit.
  File.write(path, read(path).sub(":destroy, :photo]", ":destroy]"))
  refuse_download("restricted", "plan", "photo")
end

test "inherited show-only authorization cannot be bypassed by a public download" do
  Cybertrain::CLI::NewApp.create("inherited", "{ path = \"../cybertrain\" }")
  Cybertrain::CLI::Scaffold.generate("inherited", "plan", ["title:string"])
  Cybertrain::CLI::Authentication.generate("inherited")
  path = "inherited/app/controllers/plans_controller.rb"
  File.write(path, read(path).sub("ApplicationController\n", "ApplicationController\n  allow_unauthenticated_access only: [:index, :show]\n"))
  parent = "inherited/app/controllers/application_controller.rb"
  source = read(parent).sub("Cybertrain::Controller\n", "Cybertrain::Controller\n  before_action :require_reader, only: [:show]\n")
  File.write(parent, source)
  refuse_download("inherited", "plan", "photo")

  # A policy further up the ancestry is checked as well.
  File.write(parent, source.sub("Cybertrain::Controller", "AccessController").sub("  before_action :require_reader, only: [:show]\n", ""))
  File.write("inherited/app/controllers/access_controller.rb", "class AccessController < Cybertrain::Controller\n  before_action :require_reader, only: [:show]\nend\n")
  refuse_download("inherited", "plan", "photo")
  File.write("inherited/app/controllers/access_controller.rb", "class AccessController < Cybertrain::Controller\n  before_action :require_reader, only: [:show, :photo]\nend\n")
  Cybertrain::CLI::Attachment.generate("inherited", "plan", "photo", false)
  assert_includes read(path), "allow_unauthenticated_access only: [:index, :show, :photo]"
end

# ApplicationController's `include Authentication` brings the concern's
# callbacks: they are read from the concern, which must exist.
test "the Authentication concern's callbacks count as ApplicationController's" do
  Cybertrain::CLI::NewApp.create("concerned", "{ path = \"../cybertrain\" }")
  Cybertrain::CLI::Scaffold.generate("concerned", "plan", ["title:string"])
  Cybertrain::CLI::Authentication.generate("concerned")
  path = "concerned/app/controllers/plans_controller.rb"
  File.write(path, read(path).sub("ApplicationController\n", "ApplicationController\n  allow_unauthenticated_access only: [:index, :show]\n"))
  concern = "concerned/app/controllers/concerns/authentication.rb"
  original = read(concern)
  File.write(concern, original.sub("    before_action :require_authentication\n", "    before_action :require_authentication\n    before_action :require_reader, only: [:show]\n"))
  refuse_download("concerned", "plan", "photo")
  File.delete(concern)
  refuse_download("concerned", "plan", "photo")
  File.write(concern, original)
  # The include line is recognised as `generate authentication` recognises
  # it (Authentication.include_line?): a trailing comment too, a commented
  # one not (an unknown include line still refuses).
  parent = "concerned/app/controllers/application_controller.rb"
  included = read(parent)
  File.write(parent, included.sub("  include Authentication\n", "  include AuthenticationHelpers\n"))
  refuse_download("concerned", "plan", "photo")
  File.write(parent, included.sub("  include Authentication\n", "  include Authentication # sign-in\n"))
  Cybertrain::CLI::Attachment.generate("concerned", "plan", "photo", false)
  assert_includes read(path), "allow_unauthenticated_access only: [:index, :show, :photo]"
end

test "unknown inherited policies and asymmetric skips refuse attachment scaffolds before writing" do
  Cybertrain::CLI::NewApp.create("unknown", "{ path = \"../cybertrain\" }")
  parent = "unknown/app/controllers/application_controller.rb"
  original = read(parent)
  [
    original.sub("Cybertrain::Controller", "MissingController"),
    original.sub("Cybertrain::Controller", "ApplicationController"),
    original.sub("Cybertrain::Controller\n", "Cybertrain::Controller\n  include AccessPolicy\n"),
    original.sub("Cybertrain::Controller\n", "Cybertrain::Controller\n  before_action :require_reader, only: %i[show]\n"),
    original.sub("Cybertrain::Controller\n", "Cybertrain::Controller\n  skip_before_action :require_reader, only: [:photo]\n"),
    original.sub("Cybertrain::Controller\n", "Cybertrain::Controller\n  self.before_action :require_reader, only: [:show]\n"),
    original.sub("Cybertrain::Controller\n", "Cybertrain::Controller\n  before_action :require_reader, only: [:photo], only: [:show]\n"),
    original.sub("Cybertrain::Controller\n", "Cybertrain::Controller\n  allow_unauthenticated_access only: [:photo]\n")
  ].each do |source|
    File.write(parent, source)
    before = attachment_tree("unknown")
    message = assert_raises("InvalidArgument") { Cybertrain::CLI::Scaffold.generate("unknown", "plan", ["title:string", "photo:attachment"]) }
    assert_includes message, "cannot preserve show's authorization"
    assert_equal before, attachment_tree("unknown")
  end
end

# The other order (CI's end-to-end app): the test was written without a
# sign-in, and every action redirects once authentication is added.
test "authentication generated after the attachment adds the sign-in to its test" do
  Cybertrain::CLI::NewApp.create("guild", "{ path = \"../cybertrain\" }")
  Cybertrain::CLI::Scaffold.generate("guild", "product", ["name:string"])
  Cybertrain::CLI::Attachment.generate("guild", "product", "photo", true)
  path = "guild/test/integration/product_photo_attachment_test.rb"
  refute read(path).include?("sign_in_as"), "no sign-in before authentication"
  File.write("guild/test/integration/notes_attachment_test.rb", "# written by hand\n")
  Cybertrain::CLI::Authentication.generate("guild")
  spec = read(path)
  assert_includes spec, "  setup do\n    # A user signed in through the form: the controller's actions need one.\n" \
                        "    sign_in_as users(:one)\n" \
                        "    # Uploaded files land here, not in storage/uploads.\n"
  assert_equal 1, count_of(spec, "sign_in_as")
  assert_equal "# written by hand\n", read("guild/test/integration/notes_attachment_test.rb")
  Cybertrain::CLI::Authentication.generate("guild")
  assert_equal spec, read(path)
end

test "a controller without a shared lookup cannot generate an unscoped download" do
  Cybertrain::CLI::NewApp.create("bare", "{ path = \"../cybertrain\" }")
  File.write("bare/app/models/note.rb", "class Note\nend\n")
  File.write("bare/app/controllers/notes_controller.rb", "class NotesController < ApplicationController\n  def index\n  end\nend\n")
  refuse_download("bare", "note", "scan")
  refute read("bare/app/controllers/notes_controller.rb").include?("def scan"), "no unscoped download"
end

# Update must have loaded @card before the assignment runs, or it is a
# NoMethodError on nil for every PATCH.
test "update gets the assignment only where the record is loaded" do
  File.write("bare/app/models/card.rb", "class Card\nend\n")
  File.write("bare/app/controllers/cards_controller.rb",
             "class CardsController < ApplicationController\n  before_action :set_card, only: [:show]\n\n  def show\n  end\n\n  def update\n    @card = Card.find(params[:id])\n" \
             "    if @card.update(card_params)\n    end\n  end\n\n  private\n\n  def card_params\n    params.require(:card).permit()\n  end\nend\n")
  Cybertrain::CLI::Attachment.generate("bare", "card", "face", false)
  controller = read("bare/app/controllers/cards_controller.rb")
  assert_includes controller, "  def update\n    @card = Card.find(params[:id])\n    @card.face_file = params.nested(:card).upload(:face)\n    if @card"
  # A form of nothing but files sends no card[...] key without a file.
  assert_includes controller, "params.nested(:card).permit()"
  # set_list loads @list but not for update; and before_action :set_list
  # without only: covers every action, the download included.
  File.write("bare/app/models/list.rb", "class List\nend\n")
  File.write("bare/app/controllers/lists_controller.rb",
             "class ListsController < ApplicationController\n  before_action :set_list, only: [:show]\n\n  def show\n  end\n\n  def update\n    head 204\n  end\nend\n")
  Cybertrain::CLI::Attachment.generate("bare", "list", "icon", false)
  controller = read("bare/app/controllers/lists_controller.rb")
  refute controller.include?("icon_file ="), "update does not load @list"
  assert_includes controller, "  before_action :set_list, only: [:show, :icon]\n"
  File.write("bare/app/models/tray.rb", "class Tray\nend\n")
  File.write("bare/app/controllers/trays_controller.rb",
             "class TraysController < ApplicationController\n  before_action :set_tray\n\n  def show\n  end\n\n  def update\n    head 204\n  end\nend\n")
  Cybertrain::CLI::Attachment.generate("bare", "tray", "logo", false)
  controller = read("bare/app/controllers/trays_controller.rb")
  assert_includes controller, "  before_action :set_tray\n\n  # GET /trays/1/logo -- @tray comes from"
  assert_includes controller, "  def update\n    @tray.logo_file = params.nested(:tray).upload(:logo)\n    head 204\n"
end

test "a bad field, model or tree is refused before anything is written" do
  Cybertrain::CLI::NewApp.create("strict", "{ path = \"../cybertrain\" }")
  Cybertrain::CLI::Scaffold.generate("strict", "post", ["title:string"])
  ["Cover", "9cover", "co-ver", "", "class", "index", "create", "update", "errors"].each do |field|
    assert_raises("InvalidArgument") { Cybertrain::CLI::Attachment.generate("strict", "post", field, false) }
  end
  # `def <field>` would redefine a method every controller has (params,
  # head, ...), one the generated ApplicationController has, or the
  # scaffold's own private helpers.
  ["params", "session", "flash", "request", "response", "head", "render", "redirect_to", "send_blob",
   "process", "initialize", "record_not_found", "require_authentication", "set_post", "post_params"].each do |field|
    message = assert_raises("InvalidArgument") { Cybertrain::CLI::Attachment.generate("strict", "post", field, false) }
    assert_includes message, "would redefine a method of PostsController"
  end
  refute File.exist?("strict/test/integration/post_params_attachment_test.rb")
  message = assert_raises("InvalidArgument") { Cybertrain::CLI::Attachment.generate("strict", "article", "cover", false) }
  assert_includes message, "app/models/article.rb not found"
  File.delete("strict/app/controllers/posts_controller.rb")
  message = assert_raises("InvalidArgument") { Cybertrain::CLI::Attachment.generate("strict", "post", "cover", false) }
  assert_includes message, "app/controllers/posts_controller.rb not found"
  File.write("strict/app/controllers/posts_controller.rb", "class PostsController < Base\nend\n")
  message = assert_raises("InvalidArgument") { Cybertrain::CLI::Attachment.generate("strict", "post", "cover", false) }
  assert_includes message, "class PostsController < ApplicationController"
  File.write("strict/app/models/post.rb", "module Post\nend\n")
  message = assert_raises("InvalidArgument") { Cybertrain::CLI::Attachment.generate("strict", "post", "cover", false) }
  assert_includes message, "has no `class Post` line"
  File.write("strict/config/routes.rb", "Routes.draw do\nend\n")
  message = assert_raises("InvalidArgument") { Cybertrain::CLI::Attachment.generate("strict", "post", "cover", false) }
  assert_includes message, "Cybertrain::Routes.draw do"
  assert_equal ["20260925120000_create_posts.rb"], Dir.children("strict/db/migrate").select { |f| f.end_with?(".rb") }
  refute File.exist?("strict/test/integration/post_cover_attachment_test.rb")
  File.write("strict/db/schema.rb", "create_table \"posts\" do |t|\n  t.string \"cover_key\"\nend\n")
  File.write("strict/config/routes.rb", "Cybertrain::Routes.draw do\nend\n")
  File.write("strict/app/models/post.rb", "class Post\nend\n")
  File.write("strict/app/controllers/posts_controller.rb", "class PostsController < ApplicationController\nend\n")
  message = assert_raises("InvalidArgument") { Cybertrain::CLI::Attachment.generate("strict", "post", "cover", false) }
  assert_includes message, "already has a \"cover_key\" column"
end

test "the command line: usage, --any, and the unknown generator message" do
  assert_equal 1, Cybertrain::CLI.run(["generate", "attachment"])
  assert_equal 1, Cybertrain::CLI.run(["generate", "attachment", "post"])
  assert_equal 1, Cybertrain::CLI.run(["generate", "attachment", "post", "cover", "extra"])
  assert_equal 1, Cybertrain::CLI.run(["generate", "scaffold", "--any"])
  assert_equal 1, Cybertrain::CLI.run(["generate", "passwords"])
  assert_includes Cybertrain::CLI::USAGE, "cybertrain generate attachment MODEL FIELD [--any]"
  assert_includes Cybertrain::CLI::USAGE, "attachment"
end

# ---- generate scaffold NAME field:attachment ------------------------------

test "the scaffold type writes the columns in create_table and no second migration" do
  Cybertrain::CLI::NewApp.create("gallery", "{ path = \"../cybertrain\" }")
  created = Cybertrain::CLI::Scaffold.generate("gallery", "photo", ["title:string", "image:attachment"])
  assert_equal [
    "db/migrate/20260925120000_create_photos.rb",
    "app/models/photo.rb",
    "test/models/photo_test.rb",
    "test/fixtures/photos.yml",
    "app/controllers/photos_controller.rb",
    "app/views/photos/index.html.erb",
    "app/views/photos/show.html.erb",
    "app/views/photos/new.html.erb",
    "app/views/photos/edit.html.erb",
    "app/views/photos/_form.html.erb",
    "test/controllers/photos_controller_test.rb",
    "test/fixtures/files/image.png",
    "test/integration/photo_image_attachment_test.rb"
  ], created
  assert_equal <<~RUBY, read("gallery/db/migrate/20260925120000_create_photos.rb")
    class CreatePhotos < Cybertrain::Migration::Base
      def change
        create_table "photos" do |t|
          t.string "title"
          t.string "image_key", null: false, default: "''"
          t.string "image_filename", null: false, default: "''"
          t.string "image_content_type", null: false, default: "''"
          t.integer "image_byte_size", null: false, default: "0"
          t.string "image_checksum", null: false, default: "''"
          t.timestamps
        end
      end
    end
  RUBY
  assert_equal 1, Dir.children("gallery/db/migrate").select { |f| f.end_with?(".rb") }.size
end

test "the scaffold type edits the model, controller and routes the way the generator does" do
  model = read("gallery/app/models/photo.rb")
  assert_includes model, "class Photo\n  # cybertrain:attachment image -- "
  assert_includes model, "  before_validation { |photo| photo.validate_image_upload }\n"
  assert_includes model, "  validates :title, presence: true\n"
  controller = read("gallery/app/controllers/photos_controller.rb")
  # permit has the title only: the file is never mass-assigned.
  assert_includes controller, "params.require(:photo).permit(:title)"
  assert_includes controller, "    @photo = Photo.new(photo_params)\n    @photo.image_file = params.nested(:photo).upload(:image)\n"
  assert_includes controller, "  def update\n    @photo.image_file = params.nested(:photo).upload(:image)\n"
  assert_includes controller, "  def image\n    if @photo.image_attached?"
  assert_includes controller, "before_action :set_photo, only: [:show, :edit, :update, :destroy, :image]\n"
  # The title is a field, so require stays.
  assert_includes controller, "params.require(:photo).permit(:title)"
  assert_equal <<~RUBY, read("gallery/config/routes.rb")
    Cybertrain::Routes.draw do
      get "/photos/:id/image", to: "photos#image", as: "photo_image"
      resources :photos
      # jobs_page "/admin/jobs", before_action: :require_admin
    end
  RUBY
end

test "the scaffold type's views are multipart, show the file and parse" do
  form = read("gallery/app/views/photos/_form.html.erb")
  assert_includes form, "<%= form_with(model: photo, multipart: true) do |f| %>"
  assert_includes form, "    <%= f.label :image %>\n    <%= f.file_field :image, accept: \"image/png,image/jpeg,image/gif,image/webp\" %>\n"
  index = read("gallery/app/views/photos/index.html.erb")
  assert_includes index, "      <th>Image</th>\n"
  assert_includes index, "<td><% if photo.image_attached? %><a href=\"<%= photo.image_url %>\"><%= photo.image_filename %></a><% end %></td>"
  show = read("gallery/app/views/photos/show.html.erb")
  assert_includes show, "  <strong>Image:</strong>\n  <% if @photo.image_attached? %>\n    <img src=\"<%= @photo.image_url %>\" alt=\"<%= @photo.image_filename %>\">\n  <% end %>\n"
  ["photos/_form", "photos/show", "photos/index", "photos/new", "photos/edit"].each do |name|
    template = Cybertrain::Template::Template.parse(read("gallery/app/views/#{name}.html.erb"), "#{name}.html.erb")
    assert template.nodes.size > 0, name
  end
  spec = read("gallery/test/integration/photo_image_attachment_test.rb")
  assert_includes spec, "    { title: \"A photo\", image: file }\n"
  assert_includes spec, "create_photo(fixture_file_upload(\"image.png\", \"image/png\"))"
  # The scaffold's fixtures load before each test: counts are differences.
  assert_includes read("gallery/test/fixtures/photos.yml"), "one:\n  title: MyString\n"
  assert_includes spec, "assert_difference(-> { Photo.count }, 1) do\n      create_photo("
end

test "the scaffold with --any and with nothing but a file" do
  Cybertrain::CLI::NewApp.create("vault", "{ path = \"../cybertrain\" }")
  status = Dir.chdir("vault") { Cybertrain::CLI.run(["generate", "scaffold", "secret", "scan:attachment", "--any"]) }
  assert_equal 0, status
  # Only a file: an edit without one sends no secret[...] key, so
  # neither lookup may raise.
  assert_includes read("vault/app/controllers/secrets_controller.rb"), "params.nested(:secret).permit()"
  assert_includes read("vault/app/controllers/secrets_controller.rb"), "@secret.scan_file = params.nested(:secret).upload(:scan)"
  assert_includes read("vault/app/views/secrets/_form.html.erb"), "    <%= f.file_field :scan %>\n"
  assert_includes read("vault/app/views/secrets/show.html.erb"), "<a href=\"<%= @secret.scan_url %>\"><%= @secret.scan_filename %></a>"
  refute read("vault/app/models/secret.rb").include?("validates :scan"), "no presence validation on the file"
  keep = read("vault/test/integration/secret_scan_attachment_test.rb")
  # No text fields to send: the file alone.
  assert_includes keep, "  def secret_params(file)\n    { scan: file }\n  end\n"
  assert_includes keep, "test \"an update without a file keeps the stored one\" do"
  assert_includes keep, "update_secret(record, file_named(\"\", \"application/octet-stream\", \"\"))"
  # Nothing but a file: the scaffold's create test sends an empty Hash.
  assert_includes read("vault/test/controllers/secrets_controller_test.rb"), "post secrets_url, params: { secret: {} }\n"
  # Run again: every file reports identical.
  status = Dir.chdir("vault") { Cybertrain::CLI.run(["generate", "scaffold", "secret", "scan:attachment", "--any"]) }
  assert_equal 0, status
  assert_equal 1, count_of(read("vault/app/models/secret.rb"), "# cybertrain:attachment scan -- ")
end

# Two files on one model: the second's line in create and update pushes
# the first's away from the anchor, and a re-run must still see both.
test "a scaffold with two attachments run twice has each assignment once per action" do
  Cybertrain::CLI::NewApp.create("album", "{ path = \"../cybertrain\" }")
  2.times { Cybertrain::CLI::Scaffold.generate("album", "photo", ["image:attachment", "thumb:attachment"]) }
  controller = read("album/app/controllers/photos_controller.rb")
  assert_equal 2, count_of(controller, "@photo.image_file = ")
  assert_equal 2, count_of(controller, "@photo.thumb_file = ")
  assert_includes controller, "before_action :set_photo, only: [:show, :edit, :update, :destroy, :image, :thumb]\n"
end

test "the scaffold refuses a duplicate column or a bad attachment name before writing" do
  Cybertrain::CLI::NewApp.create("refuse", "{ path = \"../cybertrain\" }")
  message = assert_raises("InvalidArgument") { Cybertrain::CLI::Scaffold.generate("refuse", "post", ["cover_key:string", "cover:attachment"]) }
  assert_includes message, "duplicate column 'cover_key'"
  message = assert_raises("InvalidArgument") { Cybertrain::CLI::Scaffold.generate("refuse", "post", ["index:attachment"]) }
  assert_includes message, "would redefine a method of PostsController"
  ["params", "head", "set_post", "post_params"].each do |field|
    message = assert_raises("InvalidArgument") { Cybertrain::CLI::Scaffold.generate("refuse", "post", ["title:string", "#{field}:attachment"]) }
    assert_includes message, "would redefine a method of PostsController (the download action is `def #{field}`)"
  end
  message = assert_raises("InvalidArgument") { Cybertrain::CLI::Scaffold.generate("refuse", "post", ["class:attachment"]) }
  assert_includes message, "Ruby keyword"
  assert_equal [], Dir.children("refuse/app/models").select { |f| f.end_with?(".rb") }
  # set_<model> of another resource is an ordinary name.
  Cybertrain::CLI::Scaffold.generate("refuse", "item", ["set_post:attachment"])
  assert_includes read("refuse/app/controllers/items_controller.rb"), "  def set_post\n    if @item.set_post_attached?"
end

Cybertrain::Test.run!
