# Checks the guide translations (docs/guide/<lang>/) against the English
# sources (docs/guide/) for structure, in the manner of script/check-docs-i18n:
# prose is not compared, everything a translator must leave alone is. Standard
# library only (the gate is gem-free). The CLI is script/check-guide-i18n.

require "digest"
require_relative "outline"
require_relative "source"

module GuidePages
  module I18nCheck
    TRANSLATED_LANGS = %w[ja zh ru fr].freeze
    EQUAL_KEYS = %w[path og_image nav].freeze

    module_function

    # Differences between the translations and the English, each
    # "docs/guide/ja/x.md: <difference>"; empty when they agree.
    def run(root, langs: TRANSLATED_LANGS)
      all = Source.all(root)
      english = all["en"] || {}
      problems = []
      langs.each do |lang|
        translated = all[lang] || {}
        english.each do |name, en|
          tr = translated[name]
          if tr
            problems.concat(compare(en, tr, root))
          else
            problems << "docs/guide/#{lang}/#{name}.md: missing translation of #{en.file}"
          end
        end
        (translated.keys - english.keys).sort.each do |name|
          problems << "#{translated[name].file}: no English source docs/guide/#{name}.md"
        end
      end
      problems
    rescue Error => e
      [e.message]
    end

    # Writes the SHA-256 of the English source into the translation's front
    # matter (as its first key when absent); returns the hex digest.
    def update_sha(file, root:)
      tr = Source.load(file, root: root)
      raise Error, "#{tr.file}: not a translation" if tr.lang == "en"

      sha = english_sha(tr.name, root)
      path = File.join(File.expand_path(root), tr.file)
      text = File.binread(path).force_encoding("UTF-8")
      raise Error, "#{tr.file}: no front matter to write source_sha256 into" unless text.match?(/\A﻿?---\r?\n/)

      front_end = text.index(/^---\r?$/, text.index("\n") + 1)
      head = text[0...front_end]
      rest = text[front_end..]
      line = "source_sha256: #{sha}"
      head = if head.match?(/^source_sha256:/)
               head.sub(/^source_sha256:[^\r\n]*/) { line }
             else
               head.sub(/\A(﻿?---(\r?\n))/) { "#{$1}#{line}#{$2}" }
             end
      File.binwrite(path, head + rest)
      sha
    end

    def english_sha(name, root)
      en = File.join(File.expand_path(root), "docs/guide/#{name}.md")
      raise Error, "no English source docs/guide/#{name}.md" unless File.file?(en)

      Digest::SHA256.file(en).hexdigest
    end

    def compare(en, tr, root)
      problems = check_sha(en, tr, root) + check_front(en, tr)
      begin
        a = Outline.parse(en.body)
        b = Outline.parse(tr.body)
      rescue Error => e
        return problems << "#{tr.file}: #{e.message}"
      end
      problems + check_outline(a, b).map { |p| "#{tr.file}: #{p}" }
    end

    def check_sha(en, tr, root)
      sha = tr.front["source_sha256"].to_s
      if sha.empty?
        return ["#{tr.file}: source_sha256 is missing (check the translation, then run script/check-guide-i18n --update-sha #{tr.file})"]
      end
      return [] if sha == english_sha(en.name, root)

      ["#{tr.file}: English changed after this translation was made; see `git log -p #{en.file}`"]
    end

    def check_front(en, tr)
      keys = ->(s) { s.front.keys - ["source_sha256"] }
      problems = []
      if keys.(en).sort != keys.(tr).sort
        extra = keys.(tr) - keys.(en)
        lacking = keys.(en) - keys.(tr)
        detail = []
        detail << "missing #{lacking.sort.join(", ")}" unless lacking.empty?
        detail << "extra #{extra.sort.join(", ")}" unless extra.empty?
        problems << "#{tr.file}: front matter keys differ (#{detail.join("; ")})"
      end
      EQUAL_KEYS.each do |key|
        next unless en.front.key?(key) && tr.front.key?(key)

        problems << "#{tr.file}: front matter #{key} must equal the English (#{en.front[key].inspect}), found #{tr.front[key].inspect}" if en.front[key] != tr.front[key]
      end
      problems
    end

    def check_outline(a, b)
      heads = ->(o) { o.sections.drop(1).map(&:level) }
      if heads.(a) != heads.(b)
        return ["headings differ in number or level: English #{heads.(a).join(",")}, translation #{heads.(b).join(",")}"]
      end

      problems = []
      steps = ->(o) { o.sections.filter_map { |s| s.step && [s.step.num, s.step.id] } }
      problems << "step comments differ: English #{steps.(a).inspect}, translation #{steps.(b).inspect}" if steps.(a) != steps.(b)
      markers = ->(o) { o.sections.flat_map(&:markers) }
      problems << "convention markers differ: English #{markers.(a).inspect}, translation #{markers.(b).inspect}" if markers.(a) != markers.(b)
      a.sections.zip(b.sections).each do |sa, sb|
        where = sa.text ? "section #{sa.text.inspect}" : "before the first heading"
        problems.concat(compare_codes(where, sa.codes, sb.codes))
        problems << "#{where}: English has #{sa.table_rows} table rows, translation has #{sb.table_rows}" if sa.table_rows != sb.table_rows
      end
      problems << "link targets differ: English #{a.links.inspect}, translation #{b.links.inspect}" if a.links != b.links
      problems
    end

    def compare_codes(where, a, b)
      return ["#{where}: English has #{a.size} code blocks, translation has #{b.size}"] if a.size != b.size

      a.zip(b).each_with_index.flat_map do |(ca, cb), i|
        at = "#{where}, code block #{i + 1}"
        if ca.lang != cb.lang
          ["#{at}: language #{ca.lang.inspect} in English, #{cb.lang.inspect} in translation"]
        elsif ca.place != cb.place
          ["#{at}: place #{ca.place.inspect} in English, #{cb.place.inspect} in translation"]
        elsif (x = normalize_code(ca.text).lines) != (y = normalize_code(cb.text).lines)
          line = (0...[x.size, y.size].max).find { |j| x[j] != y[j] }
          ["#{at} (#{ca.lang}) differs at line #{line + 1}: #{(x[line] || "(end)").chomp.inspect} in English, #{(y[line] || "(end)").chomp.inspect} in translation"]
        else
          []
        end
      end
    end

    # A code block reduced to what must not differ between languages (the
    # rules of script/check-docs-i18n).
    def normalize_code(text)
      text.each_line.filter_map do |line|
        line = line.chomp
        next if line =~ /\A\s*#(?!!)/

        line.sub(/\s+#\s.*\z/, "").rstrip
      end.join("\n")
    end
  end
end
