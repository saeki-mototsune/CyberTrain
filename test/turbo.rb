# Cybertrain::Turbo: the Turbo Stream elements, a record as a target, and
# escaping. No database.
require "cybertrain/turbo"
require "cybertrain/test"

Turbo = Cybertrain::Turbo

class BlogPost < Cybertrain::Model
  def self.table_name = "blog_posts"
  def model_name = "BlogPost"
end

def blog_post(id)
  post = BlogPost.new
  post.set_id(id)
  post
end

def safe(html)
  Cybertrain::SafeString.of(html)
end

test "each action wraps the HTML in a template" do
  assert_equal "<turbo-stream action=\"replace\" target=\"article_1\"><template><p>x</p></template></turbo-stream>",
               Turbo.replace("article_1", safe("<p>x</p>")).to_s
  assert_equal "<turbo-stream action=\"update\" target=\"t\"><template><b>u</b></template></turbo-stream>",
               Turbo.update("t", safe("<b>u</b>")).to_s
  assert_equal "<turbo-stream action=\"append\" target=\"t\"><template><li>a</li></template></turbo-stream>",
               Turbo.append("t", safe("<li>a</li>")).to_s
  assert_equal "<turbo-stream action=\"prepend\" target=\"t\"><template><li>p</li></template></turbo-stream>",
               Turbo.prepend("t", safe("<li>p</li>")).to_s
  assert_equal "<turbo-stream action=\"before\" target=\"t\"><template>b</template></turbo-stream>",
               Turbo.before("t", safe("b")).to_s
  assert_equal "<turbo-stream action=\"after\" target=\"t\"><template>a</template></turbo-stream>",
               Turbo.after("t", safe("a")).to_s
end

test "remove has no template and refresh has no target" do
  assert_equal "<turbo-stream action=\"remove\" target=\"article_1\"></turbo-stream>", Turbo.remove("article_1").to_s
  assert_equal "<turbo-stream action=\"refresh\"></turbo-stream>", Turbo.refresh.to_s
end

test "a record target becomes its dom id" do
  assert_equal "<turbo-stream action=\"remove\" target=\"blog_post_12\"></turbo-stream>", Turbo.remove(blog_post(12)).to_s
  assert_equal "<turbo-stream action=\"replace\" target=\"blog_post_3\"><template>x</template></turbo-stream>",
               Turbo.replace(blog_post(3), safe("x")).to_s
end

test "plain text is escaped, a SafeString is not, and the target is escaped" do
  assert_equal "<turbo-stream action=\"update\" target=\"a&quot;b\"><template>&lt;i&gt;&amp;</template></turbo-stream>",
               Turbo.update("a\"b", "<i>&").to_s
end

test "the result is a SafeString" do
  assert Turbo.refresh.html_safe?
  assert Turbo.append("t", "x").html_safe?
end

Cybertrain::Test.run!
