require "cybertrain/html"
require "cybertrain/model"

module Cybertrain
  # Turbo Stream elements (turbo-rails' `turbo_stream.replace` and the
  # rest), built in Ruby: what {Stream.broadcast_replace_to} and friends
  # send, and what an action can answer with for a
  # `text/vnd.turbo-stream.html` request.
  #
  #   Cybertrain::Turbo.replace(article, Cybertrain::Html.safe("<p>x</p>"))
  #   # => <turbo-stream action="replace" target="article_12"><template><p>x</p></template></turbo-stream>
  #
  # A target is a DOM id String, or a record, whose DOM id is its snake-cased
  # model name and id (`article_12`). The HTML is escaped unless it is a
  # {SafeString}.
  # @api public
  module Turbo
    # @return [SafeString]
    # @api public
    def self.replace(target, html) = Turbo.action("replace", target, html)

    # @return [SafeString]
    # @api public
    def self.update(target, html) = Turbo.action("update", target, html)

    # @return [SafeString]
    # @api public
    def self.append(target, html) = Turbo.action("append", target, html)

    # @return [SafeString]
    # @api public
    def self.prepend(target, html) = Turbo.action("prepend", target, html)

    # @return [SafeString]
    # @api public
    def self.before(target, html) = Turbo.action("before", target, html)

    # @return [SafeString]
    # @api public
    def self.after(target, html) = Turbo.action("after", target, html)

    # `<turbo-stream action="remove" target="...">`, no template.
    # @return [SafeString]
    # @api public
    def self.remove(target)
      id = Html.escape(Turbo.target_text(target))
      out = +"<turbo-stream action=\"remove\" target=\""
      out << id
      out << "\"></turbo-stream>"
      SafeString.of(out)
    end

    # `<turbo-stream action="refresh">`: the page reloads itself.
    # @return [SafeString]
    # @api public
    def self.refresh
      SafeString.of("<turbo-stream action=\"refresh\"></turbo-stream>")
    end

    def self.action(name, target, html)
      id = Html.escape(Turbo.target_text(target))
      content = Html.out(html)
      out = +"<turbo-stream action=\""
      out << name
      out << "\" target=\""
      out << id
      out << "\"><template>"
      out << content
      out << "</template></turbo-stream>"
      SafeString.of(out)
    end

    def self.target_text(target)
      case target
      when Cybertrain::Model then target_id(target)
      else target.to_s
      end
    end

    # A record's DOM id, "article_12" ("admin_user_3" for Admin::User): the
    # id `dom_id` prints in a template, so a broadcast finds the element the
    # page rendered.
    def self.target_id(record)
      Html.dom_id(record, "")
    end
    private_class_method :target_id
  end
end
