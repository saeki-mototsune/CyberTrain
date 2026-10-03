require "tmpdir"
require "cybertrain/cli"
require "cybertrain/test"

TMP = Dir.mktmpdir("cybertrain-cli-scaffold")
Dir.chdir(TMP)

# Removes a generated tree (files, dot-files and directories).
def rm_tree(path)
  if File.directory?(path)
    Dir.children(path).each { |child| rm_tree(File.join(path, child)) }
    Dir.rmdir(path)
  else
    File.delete(path)
  end
end

# Test.run! exits the process, so the temp tree is removed at exit.
at_exit do
  Dir.chdir("/")
  rm_tree(TMP)
end

ENV["CYBERTRAIN_TIMESTAMP"] = "20260925120000"
Cybertrain::CLI::NewApp.create("blog", "{ path = \"../cybertrain\" }")

def read(path)
  File.read(path)
end

def migration_versions
  Dir.children("blog/db/migrate").select { |f| f.end_with?(".rb") }.map { |f| f.split("_")[0] }.sort
end

def rejected(args)
  status = Dir.chdir("blog") { Cybertrain::CLI.run(["generate", "scaffold", "tag"] + args) }
  assert(status == 1, "accepted: #{args.join(" ")}")
  refute File.exist?("blog/app/models/tag.rb"), args.join(" ")
  refute File.exist?("blog/app/views/tags"), args.join(" ")
  assert(migration_versions.size == 4, "wrote a migration: #{args.join(" ")}")
end

POST_FILES = [
  "db/migrate/20260925120000_create_posts.rb",
  "app/models/post.rb",
  "app/controllers/posts_controller.rb",
  "app/views/posts/index.html.erb",
  "app/views/posts/show.html.erb",
  "app/views/posts/new.html.erb",
  "app/views/posts/edit.html.erb",
  "app/views/posts/_form.html.erb"
]

test "scaffold writes the migration, model, controller and views" do
  created = Cybertrain::CLI::Scaffold.generate("blog", "post", ["title:string", "body:text"])
  assert_equal POST_FILES, created
  POST_FILES.each { |f| assert(File.exist?("blog/#{f}"), "missing #{f}") }
end

test "the migration creates the table with its columns and timestamps" do
  assert_equal <<~RUBY, read("blog/db/migrate/20260925120000_create_posts.rb")
    class CreatePosts < Cybertrain::Migration::Base
      def change
        create_table "posts" do |t|
          t.string "title"
          t.text "body"
          t.timestamps
        end
      end
    end
  RUBY
end

test "the model validates presence of the first string field" do
  model = read("blog/app/models/post.rb")
  assert_includes model, "class Post\n"
  assert_includes model, "  validates :title, presence: true\n"
end

test "the controller follows the Rails scaffold shape" do
  assert_equal <<~RUBY, read("blog/app/controllers/posts_controller.rb")
    class PostsController < ApplicationController
      before_action :set_post, only: [:show, :edit, :update, :destroy]

      # GET /posts
      def index
        @posts = Post.all.to_a
      end

      # GET /posts/1
      def show
      end

      # GET /posts/new
      # (named new_action: a `new` method would shadow PostsController.new)
      def new_action
        @post = Post.new
      end

      # GET /posts/1/edit
      def edit
      end

      # POST /posts
      def create
        @post = Post.new(post_params)
        if @post.save
          flash[:notice] = "Post was successfully created."
          redirect_to post_path(@post), status: :see_other
        else
          render :new, status: :unprocessable_entity
        end
      end

      # PATCH/PUT /posts/1
      def update
        if @post.update(post_params)
          flash[:notice] = "Post was successfully updated."
          redirect_to post_path(@post), status: :see_other
        else
          render :edit, status: :unprocessable_entity
        end
      end

      # DELETE /posts/1
      def destroy
        @post.destroy
        flash[:notice] = "Post was successfully destroyed."
        redirect_to posts_path, status: :see_other
      end

      private

      def set_post
        @post = Post.find(params[:id])
      end

      def post_params
        params.require(:post).permit(:title, :body)
      end
    end
  RUBY
end

test "the views use the template subset and the form builder" do
  index = read("blog/app/views/posts/index.html.erb")
  assert_includes index, "<% @posts.each do |post| %>"
  assert_includes index, "<%= post.title %>"
  assert_includes index, "<%= link_to \"Show\", post_path(post) %>"
  assert_includes index, "<%= link_to \"New post\", new_post_path %>"
  show = read("blog/app/views/posts/show.html.erb")
  assert_includes show, "<%= @post.body %>"
  assert_includes show, "<%= link_to \"Edit this post\", edit_post_path(@post) %>"
  assert_includes show, "<%= button_to \"Destroy this post\", post_path(@post), method: :delete %>"
  assert_includes read("blog/app/views/posts/new.html.erb"), "<%= render \"form\", post: @post %>"
  assert_includes read("blog/app/views/posts/edit.html.erb"), "<%= render \"form\", post: @post %>"
  form = read("blog/app/views/posts/_form.html.erb")
  assert form.start_with?("<%# locals: (post:) %>\n"), "form must declare its strict locals"
  assert_includes form, "<%= form_with(model: post) do |f| %>"
  assert_includes form, "<% if post.errors.any? %>"
  assert_includes form, "<% post.errors.full_messages.each do |message| %>"
  assert_includes form, "<%= f.label :title %>"
  assert_includes form, "<%= f.text_field :title %>"
  assert_includes form, "<%= f.text_area :body %>"
  assert_includes form, "<%= f.submit %>"
end

test "a references field becomes t.references, a post_id input and a permitted param" do
  status = Dir.chdir("blog") { Cybertrain::CLI.run(["generate", "scaffold", "comment", "commenter:string", "body:text", "post:references"]) }
  assert_equal 0, status
  # Same CYBERTRAIN_TIMESTAMP as posts: the version is bumped past the
  # largest one in db/migrate so it stays unique and sorts after posts.
  refute File.exist?("blog/db/migrate/20260925120000_create_comments.rb")
  assert_equal <<~RUBY, read("blog/db/migrate/20260925120001_create_comments.rb")
    class CreateComments < Cybertrain::Migration::Base
      def change
        create_table "comments" do |t|
          t.string "commenter"
          t.text "body"
          t.references :post
          t.timestamps
        end
      end
    end
  RUBY
  controller = read("blog/app/controllers/comments_controller.rb")
  assert_includes controller, "params.require(:comment).permit(:commenter, :body, :post_id)"
  assert_includes controller, "before_action :set_comment, only: [:show, :edit, :update, :destroy]"
  assert_includes read("blog/app/models/comment.rb"), "validates :commenter, presence: true"
  assert_includes read("blog/app/views/comments/_form.html.erb"), "<%= f.text_field :post_id %>"
  assert_includes read("blog/app/views/comments/show.html.erb"), "<%= @comment.post_id %>"
end

test "other field types map to their form inputs" do
  Cybertrain::CLI::Scaffold.generate("blog", "Product", ["name", "price:float", "stock:integer", "active:boolean", "released_on:date"])
  form = read("blog/app/views/products/_form.html.erb")
  assert_includes form, "<%= f.text_field :name %>"
  assert_includes form, "<%= f.number_field :price %>"
  assert_includes form, "<%= f.number_field :stock %>"
  assert_includes form, "<%= f.check_box :active %>"
  assert_includes form, "<%= f.text_field :released_on %>"
  assert_includes read("blog/db/migrate/20260925120002_create_products.rb"), "      t.boolean \"active\"\n"
  assert_includes read("blog/app/controllers/products_controller.rb"), "class ProductsController < ApplicationController"
end

test "routes are inserted once, even when the scaffold runs twice" do
  again = Cybertrain::CLI::Scaffold.generate("blog", "post", ["title:string", "body:text"])
  assert_equal [], again
  assert_equal <<~RUBY, read("blog/config/routes.rb")
    Cybertrain::Routes.draw do
      resources :products
      resources :comments
      resources :posts
    end
  RUBY
end

test "an existing file is never overwritten" do
  File.write("blog/app/models/post.rb", "class Post\n  # edited\nend\n")
  Cybertrain::CLI::Scaffold.generate("blog", "post", ["title:string"])
  assert_equal "class Post\n  # edited\nend\n", read("blog/app/models/post.rb")
end

test "a model without string fields gets no validation" do
  Cybertrain::CLI::Scaffold.generate("blog", "counter", ["value:integer"])
  refute read("blog/app/models/counter.rb").include?("validates")
end

test "migration versions stay unique and increasing" do
  assert_equal ["20260925120000", "20260925120001", "20260925120002", "20260925120003"], migration_versions
  # A stamp later than every existing version is used as is.
  assert_equal "20270101000000", Cybertrain::CLI::Scaffold.next_version("blog", "20270101000000")
  # One equal to or earlier than the largest becomes largest + 1.
  assert_equal "20260925120004", Cybertrain::CLI::Scaffold.next_version("blog", "20260925120003")
  assert_equal "20260925120004", Cybertrain::CLI::Scaffold.next_version("blog", "20200101000000")
end

test "bad input is rejected before anything is written" do
  rejected(["name:strang"])
  rejected(["name:string", "name:text"])
  rejected(["post:references", "post_id:integer"])
  rejected(["id:integer"])
  rejected(["created_at:datetime"])
  rejected(["updated_at"])
  rejected(["class:string"])
  rejected(["end"])
  rejected(["self:text"])
  # A keyword as a references name is caught by the reader check (the column
  # would be end_id, which is no keyword); a keyword with a bad type reports
  # the type.
  rejected(["end:references"])
  rejected(["class:bogus"])
  # Names the generated model cannot host (Cybertrain::Ident, the generator's
  # own rule): refused here, not by the later `spin run gen`.
  rejected(["errors:string"])
  rejected(["save:text"])
  rejected(["attributes:string"])
  rejected(["hash:integer"])
  # A references field also defines a reader (def errors), so the same rule
  # applies to the field name, not only to the errors_id column.
  rejected(["errors:references"])
  rejected(["hash:references"])
  rejected(["a:string:index"])
  rejected(["a:string:"])
  rejected(["Title:string"])
  status = Dir.chdir("blog") { Cybertrain::CLI.run(["generate", "scaffold", "class", "name:string"]) }
  assert_equal 1, status
  refute File.exist?("blog/app/models/class.rb")
  # A resource's singular is the belongs_to reader on the models that
  # reference it (`hash:references` -> Thing#hash would shadow Object#hash),
  # so it answers to the same rules as a column. The plural (the has_many
  # reader) is the generator's business: it renames, never refuses.
  status = Dir.chdir("blog") { Cybertrain::CLI.run(["generate", "scaffold", "Hash", "post:references"]) }
  assert_equal 1, status
  refute File.exist?("blog/app/models/hash.rb")
  status = Dir.chdir("blog") { Cybertrain::CLI.run(["generate", "scaffold", "raise", "name:string"]) }
  assert_equal 1, status
  refute File.exist?("blog/app/models/raise.rb")
  # Object methods the generator only notes (`display`, `tap`) are not
  # refused: see "a name that shadows an Object method is accepted with a
  # note" below.
  assert_equal 4, migration_versions.size
  # TMP itself is not an app: it has no config/routes.rb.
  assert_equal 1, Cybertrain::CLI.run(["generate", "scaffold", "tag", "name:string"])
  assert_equal 1, Cybertrain::CLI.run(["generate", "scaffold"])
  assert_equal 1, Cybertrain::CLI.run(["generate", "model", "tag"])
end

test "a routes file without the draw line is rejected before anything is written" do
  Cybertrain::CLI::NewApp.create("broken", "{ path = \"../cybertrain\" }")
  File.write("broken/config/routes.rb", "# routes go here\n")
  status = Dir.chdir("broken") { Cybertrain::CLI.run(["generate", "scaffold", "tag", "name:string"]) }
  assert_equal 1, status
  assert_equal ["db/migrate/.keep"].size, Dir.children("broken/db/migrate").size
  refute File.exist?("broken/app/models/tag.rb")
  refute File.exist?("broken/app/controllers/tags_controller.rb")
  refute File.exist?("broken/app/views/tags")
end

test "a name that is its own plural links and redirects to <plural>_index_path" do
  Cybertrain::CLI::Scaffold.generate("blog", "sheep", ["name:string"])
  controller = read("blog/app/controllers/sheep_controller.rb")
  assert_includes controller, "class SheepController < ApplicationController"
  assert_includes controller, "redirect_to sheep_index_path, status: :see_other"
  assert_includes controller, "redirect_to sheep_path(@sheep), status: :see_other"
  ["show", "new", "edit"].each do |view|
    assert_includes read("blog/app/views/sheep/#{view}.html.erb"), "sheep_index_path"
  end
  assert_includes read("blog/config/routes.rb"), "resources :sheep"
end

# The policy is the generator's: refuse what it would RENAME (keywords and
# Ident::RESERVED_COLUMN_NAMES, whose renamed reader the scaffold's views and
# controller could not call), accept what it only annotates.
test "the scaffold refuses a keyword or reserved name with its own message" do
  refuse = lambda do |name, what|
    assert_raises("InvalidArgument") { Cybertrain::CLI::Scaffold.refuse_unusable!(name, what) }
  end
  assert_equal "'class' is a Ruby keyword and cannot name a field", refuse.call("class", "field")
  assert_equal "'end' is a Ruby keyword and cannot name a reference", refuse.call("end", "reference")
  assert_equal "'errors' would shadow a method of the generated model (Cybertrain::Model); pick another field", refuse.call("errors", "field")
  assert_equal "'hash' would shadow a method of the generated model (Cybertrain::Model); pick another resource", refuse.call("hash", "resource")
  # Ident answers no "shadowing" reason any more.
  assert_equal "", Cybertrain::Ident.unusable_reason("method")
  assert_equal "", Cybertrain::Ident.unusable_reason("display")
  assert Cybertrain::Ident.shadowing_column?("method")
  assert_nil Cybertrain::CLI::Scaffold.refuse_unusable!("method", "field")
end

test "a name that shadows an Object method is accepted with a note" do
  status = Dir.chdir("blog") { Cybertrain::CLI.run(["generate", "scaffold", "payment", "method:string", "amount:integer", "tap:references"]) }
  assert_equal 0, status
  assert File.exist?("blog/app/models/payment.rb")
  controller = read("blog/app/controllers/payments_controller.rb")
  assert_includes controller, "params.require(:payment).permit(:method, :amount, :tap_id)"
  assert_includes read("blog/app/views/payments/_form.html.erb"), "<%= f.text_field :method %>"
  assert_includes read("blog/app/views/payments/show.html.erb"), "<%= @payment.method %>"
  assert_includes read("blog/db/migrate/20260925120005_create_payments.rb"), "      t.string \"method\"\n"
  res = Cybertrain::CLI::Resource.new("payment", [Cybertrain::CLI::Field.parse("method:string"), Cybertrain::CLI::Field.parse("amount:integer"), Cybertrain::CLI::Field.parse("tap:references")])
  assert_equal [
    "note: 'method' shadows Object#method on the generated model; call it as payment.method",
    "note: 'tap' shadows Object#tap on the generated model; call it as payment.tap"
  ], Cybertrain::CLI::Scaffold.shadow_notes(res)
  # The resource singular is the belongs_to reader on the models that
  # reference it.
  status = Dir.chdir("blog") { Cybertrain::CLI.run(["generate", "scaffold", "displays", "name:string"]) }
  assert_equal 0, status
  assert File.exist?("blog/app/models/display.rb")
  notes = Cybertrain::CLI::Scaffold.shadow_notes(Cybertrain::CLI::Resource.new("displays", [Cybertrain::CLI::Field.parse("name:string")]))
  assert_equal ["note: 'display' shadows Object#display on a model that references displays (belongs_to reader); call it as record.display"], notes
  # No shadowing name, no note.
  assert_equal [], Cybertrain::CLI::Scaffold.shadow_notes(Cybertrain::CLI::Resource.new("post", [Cybertrain::CLI::Field.parse("title")]))
end

test "the migration timestamp comes from the clock without CYBERTRAIN_TIMESTAMP" do
  assert_equal "20260925120000", Cybertrain::CLI::Scaffold.timestamp
  ENV.delete("CYBERTRAIN_TIMESTAMP")
  stamp = Cybertrain::CLI::Scaffold.timestamp
  assert_equal 14, stamp.size
  refute stamp == "20260925120000"
end

Cybertrain::Test.run!
