# Link rewriting for the generated guide pages (the spec's step 4). A link
# in a source, as written for GitHub, becomes:
#   other.md, other.md#a   the target source's page in the same language,
#                          relative to this page; the anchor must be one of
#                          the target's (English) heading ids
#   #a                     kept; the anchor must be on this page
#   site:path              a site page, relative to the language root (api/
#                          and assets/ exist once, at the site root), made
#                          relative to this page; the file must exist in the
#                          repository's site/ (api/ is not checked: YARD
#                          builds it), or, for tutorial.html and guide/*.html,
#                          be a generated page, whose anchor is checked too
#   any other relative     https://github.com/saeki-mototsune/CyberTrain/blob/main/<path>
#                          (tree/main/ for a directory), the fragment kept; the
#                          path must exist in the repository
#   absolute URLs, /paths  unchanged
# Relative paths resolve from docs/guide/, for translations too (their links
# equal the English ones). Problems are collected in #errors, one line each.

require "pathname"
require_relative "outline"
require_relative "source"

module GuidePages
  class Links
    GITHUB = "https://github.com/saeki-mototsune/CyberTrain/"
    GUIDE_DIR = "docs/guide"
    SITE_ROOT_DIRS = %w[api assets].freeze

    attr_reader :errors

    # The language root of the site: "" for English, "<lang>/" otherwise.
    def self.lang_root(lang) = lang == "en" ? "" : "#{lang}/"

    # The page a source becomes, relative to the site root.
    def self.out_path(source) = lang_root(source.lang) + (source.front["path"] || "guide/#{source.name}.html")

    # sources: {lang => {name => Source}} (Source.all); root: the repository.
    def initialize(sources:, root:)
      @sources = sources
      @root = root
      @errors = []
      @ids = {}
    end

    # The heading ids of the page made from source name, from the English:
    # the title's slug, step ids or slugs for "##", slugs for deeper headings.
    # An id used twice is an error.
    def ids_for(name)
      @ids[name] ||= begin
        en = @sources.fetch("en").fetch(name)
        outline = begin
          Outline.parse(en.body)
        rescue Error => e
          raise Error, "#{en.file}: #{e.message}"
        end
        ids = [Outline.slug(outline.title)] + outline.sections.drop(1).map do |s|
          s.level == 2 && s.step ? s.step.id : Outline.slug(s.text)
        end
        dup = ids.find { |id| ids.count(id) > 1 }
        raise Error, "#{en.file}: heading id ##{dup} is used twice" if dup

        ids
      end
    end

    def rewrite(href, from:)
      here = Links.out_path(from)
      path, fragment = href.split("#", 2)
      return site(path, fragment, from, here) if href.start_with?("site:")
      return href if href.empty? || href == "#" || href.match?(%r{\A(?:[a-z][a-z0-9+.-]*:|/)}i)

      if path.empty?
        check_anchor(href, fragment, from.name, from)
        return href
      end
      target = Pathname.new(GUIDE_DIR).join(path).cleanpath.to_s
      if File.dirname(target) == GUIDE_DIR && target.end_with?(".md") && File.basename(target) != "README.md"
        guide(href, target, fragment, from, here)
      else
        repo(href, target, fragment, from)
      end
    end

    private

    def guide(href, target, fragment, from, here)
      name = File.basename(target, ".md")
      en = @sources.fetch("en", {})[name]
      return error(from, href, "no source #{target}") unless en

      check_anchor(href, fragment, name, from) if fragment
      page = Links.lang_root(from.lang) + (en.front["path"] || "guide/#{name}.html")
      with_fragment(relative(page, here), fragment)
    end

    def repo(href, target, fragment, from)
      full = File.join(@root, target)
      if target.start_with?("../") || target == ".." || !File.exist?(full)
        return error(from, href, "#{target} is not in the repository")
      end

      kind = File.directory?(full) ? "tree" : "blob"
      with_fragment("#{GITHUB}#{kind}/main/#{target == "." ? "" : target}", fragment)
    end

    def site(path, fragment, from, here)
      href = with_fragment(path, fragment)
      rel = path.delete_prefix("site:")
      top = rel.split("/").first
      base = SITE_ROOT_DIRS.include?(top) ? "" : Links.lang_root(from.lang)
      if rel == "tutorial.html" || top == "guide"
        en = @sources.fetch("en", {}).each_value.find { |s| Links.out_path(s) == rel }
        return error(from, href, "#{base}#{rel} is not a generated page") unless en

        check_anchor(href, fragment, en.name, from) if fragment
      elsif top != "api" && !File.file?(File.join(@root, "site", base + rel))
        return error(from, href, "site/#{base}#{rel} does not exist")
      end
      with_fragment(relative(base + rel, here), fragment)
    end

    def check_anchor(href, fragment, name, from)
      return if ids_for(name).include?(fragment)

      error(from, href, "no anchor ##{fragment} on #{@sources.fetch("en").fetch(name).file}")
    end

    def relative(page, here)
      Pathname.new(page).relative_path_from(Pathname.new(File.dirname(here))).to_s
    end

    def with_fragment(url, fragment) = fragment ? "#{url}##{fragment}" : url

    def error(from, href, message)
      @errors << "#{from.file}: link #{href}: #{message}"
      href
    end
  end
end
