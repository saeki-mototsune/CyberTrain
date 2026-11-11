require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/model"

# i18n in models (spec 8 Models, plan Task 6, decisions D9 and D10):
# validation messages looked up when the validator runs through Rails'
# key chain, full_messages through `errors.format`, `:base` messages
# alone, human_attribute_name and human_model_name.
#
# The application dictionary is a Hash the tests add keys to and remove
# them from, installed as gen/locales.rb installs Gen::Locales; the
# bundled en and ja dictionaries answer everything else.
#
# cybertrain/model links SQLite through FFI, so this program cannot run under
# CRuby: its snapshot comes from the compiled binary (spikes/NOTES.md rule 23).

module ModelLocales
  TEXTS = { "" => "" }
  TEXTS.delete("")

  def self.lookup(key) = TEXTS[key]
  def self.lookup_list(key) = key == "\u0000" ? [""] : []
  def self.resolver = ->(key) { ModelLocales.lookup(key) }
  def self.list_resolver = ->(key) { ModelLocales.lookup_list(key) }

  # The dictionary every test starts from.
  def self.reset
    TEXTS.clear
    TEXTS["ja.activerecord.attributes.post.title"] = "タイトル"
    TEXTS["ja.activerecord.models.post"] = "投稿"
    nil
  end
end

I18n.install_dictionary(ModelLocales.resolver, ModelLocales.list_resolver)

# Hand-written in the shape the model generator emits (test/gen_models.rb
# holds the emitted text, human_attribute_name included), trimmed to what
# these tests call.
class Post < Cybertrain::Model
  def self.table_name = "posts"
  def self.column_names = ["id", "title", "body", "author_id", "rating", "ratio", "slug"]
  def model_name = "Post"
  def self.human_attribute_name(attr, options = {}) = I18n.human_attribute_name("post", attr)

  attr_accessor :title, :body, :author_id, :rating, :ratio, :slug, :slug_taken

  def initialize(attrs = {})
    super()
    @title = ""
    @body = nil
    @author_id = 1
    @rating = 3
    @ratio = 2.0
    @slug = "hello"
    @slug_taken = false
    assign_attributes(attrs) unless attrs.empty?
  end

  def read_attribute(name)
    case name
    when :id then @id
    when :title then @title
    when :body then @body
    when :author_id then @author_id
    when :rating then @rating
    when :ratio then @ratio
    when :slug then @slug
    else nil
    end
  end

  def write_attribute(name, value)
    case name
    when :title then @title = Cybertrain::Cast.str(value)
    when :body then @body = Cybertrain::Cast.str_or_nil(value)
    when :author_id then @author_id = Cybertrain::Cast.int(value)
    when :rating then @rating = Cybertrain::Cast.int(value)
    when :ratio then @ratio = Cybertrain::Cast.float(value)
    when :slug then @slug = Cybertrain::Cast.str(value)
    end
    nil
  end

  def assign_attributes(attrs)
    attrs.each { |k, v| write_attribute(k.to_s.to_sym, v) }
    self
  end

  def unique_value_taken?(attr, value, scope_attr, scope_value, exclude_id, case_sensitive) = @slug_taken
end

# A model with no dictionary entries, for the humanised fallbacks.
class BlogComment < Cybertrain::Model
  def model_name = "BlogComment"
  def self.human_attribute_name(attr, options = {}) = I18n.human_attribute_name("blog_comment", attr)

  def read_attribute(name) = nil
end

class Post
  validates :title, presence: true, length: { minimum: 8 }
  validates :body, length: { maximum: 5 }, allow_nil: true
  validates_foreign_key :author_id
  validates :rating, numericality: { greater_than: 0 }
  validates :ratio, numericality: { greater_than: 1.5 }
  validates :slug, uniqueness: true
  validates :slug, exclusion: { in: ["new"], message: "is a route" }
end

def reset_i18n
  ModelLocales.reset
  I18n.default_locale = :en
  I18n.available_locales = [:en, :ja]
  I18n.raise_on_missing = false
  I18n.mark_missing = true
  I18n.locale = nil
  nil
end

def full_messages_of(attrs, taken = false)
  post = Post.new(attrs)
  post.slug_taken = taken
  post.valid?
  post.errors.full_messages
end

def messages_of(attr, attrs, taken = false)
  post = Post.new(attrs)
  post.slug_taken = taken
  post.valid?
  post.errors[attr]
end

VALID = { title: "A long title" }.freeze

test "English validation messages are unchanged" do
  reset_i18n
  assert_equal ["Title can't be blank", "Title is too short (minimum is 8 characters)"],
               full_messages_of({ title: "" })
  assert_equal ["is too short (minimum is 8 characters)"], messages_of(:title, { title: "Short" })
  assert_equal ["is too long (maximum is 5 characters)"], messages_of(:body, { title: "A long title", body: "123456" })
  assert_equal ["must be greater than 0"], messages_of(:rating, { title: "A long title", rating: 0 })
  # The limit is text (count_text:), never a plural count: 1.5 does not raise.
  assert_equal ["must be greater than 1.5"], messages_of(:ratio, { title: "A long title", ratio: 1.5 })
  assert_equal ["Ratio must be greater than 1.5"], full_messages_of({ title: "A long title", ratio: 1.0 })
  assert_equal ["has already been taken"], messages_of(:slug, VALID, true)
  assert_equal ["Author can't be blank"], full_messages_of({ title: "A long title", author_id: 0 })
  assert_equal [], full_messages_of(VALID)

  # Every key the validators use, as 0.4 printed it (the length minimum of
  # 1 reads "character": rails-i18n's plural, plan decision D10).
  assert_equal "can't be blank", I18n.error_message("post", "title", :blank)
  assert_equal "is not included in the list", I18n.error_message("post", "title", :inclusion)
  assert_equal "is reserved", I18n.error_message("post", "title", :exclusion)
  assert_equal "has already been taken", I18n.error_message("post", "title", :taken)
  assert_equal "is invalid", I18n.error_message("post", "title", :invalid)
  assert_equal "is the wrong length (should be 3 characters)", I18n.error_message("post", "title", :wrong_length, { count: 3 })
  assert_equal "is the wrong length (should be 1 character)", I18n.error_message("post", "title", :wrong_length, { count: 1 })
  assert_equal "is too short (minimum is 2 characters)", I18n.error_message("post", "title", :too_short, { count: 2 })
  assert_equal "is too short (minimum is 1 character)", I18n.error_message("post", "title", :too_short, { count: 1 })
  assert_equal "is too long (maximum is 10 characters)", I18n.error_message("post", "title", :too_long, { count: 10 })
  assert_equal "is not a number", I18n.error_message("post", "rating", :not_a_number)
  assert_equal "must be an integer", I18n.error_message("post", "rating", :not_an_integer)
  assert_equal "must be greater than 1.5", I18n.error_message("post", "rating", :greater_than, { count_text: "1.5" })
  assert_equal "must be greater than or equal to 0", I18n.error_message("post", "rating", :greater_than_or_equal_to, { count_text: "0" })
  assert_equal "must be equal to 2", I18n.error_message("post", "rating", :equal_to, { count_text: "2" })
  assert_equal "must be less than 100", I18n.error_message("post", "rating", :less_than, { count_text: "100" })
  assert_equal "must be less than or equal to 10.5", I18n.error_message("post", "rating", :less_than_or_equal_to, { count_text: "10.5" })
  assert_equal "must be other than 7", I18n.error_message("post", "rating", :other_than, { count_text: "7" })
  # No model key (a hand-written Errors): the generic keys answer.
  assert_equal "can't be blank", I18n.error_message("", "title", :blank)
end

test "Japanese messages and errors.format" do
  reset_i18n
  I18n.locale = :ja
  post = Post.new({ title: "" })
  post.valid?
  assert_equal ["タイトルを入力してください", "タイトルは8文字以上で入力してください"], post.errors.full_messages
  assert_equal ["を入力してください", "は8文字以上で入力してください"], post.errors[:title]
  assert_equal ["Ratioは1.5より大きい値にしてください"], full_messages_of({ title: "A long title", ratio: 1.0 })
  assert_equal ["Authorを入力してください"], full_messages_of({ title: "A long title", author_id: 0 })
  assert_equal ["Slugはすでに存在します"], full_messages_of(VALID, true)
  # A message: option still wins, in any locale.
  assert_equal ["Slugis a route"], full_messages_of({ title: "A long title", slug: "new" })
  # The message is looked up when the validator runs: back in en, the same
  # errors still read in ja.
  I18n.locale = :en
  assert_equal ["を入力してください", "は8文字以上で入力してください"], post.errors[:title]
  # full_messages formats in the locale it is called in.
  assert_equal ["Title を入力してください", "Title は8文字以上で入力してください"], post.errors.full_messages
  # An application errors.format overrides the bundled one.
  ModelLocales::TEXTS["en.errors.format"] = "%{attribute}: %{message}"
  assert_equal ["Title: can't be blank", "Title: is too short (minimum is 8 characters)"], full_messages_of({ title: "" })
  assert_equal "Body: is odd", I18n.full_message("post", "body", "is odd")
end

test "the model-specific key wins" do
  reset_i18n
  texts = ModelLocales::TEXTS
  assert_equal "can't be blank", I18n.error_message("post", "title", :blank)
  texts["en.errors.attributes.title.blank"] = "4: any title is needed"
  assert_equal "4: any title is needed", I18n.error_message("post", "title", :blank)
  assert_equal "can't be blank", I18n.error_message("post", "body", :blank)
  texts["en.activerecord.errors.messages.blank"] = "3: is missing"
  assert_equal "3: is missing", I18n.error_message("post", "title", :blank)
  assert_equal "3: is missing", I18n.error_message("post", "body", :blank)
  texts["en.activerecord.errors.models.post.blank"] = "2: is missing from the post"
  assert_equal "2: is missing from the post", I18n.error_message("post", "title", :blank)
  assert_equal "2: is missing from the post", I18n.error_message("post", "body", :blank)
  assert_equal "3: is missing", I18n.error_message("blog_comment", "body", :blank)
  texts["en.activerecord.errors.models.post.attributes.title.blank"] = "1: needs a title"
  assert_equal "1: needs a title", I18n.error_message("post", "title", :blank)
  assert_equal "2: is missing from the post", I18n.error_message("post", "body", :blank)
  assert_equal ["Title 1: needs a title", "Title is too short (minimum is 8 characters)"], full_messages_of({ title: "" })

  # The chain runs in the current locale before the default one: an
  # en-only model key does not hide ja's errors.messages.blank.
  I18n.locale = :ja
  assert_equal "を入力してください", I18n.error_message("post", "title", :blank)
  texts["ja.activerecord.errors.models.post.attributes.title.blank"] = "は必須です"
  assert_equal ["タイトルは必須です", "タイトルは8文字以上で入力してください"], full_messages_of({ title: "" })
  # A key ja lacks altogether falls back to en's chain.
  texts["en.errors.messages.fuzzy"] = "4: is fuzzy"
  assert_equal "4: is fuzzy", I18n.error_message("post", "title", :fuzzy)

  # %{attribute}, %{model} and %{count} are filled.
  I18n.locale = :en
  texts["en.activerecord.errors.models.post.attributes.title.too_short"] = "of a %{model} needs %{count} letters (%{attribute})"
  assert_equal ["Title 1: needs a title", "Title of a Post needs 8 letters (Title)"], full_messages_of({ title: "" })
  I18n.locale = :ja
  texts["ja.activerecord.errors.models.post.attributes.title.too_short"] = "（%{model}の%{attribute}）は%{count}文字以上"
  assert_equal ["タイトルは必須です", "タイトル（投稿のタイトル）は8文字以上"], full_messages_of({ title: "" })

  # No key anywhere: the missing text names the most specific key.
  assert_equal "translation missing: ja.activerecord.errors.models.post.attributes.title.nope",
               I18n.error_message("post", "title", :nope)
  I18n.locale = :en
  assert_equal "translation missing: en.activerecord.errors.messages.nope", I18n.error_message("", "title", :nope)
end

test "base messages have no attribute" do
  reset_i18n
  post = Post.new(VALID)
  post.valid?
  post.errors.add(:base, "Pick a date")
  post.errors.add(:title, "is odd")
  assert_equal ["Pick a date", "Title is odd"], post.errors.full_messages
  I18n.locale = :ja
  assert_equal ["Pick a date", "タイトルis odd"], post.errors.full_messages
  assert_equal "Pick a date", I18n.full_message("post", "base", "Pick a date")
  assert_equal "Pick a date", I18n.full_message("post", :base, "Pick a date")

  # An Errors made by hand has no model key: attributes are humanised.
  errors = Cybertrain::Errors.new
  assert_equal "", errors.model_key
  errors.add(:base, "Whole record")
  errors.add(:author_id, "is invalid")
  I18n.locale = :en
  assert_equal ["Whole record", "Author is invalid"], errors.full_messages
  assert_equal "post", Post.new.errors.model_key
  assert_equal "blog_comment", BlogComment.new.errors.model_key
  assert_equal "post", Cybertrain::Errors.new("post").model_key
end

test "Post.human_attribute_name(:title) and the humanised fallback for author_id" do
  reset_i18n
  assert_equal "Title", Post.human_attribute_name(:title)
  assert_equal "Author", Post.human_attribute_name(:author_id)
  assert_equal "Published at", Post.human_attribute_name("published_at")
  I18n.locale = :ja
  assert_equal "タイトル", Post.human_attribute_name(:title)
  assert_equal "タイトル", Post.human_attribute_name("title", { count: 1 })
  assert_equal "Author", Post.human_attribute_name(:author_id)
  assert_equal "Body", BlogComment.human_attribute_name(:body)
  # The ja name does not leak into en, and en's own name wins there.
  I18n.locale = :en
  assert_equal "Title", I18n.human_attribute_name("post", "title")
  ModelLocales::TEXTS["en.activerecord.attributes.post.title"] = "Headline"
  assert_equal "Headline", Post.human_attribute_name(:title)
  assert_equal ["Headline can't be blank", "Headline is too short (minimum is 8 characters)"], full_messages_of({ title: "" })
  # No model key: humanised only.
  assert_equal "Title", I18n.human_attribute_name("", "title")
  assert_equal "Author", I18n.humanize_attribute("author_id")
  assert_equal "Id", I18n.humanize_attribute("id")
  assert_equal "Published at", I18n.humanize_attribute("published_at")

  # human_model_name: activerecord.models.<model> (or its one:), else the
  # humanised key's last segment.
  assert_equal "Post", I18n.human_model_name("post")
  assert_equal "Blog comment", I18n.human_model_name("blog_comment")
  assert_equal "Post", I18n.human_model_name("admin/post")
  I18n.locale = :ja
  assert_equal "投稿", I18n.human_model_name("post")
  ModelLocales::TEXTS["en.activerecord.models.blog_comment.one"] = "Remark"
  ModelLocales::TEXTS["en.activerecord.models.blog_comment.other"] = "Remarks"
  assert_equal "Remark", I18n.human_model_name("blog_comment")
  I18n.locale = :en
  assert_equal "Remark", I18n.human_model_name("blog_comment")
end

test "raise_on_missing does not touch the fallbacks" do
  reset_i18n
  I18n.raise_on_missing = true
  assert_equal "Author", Post.human_attribute_name(:author_id)
  assert_equal "Blog comment", I18n.human_model_name("blog_comment")
  assert_equal ["Title can't be blank", "Title is too short (minimum is 8 characters)"], full_messages_of({ title: "" })
  message = assert_raises("I18n::MissingTranslationData") { I18n.error_message("post", "title", :nope) }
  assert_equal "translation missing: en.activerecord.errors.models.post.attributes.title.nope", message
  I18n.raise_on_missing = false
end

Cybertrain::Test.run!
