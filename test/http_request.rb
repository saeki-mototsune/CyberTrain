# What cybertrain adds to the HTTP layer's Request (spinel-http's, whose own
# cases are in its test/http_request.rb): the format family
# (cybertrain/request_format.rb) and the locale I18n negotiates
# (cybertrain/i18n.rb). The layer loads before cybertrain/i18n here, the
# other way round from test/spinel_http_aliases.rb.
require "cybertrain/http/request"
require "cybertrain/request_format"
require "cybertrain/i18n"
require "cybertrain/test"

Request = Cybertrain::Request

def request_with(headers, version = "HTTP/1.1")
  Request.new("GET", "/", headers, "", "127.0.0.1", version)
end

def req_with_accept(accept)
  Request.new("GET", "/", { "accept" => accept }, "", "127.0.0.1")
end

test "Accept decides the format when there is no extension" do
  assert_equal :html, req_with_accept("").format
  assert_equal :html, request_with({}).format
  assert_equal :html, req_with_accept("*/*").format
  assert_equal :turbo_stream, req_with_accept("text/vnd.turbo-stream.html, text/html, application/xhtml+xml").format
  assert_equal :json, req_with_accept("application/json").format
  assert_equal :json, req_with_accept("application/json, */*").format
  assert_equal :html, req_with_accept("text/html, application/json").format
  assert_equal :json, req_with_accept("Application/JSON; charset=utf-8").format
end

test "Accept with q-values and wildcards" do
  assert_equal :html, req_with_accept("text/html;q=0.9, application/json").format
  assert_equal :html, req_with_accept("application/json;q=0, text/html").format
  assert_equal :html, req_with_accept("application/json;q=0").format
  assert_equal :json, req_with_accept("text/*, application/json;q=0.1").format   # text/* is not text/html
  assert_equal :html, req_with_accept("text/vnd.turbo-stream.html; q=0.000, text/html").format
  assert_equal :json, req_with_accept("text/html;q=0.0, application/json").format
end

test "the extension wins over Accept, and setting it again forgets the memo" do
  req = req_with_accept("application/json")
  assert_equal "", req.format_extension
  assert_equal :json, req.format
  req.format_extension = "csv"
  assert_equal "csv", req.format_extension
  assert_equal :csv, req.format
  req.format_extension = "v2"
  assert_equal :unknown, req.format
end

test "extensions map to Rails' registered formats" do
  assert_equal :jpeg, Cybertrain::Request.format_for_extension("jpg")
  assert_equal :text, Cybertrain::Request.format_for_extension("txt")
  assert_equal :unknown, Cybertrain::Request.format_for_extension("v2")
  assert_equal "text/vnd.turbo-stream.html; charset=utf-8", Cybertrain::Request.mime_type(:turbo_stream)
  assert_equal :html, Cybertrain::Request.format_for_extension("htm")
  assert_equal :turbo_stream, Cybertrain::Request.format_for_extension("turbo_stream")
  assert_equal :woff2, Cybertrain::Request.format_for_extension("woff2")
  assert_equal :url_encoded_form, Cybertrain::Request.format_for_extension("url_encoded_form")
  assert_equal :unknown, Cybertrain::Request.format_for_extension("JSON")
  assert_equal :unknown, Cybertrain::Request.format_for_extension("")
  assert_equal "text/html; charset=utf-8", Cybertrain::Request.mime_type(:html)
  assert_equal "application/json; charset=utf-8", Cybertrain::Request.mime_type(:json)
  assert_equal "text/csv; charset=utf-8", Cybertrain::Request.mime_type(:csv)
  assert_equal "application/xml; charset=utf-8", Cybertrain::Request.mime_type(:xml)
  assert_equal "text/plain; charset=utf-8", Cybertrain::Request.mime_type(:text)
  assert_equal "text/javascript; charset=utf-8", Cybertrain::Request.mime_type(:js)
  assert_equal "text/css; charset=utf-8", Cybertrain::Request.mime_type(:css)
  assert_equal "application/octet-stream", Cybertrain::Request.mime_type(:pdf)
  assert_equal "application/octet-stream", Cybertrain::Request.mime_type(:unknown)
end

def locale_request(value)
  request_with({ "Accept-Language" => value })
end

test "preferred_locale with q-values, regions, wildcards and junk" do
  I18n.default_locale = :en
  both = [:en, :ja]
  # q-values order the choice: en (0.9) beats ja-JP (0.8) wherever they stand.
  assert_equal :en, locale_request("ja-JP;q=0.8, en;q=0.9").preferred_locale(both)
  assert_equal :ja, locale_request("ja-JP;q=0.8, en;q=0.7").preferred_locale(both)
  assert_equal :ja, locale_request("en;q=0.1, ja;q=0.2").preferred_locale(both)
  # equal q-values: the earlier entry wins
  assert_equal :ja, locale_request("ja, en").preferred_locale(both)
  assert_equal :en, locale_request("en, ja").preferred_locale(both)
  # a region matches its language, any case
  assert_equal :ja, locale_request("ja-JP").preferred_locale(both)
  assert_equal :ja, locale_request("JA-jp").preferred_locale(both)
  assert_equal :ja, locale_request("ja_JP").preferred_locale(both)
  assert_equal :en, locale_request("en-GB,en;q=0.9").preferred_locale(both)
  # a full tag is tried before its language
  assert_equal :"pt-BR", locale_request("pt-BR, pt;q=0.5").preferred_locale([:pt, :"pt-BR", :en])
  assert_equal :pt, locale_request("pt-PT").preferred_locale([:en, :pt, :"pt-BR"])
  # a wildcard and unknown languages mean the default
  assert_equal :en, locale_request("fr, *").preferred_locale(both)
  assert_equal :en, locale_request("*").preferred_locale(both)
  assert_equal :en, locale_request("fr, de;q=0.8").preferred_locale(both)
  # q=0 excludes; a later entry still counts
  assert_equal :en, locale_request("ja;q=0").preferred_locale(both)
  assert_equal :en, locale_request("ja;q=0.000").preferred_locale(both)
  assert_equal :en, locale_request("ja;q=0, en;q=0.1").preferred_locale(both)
  assert_equal :ja, locale_request("en;q=0, ja;q=0.1").preferred_locale(both)
  # no header, an empty one, junk: the default, never nil
  assert_equal :en, request_with({}).preferred_locale(both)
  assert_equal :en, locale_request("").preferred_locale(both)
  assert_equal :en, locale_request(";;;,,,=;q=").preferred_locale(both)
  assert_equal :en, locale_request("ja;q=abc").preferred_locale(both)
  assert_equal :en, locale_request("ja;q=1.5").preferred_locale(both)
  assert_equal :en, locale_request("ja;q=-1").preferred_locale(both)
  assert_equal :en, locale_request("ja;q=0.8888888").preferred_locale(both)
  assert_equal :en, locale_request("../ja, ja/../en").preferred_locale(both)
  assert_equal :en, locale_request("j\u0000a").preferred_locale(both)
  # nothing available: the default
  assert_equal :en, locale_request("ja").preferred_locale([])
  # the default need not be the first available locale
  I18n.default_locale = :ja
  assert_equal :ja, locale_request("fr").preferred_locale(both)
  assert_equal :en, locale_request("en").preferred_locale(both)
  I18n.default_locale = :en
end

test "preferred_locale reads at most 4 KB and 32 entries and survives a huge header" do
  I18n.default_locale = :en
  both = [:en, :ja]
  # 10 KB of commas
  assert_equal :en, locale_request("," * 10_240).preferred_locale(both)
  # 10 KB of one tag
  assert_equal :en, locale_request("x" * 10_240).preferred_locale(both)
  # a match inside the first 32 entries counts; the 33rd entry does not
  filler = "fr, " * 31
  assert_equal :ja, locale_request("#{filler}ja").preferred_locale(both)
  assert_equal :en, locale_request("#{filler}fr, ja").preferred_locale(both)
  # a match inside the first 4 KB counts; one past it does not
  pad = "x" * 4000
  assert_equal :ja, locale_request("#{pad},ja").preferred_locale(both)
  assert_equal :en, locale_request("#{pad}#{' ' * 200},ja").preferred_locale(both)
  # an enormous q-value text is dropped, not parsed
  assert_equal :en, locale_request("ja;q=#{'9' * 3000}").preferred_locale(both)
end

test "preferred_locale never raises on a header that is not valid UTF-8" do
  I18n.default_locale = :en
  both = [:en, :ja]
  bad = "\xff,ja".dup.force_encoding("UTF-8")
  assert_equal false, bad.valid_encoding?
  assert_equal :en, locale_request(bad).preferred_locale(both)
  bad = "ja,\xff".dup.force_encoding("UTF-8")
  assert_equal :en, locale_request(bad).preferred_locale(both)
  # a multibyte character cut by the 4 KB limit
  cut = ("x" * 4095 + "\u00e9,ja").dup.force_encoding("UTF-8")
  assert_equal :en, locale_request(cut).preferred_locale(both)
  # valid multibyte text is only junk
  assert_equal :ja, locale_request("\u00e9, ja").preferred_locale(both)
  # an underscore in the request's tag matches a hyphenated locale
  assert_equal :"pt-BR", locale_request("pt_BR").preferred_locale([:pt, :"pt-BR", :en])
  assert_equal :"pt-BR", locale_request("pt_br, pt;q=0.5").preferred_locale([:pt, :"pt-BR", :en])
end

test "negotiate_locale answers the given default, not I18n's" do
  I18n.default_locale = :en
  assert_equal "fr", request_with({}).negotiate_locale(["en", "ja"], "fr")
  assert_equal "ja", locale_request("ja;q=0.9, en;q=0.8").negotiate_locale(["en", "ja"], "fr")
end

test "a ?locale= value from the query only passes when it names an available locale" do
  I18n.default_locale = :en
  I18n.available_locales = [:en, :ja]
  accepted = ["ja", "en"]
  refused = ["xx", "JA", "Ja", "../en", "..%2Fen", "en/../ja", "ja ", "", "ja%00", "e", "*", "ja;q=1", "a" * 5000]
  accepted.each do |value|
    req = Request.new("GET", "/?locale=#{value}", {}, "")
    assert_equal value, req.query_value("locale")
    assert_equal true, I18n.locale_available?(req.query_value("locale"))
  end
  refused.each do |value|
    req = Request.new("GET", "/?locale=#{value}", {}, "")
    assert_equal false, I18n.locale_available?(req.query_value("locale"))
  end
  assert_equal false, I18n.locale_available?(Request.new("GET", "/", {}, "").query_value("locale"))
  # a refused value never changes the thread's locale
  I18n.locale = nil
  refused.each do |value|
    req = Request.new("GET", "/?locale=#{value}", {}, "")
    I18n.locale = req.query_value("locale") if I18n.locale_available?(req.query_value("locale"))
  end
  assert_equal :en, I18n.locale
  I18n.available_locales = []
end

Cybertrain::Test.run!
