require "tmpdir"
require "digest"
require "cybertrain/test"
require "cybertrain/generator"
require_relative "fixtures/assets_app/gen/assets"

# Assets at gen time (spec section 7.1, 7.3): digests, CSS url() rewriting,
# three kept versions under public/assets, the import map and gen/assets.rb.
# Runs on a copy of test/fixtures/assets_app in a temporary directory, so
# public/assets and the edited sources never touch the checked-in fixture.

FIXTURE = "test/fixtures/assets_app"
TMP = Dir.mktmpdir("cybertrain-gen-assets")
SOURCES = [
  "app/assets/stylesheets/application.css",
  "app/assets/images/logo.svg",
  "app/assets/images/.keep",
  "app/assets/fonts/x.woff2",
  "app/javascript/application.js",
  "app/javascript/controllers/hello_controller.js",
  "vendor/javascript/chart.js",
  "config/importmap.rb"
]
["app", "app/assets", "app/assets/stylesheets", "app/assets/images", "app/assets/fonts", "app/javascript", "app/javascript/controllers",
 "vendor", "vendor/javascript", "config"].each { |d| Dir.mkdir("#{TMP}/#{d}") }
SOURCES.each { |f| File.write("#{TMP}/#{f}", File.read("#{FIXTURE}/#{f}")) }

def remove_tree(path)
  if File.directory?(path)
    Dir.children(path).each { |child| remove_tree("#{path}/#{child}") }
    Dir.rmdir(path)
  elsif File.exist?(path)
    File.delete(path)
  end
  nil
end

at_exit { remove_tree(TMP) }

def scan_now
  Cybertrain::Gen::AssetScan.scan(TMP)
end

def asset(logical)
  scan_now.each { |f| return f if f.logical_path == logical }
  flunk("no asset #{logical}")
end

def digest(logical)
  asset(logical).asset_digest
end

# application.css as the stylesheet the url()s are read from.
def rewrite(css)
  Cybertrain::Gen::AssetScan.rewrite_css(css, "application.css", scan_now)
end

# "path bytes" for every file under public/assets (the manifest included),
# sorted: what a run that writes nothing leaves unchanged.
def public_snapshot
  out = +""
  public_files("#{TMP}/public/assets", "").sort.each do |rel|
    out << rel << "\n" << File.binread("#{TMP}/public/assets/#{rel}") << "\n"
  end
  out
end

def public_files(dir, prefix)
  files = Array.new(0) { "" }
  return files unless File.directory?(dir)

  Dir.children(dir).each do |entry|
    rel = prefix == "" ? entry : "#{prefix}/#{entry}"
    if File.directory?("#{dir}/#{entry}")
      public_files("#{dir}/#{entry}", rel).each { |f| files << f }
    else
      files << rel
    end
  end
  files
end

test "files are digested with the first 8 hex of their SHA-256" do
  files = Cybertrain::Gen::AssetScan.scan(TMP)
  logo = files.find { |f| f.logical_path == "logo.svg" }
  assert_equal Digest::SHA256.hexdigest(File.binread("#{TMP}/app/assets/images/logo.svg"))[0, 8], logo.asset_digest
  assert_equal "logo-#{logo.asset_digest}.svg", logo.digested_path
  assert_equal "controllers/hello_controller.js", files.find { |f| f.source_path.end_with?("hello_controller.js") }.logical_path
  assert_equal ["application.css", "application.js", "chart.js", "controllers/hello_controller.js", "logo.svg", "x.woff2"],
               files.map { |f| f.logical_path }
end

test "digested names keep every extension and a directory" do
  assert_equal "logo-1a2b3c4d.svg", Cybertrain::AssetManifest.digested_name("logo.svg", "1a2b3c4d")
  assert_equal "app-1a2b3c4d.js.map", Cybertrain::AssetManifest.digested_name("app.js.map", "1a2b3c4d")
  assert_equal "LICENSE-1a2b3c4d", Cybertrain::AssetManifest.digested_name("LICENSE", "1a2b3c4d")
  assert_equal "controllers/hello_controller-1a2b3c4d.js",
               Cybertrain::AssetManifest.digested_name("controllers/hello_controller.js", "1a2b3c4d")
end

test "a logical path under two roots is refused" do
  File.write("#{TMP}/vendor/javascript/application.js", "// vendored\n")
  message = assert_raises("ArgumentError") { scan_now }
  File.delete("#{TMP}/vendor/javascript/application.js")
  assert_equal "asset application.js is both app/javascript/application.js and vendor/javascript/application.js", message
end

# url() resolves against the CSS file's logical directory (Propshaft; ruling
# F28): from application.css, "logo.svg" and "/logo.svg" are the image, and
# "../images/logo.svg" climbs out of the logical root, so it is not an asset.
test "url() suffixes, quotes and non-asset references" do
  css, warnings = rewrite(%(a{b:url("logo.svg")} c{d:url(x.woff2?v=3#iefix)} e{f:url(data:image/png;base64,AA)} g{h:url(https://cdn/x.png)} i{j:url(#clip)} k{l:url(missing.png)} m{n:url( '/logo.svg' )} o{p:url(%23x)} q{r:url(//cdn/y.png)}))
  assert_includes css, %(url("/assets/logo-#{digest("logo.svg")}.svg"))
  assert_includes css, "url(/assets/x-#{digest("x.woff2")}.woff2?v=3#iefix)"
  assert_includes css, "url(data:image/png;base64,AA)"
  assert_includes css, "url(https://cdn/x.png)"
  assert_includes css, "url(#clip)"
  assert_includes css, "url(missing.png)"
  assert_includes css, "url( '/assets/logo-#{digest("logo.svg")}.svg' )"
  assert_includes css, "url(%23x)"
  assert_includes css, "url(//cdn/y.png)"
  assert_equal 1, warnings.size
  assert_equal "warning: app/assets/stylesheets/application.css: url(missing.png) is not an asset; left as written", warnings[0]
end

test "url() resolves against the stylesheet's logical directory and never climbs out of it" do
  css, warnings = rewrite(%(a{b:url(../images/logo.svg)} c{d:url(../../etc/passwd)} e{f:url(./x.woff2)}))
  assert_includes css, "url(../images/logo.svg)"
  assert_includes css, "url(../../etc/passwd)"
  assert_includes css, "url(/assets/x-#{digest("x.woff2")}.woff2)"
  assert_equal 2, warnings.size
  nested, nested_warnings = Cybertrain::Gen::AssetScan.rewrite_css("a{b:url(../logo.svg)} c{d:url(hello_controller.js)}", "controllers/card.css", scan_now)
  assert_includes nested, "url(/assets/logo-#{digest("logo.svg")}.svg)"
  assert_includes nested, "url(/assets/controllers/hello_controller-#{digest("controllers/hello_controller.js")}.js)"
  assert_equal 0, nested_warnings.size
end

test "a CSS digest is taken after rewriting, CSS files in dependency order" do
  css = asset("application.css")
  assert_includes css.asset_body, %(url("/assets/logo-#{digest("logo.svg")}.svg"))
  assert_equal Digest::SHA256.hexdigest(css.asset_body)[0, 8], css.asset_digest
  File.write("#{TMP}/app/assets/stylesheets/a.css", "@import url(b.css);\n")
  File.write("#{TMP}/app/assets/stylesheets/b.css", "x{y:url(logo.svg)}\n")
  a = asset("a.css")
  File.delete("#{TMP}/app/assets/stylesheets/a.css")
  File.delete("#{TMP}/app/assets/stylesheets/b.css")
  assert_includes a.asset_body, "@import url(/assets/b-"
end

test "a stylesheet named with a ?query is still a dependency, even when its referrer sorts first" do
  File.write("#{TMP}/app/assets/stylesheets/a.css", "@import url(b.css?v=1);\n")
  File.write("#{TMP}/app/assets/stylesheets/b.css", "x{y:url(logo.svg)}\n")
  css, warnings = Cybertrain::Gen::AssetScan.rewrite_css("@import url(b.css?v=1);\n", "a.css", scan_now)
  before_a = digest("a.css")
  before_b = digest("b.css")
  File.write("#{TMP}/app/assets/stylesheets/b.css", "x{y:url(\"logo.svg\")}\n")
  after_a = digest("a.css")
  after_b = digest("b.css")
  File.delete("#{TMP}/app/assets/stylesheets/a.css")
  File.delete("#{TMP}/app/assets/stylesheets/b.css")
  assert_equal 0, warnings.size
  assert_equal "@import url(/assets/b-#{before_b}.css?v=1);\n", css
  refute after_b == before_b
  refute after_a == before_a
end

test "a CSS url() cycle through a suffixed url is refused" do
  File.write("#{TMP}/app/assets/stylesheets/a.css", "@import url(b.css?v=1);\n")
  File.write("#{TMP}/app/assets/stylesheets/b.css", "@import url(\"a.css#top\");\n")
  message = assert_raises("ArgumentError") { scan_now }
  File.delete("#{TMP}/app/assets/stylesheets/a.css")
  File.delete("#{TMP}/app/assets/stylesheets/b.css")
  assert_equal "CSS url() cycle: a.css -> b.css -> a.css", message
end

test "a symlinked file leading outside its tree, or nowhere, stops gen" do
  File.write("#{TMP}/outside.txt", "secret\n")
  File.symlink("#{TMP}/outside.txt", "#{TMP}/app/assets/images/host.txt")
  message = assert_raises("ArgumentError") { scan_now }
  File.delete("#{TMP}/app/assets/images/host.txt")
  assert_equal "asset app/assets/images/host.txt is a symlink to a file outside app/assets; copy the file in instead", message
  File.symlink("#{TMP}/missing.txt", "#{TMP}/app/assets/images/gone.txt")
  message = assert_raises("ArgumentError") { scan_now }
  File.delete("#{TMP}/app/assets/images/gone.txt")
  assert_equal "asset app/assets/images/gone.txt is a symlink to a file that does not exist", message
  File.symlink("#{TMP}/app/assets/images/logo.svg", "#{TMP}/app/assets/fonts/logo-link.svg")
  linked = asset("logo-link.svg")
  File.delete("#{TMP}/app/assets/fonts/logo-link.svg")
  File.delete("#{TMP}/outside.txt")
  assert_equal digest("logo.svg"), linked.asset_digest
end

test "an asset root that is itself a symlink stops gen" do
  Dir.mkdir("#{TMP}/elsewhere")
  File.write("#{TMP}/elsewhere/secret.js", "secret\n")
  File.rename("#{TMP}/vendor/javascript", "#{TMP}/vendor/javascript.real")
  File.symlink("#{TMP}/elsewhere", "#{TMP}/vendor/javascript")
  message = assert_raises("ArgumentError") { scan_now }
  File.delete("#{TMP}/vendor/javascript")
  File.rename("#{TMP}/vendor/javascript.real", "#{TMP}/vendor/javascript")
  remove_tree("#{TMP}/elsewhere")
  assert_equal "vendor/javascript is a symlink; asset directories are never followed, so make it a real directory", message
  assert_equal "chart.js", asset("chart.js").logical_path
end

test "a CSS url() cycle is refused" do
  File.write("#{TMP}/app/assets/stylesheets/a.css", "@import url(b.css);\n")
  File.write("#{TMP}/app/assets/stylesheets/b.css", "@import url(a.css);\n")
  message = assert_raises("ArgumentError") { scan_now }
  File.delete("#{TMP}/app/assets/stylesheets/a.css")
  File.delete("#{TMP}/app/assets/stylesheets/b.css")
  assert_equal "CSS url() cycle: a.css -> b.css -> a.css", message
end

test "a CSS digest changes when an image it names changes" do
  before_css = asset("application.css")
  before_logo = digest("logo.svg")
  original = File.read("#{TMP}/app/assets/images/logo.svg")
  File.write("#{TMP}/app/assets/images/logo.svg", original.sub("r=\"7\"", "r=\"6\""))
  after_css = asset("application.css")
  after_logo = digest("logo.svg")
  File.write("#{TMP}/app/assets/images/logo.svg", original)
  refute after_logo == before_logo
  refute after_css.asset_digest == before_css.asset_digest
  assert_includes before_css.asset_body, "url(\"/assets/logo-#{before_logo}.svg\")"
  assert_includes after_css.asset_body, "url(\"/assets/logo-#{after_logo}.svg\")"
end

test "three versions are kept, older ones deleted" do
  Dir.mkdir("#{TMP}/public")
  Dir.mkdir("#{TMP}/public/assets")
  File.write("#{TMP}/public/assets/keep.txt", "undigested\n")
  original = File.read("#{TMP}/app/assets/stylesheets/application.css")
  digests = Array.new(0) { "" }
  4.times do |i|
    File.write("#{TMP}/app/assets/stylesheets/application.css", "#{original}/* v#{i} */\n")
    files = scan_now
    files.each { |f| digests << f.asset_digest if f.logical_path == "application.css" }
    Cybertrain::Gen::AssetsEmitter.sync_public(TMP, files).each { |line| puts line }
  end
  File.write("#{TMP}/app/assets/stylesheets/application.css", original)
  refute File.exist?("#{TMP}/public/assets/application-#{digests[0]}.css")
  [1, 2, 3].each { |i| assert File.exist?("#{TMP}/public/assets/application-#{digests[i]}.css") }
  assert File.exist?("#{TMP}/public/assets/controllers/hello_controller-#{digest("controllers/hello_controller.js")}.js")
  assert_includes File.read("#{TMP}/public/assets/.manifest"), "application.css #{digests[3]} #{digests[2]} #{digests[1]}\n"
  assert_equal "undigested\n", File.read("#{TMP}/public/assets/keep.txt")
  css = File.read("#{TMP}/public/assets/application-#{digests[3]}.css")
  assert_includes css, "url(\"/assets/logo-#{digest("logo.svg")}.svg\")"
end

test "a manifest line naming a path outside public/assets deletes nothing" do
  File.write("#{TMP}/outside.txt", "keep me\n")
  Cybertrain::Gen::AssetsEmitter.sync_public(TMP, scan_now).each { |line| puts line }
  manifest = File.read("#{TMP}/public/assets/.manifest")
  File.write("#{TMP}/public/assets/.manifest", "#{manifest}../outside.txt 00000000 11111111 22222222 33333333\n/etc/x 00000000\n")
  Cybertrain::Gen::AssetsEmitter.sync_public(TMP, scan_now).each { |line| puts line }
  assert_equal "keep me\n", File.read("#{TMP}/outside.txt")
  assert_equal manifest, File.read("#{TMP}/public/assets/.manifest")
  File.delete("#{TMP}/outside.txt")
end

test "boot and gen read a malformed manifest line alike: the whole line is dropped" do
  Cybertrain::Gen::AssetsEmitter.sync_public(TMP, scan_now).each { |line| puts line }
  manifest = File.read("#{TMP}/public/assets/.manifest")
  File.write("#{TMP}/public/assets/.manifest", "#{manifest}gone.css 1a2b3c4d 2b3c4d5e\nbad.css 1a2b3c4d ZZZZZZZZ\nshort.css 1a2b3c\n")
  Cybertrain::Assets.load_kept("#{TMP}/public")
  # a well-formed line whose asset is gone: gen keeps it, boot serves it
  assert Cybertrain::Assets.kept_file?("gone-2b3c4d5e.css")
  # one bad digest drops the line's good one too, for both
  refute Cybertrain::Assets.kept_file?("bad-1a2b3c4d.css")
  refute Cybertrain::Assets.kept_file?("short-1a2b3c.css")
  Cybertrain::Gen::AssetsEmitter.sync_public(TMP, scan_now).each { |line| puts line }
  rewritten = File.read("#{TMP}/public/assets/.manifest")
  assert_includes rewritten, "gone.css 1a2b3c4d 2b3c4d5e\n"
  refute rewritten.include?("bad.css")
  refute rewritten.include?("short.css")
  assert_equal ["bad.css", "gone.css"], Cybertrain::AssetManifest.read_kept("bad.css 1a2b3c4d\ngone.css 2b3c4d5e\nx.css 1a2b3c4d Q\n").keys.sort
  File.write("#{TMP}/public/assets/.manifest", manifest)
  Cybertrain::Assets.load_kept("#{TMP}/public")
end

test "the import map, preloads and the emitted case" do
  files = scan_now
  text = File.read("#{TMP}/config/importmap.rb")
  pins = Cybertrain::Gen::ImportmapReader.read(text, files)
  source = Cybertrain::Gen::AssetsEmitter.emit(files, pins)
  app = digest("application.js")
  hello = digest("controllers/hello_controller.js")
  json = %({"imports":{"application":"/assets/application-#{app}.js","@hotwired/turbo":"https://cdn.jsdelivr.net/npm/@hotwired/turbo@8.0.12/dist/turbo.es2017-esm.js","controllers/hello_controller":"/assets/controllers/hello_controller-#{hello}.js"}})
  assert_includes source, "require \"cybertrain/assets\"\n"
  assert_includes source, "      when \"logo.svg\" then \"/assets/logo-#{digest("logo.svg")}.svg\"\n"
  assert_includes source, "      else \"\"\n"
  assert_includes source, "      #{Cybertrain::Gen::ViewsEmitter.literal(json)}\n"
  assert_includes source, "    def self.resolver = ->(name) { digest_path(name) }\n"
  build = Cybertrain::Gen::AssetsEmitter.build_digest_of(files, pins, "")
  assert_equal 16, build.size
  assert_includes source, "\nCybertrain::Assets.install(Gen::Assets.resolver, Gen::Assets.importmap_json, Gen::Assets.preload_paths,\n" \
                          "                           \"#{build}\")\n"
  assert_includes source, %(      ["/assets/application-#{app}.js", "https://cdn.jsdelivr.net/npm/@hotwired/turbo@8.0.12/dist/turbo.es2017-esm.js", "/assets/controllers/hello_controller-#{hello}.js"]\n)
  assert_equal json, Cybertrain::Gen::AssetsEmitter.importmap_json(pins, files)

  more = Cybertrain::Gen::ImportmapReader.read("pin \"chart\", to: \"chart.js\", preload: false\npin \"application\" # entry\n", files)
  assert_equal ["chart", "application"], more.map { |p| p.pin_name }
  assert_equal ["/assets/application-#{app}.js"], Cybertrain::Gen::AssetsEmitter.preload_list(more, files)
  assert_equal %({"imports":{"chart":"/assets/chart-#{digest("chart.js")}.js","application":"/assets/application-#{app}.js"}}),
               Cybertrain::Gen::AssetsEmitter.importmap_json(more, files)
  script = Cybertrain::Gen::ImportmapReader.read("pin \"x\", to: \"https://cdn/a</script>.js\"\n", files)
  assert_equal %({"imports":{"x":"https://cdn/a\\u003c/script>.js"}}), Cybertrain::Gen::AssetsEmitter.importmap_json(script, files)

  message = assert_raises("ArgumentError") { Cybertrain::Gen::ImportmapReader.read("pin \"application\"\n\n# x\nenable_integrity!\n", files) }
  assert_equal "config/importmap.rb:4: only pin and pin_all_from lines are read", message
  message = assert_raises("ArgumentError") { Cybertrain::Gen::ImportmapReader.read("pin \"application\"\npin \"x\"\n", files) }
  assert_equal "config/importmap.rb:2: pin \"x\": x.js is not an asset", message
  message = assert_raises("ArgumentError") { Cybertrain::Gen::ImportmapReader.read("pin \"y\", to: \"x.js\"\n", files) }
  assert_equal "config/importmap.rb:1: pin \"y\": x.js is not an asset", message
end

test "the build digest changes with an asset, the import map or the embedded views" do
  files = scan_now
  pins = Cybertrain::Gen::ImportmapReader.read(File.read("#{TMP}/config/importmap.rb"), files)
  base = Cybertrain::Gen::AssetsEmitter.build_digest_of(files, pins, "")
  assert_equal base, Cybertrain::Gen::AssetsEmitter.build_digest_of(files, pins, "")
  refute base == Cybertrain::Gen::AssetsEmitter.build_digest_of(files, pins, "SOURCES = {}")
  fewer = Cybertrain::Gen::ImportmapReader.read("pin \"application\"\n", files)
  refute base == Cybertrain::Gen::AssetsEmitter.build_digest_of(files, fewer, "")
  refute base == Cybertrain::Gen::AssetsEmitter.build_digest_of(files[1, files.size - 1].to_a, pins, "")
  # an --embed-views run hands its gen/views.rb to the digest
  refute Cybertrain::Gen::Runner.assets_output(TMP, true, "embedded views") == Cybertrain::Gen::Runner.assets_source(TMP)
end

test "an application with no assets gets an empty table" do
  source = Cybertrain::Gen::AssetsEmitter.emit(Array.new(0) { Cybertrain::Gen::AssetFile.new("", "", "") },
                                               Array.new(0) { Cybertrain::Gen::ImportmapPin.new("", "", false) })
  assert_includes source, "    def self.digest_path(logical)\n      \"\"\n    end\n"
  assert_includes source, "      \"{\\\"imports\\\":{}}\"\n"
  assert_includes source, "      Array.new(0) { \"\" }\n"
end

# The fixture's checked-in gen/assets.rb, required at the top: a populated
# table compiled into this program. A stale file is rewritten so that the
# next build picks it up.
test "the fixture's compiled gen/assets.rb installs its table" do
  source = Cybertrain::Gen::Runner.assets_source(FIXTURE)
  unless File.read("#{FIXTURE}/gen/assets.rb") == source
    File.write("#{FIXTURE}/gen/assets.rb", source)
    flunk("fixture stale: #{FIXTURE}/gen/assets.rb (rewritten; rebuild and rerun)")
  end
  assert_equal "/assets/logo-#{digest("logo.svg")}.svg", Cybertrain::Assets.digest_path("logo.svg")
  assert_equal "/assets/controllers/hello_controller-#{digest("controllers/hello_controller.js")}.js",
               Cybertrain::Assets.digest_path("controllers/hello_controller.js")
  assert_equal "", Cybertrain::Assets.digest_path("missing.png")
  assert_equal Gen::Assets.importmap_json, Cybertrain::Assets.importmap_json
  assert_includes Cybertrain::Assets.importmap_json, "\"application\":\"/assets/application-#{digest("application.js")}.js\""
  assert_equal 3, Cybertrain::Assets.preload_paths.size
  assert_equal "/assets/application-#{digest("application.js")}.js", Cybertrain::Assets.preload_paths[0]
end

test "gen --check compares gen/assets.rb only" do
  assert_equal 0, Cybertrain::Gen::Runner.run(TMP, [])
  assert File.exist?("#{TMP}/gen/assets.rb")
  assert_includes File.read("#{TMP}/gen/app.rb"), "require_relative \"routes\"\nrequire_relative \"assets\"\n"
  manifest = File.read("#{TMP}/public/assets/.manifest")
  snapshot = public_snapshot
  assert_equal 0, Cybertrain::Gen::Runner.run(TMP, ["--check"])
  assert_equal manifest, File.read("#{TMP}/public/assets/.manifest")
  assert_equal snapshot, public_snapshot
  original = File.read("#{TMP}/app/javascript/application.js")
  File.write("#{TMP}/app/javascript/application.js", "#{original}// changed\n")
  assert_equal 1, Cybertrain::Gen::Runner.run(TMP, ["--check"])
  assert_equal manifest, File.read("#{TMP}/public/assets/.manifest")
  assert_equal snapshot, public_snapshot
  File.write("#{TMP}/app/javascript/application.js", original)
  assert_equal 0, Cybertrain::Gen::Runner.run(TMP, ["--check"])
end

Cybertrain::Test.run!
