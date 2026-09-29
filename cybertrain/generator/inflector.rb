module Cybertrain
  # ActiveSupport::Inflector's camelize, underscore, pluralize and
  # singularize with Rails' default English inflections
  # (active_support/inflections.rb), checked rule for rule against
  # ActiveSupport 8.1.4.
  #
  # Rails keeps its rules in tables that inflect.plural/singular/irregular/
  # uncountable prepend to and tries them newest first, the first match
  # winning. Spinel cannot keep Regexp objects in a collection, so each table
  # is written out below as literal regexes in that application order: the
  # expansion of every inflect.irregular (newest first), then the plain rules
  # (newest first). An uncountable word -- or a compound ending in one after a
  # word boundary, so "my money" but not "blog_fish" -- and "" come back
  # unchanged.
  #
  # Application-defined inflections (config/initializers/inflections.rb:
  # inflect.irregular, inflect.uncountable, inflect.acronym, ...) and locales
  # other than English are not supported; camelize and underscore behave as
  # Rails' do with no acronyms defined.
  module Inflector
    # "posts_controller" -> "PostsController"; "admin/posts" -> "Admin::Posts".
    # As Rails: the leading lowercase/digit run is capitalized, and each "_"
    # or "/" is dropped and the alphanumeric run after it capitalized (the
    # rest of that run downcased: "foo_BAR" -> "FooBar"); "/" becomes "::".
    def self.camelize(term)
      out = +""
      n = term.size
      i = 0
      while i < n && lower_or_digit?(term[i])
        out << (i == 0 ? term[i].upcase : term[i])
        i += 1
      end
      while i < n
        ch = term[i]
        i += 1
        if ch == "_" || ch == "/"
          out << "::" if ch == "/"
          start = i
          while i < n && alnum?(term[i])
            out << (i == start ? term[i].upcase : term[i].downcase)
            i += 1
          end
        else
          out << ch
        end
      end
      out
    end

    # "PostsController" -> "posts_controller"; "HTMLTidyGenerator" ->
    # "html_tidy_generator"; "Admin::Posts" -> "admin/posts". As Rails: "_"
    # goes before an uppercase letter that follows a lowercase letter or digit,
    # or that follows an uppercase letter and precedes a lowercase one; "-"
    # becomes "_" and the result is downcased.
    def self.underscore(camel_cased_word)
      return camel_cased_word.dup unless camel_cased_word.match?(/[A-Z-]|::/)

      # Two steps: in a threaded program a collection inside `chars` freed the
      # unnamed gsub result it was splitting ("Post" came back as "").
      path = camel_cased_word.gsub("::", "/")
      chars = path.chars
      out = +""
      chars.each_with_index do |ch, i|
        if i > 0 && upper?(ch)
          prev = chars[i - 1]
          nxt = i + 1 < chars.size ? chars[i + 1] : ""
          out << "_" if lower_or_digit?(prev) || (upper?(prev) && lower?(nxt))
        end
        out << (ch == "-" ? "_" : ch)
      end
      out.downcase
    end

    # "post" -> "posts", "person" -> "people", "sales_person" ->
    # "sales_people", "Category" -> "Categories", "sheep" -> "sheep".
    def self.pluralize(word)
      return word.dup if word.empty? || uncountable?(word)

      # inflect.irregular, newest first: zombie, move, sex, child, man, person.
      return word.sub(/(z)ombies$/i, '\1ombies') if word.match?(/(z)ombies$/i)
      return word.sub(/(z)ombie$/i, '\1ombies') if word.match?(/(z)ombie$/i)
      return word.sub(/(m)oves$/i, '\1oves') if word.match?(/(m)oves$/i)
      return word.sub(/(m)ove$/i, '\1oves') if word.match?(/(m)ove$/i)
      return word.sub(/(s)exes$/i, '\1exes') if word.match?(/(s)exes$/i)
      return word.sub(/(s)ex$/i, '\1exes') if word.match?(/(s)ex$/i)
      return word.sub(/(c)hildren$/i, '\1hildren') if word.match?(/(c)hildren$/i)
      return word.sub(/(c)hild$/i, '\1hildren') if word.match?(/(c)hild$/i)
      return word.sub(/(m)en$/i, '\1en') if word.match?(/(m)en$/i)
      return word.sub(/(m)an$/i, '\1en') if word.match?(/(m)an$/i)
      return word.sub(/(p)eople$/i, '\1eople') if word.match?(/(p)eople$/i)
      return word.sub(/(p)erson$/i, '\1eople') if word.match?(/(p)erson$/i)
      # inflect.plural, newest first.
      return word.sub(/(quiz)$/i, '\1zes') if word.match?(/(quiz)$/i)
      return word.sub(/^(oxen)$/i, '\1') if word.match?(/^(oxen)$/i)
      return word.sub(/^(ox)$/i, '\1en') if word.match?(/^(ox)$/i)
      return word.sub(/^(m|l)ice$/i, '\1ice') if word.match?(/^(m|l)ice$/i)
      return word.sub(/^(m|l)ouse$/i, '\1ice') if word.match?(/^(m|l)ouse$/i)
      return word.sub(/(matr|vert|ind)(?:ix|ex)$/i, '\1ices') if word.match?(/(matr|vert|ind)(?:ix|ex)$/i)
      return word.sub(/(x|ch|ss|sh)$/i, '\1es') if word.match?(/(x|ch|ss|sh)$/i)
      return word.sub(/([^aeiouy]|qu)y$/i, '\1ies') if word.match?(/([^aeiouy]|qu)y$/i)
      return word.sub(/(hive)$/i, '\1s') if word.match?(/(hive)$/i)
      return word.sub(/(?:([^f])fe|([lr])f)$/i, '\1\2ves') if word.match?(/(?:([^f])fe|([lr])f)$/i)
      return word.sub(/sis$/i, "ses") if word.match?(/sis$/i)
      return word.sub(/([ti])a$/i, '\1a') if word.match?(/([ti])a$/i)
      return word.sub(/([ti])um$/i, '\1a') if word.match?(/([ti])um$/i)
      return word.sub(/(buffal|tomat)o$/i, '\1oes') if word.match?(/(buffal|tomat)o$/i)
      return word.sub(/(bu)s$/i, '\1ses') if word.match?(/(bu)s$/i)
      return word.sub(/(alias|status)$/i, '\1es') if word.match?(/(alias|status)$/i)
      return word.sub(/(octop|vir)i$/i, '\1i') if word.match?(/(octop|vir)i$/i)
      return word.sub(/(octop|vir)us$/i, '\1i') if word.match?(/(octop|vir)us$/i)
      return word.sub(/^(ax|test)is$/i, '\1es') if word.match?(/^(ax|test)is$/i)
      return word.sub(/s$/i, "s") if word.match?(/s$/i)

      word.sub(/$/, "s")
    end

    # "posts" -> "post", "people" -> "person", "sales_people" ->
    # "sales_person", "Categories" -> "Category", "news" -> "news".
    def self.singularize(word)
      return word.dup if word.empty? || uncountable?(word)

      # inflect.irregular, newest first: zombie, move, sex, child, man, person.
      return word.sub(/(z)ombies$/i, '\1ombie') if word.match?(/(z)ombies$/i)
      return word.sub(/(z)ombie$/i, '\1ombie') if word.match?(/(z)ombie$/i)
      return word.sub(/(m)oves$/i, '\1ove') if word.match?(/(m)oves$/i)
      return word.sub(/(m)ove$/i, '\1ove') if word.match?(/(m)ove$/i)
      return word.sub(/(s)exes$/i, '\1ex') if word.match?(/(s)exes$/i)
      return word.sub(/(s)ex$/i, '\1ex') if word.match?(/(s)ex$/i)
      return word.sub(/(c)hildren$/i, '\1hild') if word.match?(/(c)hildren$/i)
      return word.sub(/(c)hild$/i, '\1hild') if word.match?(/(c)hild$/i)
      return word.sub(/(m)en$/i, '\1an') if word.match?(/(m)en$/i)
      return word.sub(/(m)an$/i, '\1an') if word.match?(/(m)an$/i)
      return word.sub(/(p)eople$/i, '\1erson') if word.match?(/(p)eople$/i)
      return word.sub(/(p)erson$/i, '\1erson') if word.match?(/(p)erson$/i)
      # inflect.singular, newest first.
      return word.sub(/(database)s$/i, '\1') if word.match?(/(database)s$/i)
      return word.sub(/(quiz)zes$/i, '\1') if word.match?(/(quiz)zes$/i)
      return word.sub(/(matr)ices$/i, '\1ix') if word.match?(/(matr)ices$/i)
      return word.sub(/(vert|ind)ices$/i, '\1ex') if word.match?(/(vert|ind)ices$/i)
      return word.sub(/^(ox)en/i, '\1') if word.match?(/^(ox)en/i)
      return word.sub(/(alias|status)(es)?$/i, '\1') if word.match?(/(alias|status)(es)?$/i)
      return word.sub(/(octop|vir)(us|i)$/i, '\1us') if word.match?(/(octop|vir)(us|i)$/i)
      return word.sub(/^(a)x[ie]s$/i, '\1xis') if word.match?(/^(a)x[ie]s$/i)
      return word.sub(/(cris|test)(is|es)$/i, '\1is') if word.match?(/(cris|test)(is|es)$/i)
      return word.sub(/(shoe)s$/i, '\1') if word.match?(/(shoe)s$/i)
      return word.sub(/(o)es$/i, '\1') if word.match?(/(o)es$/i)
      return word.sub(/(bus)(es)?$/i, '\1') if word.match?(/(bus)(es)?$/i)
      return word.sub(/^(m|l)ice$/i, '\1ouse') if word.match?(/^(m|l)ice$/i)
      return word.sub(/(x|ch|ss|sh)es$/i, '\1') if word.match?(/(x|ch|ss|sh)es$/i)
      return word.sub(/(m)ovies$/i, '\1ovie') if word.match?(/(m)ovies$/i)
      return word.sub(/(s)eries$/i, '\1eries') if word.match?(/(s)eries$/i)
      return word.sub(/([^aeiouy]|qu)ies$/i, '\1y') if word.match?(/([^aeiouy]|qu)ies$/i)
      return word.sub(/([lr])ves$/i, '\1f') if word.match?(/([lr])ves$/i)
      return word.sub(/(tive)s$/i, '\1') if word.match?(/(tive)s$/i)
      return word.sub(/(hive)s$/i, '\1') if word.match?(/(hive)s$/i)
      return word.sub(/([^f])ves$/i, '\1fe') if word.match?(/([^f])ves$/i)
      return word.sub(/(^analy)(sis|ses)$/i, '\1sis') if word.match?(/(^analy)(sis|ses)$/i)
      if word.match?(/((a)naly|(b)a|(d)iagno|(p)arenthe|(p)rogno|(s)ynop|(t)he)(sis|ses)$/i)
        return word.sub(/((a)naly|(b)a|(d)iagno|(p)arenthe|(p)rogno|(s)ynop|(t)he)(sis|ses)$/i, '\1sis')
      end
      return word.sub(/([ti])a$/i, '\1um') if word.match?(/([ti])a$/i)
      return word.sub(/(n)ews$/i, '\1ews') if word.match?(/(n)ews$/i)
      return word.sub(/(ss)$/i, '\1') if word.match?(/(ss)$/i)
      return word.sub(/s$/i, "") if word.match?(/s$/i)

      word.dup
    end

    # inflect.uncountable: Rails matches /\b<word>\Z/i, so "my money" and
    # "Sheep" are uncountable but "blog_fish" ("_" is a word character) is not.
    def self.uncountable?(word)
      word.match?(/\b(?:equipment|information|rice|money|species|series|fish|sheep|jeans|police)\Z/i)
    end

    def self.upper?(ch)
      ch >= "A" && ch <= "Z"
    end

    def self.lower?(ch)
      ch >= "a" && ch <= "z"
    end

    def self.lower_or_digit?(ch)
      lower?(ch) || (ch >= "0" && ch <= "9")
    end

    def self.alnum?(ch)
      upper?(ch) || lower_or_digit?(ch)
    end
  end
end
