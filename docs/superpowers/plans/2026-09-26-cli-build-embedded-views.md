# CLI migration/server/build + embedded views Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `cybertrain migration` / `cybertrain server` / `cybertrain build` work end to end; an app has one entry binary (`./blog`, `./blog migrate`); `cybertrain build` assembles `dist/` with the views embedded in the binary and `public/` copied beside it.

**Architecture:** `Template::Engine` gains an embedded mode (a `Hash<String,String>` of template name → source, keys identical to today's relative paths, so error messages keep the `articles/show.html.erb:12` shape). `spin run gen` always writes `gen/views.rb`: an empty table by default (the committed state), the full table with `--embed-views` (what `cybertrain build` runs, then reverts). `bin/<name>.rb` calls `Cybertrain::Main.run`, which dispatches `server` / `migrate` / `db ...`. The CLI (CRuby gem and spin-built alike) shells out to `spin`.

**Tech Stack:** Spinel `2026.09.12` (`spinel`, `spin`), CRuby 3.2+ for the gem CLI. Tests are `spin test` snapshot programs (`test/<name>.rb` + `.expected`), regenerated with `spin test --regen test/<name>.rb` for CRuby-portable programs.

**Spec:** `docs/superpowers/specs/2026-09-26-cli-build-embedded-views-design.md` (Japanese; authoritative). Spinel constraints: `spikes/NOTES.md` (42 rules).

> **Historical (2026-09-27):** this plan was executed on 2026-09-26; the code and `docs/superpowers/specs/2026-09-26-cli-build-embedded-views-design.md` §8 (as built) are authoritative. Deviations from the tasks below: development migrations run through `bin/db.rb` (kept), so `cybertrain migration` is `spin run gen; spin run db -- migrate; spin run gen` and `Build.migration_commands` takes no name; the CLI uses `system`, not `exec`; `gen/views.rb` embeds only `*.erb`; a build lock (`tmp/cybertrain-build.lock`) and atomic `dist/` replacement were added in PR #5.

## Global Constraints

- Every file under `cybertrain/` compiles under Spinel: no `send` with computed names, no `instance_exec`, no `FileUtils`, no `Dir.glob`; typed empty containers seed-then-delete (`{ "" => "" }; h.delete("")`, `Array.new(0) { "" }`) — spikes/NOTES.md rule 9.
- The CLI files (`cybertrain/cli.rb`, `cybertrain/cli/*.rb`, `cybertrain/generator/inflector.rb`, `cybertrain/version.rb`) must also run under CRuby and must not require anything outside that list (the gemspec lists them by hand; add `cybertrain/cli/build.rb` there).
- Nullable ivars follow the existing pattern: initialize to `nil`, read into a local, test `.nil?` (`@stack` in application.rb, `@engine` in views.rb).
- Do not pass a lambda literal as a keyword argument (application.rb header comment).
- `spin test` must stay green on the full suite; run the full suite in the background (it can exceed 180 s) and subsets (`spin test test/a.rb test/b.rb`, ≤ 6 files) in the foreground.
- Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Output directory name is `dist/` (never `build/`, which spin owns). `dist/storage/` and `dist/tmp/` are never emptied.

---

### Task 1: Embedded mode for `Template::Engine` and `Views`

**Files:**
- Modify: `cybertrain/template/engine.rb` (class `Engine`, lines 46-118)
- Modify: `cybertrain/views.rb` (add `configure_embedded`)
- Create: `test/template_embedded.rb`, `test/template_embedded.rb.expected`

**Interfaces:**
- Produces: `Cybertrain::Template::Engine.embedded(sources)` → `Engine` whose `template(name)` / `exists?(name)` / `render` / `render_with_layout` read from `sources` (`Hash<String, String>`, keys like `"posts/index.html.erb"`). Missing key raises `MissingTemplate, "Missing template posts/nope.html.erb (embedded)"`.
- Produces: `Cybertrain::Views.configure_embedded(sources)` → installs `Engine.embedded(sources)` as the process engine.

- [ ] **Step 1: Write the failing test**

`test/template_embedded.rb`:

```ruby
require "cybertrain/test"
require "cybertrain/template"
require "cybertrain/views"

# Template::Engine.embedded: templates come from a Hash instead of app/views.
# CRuby-portable (no database): `spin test --regen test/template_embedded.rb`.

Engine = Cybertrain::Template::Engine

def helpers = Cybertrain::Template::HelperBase.new

def sources
  table = { "" => "" }
  table.delete("")
  table["layouts/application.html.erb"] = "<html><title><%= yield :title %></title><body>\n<%= yield %></body></html>\n"
  table["pages/index.html.erb"] = "<h1>Hello <%= name %></h1>\n<%= render \"pages/note\", note: \"n1\" %>\n"
  table["pages/_note.html.erb"] = "<%# locals: (note:) %>\n<p><%= note %></p>\n"
  table["pages/broken.html.erb"] = "<p>ok</p>\n<%= missing_helper %>\n"
  table
end

def new_env
  env = {}
  env["name"] = "<world>"
  env["__content_title"] = "Home"
  env
end

test "renders a page and its partial from the embedded table" do
  engine = Engine.embedded(sources)
  assert_equal "<h1>Hello &lt;world&gt;</h1>\n<p>n1</p>\n\n", engine.render("pages/index", new_env, helpers)
end

test "renders inside the embedded layout" do
  html = Engine.embedded(sources).render_with_layout("pages/index", "layouts/application", new_env, helpers)
  assert_equal "<html><title>Home</title><body>\n<h1>Hello &lt;world&gt;</h1>\n<p>n1</p>\n\n</body></html>\n", html
end

test "names with and without the extension are the same template, parsed once" do
  engine = Engine.embedded(sources)
  assert engine.template("pages/index").equal?(engine.template("pages/index.html.erb"))
  assert engine.exists?("pages/index")
  assert engine.exists?("pages/_note.html.erb")
  refute engine.exists?("pages/nope")
end

test "the template name is the key, so errors keep the name:line shape" do
  engine = Engine.embedded(sources)
  assert_equal "pages/index.html.erb", engine.template("pages/index").name
  assert_equal "pages/index.html.erb", engine.template("pages/index").source_path
  error = assert_raises("StandardError") { engine.render("pages/broken", new_env, helpers) }
  assert_includes error.message, "pages/broken.html.erb:2"
end

test "a missing embedded template says so" do
  error = assert_raises("Cybertrain::Template::MissingTemplate") { Engine.embedded(sources).template("pages/nope") }
  assert_equal "Missing template pages/nope.html.erb (embedded)", error.message
end

test "Views.configure_embedded installs an embedded engine" do
  Cybertrain::Views.configure_embedded(sources)
  assert Cybertrain::Views.engine.exists?("pages/index")
  refute Cybertrain::Views.engine.exists?("pages/nope")
end

Cybertrain::Test.run!
```

Check `assert_raises`' signature in `cybertrain/test.rb:107` (it takes a class name string and a block, and returns the error) and the exact wording of the interpreter's undefined-helper error by reading `test/template_interpreter.rb` before finalizing the `"pages/broken.html.erb:2"` assertion; adjust the assertion to whatever `name:line` string the interpreter puts in its message (it must contain the key and line 2).

- [ ] **Step 2: Run the test to verify it fails**

Run: `ruby -I. test/template_embedded.rb`
Expected: `NoMethodError: undefined method 'embedded' for class Cybertrain::Template::Engine`.

- [ ] **Step 3: Implement the embedded mode**

In `cybertrain/template/engine.rb`, replace the header comment's second paragraph and the `Engine` class body:

```ruby
# Templates are parsed at run time. Two sources:
#   Engine.new("app/views", cache: false)   -- files under a root; with
#     `cache: true` (production) each file is parsed once, with `cache: false`
#     (development) a file is re-parsed whenever its mtime or size changes.
#   Engine.embedded(sources)                -- a Hash of "posts/index.html.erb"
#     => source, generated into the binary by `spin run gen -- --embed-views`;
#     parsed once, never re-read.
```

```ruby
    class Engine
      attr_reader :root

      def initialize(root, cache: true)
        @root = root
        @cache = cache
        # nil: read files under root. A Hash: the embedded table.
        @sources = nil
        # Typed empty Hashes (spikes/NOTES.md rule 9).
        @templates = { "" => Template.new("", INode.list, Array.new(0) { "" }, false, "") }
        @templates.delete("")
        @stamps = { "" => "" }
        @stamps.delete("")
      end

      # An engine over an embedded table (Gen::Views::SOURCES).
      def self.embedded(sources)
        engine = Engine.new("", cache: true)
        engine.sources = sources
        engine
      end

      def sources=(table)
        @sources = table
      end

      # "posts/show" and "posts/show.html.erb" name the same template.
      def template(name)
        key = file_name(name)
        cached = @templates[key]
        sources = @sources
        return embedded_template(key, cached, sources) unless sources.nil?
        return cached if @cache && !cached.nil?

        path = File.join(@root, key)
        raise MissingTemplate, "Missing template #{path}" unless File.exist?(path)

        stamp = file_stamp(path)
        return cached if !cached.nil? && @stamps[key] == stamp

        parsed = Template.parse(File.read(path), key, path)
        @templates[key] = parsed
        @stamps[key] = stamp
        parsed
      end

      def exists?(name)
        key = file_name(name)
        sources = @sources
        return sources.key?(key) unless sources.nil?

        File.exist?(File.join(@root, key))
      end
```

and, under `private`:

```ruby
      # Embedded sources never change while the process runs: parsed once,
      # whatever `cache` says. The key doubles as source_path so error
      # messages read "posts/show.html.erb:12: ..." exactly as from disk.
      def embedded_template(key, cached, sources)
        return cached unless cached.nil?

        source = sources[key]
        raise MissingTemplate, "Missing template #{key} (embedded)" if source.nil?

        parsed = Template.parse(source, key, key)
        @templates[key] = parsed
        parsed
      end
```

`render`, `render_with_layout`, `clear_cache!`, `file_name`, `file_stamp` stay as they are.

In `cybertrain/views.rb`, after `configure`:

```ruby
    # Production: the templates `spin run gen -- --embed-views` compiled in.
    def self.configure_embedded(sources)
      @engine = Template::Engine.embedded(sources)
      nil
    end
```

- [ ] **Step 4: Run the test under CRuby, then compiled**

Run: `ruby -I. test/template_embedded.rb`
Expected: `6 tests, N assertions, 0 failures`.

Run: `spin test --regen test/template_embedded.rb && spin test test/template_embedded.rb test/template_engine.rb test/template_integration.rb`
Expected: all pass (the compiled program's output equals the CRuby snapshot). If Spinel rejects `@sources = nil` followed by a Hash assignment, mirror `Views.engine` (`views.rb:20-29`): that pattern is known to compile.

- [ ] **Step 5: Commit**

```bash
git add cybertrain/template/engine.rb cybertrain/views.rb test/template_embedded.rb test/template_embedded.rb.expected
git commit -m "Template::Engine.embedded: render views from a generated table

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: `gen/views.rb` — `ViewsEmitter` and `spin run gen -- --embed-views`

**Files:**
- Create: `cybertrain/generator/views_emitter.rb`
- Modify: `cybertrain/generator/runner.rb` (`run`, lines 18-51)
- Create: `test/fixtures/embed_app/app/views/layouts/application.html.erb`, `test/fixtures/embed_app/app/views/pages/hello.html.erb`, `test/fixtures/embed_app/gen/views.rb` (checked-in emitter output)
- Create: `test/fixtures/gen_app/gen/views.rb` (empty variant; the runner's fixture output)
- Create: `test/gen_views.rb` (+ `.expected`), `test/gen_views_compiles.rb` (+ `.expected`)
- Modify: `test/gen_runner_models.rb` (`GEN_FILES` add `"gen/views.rb"`), regenerate `test/gen_runner_models.rb.expected`
- Modify: `examples/blog/gen/views.rb` (new, empty variant — created by running `spin run gen` in `examples/blog`)

**Interfaces:**
- Produces: `Cybertrain::Gen::ViewsEmitter.emit(root, embed)` → String source of `gen/views.rb`. `embed == false`: empty `Gen::Views::SOURCES`. `embed == true`: every file under `root/app/views/**` (any extension), keys relative to `app/views`, sorted; plus the trailing `ENV["CYBERTRAIN_ENV"]` default line.
- Produces: `Cybertrain::Gen::ViewsEmitter.literal(text)` → a double-quoted Ruby literal (escapes `\`, `"`, `#`, newline, CR, tab; everything else raw, UTF-8 included — verified against Spinel by spike, 47-byte round trip).
- Produces: `Cybertrain::Gen::ViewsEmitter.view_files(dir)` → sorted relative paths of every regular file under `dir` (recursive, `Dir.children`-based like `ControllerScan.ruby_files`).
- Produces: `spin run gen -- --embed-views` (Runner reads `argv.include?("--embed-views")`).

- [ ] **Step 1: Create the fixture app views**

`test/fixtures/embed_app/app/views/layouts/application.html.erb`:

```erb
<html><body>
<%= yield %></body></html>
```

`test/fixtures/embed_app/app/views/pages/hello.html.erb` (contains a quote, a backslash, a hash-brace, a tab and Japanese on purpose):

```erb
<%# locals: (name:) %>
<h1>こんにちは "<%= name %>"</h1>
<p>backslash \ and #{not interpolated} and	tab</p>
```

(The third line has a literal TAB character between `and` and `tab`.)

- [ ] **Step 2: Write the failing emitter test**

`test/gen_views.rb`:

```ruby
require "tmpdir"
require "cybertrain/test"
require "cybertrain/generator"

# Gen::ViewsEmitter writes gen/views.rb: an empty table by default, the
# whole app/views tree with --embed-views. CRuby-portable (text only).

FIXTURE = "test/fixtures/embed_app"

test "literal escapes what a double-quoted Ruby string needs and nothing else" do
  assert_equal "\"plain\"", Cybertrain::Gen::ViewsEmitter.literal("plain")
  assert_equal "\"a\\\"b\"", Cybertrain::Gen::ViewsEmitter.literal("a\"b")
  assert_equal "\"a\\\\b\"", Cybertrain::Gen::ViewsEmitter.literal("a\\b")
  assert_equal "\"\\#{x}\"", Cybertrain::Gen::ViewsEmitter.literal("\#{x}")
  assert_equal "\"l1\\nl2\\r\\tz\"", Cybertrain::Gen::ViewsEmitter.literal("l1\nl2\r\tz")
  assert_equal "\"こんにちは\"", Cybertrain::Gen::ViewsEmitter.literal("こんにちは")
end

test "view_files lists every file under app/views, sorted, relative" do
  assert_equal ["layouts/application.html.erb", "pages/hello.html.erb"],
               Cybertrain::Gen::ViewsEmitter.view_files("#{FIXTURE}/app/views")
  assert_equal 0, Cybertrain::Gen::ViewsEmitter.view_files("#{FIXTURE}/no_such_dir").size
end

test "without --embed-views the table is empty and the env is untouched" do
  source = Cybertrain::Gen::ViewsEmitter.emit(FIXTURE, false)
  assert_equal <<~RUBY, source
    # Generated by `spin run gen`. Do not edit.
    # Empty: this build reads app/views/ from disk. `spin run gen -- --embed-views`
    # (what `cybertrain build` runs) fills it and the binary stops reading disk.
    module Gen
      module Views
        SOURCES = { "" => "" }
        SOURCES.delete("")
      end
    end
  RUBY
  assert_nil source.index("CYBERTRAIN_ENV")
end

test "with --embed-views every view is a literal and production becomes the default env" do
  source = Cybertrain::Gen::ViewsEmitter.emit(FIXTURE, true)
  assert_equal File.read("#{FIXTURE}/gen/views.rb"), source
  assert_includes source, "\"pages/hello.html.erb\" => \"<%# locals: (name:) %>\\n<h1>こんにちは \\\"<%= name %>\\\"</h1>\\n<p>backslash \\\\ and \\#{not interpolated} and\\ttab</p>\\n\","
  assert_includes source, "ENV[\"CYBERTRAIN_ENV\"] = \"production\" if (ENV[\"CYBERTRAIN_ENV\"] || \"\").empty?\n"
end

test "the runner writes gen/views.rb, empty by default and full with --embed-views" do
  root = Dir.mktmpdir("cybertrain-gen-views")
  Dir.mkdir("#{root}/app")
  Dir.mkdir("#{root}/app/views")
  File.write("#{root}/app/views/a.html.erb", "<p>a</p>\n")
  Dir.mkdir("#{root}/app/controllers")
  Cybertrain::Routes.reset! if Cybertrain::Routes.respond_to?(:reset!)
  Cybertrain::Gen::Runner.run(root, [])
  assert_nil File.read("#{root}/gen/views.rb").index("a.html.erb")
  Cybertrain::Gen::Runner.run(root, ["--embed-views"])
  assert_includes File.read("#{root}/gen/views.rb"), "\"a.html.erb\" => \"<p>a</p>\\n\","
  Cybertrain::Gen::Runner.run(root, [])
  assert_nil File.read("#{root}/gen/views.rb").index("a.html.erb")
  ["gen/views.rb", "gen/routes.rb", "gen/controllers.rb", "gen/app.rb", "app/views/a.html.erb"].each do |f|
    File.delete("#{root}/#{f}") if File.exist?("#{root}/#{f}")
  end
  ["gen", "app/views", "app/controllers", "app"].each { |d| Dir.rmdir("#{root}/#{d}") if File.directory?("#{root}/#{d}") }
  Dir.rmdir(root)
end

Cybertrain::Test.run!
```

Before running: check how `test/gen_manifest.rb` and `test/gen_runner_models.rb` set up routes for `Runner.run` (the runner calls `Cybertrain::Routes.specs`; with no `config/routes.rb` loaded it must still work — those tests show the pattern). Replace the `respond_to?` line with whatever they do; `respond_to?` is not for Spinel code, but a test program may still avoid it — follow the existing tests.

- [ ] **Step 3: Run the test to verify it fails**

Run: `ruby -I. test/gen_views.rb`
Expected: `NameError: uninitialized constant Cybertrain::Gen::ViewsEmitter`.

- [ ] **Step 4: Implement the emitter**

`cybertrain/generator/views_emitter.rb`:

```ruby
module Cybertrain
  module Gen
    # Cybertrain::Gen::ViewsEmitter -- writes gen/views.rb, the table a
    # production binary renders views from (Template::Engine.embedded).
    #
    # Plain `spin run gen` writes an empty table: the committed state, so
    # editing a view never dirties gen/, and a development binary reads
    # app/views/ from disk. `spin run gen -- --embed-views` (what
    # `cybertrain build` runs before `spin build`, reverting afterwards)
    # writes every file under app/views/ as a string literal, and makes
    # production the default CYBERTRAIN_ENV of that binary.
    module ViewsEmitter
      HEADER = "# Generated by `spin run gen`. Do not edit.\n"

      def self.emit(root, embed)
        embed ? emit_embedded(root) : emit_empty
      end

      def self.emit_empty
        HEADER +
          "# Empty: this build reads app/views/ from disk. `spin run gen -- --embed-views`\n" \
          "# (what `cybertrain build` runs) fills it and the binary stops reading disk.\n" \
          "module Gen\n" \
          "  module Views\n" \
          "    SOURCES = { \"\" => \"\" }\n" \
          "    SOURCES.delete(\"\")\n" \
          "  end\n" \
          "end\n"
      end

      def self.emit_embedded(root)
        dir = "#{root}/app/views"
        buf = +HEADER
        buf << "module Gen\n  module Views\n    SOURCES = {\n"
        view_files(dir).each do |rel|
          buf << "      #{literal(rel)} => #{literal(File.read("#{dir}/#{rel}"))},\n"
        end
        buf << "    }\n  end\nend\n"
        buf << "ENV[\"CYBERTRAIN_ENV\"] = \"production\" if (ENV[\"CYBERTRAIN_ENV\"] || \"\").empty?\n"
        buf
      end

      # A double-quoted literal Spinel and CRuby read back to the same
      # bytes: only the six characters that need escaping are escaped;
      # UTF-8 passes through raw (verified by spike, 2026-09-26).
      def self.literal(text)
        escaped = text.gsub("\\", "\\\\\\\\").gsub("\"", "\\\"").gsub("#", "\\#")
                      .gsub("\n", "\\n").gsub("\r", "\\r").gsub("\t", "\\t")
        "\"#{escaped}\""
      end

      # Every regular file under dir, as sorted paths relative to dir.
      def self.view_files(dir)
        files = Array.new(0) { "" }
        collect(dir, "", files)
        files.sort
      end

      def self.collect(dir, prefix, files)
        return nil unless File.directory?(dir)

        Dir.children(dir).sort.each do |entry|
          path = "#{dir}/#{entry}"
          rel = prefix == "" ? entry : "#{prefix}/#{entry}"
          if File.directory?(path)
            collect(path, rel, files)
          else
            files << rel
          end
        end
        nil
      end
    end
  end
end
```

Verify the `gsub("\\", "\\\\\\\\")` replacement string under CRuby: `"a\\b".gsub("\\", "\\\\\\\\")` must give `a\\b` (two backslashes); if it gives four, use `gsub("\\") { "\\\\" }` — but a block form must also compile under Spinel, so test both in `ruby -e` and in the compiled test before choosing.

In `cybertrain/generator/runner.rb`: add `require "cybertrain/generator/views_emitter"` at the top, and in `run` right after `check = argv.include?("--check")`:

```ruby
        embed = argv.include?("--embed-views")
        outputs = [
          ["gen/routes.rb", RoutesEmitter.emit(Cybertrain::Routes.specs)],
          ["gen/controllers.rb", ControllersEmitter.emit(ControllerScan.scan_dir("#{root}/app/controllers"))],
          ["gen/views.rb", ViewsEmitter.emit(root, embed)]
        ]
```

Update the module comment: "`--embed-views` writes gen/views.rb with the app/views tree instead of an empty table".

- [ ] **Step 5: Generate the fixture outputs and run**

```bash
ruby -I. -e 'require "cybertrain/generator"; File.write("test/fixtures/embed_app/gen/views.rb", Cybertrain::Gen::ViewsEmitter.emit("test/fixtures/embed_app", true))'
ruby -I. -e 'require "cybertrain/generator"; File.write("test/fixtures/gen_app/gen/views.rb", Cybertrain::Gen::ViewsEmitter.emit("test/fixtures/gen_app", false))'
ruby -I. test/gen_views.rb
```

Expected: `5 tests, N assertions, 0 failures`. Inspect `test/fixtures/embed_app/gen/views.rb` by eye: two entries, the Japanese raw, `\"`, `\\`, `\#{`, `\t`, `\n`.

- [ ] **Step 6: Write the compile round-trip test**

`test/gen_views_compiles.rb`:

```ruby
require "cybertrain/test"
require_relative "fixtures/embed_app/gen/views"

# The literals gen/views.rb emits read back, compiled by Spinel, to the
# same bytes as the files they came from. Also runs under CRuby.

test "every embedded view equals its file byte for byte" do
  ["layouts/application.html.erb", "pages/hello.html.erb"].each do |key|
    assert_equal File.read("test/fixtures/embed_app/app/views/#{key}"), Gen::Views::SOURCES[key]
  end
  assert_equal 2, Gen::Views::SOURCES.size
end

test "an embedded build defaults CYBERTRAIN_ENV to production" do
  assert_equal "production", ENV["CYBERTRAIN_ENV"]
end

Cybertrain::Test.run!
```

Run: `spin test --regen test/gen_views.rb test/gen_views_compiles.rb && spin test test/gen_views.rb test/gen_views_compiles.rb`
Expected: both pass compiled. If `--regen` accepts one file only, run it twice. If the compiled `gen_views_compiles` differs from CRuby, the emitter's escaping is wrong for Spinel: fix `literal`, never the test.

- [ ] **Step 7: Update the runner snapshot tests and the example app**

- `test/gen_runner_models.rb`: add `"gen/views.rb"` to `GEN_FILES`. Run `spin test --regen test/gen_runner_models.rb`; check the diff of `.expected` only adds `wrote gen/views.rb` / `identical gen/views.rb` lines.
- Grep `test/` for other programs that call `Runner.run` (`grep -ln "Runner.run" test/*.rb`); regenerate each the same way and review the diff.
- `cd examples/blog && spin run gen` → creates `examples/blog/gen/views.rb` (empty variant). `spin run gen -- --check` must then exit 0.

Run: `spin test test/gen_runner_models.rb test/gen_manifest.rb test/gen_views.rb test/gen_views_compiles.rb`
Expected: pass.

- [ ] **Step 8: Commit**

```bash
git add cybertrain/generator/views_emitter.rb cybertrain/generator/runner.rb test/gen_views.rb test/gen_views.rb.expected test/gen_views_compiles.rb test/gen_views_compiles.rb.expected test/fixtures/embed_app test/fixtures/gen_app/gen/views.rb test/gen_runner_models.rb test/gen_runner_models.rb.expected examples/blog/gen/views.rb
git commit -m "gen: write gen/views.rb; --embed-views compiles app/views into the binary

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `Application` takes `views:` and `name:`; production requires embedded views

**Files:**
- Modify: `cybertrain/application.rb` (`initialize` 38-48, `boot` 66-75, `serve` 96-109, `port_argument`, `exec_new_build`)
- Modify: `cybertrain/dev/rebuilder.rb` (comment only: target is the app name)
- Modify: `test/application.rb` (add two tests near "production puts ErrorPages outermost", line 259)
- Modify: `test/dev_application.rb:86,142-145` (rebuilder built with a name)

**Interfaces:**
- Consumes: `Views.configure_embedded(sources)` (Task 1).
- Produces: `Cybertrain::Application.new(router:, url_resolver:, views: <Hash>, name: "server", config: Cybertrain.config)`. `views` defaults to an empty Hash; `name` is the `spin build` target and `build/bin/<name>` the dev loop execs.
- Produces: `Application#run(argv)` and `Application#serve(argv)` — the port comes from `argv`, not `ARGV`.
- Produces: `Application.embedded_views_missing?(config, views)` → true when `config.production?` and `views.empty?` (what `boot` refuses on).

- [ ] **Step 1: Write the failing tests**

In `test/application.rb`, after the "production puts ErrorPages outermost" test:

```ruby
test "production refuses to boot without embedded views" do
  c = Cybertrain::Config.new
  c.env = "production"
  c.secret_key_base = "production-secret"
  none = { "" => "" }
  none.delete("")
  assert Cybertrain::Application.embedded_views_missing?(c, none)
  some = { "pages/index.html.erb" => "<p>hi</p>\n" }
  refute Cybertrain::Application.embedded_views_missing?(c, some)
  c.env = "development"
  refute Cybertrain::Application.embedded_views_missing?(c, none)
end

test "production boots on the embedded table, development on app/views" do
  c = Cybertrain::Config.new
  c.env = "production"
  c.database_path = ":memory:"
  c.secret_key_base = "production-secret"
  c.log_level = :none
  some = { "pages/index.html.erb" => "<p>embedded</p>\n" }
  Cybertrain::Application.new(router: Cybertrain::Router.new, url_resolver: ->(name, args) { "/" }, views: some, config: c).boot
  assert Cybertrain::Views.engine.exists?("pages/index")
  refute Cybertrain::Views.engine.exists?("layouts/application")
  d = Cybertrain::Config.new
  d.env = "development"
  d.database_path = ":memory:"
  d.secret_key_base = "dev-secret"
  d.log_level = :none
  d.views_root = "test/fixtures/views"
  Cybertrain::Application.new(router: Cybertrain::Router.new, url_resolver: ->(name, args) { "/" }, views: some, config: d).boot
  assert Cybertrain::Views.engine.exists?("layouts/application")
  refute Cybertrain::Views.engine.exists?("pages/index")
end
```

Check whether `boot` connecting `DB` twice is a problem (`DB.connect ... unless DB.connected?` — it is guarded, and `APP.boot` at line 231 already connected; fine). Keep the `url_resolver` lambdas as the surrounding tests write them.

In `test/dev_application.rb`, change line 86 to `REBUILDER = Cybertrain::Dev::Rebuilder.new(File.expand_path(ROOT), "blog")` and the test at 142-145 to expect `build/bin/blog`, renaming it "the rebuilder targets the app's build/bin/<name>".

- [ ] **Step 2: Run to verify failure**

Run: `spin test test/application.rb test/dev_application.rb`
Expected: compile or assertion failure (`embedded_views_missing?` undefined; `views:` unknown keyword).

- [ ] **Step 3: Implement**

`cybertrain/application.rb`:

```ruby
    def initialize(router:, url_resolver:, views: Application.no_views, name: "server", config: Cybertrain.config)
      @router = router
      @url_resolver = url_resolver
      @views = views
      @name = name
      @config = config
      ...
    end

    # A typed empty table (spikes/NOTES.md rule 9): the default for a
    # binary built without `--embed-views`.
    def self.no_views
      none = { "" => "" }
      none.delete("")
      none
    end

    # Production renders only embedded views (gen/views.rb written by
    # `spin run gen -- --embed-views`); a plain build has an empty table.
    def self.embedded_views_missing?(config, views)
      config.production? && views.empty?
    end

    def boot
      c = @config
      if Application.embedded_views_missing?(c, @views)
        puts "error: views are not embedded in this binary; build with `cybertrain build` (or run with CYBERTRAIN_ENV=development)"
        STDOUT.flush
        exit(1)
      end
      c.resolve_secret!
      DB.connect(c.database_path, size: c.pool_size) unless DB.connected?
      if c.production?
        Views.configure_embedded(@views)
      else
        Views.configure(c.views_root, cache: !c.development?)
      end
      Views.url_resolver = @url_resolver
      Views.layout_name = c.layout
      Cybertrain.logger.level = c.log_level == :none ? :error : c.log_level
      self
    end

    # Boots and serves until SIGTERM. argv: [] or ["<port>"] (Main passes
    # what follows the `server` word; the dev loop's execv passes the port).
    def run(argv)
      boot
      serve(argv)
    end

    def serve(argv)
      ENV["SPINEL_WORKERS"] = @config.workers.to_s
      port = Application.port_argument(argv)
      @config.port = port if port > 0
      print_boot_banner
      if @config.development?
        serve_development(Dev::Rebuilder.new(Dir.pwd, @name))
      else
        ...
```

Update the class comment (lines 18-29) to the new `bin/<name>.rb` shape (see Task 4's template). `exec_new_build` is unchanged (it uses `rebuilder.binary_path`, now `build/bin/<name>`).

In `cybertrain/dev/rebuilder.rb`, change the class comment: "target is the app's bin/<name>.rb executable (the package name); `server` only as a default for tests".

- [ ] **Step 4: Run the tests**

Run: `spin test --regen test/application.rb` is NOT possible (FFI) — instead build and run: `spin test test/application.rb test/dev_application.rb test/dev_error_page.rb`. When only the new tests' `ok` lines are missing from the snapshot, append them by taking the compiled binary's output: `./build/test/application > test/application.rb.expected` and `./build/test/dev_application > test/dev_application.rb.expected` (the pattern in `examples/blog/test/support/blog_test.rb`'s header), then `git diff test/*.expected` to confirm only the new/renamed lines changed.
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add cybertrain/application.rb cybertrain/dev/rebuilder.rb test/application.rb test/application.rb.expected test/dev_application.rb test/dev_application.rb.expected
git commit -m "Application: embedded views in production, app name for the dev loop

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: `Cybertrain::Main` — the single app entry

**Files:**
- Create: `cybertrain/main.rb`
- Modify: `cybertrain.rb` (add `require "cybertrain/main"` after `require "cybertrain/application"`)
- Create: `test/main.rb`, `test/main.rb.expected`

**Interfaces:**
- Consumes: `Application.new(router:, url_resolver:, views:, name:)`, `Application#run(argv)` (Task 3); `DB::CLI.run(argv)`.
- Produces: `Cybertrain::Main.run(name, argv, router:, url_resolver:, views:)` → Integer exit code. Dispatch: `[]`/`["server"]`/`["3000"]`/`["server", "3000"]` → serve; `["migrate"]` → `DB::CLI.run(["migrate"])`; `["db", *rest]` → `DB::CLI.run(rest)`; `["help"]`, `["--help"]`, `["-h"]` → usage, 0; anything else → usage, 1.
- Produces: `Cybertrain::Main.server_args(argv)` → the argv `Application#run` gets (`["3000"]` or `[]`), and `Cybertrain::Main.usage(name)` → String.

- [ ] **Step 1: Write the failing test**

`test/main.rb`:

```ruby
require "cybertrain/test"
require "cybertrain/main"

# Cybertrain::Main.run dispatches bin/<name>.rb's argv. The server branch
# is not exercised here (it would listen); Application covers it. The db
# branch goes through DB::CLI, which links SQLite: this program's snapshot
# comes from the compiled binary (spikes/NOTES.md rule 23).

def no_views
  none = { "" => "" }
  none.delete("")
  none
end

def resolver = ->(name, args) { "/" }

def run(argv)
  Cybertrain::Main.run("blog", argv, router: Cybertrain::Router.new, url_resolver: resolver, views: no_views)
end

test "server_args keeps only a port" do
  assert_equal 0, Cybertrain::Main.server_args([]).size
  assert_equal 0, Cybertrain::Main.server_args(["server"]).size
  assert_equal ["3000"], Cybertrain::Main.server_args(["3000"])
  assert_equal ["3000"], Cybertrain::Main.server_args(["server", "3000"])
end

test "server? recognises the bare, named and port forms" do
  assert Cybertrain::Main.server?([])
  assert Cybertrain::Main.server?(["server"])
  assert Cybertrain::Main.server?(["3000"])
  assert Cybertrain::Main.server?(["server", "3000"])
  refute Cybertrain::Main.server?(["migrate"])
  refute Cybertrain::Main.server?(["frobnicate"])
end

test "help prints the usage for this app and exits 0" do
  assert_equal 0, run(["help"])
  assert_equal 0, run(["--help"])
end

test "an unknown word prints the usage and exits 1" do
  assert_equal 1, run(["frobnicate"])
end

test "db passes its arguments to DB::CLI" do
  ENV["CYBERTRAIN_DATABASE"] = ":memory:"
  assert_equal 0, run(["db", "status"])
  assert_equal 1, run(["db", "rollback", "x"])
  assert_equal 1, run(["db"])
end

test "migrate is db migrate" do
  ENV["CYBERTRAIN_DATABASE"] = ":memory:"
  assert_equal 0, run(["migrate"])
end

Cybertrain::Test.run!
```

Read `test/db_cli.rb` first to see how it isolates the database (`:memory:` through `CYBERTRAIN_DATABASE` or a temp path) and copy that; `Cybertrain::Migration.reset!` may be needed so `migrate` has nothing to apply.

- [ ] **Step 2: Run to verify failure**

Run: `spin test test/main.rb`
Expected: compile error, `cybertrain/main` not found.

- [ ] **Step 3: Implement**

`cybertrain/main.rb`:

```ruby
require "cybertrain/application"
require "cybertrain/db/cli"

module Cybertrain
  # Cybertrain::Main -- what bin/<name>.rb runs, the one binary an app
  # builds (`spin build blog` -> build/bin/blog; `cybertrain build` ->
  # dist/blog):
  #
  #   ./blog              serve (port from PORT / config)
  #   ./blog server 3000  serve on 3000 (a bare "3000" too: the dev loop's
  #                       execv passes the port that way)
  #   ./blog migrate      apply db/migrate (gen/migrations.rb)
  #   ./blog db status    any DB::CLI command: status, rollback N, schema:dump, create
  #
  # `gen` stays a separate bin/gen.rb: it needs the generator and the
  # routes/schema DSL, none of which belong in the production binary.
  module Main
    def self.run(name, argv, router:, url_resolver:, views:)
      return serve(name, argv, router, url_resolver, views) if server?(argv)

      case argv[0]
      when "migrate"
        DB::CLI.run(["migrate"])
      when "db"
        DB::CLI.run(argv[1, argv.size - 1])
      when "help", "--help", "-h"
        puts usage(name)
        0
      else
        puts "Unknown command '#{argv[0]}'"
        puts usage(name)
        1
      end
    end

    # [], ["server"], ["<port>"], ["server", "<port>"].
    def self.server?(argv)
      return true if argv.empty?
      return true if argv[0] == "server"

      Application.port_argument(argv) > 0
    end

    # The port argument Application#run expects, without the "server" word.
    def self.server_args(argv)
      return argv[1, argv.size - 1] if !argv.empty? && argv[0] == "server"

      argv
    end

    def self.serve(name, argv, router, url_resolver, views)
      app = Application.new(router: router, url_resolver: url_resolver, views: views, name: name)
      app.run(server_args(argv))
      0
    end

    def self.usage(name)
      <<~TEXT
        Usage:
          ./#{name} [server [PORT]]   start the server
          ./#{name} migrate           apply pending migrations
          ./#{name} db COMMAND        migrate | rollback [N] | status | schema:dump | create
          ./#{name} help
      TEXT
    end
  end
end
```

Passing `url_resolver` positionally through `serve` and then as a keyword to `Application.new` is the "method-returned / positional" shape the application.rb header allows; do not inline a lambda literal.

Add `require "cybertrain/main"` at the end of `cybertrain.rb`.

- [ ] **Step 4: Run, snapshot from the compiled binary, re-run**

Run: `spin test test/main.rb`; on the expected-file mismatch, `./build/test/main > test/main.rb.expected`, read the file (usage text, `db status` output, `ok` lines, `6 tests, ... 0 failures`), then `spin test test/main.rb` again.
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add cybertrain/main.rb cybertrain.rb test/main.rb test/main.rb.expected
git commit -m "Cybertrain::Main: one app binary with server, migrate and db subcommands

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: `cybertrain new` writes `bin/<name>.rb`

**Files:**
- Modify: `cybertrain/cli/templates.rb` (`gitignore` 76-84, `readme` 86-105, `bin_server` 207-218 → `bin_app(package)`, delete `bin_db` 231-240)
- Modify: `cybertrain/cli/new_app.rb` (file list, lines 17-38)
- Modify: `test/cli_new.rb` (`EXPECTED_FILES`, the bin tests, the README test), regenerate `test/cli_new.rb.expected`

**Interfaces:**
- Consumes: `Cybertrain::Main.run` signature (Task 4) — the template text must match it.
- Produces: `Templates.bin_app(package)` → the `bin/<package>.rb` source below. `NewApp.create` writes `bin/<package>.rb` and `bin/gen.rb` only.

- [ ] **Step 1: Update the test**

In `test/cli_new.rb`:

- `EXPECTED_FILES`: replace `"bin/server.rb", "bin/gen.rb", "bin/db.rb"` with `"bin/blog.rb", "bin/gen.rb"`.
- Replace the "bin/server.rb boots the application" test with:

```ruby
test "bin/blog.rb is the app's one binary: server, migrate, db" do
  assert_equal <<~RUBY, read("blog/bin/blog.rb")
    require "cybertrain"
    require_relative "../gen/views"      # embedded build: sets CYBERTRAIN_ENV=production by default
    require_relative "../config/app"     # so it comes before the config
    require_relative "../gen/app"
    require_relative "../gen/migrations"

    exit(Cybertrain::Main.run("blog", ARGV,
                              router: Gen::Routes.build(Cybertrain::Router.new),
                              url_resolver: Gen::Routes.url_resolver,
                              views: Gen::Views::SOURCES))
  RUBY
end
```

- Replace "bin/gen.rb and bin/db.rb drive the generator and the migrator" with a test named "bin/gen.rb drives the generator" that asserts only `bin/gen.rb` (same content as today) and `refute File.exist?("blog/bin/db.rb")`, `refute File.exist?("blog/bin/server.rb")`.
- Replace the README test with:

```ruby
test "README.md gives the cybertrain command sequence" do
  readme = read("blog/README.md")
  assert_includes readme, "cybertrain migration"
  assert_includes readme, "cybertrain server"
  assert_includes readme, "cybertrain build"
  assert_nil readme.index("spin run db")
end
```

- In "application_controller.rb and config/app.rb are ready to edit", add `assert_includes read("blog/.gitignore"), "/dist/"`.

- [ ] **Step 2: Run to verify failure**

Run: `ruby -I. test/cli_new.rb`
Expected: the file-list assertion fails (`bin/server.rb` still written).

- [ ] **Step 3: Implement the templates**

`cybertrain/cli/templates.rb`:

`gitignore`: add `/dist/` after `/build/`.

`readme(title)`:

```ruby
      def self.readme(title)
        <<~MARKDOWN
          # #{title}

          A cybertrain application, compiled to one binary by Spinel.

          ```sh
          cybertrain generate scaffold post title:string body:text
          cybertrain migration   # gen, apply db/migrate, gen again
          cybertrain server      # http://127.0.0.1:3000
          cybertrain build       # dist/: the binary (views embedded) + public/
          ```

          `spin run gen` (which `migration`, `server` and `build` run for you)
          regenerates `gen/` from db/schema.rb, config/routes.rb and app/;
          commit `gen/`. In development views under `app/views/` are read at
          run time: edit them without rebuilding. `cybertrain db status` and
          `cybertrain db rollback 1` reach the other database commands.

          To deploy, copy `dist/` to a machine with the same OS and CPU, then
          `cd dist && ./#{package} migrate && ./#{package}` (production by default;
          set CYBERTRAIN_SECRET_KEY_BASE).
        MARKDOWN
      end
```

`readme` now needs the package name: change the signature to `readme(title, package)` and the call in `new_app.rb` to `Templates.readme(title, package)`.

Replace `bin_server` and delete `bin_db`:

```ruby
      def self.bin_app(package)
        <<~RUBY
          require "cybertrain"
          require_relative "../gen/views"      # embedded build: sets CYBERTRAIN_ENV=production by default
          require_relative "../config/app"     # so it comes before the config
          require_relative "../gen/app"
          require_relative "../gen/migrations"

          exit(Cybertrain::Main.run("#{package}", ARGV,
                                    router: Gen::Routes.build(Cybertrain::Router.new),
                                    url_resolver: Gen::Routes.url_resolver,
                                    views: Gen::Views::SOURCES))
        RUBY
      end
```

`cybertrain/cli/new_app.rb` file list: replace the three bin entries with

```ruby
          ["bin/#{package}.rb", Templates.bin_app(package)],
          ["bin/gen.rb", Templates.bin_gen],
```

Note `gen/migrations.rb` is only written once `db/migrate/` exists (runner.rb:25) — `cybertrain new` creates `db/migrate/.keep`, so it exists from the first `spin run gen`. Confirm by reading runner.rb:25; if the check were on `.rb` files rather than the directory, `bin/<name>.rb` would fail to compile on a fresh app and the emitter must be made unconditional.

- [ ] **Step 4: Run, regenerate the snapshot, re-run**

Run: `ruby -I. test/cli_new.rb` → expect `16 tests ... 0 failures`. Then `spin test --regen test/cli_new.rb && spin test test/cli_new.rb test/cli_scaffold.rb test/cli_scaffold_views.rb`.
Expected: pass. `git diff test/cli_new.rb.expected` shows only the bin lines and renamed tests.

- [ ] **Step 5: Smoke `cybertrain new` against the checkout**

```bash
cd /private/tmp/claude-501/-Users-saeki-work-cybertrain/3c08a7ff-5489-489a-ba5a-664c2c4952c3/scratchpad && rm -rf smoke && ruby -I/Users/saeki/work/cybertrain /Users/saeki/work/cybertrain/bin/cybertrain.rb new smoke --path /Users/saeki/work/cybertrain && cd smoke && spin build smoke && ./build/bin/smoke help
```

Expected: builds; `help` prints the usage with `./smoke`. Then `CYBERTRAIN_ENV=production ./build/bin/smoke` must print the "views are not embedded" error and exit 1 (`echo $?`).

- [ ] **Step 6: Commit**

```bash
git add cybertrain/cli/templates.rb cybertrain/cli/new_app.rb test/cli_new.rb test/cli_new.rb.expected
git commit -m "cybertrain new: one bin/<name>.rb entry, README with the cybertrain commands

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: CLI `migration`, `db`, `server`, `build`

**Files:**
- Create: `cybertrain/cli/build.rb`
- Modify: `cybertrain/cli.rb` (`USAGE`, `run`, new `run_*` methods)
- Modify: `cybertrain.gemspec` (`spec.files` add `"cybertrain/cli/build.rb"`)
- Modify: `.gitignore` (repo root: add `dist/`)
- Create: `test/cli_build.rb`, `test/cli_build.rb.expected`
- Modify: `test/cli_new.rb.expected` (USAGE text changes) — regenerate

**Interfaces:**
- Produces: `Cybertrain::CLI::Build.app_name(root)` → the `[package] name` from `root/spin.toml`, or `""`.
- Produces: `Cybertrain::CLI::Build.commands(name)` → `["spin run gen -- --embed-views", "spin build <name>", "spin run gen"]`; `Build.migration_commands(name)` → `["spin run gen", "spin run <name> -- migrate", "spin run gen"]`.
- Produces: `Cybertrain::CLI::Build.assemble(root, name)` → copies `root/build/bin/<name>` to `root/dist/<name>`, replaces `root/dist/public` with a copy of `root/public`, creates `root/dist/storage` and `root/dist/tmp` if missing; returns the list of paths it wrote (`["dist/<name>", "dist/public/", "dist/storage/", "dist/tmp/"]`).
- Produces: `Cybertrain::CLI::Build.run(root, name)` → exit code: runs step 1-2, always runs step 3, assembles on success, prints the summary.
- Produces: CLI words `migration`, `db ARGS...`, `server`, `build` (`cybertrain/cli.rb`).

- [ ] **Step 1: Write the failing test**

`test/cli_build.rb`:

```ruby
require "tmpdir"
require "cybertrain/test"
require "cybertrain/cli"

# cybertrain build without spin: the command list and the dist/ assembly
# from a fake build/bin/<name>. CRuby-portable.

ROOT = Dir.mktmpdir("cybertrain-cli-build")
Dir.chdir(ROOT)

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
  rm_tree(ROOT)
end

def make_app
  File.write("spin.toml", "[package]\nname = \"blog\"\nversion = \"0.1.0\"\n\n[dependencies]\ncybertrain = { path = \"../cybertrain\" }\n")
  Dir.mkdir("build")
  Dir.mkdir("build/bin")
  File.write("build/bin/blog", "#!/bin/sh\necho built\n")
  File.chmod(0o755, "build/bin/blog")
  Dir.mkdir("public")
  Dir.mkdir("public/img")
  File.write("public/style.css", "body{}\n")
  File.write("public/img/logo.txt", "logo\n")
end

make_app

test "app_name reads [package] name from spin.toml" do
  assert_equal "blog", Cybertrain::CLI::Build.app_name(".")
  assert_equal "", Cybertrain::CLI::Build.app_name("no_such_dir")
end

test "build embeds the views, builds, then restores the empty table" do
  assert_equal ["spin run gen -- --embed-views", "spin build blog", "spin run gen"], Cybertrain::CLI::Build.commands("blog")
  assert_equal ["spin run gen", "spin run blog -- migrate", "spin run gen"], Cybertrain::CLI::Build.migration_commands("blog")
end

test "assemble copies the binary and public/ into dist/ and keeps storage/ and tmp/" do
  Dir.mkdir("dist")
  Dir.mkdir("dist/storage")
  File.write("dist/storage/production.sqlite3", "keep me")
  Dir.mkdir("dist/public")
  File.write("dist/public/stale.css", "old")
  written = Cybertrain::CLI::Build.assemble(".", "blog")
  assert_equal ["dist/blog", "dist/public/", "dist/storage/", "dist/tmp/"], written
  assert_equal "#!/bin/sh\necho built\n", File.read("dist/blog")
  assert File.executable?("dist/blog")
  assert_equal "body{}\n", File.read("dist/public/style.css")
  assert_equal "logo\n", File.read("dist/public/img/logo.txt")
  refute File.exist?("dist/public/stale.css")
  assert_equal "keep me", File.read("dist/storage/production.sqlite3")
  assert File.directory?("dist/tmp")
end

test "assemble fails clearly when the binary is missing" do
  File.delete("build/bin/blog")
  error = assert_raises("Cybertrain::CLI::InvalidArgument") { Cybertrain::CLI::Build.assemble(".", "blog") }
  assert_equal "build/bin/blog is missing: `spin build blog` did not produce it", error.message
end

test "the CLI needs spin.toml for migration, db, server and build" do
  Dir.mkdir("elsewhere")
  Dir.chdir("elsewhere")
  assert_equal 1, Cybertrain::CLI.run(["migration"])
  assert_equal 1, Cybertrain::CLI.run(["db", "status"])
  assert_equal 1, Cybertrain::CLI.run(["server"])
  assert_equal 1, Cybertrain::CLI.run(["build"])
  Dir.chdir("..")
end

Cybertrain::Test.run!
```

Check `InvalidArgument` is defined in `cybertrain/cli/scaffold.rb` or `templates.rb` (it is rescued in `cli.rb:44`); `require "cybertrain/cli"` loads it. If `File.chmod` / `File.executable?` are not in Spinel's subset (this test is compiled too), replace the executable assertion with `assert_equal File.stat("build/bin/blog").mode, File.stat("dist/blog").mode` or, failing that, drop it and rely on `cp` preserving the mode (see implementation).

- [ ] **Step 2: Run to verify failure**

Run: `ruby -I. test/cli_build.rb`
Expected: `NameError: uninitialized constant Cybertrain::CLI::Build`.

- [ ] **Step 3: Implement `Build`**

`cybertrain/cli/build.rb`:

```ruby
# `cybertrain build`: dist/ = the app binary with app/views embedded, plus
# public/. Also the command lists `cybertrain migration` runs. Plain Ruby:
# runs under CRuby (the gem) and compiles under Spinel (spin install).
module Cybertrain
  module CLI
    module Build
      # The [package] name in root/spin.toml, or "" when there is none.
      def self.app_name(root)
        path = "#{root}/spin.toml"
        return "" unless File.exist?(path)

        in_package = false
        File.read(path).each_line do |line|
          text = line.strip
          in_package = text == "[package]" if text.start_with?("[")
          next unless in_package && text.start_with?("name")

          match = text.match(/\Aname\s*=\s*"([^"]*)"/)
          return match[1] unless match.nil?
        end
        ""
      end

      def self.commands(name)
        ["spin run gen -- --embed-views", "spin build #{name}", "spin run gen"]
      end

      def self.migration_commands(name)
        ["spin run gen", "spin run #{name} -- migrate", "spin run gen"]
      end

      # Runs the build in root and assembles dist/. Returns the exit code.
      def self.run(root, name)
        steps = commands(name)
        ok = run_in(root, steps[0]) && run_in(root, steps[1])
        # Always put gen/views.rb back to the empty table, even after a failure.
        restored = run_in(root, steps[2])
        return 1 unless ok && restored

        written = assemble(root, name)
        puts ""
        puts "dist/#{name}       (production by default)"
        puts "dist/public/"
        puts "run:  cd dist && ./#{name} migrate && ./#{name}"
        written.size > 0 ? 0 : 1
      end

      def self.run_in(root, command)
        puts "run    #{command}"
        system("cd #{shell_quote(root)} && #{command}")
      end

      # Copies build/bin/<name> and public/ into dist/; storage/ and tmp/ are
      # created when missing and never emptied (a database and the secret
      # key can live there).
      def self.assemble(root, name)
        binary = "#{root}/build/bin/#{name}"
        raise InvalidArgument, "build/bin/#{name} is missing: `spin build #{name}` did not produce it" unless File.exist?(binary)

        Templates.mkdir_p("#{root}/dist")
        copy_command = "cp #{shell_quote(binary)} #{shell_quote("#{root}/dist/#{name}")}"
        raise InvalidArgument, "could not copy #{binary} to dist/" unless system(copy_command)

        rm_tree("#{root}/dist/public")
        if File.directory?("#{root}/public")
          public_command = "cp -R #{shell_quote("#{root}/public")} #{shell_quote("#{root}/dist/public")}"
          raise InvalidArgument, "could not copy public/ to dist/" unless system(public_command)
        else
          Dir.mkdir("#{root}/dist/public")
        end
        Templates.mkdir_p("#{root}/dist/storage")
        Templates.mkdir_p("#{root}/dist/tmp")
        ["dist/#{name}", "dist/public/", "dist/storage/", "dist/tmp/"]
      end

      def self.rm_tree(path)
        return nil unless File.exist?(path)

        if File.directory?(path)
          Dir.children(path).each { |child| rm_tree("#{path}/#{child}") }
          Dir.rmdir(path)
        else
          File.delete(path)
        end
        nil
      end

      def self.shell_quote(text)
        "'#{text.gsub("'", "'\\\\''")}'"
      end
    end
  end
end
```

`cp` keeps the executable bit; `cp -R src dst` where `dst` does not exist copies the tree to `dst` on both macOS and GNU (that is why `rm_tree` runs first). `File.symlink?` is not handled: `public/` is expected to be plain files.

`cybertrain/cli.rb`: `require "cybertrain/cli/build"`; extend `USAGE` with

```
        cybertrain migration
            Generate, apply pending migrations, generate again
            (spin run gen; spin run NAME -- migrate; spin run gen).
        cybertrain db COMMAND...
            Any database command: status, rollback [N], schema:dump, create.
        cybertrain server
            Start the development server (spin run NAME).
        cybertrain build
            Build NAME with app/views embedded and assemble dist/
            (the binary, public/, storage/, tmp/).
```

and the dispatch:

```ruby
      when "migration" then run_in_app { |name| run_all(Build.migration_commands(name)) }
      when "db" then run_in_app { |name| run_all(["spin run #{name} -- db #{argv[1, argv.size - 1].join(" ")}"]) }
      when "server" then run_in_app { |name| run_all(["spin run #{name}"]) }
      when "build" then run_in_app { |name| Build.run(".", name) }
```

with

```ruby
    # Commands that need the app: its name comes from ./spin.toml.
    def self.run_in_app
      name = Build.app_name(".")
      if name == ""
        puts "error: no spin.toml with a [package] name here; run this inside a cybertrain application"
        return 1
      end
      yield name
    end

    def self.run_all(commands)
      commands.each do |command|
        puts "run    #{command}"
        return 1 unless system(command)
      end
      0
    end
```

`yield` inside `run_in_app` with a block that closes over `argv`: fine in CRuby; under Spinel a `yield` to a literal block is the supported form (not a stored block). `exec` is not used: `system` then returning keeps Ctrl-C handling identical in both runtimes (the child gets the signal; the CLI returns its status). `db` arguments must be shell-safe: join with `Build.shell_quote` per argument instead of a plain join (`argv[1, ...].map { |a| Build.shell_quote(a) }.join(" ")`).

`cybertrain.gemspec`: add `"cybertrain/cli/build.rb"` to `spec.files`. Repo `.gitignore`: add `dist/` under the spin outputs.

- [ ] **Step 4: Run the tests and regenerate the USAGE snapshot**

Run: `ruby -I. test/cli_build.rb` → `5 tests ... 0 failures`. Then `spin test --regen test/cli_build.rb test/cli_new.rb && spin test test/cli_build.rb test/cli_new.rb`.
Expected: pass; `git diff test/cli_new.rb.expected` shows only the added usage lines.

- [ ] **Step 5: Smoke the four commands on the scratch app from Task 5**

```bash
cd /private/tmp/claude-501/-Users-saeki-work-cybertrain/3c08a7ff-5489-489a-ba5a-664c2c4952c3/scratchpad/smoke
CT="ruby -I/Users/saeki/work/cybertrain /Users/saeki/work/cybertrain/bin/cybertrain.rb"
$CT g scaffold article title:string body:text
$CT migration
$CT db status
$CT build
ls -la dist dist/public
git status --short gen/   # nothing: views.rb is back to the empty table
cd dist && CYBERTRAIN_SECRET_KEY_BASE=$(openssl rand -hex 32) ./smoke migrate && (CYBERTRAIN_SECRET_KEY_BASE=$(openssl rand -hex 32) PORT=3456 ./smoke & sleep 1; curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:3456/articles; curl -s http://127.0.0.1:3456/articles | head -5; kill %1)
```

(The checks: `migration` exits 0, `db status` lists the migration, `build` prints the summary, `dist/smoke` runs in production by default — the boot banner says `production environment` — and `/articles` answers 200 with the embedded index view.) Also run `$CT server` for a few seconds and confirm the dev banner still says `development environment` and `Watching ...`, then Ctrl-C / kill it.

- [ ] **Step 6: Commit**

```bash
git add cybertrain/cli.rb cybertrain/cli/build.rb cybertrain.gemspec .gitignore test/cli_build.rb test/cli_build.rb.expected test/cli_new.rb.expected
git commit -m "CLI: migration, db, server and build (dist/ with embedded views)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Convert `examples/blog` and run it end to end

**Files:**
- Create: `examples/blog/bin/blog.rb`; Delete: `examples/blog/bin/server.rb`, `examples/blog/bin/db.rb`
- Modify: `examples/blog/README.md`, `examples/blog/.gitignore` (add `/dist/`), `examples/blog/test/support/blog_test.rb` (comment at lines 5 and 27-32; boot with `views:` untouched — test env reads disk)
- Modify: `test/db_integration.rb` if it references `bin/db.rb` in a comment (grep; comments only)

**Interfaces:**
- Consumes: everything above. No new interfaces.

- [ ] **Step 1: Write `bin/blog.rb` and remove the old entries**

`examples/blog/bin/blog.rb` — exactly `Templates.bin_app("blog")`'s output (copy the heredoc from Task 5). `git rm examples/blog/bin/server.rb examples/blog/bin/db.rb`.

- [ ] **Step 2: Update the README and comments**

`examples/blog/README.md`: replace the second code block with

```sh
cybertrain migration   # spin run gen; spin run blog -- migrate; spin run gen
cybertrain server      # http://127.0.0.1:3000 (PORT=4000 to change it)
cybertrain build       # dist/blog (views embedded) + dist/public/
spin test              # test/articles.rb, test/comments.rb against storage/test.sqlite3
```

and the trailing paragraph: keep the `spin run gen -- --check` sentence; add "A production binary (`cybertrain build`, or `CYBERTRAIN_ENV=production`) renders only the views embedded at build time."

`examples/blog/test/support/blog_test.rb`: line 5 "The app is built the way bin/blog.rb builds it" — the `Application.new` there stays without `views:` (test env reads `app/views/`).

- [ ] **Step 3: Run the example app's own tests and the end-to-end flow**

```bash
cd examples/blog
spin run gen -- --check          # exit 0: gen/views.rb (empty) is committed
spin test                        # articles + comments pass
ruby -I../.. ../../bin/cybertrain.rb build
ls dist
cd dist && CYBERTRAIN_SECRET_KEY_BASE=$(openssl rand -hex 32) ./blog migrate
CYBERTRAIN_SECRET_KEY_BASE=$(openssl rand -hex 32) PORT=3457 ./blog &
sleep 1
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:3457/      # 200
curl -s http://127.0.0.1:3457/ | grep -c "Articles"                     # >= 1
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:3457/style.css   # 200: dist/public served
kill %1
cd .. && git status --short      # only the intended files; no gen/views.rb change, no dist/ (ignored)
```

Then the error-location check: temporarily edit `app/views/articles/index.html.erb` to call `<%= no_such_helper %>` on line 3, rebuild with `cybertrain build`, start `dist/blog` in production, request `/`, and confirm the log line names `articles/index.html.erb:3`. Revert the edit and rebuild.

- [ ] **Step 4: Commit**

```bash
git add -A examples/blog
git commit -m "examples/blog: bin/blog.rb as the single entry; README with the cybertrain commands

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Docs and CI

**Files:**
- Modify: `README.md` (Installing the CLI: command list; Walkthrough "Create the application", "Generate, migrate, run"; the "How it works" paragraph that says views live outside the binary; the test-snapshot paragraph is unchanged)
- Modify: `docs/deploy.md` (2-3, 2-4, 2-6, the systemd unit `ExecStart`/`WorkingDirectory`, deploy.sh, the troubleshooting table)
- Modify: `docs/design.md` section 13 (append a dated bullet)
- Modify: `.github/workflows/ci.yml` (gem e2e step)
- Modify: `cybertrain/cli.rb` `USAGE`? — no, done in Task 6.

- [ ] **Step 1: README**

- "Installing the CLI": list the six commands: `new`, `generate scaffold`, `migration`, `db`, `server`, `build`; one sentence each, matching `USAGE`.
- "Create the application": after `cd blog`, replace `spin build` with `cybertrain server            # works right away` and the tree listing's `bin/server.rb bin/gen.rb bin/db.rb` with `bin/blog.rb bin/gen.rb`, `gen/` gains `views.rb` in prose.
- "Generate, migrate, run": replace the block with

```sh
cybertrain migration     # spin run gen; spin run blog -- migrate; spin run gen
cybertrain server        # http://127.0.0.1:3000; rebuilds on Ruby edits, views reload without a rebuild
```

- Add a subsection "Build for deployment" after the walkthrough's last step:

```sh
cybertrain build
```

"writes `dist/`: `dist/blog`, the app compiled with every `app/views/` template embedded (rendered from memory, error messages still say `articles/show.html.erb:12`), `dist/public/`, and empty `dist/storage/` and `dist/tmp/`. Copy `dist/` to a machine with the same OS and CPU (the binary links the system SQLite) and run `./blog migrate && ./blog`; a built binary is production by default (`CYBERTRAIN_ENV` overrides). Set `CYBERTRAIN_SECRET_KEY_BASE`. Static files can also be served by the reverse proxy from `dist/public/` — see docs/deploy.md."

- "How it works" (grep `read at run time` / `outside the binary`): state the two modes: development reads `app/views/` from disk and re-parses on change; `cybertrain build` runs `spin run gen -- --embed-views`, which writes the templates into `gen/views.rb` for that one `spin build`, then restores the empty table that is committed.
- Add one line under "Differences from Rails" or the walkthrough: apps created before this change replace `bin/server.rb` + `bin/db.rb` with `bin/<name>.rb` (copy it from a fresh `cybertrain new`).

- [ ] **Step 2: docs/deploy.md**

- 2-3: replace the three-command block with `cybertrain migration`.
- 2-4: `cybertrain server`.
- 2-6: 

```sh
cybertrain build
export CYBERTRAIN_SECRET_KEY_BASE="$(openssl rand -hex 32)"
export CYBERTRAIN_DATABASE="$PWD/storage/rehearsal.sqlite3"
dist/notes migrate
dist/notes
```

(no `CYBERTRAIN_ENV` export: the built binary is production by default; say so.)
- Architecture diagram at the top: `dist/notes (127.0.0.1:3000, systemd)`, `public/ は dist/public/`, remove the "app/views/ を実行時に読む" line and the "バイナリ単体では動きません" sentence; the reason to build on the server is now only the OS/libc match.
- systemd unit: `WorkingDirectory=/srv/notes/current/dist`, `ExecStart=/srv/notes/current/dist/notes`; the note about `WorkingDirectory` now says `public/` and `storage/` are resolved from it (views no longer). Caddy `root * /srv/notes/current/dist/public`.
- deploy.sh: `spin run gen -- --check` stays; replace `spin build server` + `spin run db -- migrate` with `cybertrain build` and `dist/notes migrate` (the env file must be sourced for the migrate: `set -a; . /etc/notes/notes.env; set +a` before it, if the script does not already).
- Troubleshooting: `status=203/EXEC` → `dist/notes がない`; the `Missing template` row becomes "ビルド時に app/views/ に無かったテンプレート。`cybertrain build` をやり直す".

- [ ] **Step 3: docs/design.md section 13**

Append:

```
- 2026-09-26: アプリの入口を `bin/<name>.rb`（`Cybertrain::Main`: server / migrate / db）に統合。`spin run gen` は `gen/views.rb` を常に書き、`--embed-views` で `app/views/` を文字列テーブルとして埋め込む。本番は埋め込みテーブルのみを描画し（`Template::Engine.embedded`）、空なら起動を拒否する。`cybertrain migration` / `server` / `build` を追加、`build` は `dist/`（バイナリ + public/）を組み立てる。設計: docs/superpowers/specs/2026-09-26-cli-build-embedded-views-design.md。クロスビルドと public/ の埋め込みはスコープ外。
```

- [ ] **Step 4: CI**

In `.github/workflows/ci.yml`, the gem e2e step's tail becomes:

```yaml
          cybertrain generate scaffold product name:string price:integer
          cybertrain migration
          cybertrain db status
          cybertrain build
          test -x dist/shop
          cd dist && CYBERTRAIN_SECRET_KEY_BASE=ci-secret-ci-secret-ci-secret-ci-secret ./shop migrate
          CYBERTRAIN_SECRET_KEY_BASE=ci-secret-ci-secret-ci-secret-ci-secret PORT=3999 ./shop > server.log 2>&1 &
          sleep 2
          curl -fsS http://127.0.0.1:3999/products > /dev/null
          curl -fsS http://127.0.0.1:3999/style.css > /dev/null
          grep -q "production environment" server.log
          kill %1
```

Check `Config#resolve_secret!` (config.rb) for the minimum secret length in production (`SECRET_LENGTH = 64` looks like a generated length, not a minimum); use `openssl rand -hex 32` in CI as deploy.md does if a minimum applies.

- [ ] **Step 5: Full suite and final review**

Run in the background: `spin test > /tmp/spin-test.log 2>&1` (over 180 s). Poll the log; expected last line: all programs pass. Then `cd examples/blog && spin test && spin run gen -- --check`. Then `gem build cybertrain.gemspec --output /tmp/ct.gem && gem install --local /tmp/ct.gem && cybertrain help` in a temp dir to see the new usage from the installed gem; `gem uninstall cybertrain` afterwards if it was not installed before.

- [ ] **Step 6: Commit**

```bash
git add README.md docs/deploy.md docs/design.md .github/workflows/ci.yml
git commit -m "Docs and CI for cybertrain migration/server/build and dist/

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-review

- **Spec coverage:** §3 entry (Task 4, 5, 7); §4.1 Engine (Task 1); §4.2 gen/views.rb, `--check` (Task 2); §4.3 boot selection + refusal (Task 3); §5 four commands + dist/ layout + storage/tmp kept + summary text (Task 6); §6 file list (Tasks 1-8, gemspec in Task 6, .gitignore in Tasks 5-7); §7 tests: template_embedded (1), gen_views (2), main (4), cli_build (6), cli_new (5), application/dev_application (3), e2e (7, 8). The CI "Generated code is fresh" step is unchanged and now also covers the empty `gen/views.rb`.
- **Placeholders:** none; the two "check X first" notes name the file and the fallback.
- **Type consistency:** `Engine.embedded(sources)` / `Views.configure_embedded(sources)` (1) used in 3; `Application.new(views:, name:)`, `run(argv)` (3) used in 4; `Main.run(name, argv, router:, url_resolver:, views:)` (4) used in 5 and 7; `Build.app_name / commands / migration_commands / assemble / run` (6) used within 6 and by CI (8); `ViewsEmitter.emit(root, embed)` (2) used by Runner (2).
