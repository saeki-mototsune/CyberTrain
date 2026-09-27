module Cybertrain
  # The handful of Rails inflections the generators, Schema and Migration
  # need. Singular/plural forms come from a small irregulars table plus
  # English suffix rules; a word in neither gets the rules ("box" -> "boxes",
  # and a singular already ending in "s" is left alone unless it is in
  # ES_WORDS).
  module Inflector
    IRREGULARS = {
      "person" => "people", "man" => "men", "woman" => "women",
      "child" => "children", "mouse" => "mice", "ox" => "oxen"
    }
    UNCOUNTABLE = %w[equipment information rice money species series fish sheep news jeans]
    # Singulars ending in "s" whose plural adds "es" (Rails' alias/status/bus rules).
    ES_WORDS = %w[status alias bus]

    # "posts_controller" -> "PostsController"; "admin/posts" -> "Admin::Posts".
    def self.camelize(str)
      out = +""
      upper = true
      str.each_char do |ch|
        if ch == "_"
          upper = true
        elsif ch == "/"
          out << "::"
          upper = true
        elsif upper
          out << ch.upcase
          upper = false
        else
          out << ch
        end
      end
      out
    end

    # "PostsController" -> "posts_controller"; "HTMLParser" -> "html_parser".
    def self.underscore(str)
      # Two steps: in a threaded program a collection inside `chars` freed the
      # unnamed gsub result it was splitting ("Post" came back as "").
      path = str.gsub("::", "/")
      chars = path.chars
      out = +""
      chars.each_with_index do |ch, i|
        if upper?(ch)
          prev = i > 0 ? chars[i - 1] : ""
          nxt = i + 1 < chars.size ? chars[i + 1] : ""
          if prev != "" && prev != "/" && (lower_or_digit?(prev) || (upper?(prev) && lower_or_digit?(nxt)))
            out << "_"
          end
          out << ch.downcase
        else
          out << ch
        end
      end
      out
    end

    # "posts" -> "post"; only the last "_" word is inflected ("blog_posts").
    def self.singularize(str)
      parts = split_last_word(str)
      parts[0] + singular_word(parts[1])
    end

    # "post" -> "posts"; only the last "_" word is inflected.
    def self.pluralize(str)
      parts = split_last_word(str)
      parts[0] + plural_word(parts[1])
    end

    def self.singular_word(word)
      return word if UNCOUNTABLE.include?(word)

      IRREGULARS.each { |singular, plural| return singular if word == plural }
      return word if IRREGULARS.key?(word)

      if word.end_with?("ies") && word.size > 3 && !vowel?(word[word.size - 4])
        word[0, word.size - 3] + "y"
      elsif ES_WORDS.include?(word[0, word.size - 2]) || word.end_with?("sses") ||
            word.end_with?("xes") || word.end_with?("ches") || word.end_with?("shes")
        word[0, word.size - 2]
      elsif word.end_with?("ss") || ES_WORDS.include?(word)
        word
      elsif word.end_with?("s")
        word[0, word.size - 1]
      else
        word
      end
    end

    def self.plural_word(word)
      return word if UNCOUNTABLE.include?(word)

      plural = IRREGULARS[word]
      return plural unless plural.nil?

      if word.end_with?("y") && word.size > 1 && !vowel?(word[word.size - 2])
        word[0, word.size - 1] + "ies"
      elsif ES_WORDS.include?(word) || word.end_with?("ss") || word.end_with?("x") ||
            word.end_with?("ch") || word.end_with?("sh")
        word + "es"
      elsif word.end_with?("s")
        word
      else
        word + "s"
      end
    end

    # "sales_people" -> ["sales_", "people"].
    def self.split_last_word(str)
      i = str.rindex("_")
      return ["", str] if i.nil?

      [str[0, i + 1], str[i + 1, str.size - i - 1]]
    end

    def self.vowel?(ch)
      ch == "a" || ch == "e" || ch == "i" || ch == "o" || ch == "u"
    end

    def self.upper?(ch)
      ch >= "A" && ch <= "Z"
    end

    def self.lower_or_digit?(ch)
      (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9")
    end
  end
end
