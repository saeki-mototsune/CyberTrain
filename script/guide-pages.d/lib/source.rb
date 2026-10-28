# A guide Markdown source (docs/guide/**/*.md): file name, language, YAML front
# matter and body. Standard library only.

require "pathname"
require "yaml"
require_relative "outline"

module GuidePages
  LANGS = %w[en ja zh ru fr].freeze
  FRONT_KEYS = %w[path title description og_title og_description og_image crumb meta toc_title nav source_sha256].freeze

  class Source
    attr_reader :name, :lang, :front, :body, :file

    # file may be absolute or relative to root; Source#file is relative to root.
    def self.load(file, root:)
      abs = Pathname.new(file).expand_path(root)
      rel = abs.relative_path_from(Pathname.new(root).expand_path).to_s
      new(rel, File.binread(abs).force_encoding("UTF-8"))
    end

    # {lang => {name => Source}} for docs/guide/*.md and docs/guide/<lang>/*.md.
    def self.all(root)
      dirs = { "en" => "docs/guide" }
      (LANGS - ["en"]).each { |l| dirs[l] = "docs/guide/#{l}" }
      dirs.each_with_object({}) do |(lang, dir), out|
        files = Dir.glob(File.join(root, dir, "*.md")).sort.reject { |f| File.basename(f) == "README.md" }
        next if files.empty?

        out[lang] = files.to_h { |f| s = load(f, root: root); [s.name, s] }
      end
    end

    def initialize(file, text)
      @file = file
      @name = File.basename(file, ".md")
      @lang = lang_of(file)
      text = text.delete_prefix("﻿").gsub("\r\n", "\n")
      @front, @body = split_front(text)
    end

    private

    def lang_of(file)
      parts = file.split("/")
      return "en" if parts.size == 3 && parts[0, 2] == %w[docs guide]
      return parts[2] if parts.size == 4 && parts[0, 2] == %w[docs guide] && LANGS.include?(parts[2]) && parts[2] != "en"

      raise Error, "#{file}: not under docs/guide/ or docs/guide/<lang>/"
    end

    def split_front(text)
      return [{}, text] unless text.start_with?("---\n")

      lines = text.lines
      close = (1...lines.size).find { |i| lines[i].chomp == "---" }
      raise Error, "#{@file}: front matter is not closed with ---" unless close

      data = begin
        YAML.safe_load(lines[1...close].join) || {}
      rescue Psych::Exception => e
        raise Error, "#{@file}: front matter is not valid YAML (#{e.message})"
      end
      raise Error, "#{@file}: front matter is not a mapping" unless data.is_a?(Hash)

      unknown = data.keys.map(&:to_s) - FRONT_KEYS
      raise Error, "#{@file}: unknown front matter key #{unknown.first.inspect}" unless unknown.empty?

      [data.transform_keys(&:to_s), lines[(close + 1)..].join]
    end
  end
end
