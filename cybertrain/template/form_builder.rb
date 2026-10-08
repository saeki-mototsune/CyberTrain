# Cybertrain::FormBuilder -- the `f` in `<%= form_with(model: post) do |f| %>`.
#
#   <%= f.label :title %>          <label for="post_title">Title</label>
#   <%= f.text_field :title %>     <input type="text" name="post[title]" id="post_title" value="...">
#   <%= f.submit %>                <input type="submit" name="commit" value="Create Post">
#
# Templates reach it through the interpreter's generic method call, which
# hands `f.xxx` to Helpers#call_object_method and from there to
# call_method(name_sym, args, kwargs): Spinel has no `send`, so the builder
# methods are a `case` table. Every method returns a SafeString.
require "cybertrain/html"
require "cybertrain/model"
require "cybertrain/generator/inflector"

module Cybertrain
  class FormBuilder
    ERROR_CLASS = "field_with_errors"

    # A template value as text. Every branch is statically a String (see
    # Interpreter#to_s_value): a literal, an interpolation, or to_s, which
    # every class in the program answers with a String (Html.escape). to_s
    # hands back a String or a SafeString's own String without copying it;
    # Spinel's interpolation always copies and does not call a
    # user-defined to_s.
    def self.value_text(v)
      case v
      when SafeString then v.to_s
      when String then v.to_s
      when nil then ""
      when Integer then "#{v}"
      when Float then "#{v}"
      when true then "true"
      when false then "false"
      when Symbol then "#{v}"
      when Time then "#{v}"
      else "#{v.to_s}"
      end
    end

    # A template value as HTML: a SafeString as is, anything else escaped
    # (the same rule as Helpers#to_html).
    def self.html_text(v)
      case v
      when SafeString then v.to_s
      else Html.escape(FormBuilder.value_text(v))
      end
    end

    # "published_at" -> "Published at", "author_id" -> "Author".
    # Intermediate results are bound to locals, never chained: in threaded
    # programs an unnamed temporary can be collected while the next call in
    # the chain still reads it (see Inflector.underscore).
    def self.humanize(name)
      base = name.end_with?("_id") ? name[0, name.length - 3] : name
      spaced = base.tr("_", " ")
      spaced.capitalize
    end

    # ` name="value"`, escaped. Tag builders append what this returns: a
    # method that appends to a String it was given (`buf << ...` on a
    # parameter) makes Spinel run the GC write barrier on the caller's
    # stack slot, which later crashes a minor collection. Where the name is
    # a literal, the builders write `buf << " name=\"" << Html.escape(v) <<
    # "\""` instead: the literals are static and Html.escape returns its
    # argument when nothing needs escaping, so that allocates nothing.
    def self.html_attr(name, value)
      " #{name}=\"#{Html.escape(value)}\"" # one String, sized up front
    end

    # model: a Cybertrain::Model, or nil for `form_with url: ...` (fields are
    # then named after the attribute alone).
    def initialize(model)
      @model = model
      @scope = model.nil? ? "" : Inflector.underscore(model.model_name)
    end

    def call_method(name_sym, args, kwargs)
      case name_sym
      when :label then label(args, kwargs)
      when :text_field then input_field("text", args, kwargs)
      when :email_field then input_field("email", args, kwargs)
      when :password_field then input_field("password", args, kwargs)
      when :number_field then input_field("number", args, kwargs)
      when :date_field then input_field("date", args, kwargs)
      when :hidden_field then input_field("hidden", args, kwargs)
      when :text_area then text_area(args, kwargs)
      when :check_box then check_box(args, kwargs)
      when :submit then submit(args, kwargs)
      else raise ArgumentError, "undefined method '#{name_sym}' for FormBuilder"
      end
    end

    private

    # Explicit text is escaped unless it is a SafeString (`raw('<i>T</i>')`).
    def label(args, kwargs)
      attr = attribute_name(args, "label", "")
      text = args.size > 1 ? FormBuilder.html_text(args[1]) : Html.escape(FormBuilder.humanize(attr))
      buf = +"<label"
      buf << " for=\"" << Html.escape(field_id(attr)) << "\""
      buf << option_attrs(kwargs, errors_on?(attribute_sym(args, attr)))
      buf << ">" << text << "</label>"
      SafeString.new(buf)
    end

    # nil values (and password fields) get no value attribute, as in Rails.
    def input_field(type, args, kwargs)
      attr = attribute_name(args, type, "_field")
      sym = attribute_sym(args, attr)
      buf = +"<input"
      buf << " type=\"" << Html.escape(type) << "\""
      buf << " name=\"" << Html.escape(field_name(attr)) << "\""
      buf << " id=\"" << Html.escape(field_id(attr)) << "\""
      value = read_value(sym)
      buf << " value=\"" << Html.escape(FormBuilder.value_text(value)) << "\"" unless value.nil? || type == "password"
      buf << option_attrs(kwargs, errors_on?(sym))
      buf << ">"
      SafeString.new(buf)
    end

    # The newline after the opening tag is Rails' too: browsers drop the
    # first newline of a textarea, so a value starting with one survives.
    def text_area(args, kwargs)
      attr = attribute_name(args, "text_area", "")
      sym = attribute_sym(args, attr)
      buf = +"<textarea"
      buf << " name=\"" << Html.escape(field_name(attr)) << "\""
      buf << " id=\"" << Html.escape(field_id(attr)) << "\""
      buf << option_attrs(kwargs, errors_on?(sym))
      buf << ">\n" << Html.escape(FormBuilder.value_text(read_value(sym))) << "</textarea>"
      SafeString.new(buf)
    end

    # The hidden "0" makes an unchecked box submit a value at all.
    def check_box(args, kwargs)
      attr = attribute_name(args, "check_box", "")
      sym = attribute_sym(args, attr)
      name = Html.escape(field_name(attr))
      buf = +"<input"
      buf << " type=\"hidden\""
      buf << " name=\"" << name << "\""
      buf << " value=\"0\""
      buf << "><input"
      buf << " type=\"checkbox\""
      buf << " name=\"" << name << "\""
      buf << " id=\"" << Html.escape(field_id(attr)) << "\""
      buf << " value=\"1\""
      buf << " checked=\"checked\"" if checked?(read_value(sym))
      buf << option_attrs(kwargs, errors_on?(sym))
      buf << ">"
      SafeString.new(buf)
    end

    def submit(args, kwargs)
      text = args.empty? ? default_submit_text : FormBuilder.value_text(args[0])
      buf = +"<input"
      buf << " type=\"submit\""
      buf << " name=\"commit\""
      buf << " value=\"" << Html.escape(text) << "\""
      buf << option_attrs(kwargs, false)
      buf << ">"
      SafeString.new(buf)
    end

    # "Create Post" / "Update Post", or "Save changes" without a model.
    def default_submit_text
      model = @model
      return "Save changes" if model.nil?

      human = FormBuilder.humanize(@scope)
      model.persisted? ? "Update #{human}" : "Create #{human}"
    end

    # The method name for the error is method + suffix ("text" + "_field"),
    # joined only when it is raised.
    def attribute_name(args, method, suffix)
      raise ArgumentError, "wrong number of arguments for '#{method}#{suffix}'" if args.empty?

      FormBuilder.value_text(args[0])
    end

    # The attribute as a Symbol: `f.text_field :title` passes one already.
    # String#to_sym is a linear search of the program's symbol table in
    # Spinel 2026.09.12, so it is only the fallback for `f.text_field "title"`.
    def attribute_sym(args, attr)
      first = args[0]
      case first
      when Symbol then first
      else attr.to_sym
      end
    end

    def field_name(attr)
      @scope.empty? ? attr : "#{@scope}[#{attr}]"
    end

    def field_id(attr)
      @scope.empty? ? attr : "#{@scope}_#{attr}"
    end

    def read_value(sym)
      model = @model
      return nil if model.nil?

      model.read_attribute(sym)
    end

    def errors_on?(sym)
      model = @model
      return false if model.nil?

      model.errors.key?(sym)
    end

    def checked?(value)
      case value
      when true then true
      when Integer then value == 1
      when String then value == "1" || value == "t" || value == "true"
      else false
      end
    end


    # Keyword arguments become attributes in the order given (`true` as
    # name="name", false/nil dropped); the error class joins `class:`.
    def option_attrs(kwargs, with_errors)
      out = +""
      classes = +""
      kwargs.each_key do |key|
        value = kwargs[key]
        if key == "class"
          classes << FormBuilder.value_text(value)
        else
          case value
          when nil, false then nil
          when true then out << FormBuilder.html_attr(key.tr("_", "-"), key.tr("_", "-"))
          else out << FormBuilder.html_attr(key.tr("_", "-"), FormBuilder.value_text(value))
          end
        end
      end
      if with_errors
        classes << " " unless classes.empty?
        classes << ERROR_CLASS
      end
      out << " class=\"" << Html.escape(classes) << "\"" unless classes.empty?
      out
    end
  end
end
