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

    # A template value as text. Every branch is an interpolation or a
    # literal so the result is statically a String (see
    # Interpreter#to_s_value); Spinel's interpolation does not call a
    # user-defined to_s, hence "#{v.to_s}" for SafeString.
    def self.value_text(v)
      case v
      when SafeString then "#{v.to_s}"
      when String then "#{v}"
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
      when SafeString then "#{v.to_s}"
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
    # stack slot, which later crashes a minor collection.
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
      attr = attribute_name(args, "label")
      text = args.size > 1 ? FormBuilder.html_text(args[1]) : Html.escape(FormBuilder.humanize(attr))
      buf = +"<label"
      buf << FormBuilder.html_attr("for", field_id(attr))
      buf << option_attrs(kwargs, errors_on?(attr))
      buf << ">" << text << "</label>"
      SafeString.new(buf)
    end

    # nil values (and password fields) get no value attribute, as in Rails.
    def input_field(type, args, kwargs)
      attr = attribute_name(args, "#{type}_field")
      buf = +"<input"
      buf << FormBuilder.html_attr("type", type)
      buf << FormBuilder.html_attr("name", field_name(attr))
      buf << FormBuilder.html_attr("id", field_id(attr))
      value = read_value(attr)
      buf << FormBuilder.html_attr("value", FormBuilder.value_text(value)) unless value.nil? || type == "password"
      buf << option_attrs(kwargs, errors_on?(attr))
      buf << ">"
      SafeString.new(buf)
    end

    # The newline after the opening tag is Rails' too: browsers drop the
    # first newline of a textarea, so a value starting with one survives.
    def text_area(args, kwargs)
      attr = attribute_name(args, "text_area")
      buf = +"<textarea"
      buf << FormBuilder.html_attr("name", field_name(attr))
      buf << FormBuilder.html_attr("id", field_id(attr))
      buf << option_attrs(kwargs, errors_on?(attr))
      buf << ">\n" << Html.escape(FormBuilder.value_text(read_value(attr))) << "</textarea>"
      SafeString.new(buf)
    end

    # The hidden "0" makes an unchecked box submit a value at all.
    def check_box(args, kwargs)
      attr = attribute_name(args, "check_box")
      buf = +"<input"
      buf << FormBuilder.html_attr("type", "hidden")
      buf << FormBuilder.html_attr("name", field_name(attr))
      buf << FormBuilder.html_attr("value", "0")
      buf << "><input"
      buf << FormBuilder.html_attr("type", "checkbox")
      buf << FormBuilder.html_attr("name", field_name(attr))
      buf << FormBuilder.html_attr("id", field_id(attr))
      buf << FormBuilder.html_attr("value", "1")
      buf << FormBuilder.html_attr("checked", "checked") if checked?(read_value(attr))
      buf << option_attrs(kwargs, errors_on?(attr))
      buf << ">"
      SafeString.new(buf)
    end

    def submit(args, kwargs)
      text = args.empty? ? default_submit_text : FormBuilder.value_text(args[0])
      buf = +"<input"
      buf << FormBuilder.html_attr("type", "submit")
      buf << FormBuilder.html_attr("name", "commit")
      buf << FormBuilder.html_attr("value", text)
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

    def attribute_name(args, method)
      raise ArgumentError, "wrong number of arguments for '#{method}'" if args.empty?

      FormBuilder.value_text(args[0])
    end

    def field_name(attr)
      @scope.empty? ? attr : "#{@scope}[#{attr}]"
    end

    def field_id(attr)
      @scope.empty? ? attr : "#{@scope}_#{attr}"
    end

    def read_value(attr)
      model = @model
      return nil if model.nil?

      model.read_attribute(attr.to_sym)
    end

    def errors_on?(attr)
      model = @model
      return false if model.nil?

      model.errors.key?(attr.to_sym)
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
      out << FormBuilder.html_attr("class", classes) unless classes.empty?
      out
    end
  end
end
