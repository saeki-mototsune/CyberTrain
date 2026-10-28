# Builds the guide pages (script/guide-pages): every source in docs/guide/
# and docs/guide/<lang>/, rendered (GuidePages::Render) into the shell of
# layout.html.erb, at its output path (spec "Output"):
#   tutorial.html, <lang>/tutorial.html          front matter path: tutorial.html
#   guide/<name>.html, <lang>/guide/<name>.html  the default (the only other path allowed)
# and, for the English pages, the old YARD URLs as redirects:
#   api/file.<name>.html                         -> the guide (not for index)
#   api/file.walkthrough.html                    -> tutorial.html, once tutorial.md exists
# Every problem in every source is collected; when there is any, nothing is
# written.
#
#   errors = GuidePages::Build.run(root: repo, out: "site")   # [] when written

require "erb"
require "fileutils"
require "pathname"
require_relative "source"
require_relative "outline"
require_relative "links"
require_relative "render"
require_relative "words"

module GuidePages
  module Build
    BASE = "https://saeki-mototsune.github.io/CyberTrain/"
    LAYOUT = File.expand_path("../layout.html.erb", __dir__)
    HREFLANG = { "en" => "en", "ja" => "ja", "zh" => "zh-Hans", "ru" => "ru", "fr" => "fr" }.freeze
    OG_LOCALE = { "en" => "en_US", "ja" => "ja_JP", "zh" => "zh_CN", "ru" => "ru_RU", "fr" => "fr_FR" }.freeze
    LANG_NAME = { "en" => "English", "ja" => "日本語", "zh" => "简体中文", "ru" => "Русский", "fr" => "Français" }.freeze
    NAVS = %w[tutorial guides].freeze
    REDIRECT = %(<!doctype html><meta charset="utf-8"><title>Moved</title><link rel="canonical" href="%<abs>s">) +
               %(<meta http-equiv="refresh" content="0; url=%<rel>s"><p>Moved to <a href="%<rel>s">%<rel>s</a>.</p>\n)

    module_function

    def run(root:, out:)
      root = File.expand_path(root)
      errors = []
      sources, bad = load(root, errors)
      links = Links.new(sources: sources, root: root)
      layout = ERB.new(File.read(LAYOUT, encoding: "UTF-8"), trim_mode: "-")
      files = {}
      sources.each_value do |by_name|
        by_name.each_value do |src|
          next if bad.include?(src.file)

          en_file = "docs/guide/#{src.name}.md"
          next if bad.include?(en_file)

          english = sources.fetch("en", {})[src.name]
          next errors << "#{src.file}: no English source #{en_file}" unless english

          path = Links.out_path(src)
          next errors << "#{src.file}: output #{path} is also written by another source" if files.key?(path)

          files[path] = page(src, english, links, layout)
        rescue Error => e
          errors << e.message
        end
      end
      errors.concat(links.errors)
      return errors.uniq unless errors.empty?

      files.merge!(redirects(sources.fetch("en", {})))
      files.each do |path, html|
        file = File.join(out, path)
        FileUtils.mkdir_p(File.dirname(file))
        File.write(file, html)
      end
      []
    end

    # Source.all, but a source that fails to load, has no single "# " title
    # or a path other than tutorial.html or guide/<name>.html is reported; bad
    # lists those files, which are not rendered (nor, for an English source,
    # its translations).
    def load(root, errors)
      bad = []
      sources = {}
      LANGS.each do |lang|
        dir = lang == "en" ? "docs/guide" : "docs/guide/#{lang}"
        Dir.glob(File.join(root, dir, "*.md")).sort.each do |f|
          next if File.basename(f) == "README.md"

          src = Source.load(f, root: root)
          (sources[lang] ||= {})[src.name] = src
          begin
            Outline.parse(src.body)
            check_path(src)
          rescue Error => e
            errors << "#{src.file}: #{e.message}"
            bad << src.file
          end
        rescue Error => e
          errors << e.message
          bad << File.join(dir, File.basename(f))
        end
      end
      [sources, bad]
    end

    def check_path(src)
      path = src.front["path"]
      allowed = ["tutorial.html", "guide/#{src.name}.html"]
      return if path.nil? || allowed.include?(path)

      raise Error, "path must be #{allowed.join(" or ")}, not #{path.inspect}"
    end

    def page(src, english, links, layout)
      links.ids_for(src.name) # an id used twice fails every page, linked to or not
      words = WORDS.fetch(src.lang)
      view = View.new(src, english, Render.page(src, english: english, links: links, words: words), words)
      view.meta = meta(src, links, words)
      layout.result(view.binding_for_layout)
    end

    def meta(src, links, words)
      rows = src.front["meta"] || []
      ok = rows.is_a?(Array) && rows.all? { |r| r.is_a?(Hash) && r.keys.map(&:to_s).sort == %w[term text] }
      raise Error, "#{src.file}: meta must be a list of {term, text}" unless ok

      rows.map do |r|
        r = r.transform_keys(&:to_s)
        [View.text(r["term"].to_s), Render.inline(r["text"].to_s, source: src, links: links, words: words)]
      end
    end

    def redirects(english)
      english.each_value.with_object({}) do |src, out|
        next if src.name == "index" || (src.name == "walkthrough" && english.key?("tutorial"))

        name = src.name == "tutorial" ? "walkthrough" : src.name
        target = Links.out_path(src)
        rel = "../#{target}"
        out["api/file.#{name}.html"] = format(REDIRECT, abs: BASE + target, rel: rel)
      end
    end

    # What layout.html.erb sees: the page, its words, and its place on the site.
    class View
      Lang = Struct.new(:hreflang, :url, :item)

      attr_accessor :meta
      attr_reader :page, :lang, :url, :langs, :up, :home, :title, :description,
                  :og_title, :og_description, :og_image, :crumbs, :toc_title, :toc_label

      # Front matter text: escaped, but entities kept as typed.
      def self.text(s)
        s.to_s.gsub(/&(?!(?:[A-Za-z][A-Za-z0-9]*|#\d+|#x\h+);)/, "&amp;")
         .gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;").gsub("\u00A0", "&nbsp;")
      end

      # Rendered HTML as one line of text, for <title> and attributes.
      def self.flat(html) = html.to_s.gsub(/<[^>]*>/, "").gsub('"', "&quot;").split.join(" ")

      def initialize(src, english, page, words)
        @page, @words, @lang = page, words, src.lang
        front = src.front
        @nav = front["nav"] || "guides"
        raise Error, "#{src.file}: nav must be one of #{NAVS.join(", ")}, not #{@nav.inspect}" unless NAVS.include?(@nav)

        path = Links.out_path(src)
        rel = Links.out_path(english) # the page's path in any language, from the language root
        @url = BASE + path
        @up = "../" * path.count("/")
        @home = "../" * rel.count("/")
        @langs = LANGS.map do |l|
          href = @up + Links.lang_root(l) + rel
          item = %(<li><a href="#{href}" hreflang="#{HREFLANG[l]}" lang="#{HREFLANG[l]}"#{' aria-current="true"' if l == @lang}>#{LANG_NAME[l]}</a></li>)
          Lang.new(HREFLANG[l], BASE + Links.lang_root(l) + rel, item)
        end
        @title = front.key?("title") ? View.text(front["title"]) : View.flat(page.h1)
        @description = front.key?("description") ? View.text(front["description"]) : View.flat(page.intro_html)
        @og_title = front.key?("og_title") ? View.text(front["og_title"]) : @title
        @og_description = front.key?("og_description") ? View.text(front["og_description"]) : @description
        @og_image = "#{BASE}assets/og/#{@lang}/#{front["og_image"] || "index.png"}"
        # After "CyberTrain": [text, href or nil]; guides sit under the Guides index.
        crumb = front.key?("crumb") ? View.text(front["crumb"]) : page.h1
        guides = w(:guides)
        @crumbs = if @nav == "tutorial" then [[crumb, nil]]
                  elsif src.name == "index" then [[guides, nil]]
                  else [[guides, "#{@home}guide/index.html"], [crumb, nil]]
                  end
        @toc_title = front.key?("toc_title") ? View.text(front["toc_title"]) : w(:contents)
        @toc_label = @nav == "tutorial" ? w(:steps_label) : @toc_title
      end

      def html_lang = HREFLANG.fetch(@lang)
      def og_locale = OG_LOCALE.fetch(@lang)
      def other_locales = LANGS.reject { |l| l == @lang }.map { |l| OG_LOCALE[l] }
      def w(key) = View.text(@words.fetch(key))
      def current(nav) = nav == @nav ? ' aria-current="page"' : ""
      def toc_num(num) = View.text(num).gsub("→", "&rarr;")
      def binding_for_layout = binding
    end
  end
end
