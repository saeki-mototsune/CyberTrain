require "test_helper"

# Broadcasts and Turbo Stream answers (spec section 9.3): creating an
# article appends its title to every page subscribed to "articles", and a
# form Turbo submits is answered with the same append.
class ArticleStreamsTest < ActionDispatch::IntegrationTest
  test "a new article is broadcast" do
    payloads = assert_broadcasts("articles", 1) do
      post articles_path, params: { article: { title: "Streamed", body: "A body.", author_id: users(:alice).id } }
    end
    assert_includes payloads[0], 'target="articles"'
    assert_includes payloads[0], "Streamed"
  end

  test "a new article answers with a Turbo Stream" do
    post articles_path, params: { article: { title: "Streamed", body: "A body.", author_id: users(:alice).id } },
                        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    assert_turbo_stream action: "append", target: "articles"
    assert_broadcasts "articles", 1
    assert_no_broadcasts articles(:one)
  end
end
