# Cybertrain::FormBuilder -- the `f` in `<%= form_with(model: post) do |f| %>`.
#
#   <%= f.label :title %>          <label for="post_title">Title</label>
#   <%= f.text_field :title %>     <input type="text" name="post[title]" id="post_title" value="...">
#   <%= f.file_field :cover %>     <input type="file" name="post[cover]" id="post_cover"> (form_with multipart: true)
#   <%= f.select :status, ["draft", "published"] %>
#                                  <select name="post[status]" id="post_status"><option value="draft">draft</option>...
#   <%= f.radio_button :status, "draft" %>
#                                  <input type="radio" name="post[status]" id="post_status_draft" value="draft">
#   <%= f.submit %>                <input type="submit" name="commit" value="Create Post">
#
# Templates reach it through the interpreter's generic method call, which
# hands `f.xxx` to Helpers#call_object_method and from there to
# call_method(name_sym, args, kwargs): Spinel has no `send`, so the builder
# methods are a `case` table. Every method returns a SafeString. `f.select`
# runs the private select_field: there is no public `select` (Kernel's,
# and Enumerable's on every collection, return other types; spikes/NOTES.md
# rule 34), so it is reachable from templates only.
#
# The class methods build the <option> lists and attributes the standalone
# tag helpers (select_tag, options_for_select, ... in Template::Helpers)
# share with the builder. Every attribute value and every option text is
# escaped once: a SafeString goes in as it is, anything else through
# Html.escape. Selected and disabled values are compared as Strings, so an
# Integer column selects the option "3".
require "cybertrain/html"
require "cybertrain/model"
require "cybertrain/generator/inflector"
require "cybertrain/i18n"

module Cybertrain
  class FormBuilder
    ERROR_CLASS = "field_with_errors"
    # Keywords a field reads itself; they are never written as attributes.
    NO_KEYS = Array.new(0) { "" }
    SELECT_KEYS = %w[include_blank prompt selected disabled multiple include_hidden]
    CHECK_BOX_KEYS = %w[include_hidden]
    RADIO_KEYS = %w[checked]
    # select_tag writes multiple: as an attribute (multiple="multiple").
    TAG_SELECT_KEYS = %w[include_blank prompt]
    TAG_INPUT_KEYS = %w[id]

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

    # ` name="value"` for any value: a SafeString as is (it is HTML
    # already, as in Rails' tag_option), anything else as text, escaped.
    def self.text_attr(name, value)
      " #{name}=\"#{FormBuilder.html_text(value)}\""
    end

    # Keyword arguments become attributes in the order given, skipping the
    # keys in skip: `true` as name="name", false/nil dropped, `data:` and
    # `aria:` Hashes as data-*/aria-* attributes; extra_class (the error
    # class, or "") joins `class:` at the end.
    def self.attrs_html(kwargs, skip, extra_class)
      return "" if kwargs.empty? && extra_class.empty?

      out = +""
      classes = +""
      kwargs.each_key do |key|
        unless skip.include?(key)
          value = kwargs[key]
          if key == "class"
            # A SafeString class is HTML already: escaped once, here.
            classes << FormBuilder.html_text(value)
          else
            out << FormBuilder.attr_html(key.tr("_", "-"), value)
          end
        end
      end
      unless extra_class.empty?
        classes << " " unless classes.empty?
        classes << Html.escape(extra_class)
      end
      out << " class=\"" << classes << "\"" unless classes.empty?
      out
    end

    # One keyword's attribute(s), or "" when it is dropped.
    def self.attr_html(name, value)
      case value
      when nil, false then ""
      when true then " #{name}=\"#{name}\""
      # Time before Hash: a Time in a polymorphic slot can match a
      # collection class (spikes/NOTES.md rule 8).
      when Time then " #{name}=\"#{FormBuilder.html_text(value)}\""
      when Hash
        unless name == "data" || name == "aria"
          msg = "attribute '#{name}' cannot be a Hash"
          raise ArgumentError, msg
        end
        out = +""
        value.each_key do |sub|
          sub_value = value[sub]
          unless sub_value.nil?
            sub_name = "#{name}-#{sub.tr("_", "-")}"
            unless Html.attribute_name?(sub_name)
              msg = "invalid attribute name '#{sub_name}'"
              raise ArgumentError, msg
            end
            out << " " << sub_name << "=\"" << FormBuilder.html_text(sub_value) << "\""
          end
        end
        out
      else " #{name}=\"#{FormBuilder.html_text(value)}\""
      end
    end

    # A value (or an Array of them) as the Strings a selected:/disabled:
    # list compares option values with.
    def self.text_list(v)
      out = Array.new(0) { "" }
      case v
      when nil then nil
      when Time then out << FormBuilder.value_text(v)
      when Array
        i = 0
        while i < v.size
          out << FormBuilder.value_text(v[i])
          i += 1
        end
      else out << FormBuilder.value_text(v)
      end
      out
    end

    # `<option selected="selected" disabled="disabled" value="v">text</option>`,
    # in Rails' attribute order.
    def self.option_tag(text, value, selected, disabled)
      v = FormBuilder.value_text(value)
      sel = selected.include?(v) ? " selected=\"selected\"" : ""
      dis = disabled.include?(v) ? " disabled=\"disabled\"" : ""
      "<option#{sel}#{dis} value=\"#{FormBuilder.html_text(value)}\">#{FormBuilder.html_text(text)}</option>"
    end

    # One choice: a value (its own text) or a [text, value] pair.
    def self.choice_option(el, selected, disabled)
      case el
      when Time then FormBuilder.option_tag(el, el, selected, disabled)
      when Array
        n = el.size
        text = n > 0 ? el[0] : nil
        value = n > 1 ? el[1] : text
        FormBuilder.option_tag(text, value, selected, disabled)
      else FormBuilder.option_tag(el, el, selected, disabled)
      end
    end

    def self.group_choices?(v)
      case v
      when Time then false
      when Array then true
      else false
      end
    end

    def self.optgroup(label, choices, selected, disabled)
      "<optgroup label=\"#{FormBuilder.html_text(label)}\">#{FormBuilder.options_html(choices, selected, disabled)}</optgroup>"
    end

    # The <option> tags of choices, joined with "\n" as Rails does: an
    # Array of values or of [text, value] pairs, a Hash of text => value,
    # or groups (a Hash of label => choices, or [label, choices] pairs)
    # as <optgroup> tags, written one after another.
    def self.options_html(choices, selected, disabled)
      out = +""
      prev_option = false
      case choices
      when nil then nil
      when Time then out << FormBuilder.choice_option(choices, selected, disabled)
      when Hash
        keys = choices.keys
        i = 0
        while i < keys.size
          key = keys[i]
          value = choices[key]
          group = FormBuilder.group_choices?(value)
          if group
            out << FormBuilder.optgroup(key, value, selected, disabled)
          else
            out << "\n" if prev_option
            out << FormBuilder.option_tag(key, value, selected, disabled)
          end
          prev_option = !group
          i += 1
        end
      when Array
        i = 0
        while i < choices.size
          el = choices[i]
          group = false
          case el
          when Time then nil
          when Array
            if el.size == 2 && FormBuilder.group_choices?(el[1])
              group = true
              out << FormBuilder.optgroup(el[0], el[1], selected, disabled)
            end
          end
          unless group
            out << "\n" if prev_option
            out << FormBuilder.choice_option(el, selected, disabled)
          end
          prev_option = !group
          i += 1
        end
      else
        msg = "select expects choices as an Array or a Hash, got #{FormBuilder.value_text(choices)}"
        raise ArgumentError, msg
      end
      out
    end

    # The prompt and blank options before a select's choices, each
    # followed by sep ("\n" in the builder, "" in select_tag, as in
    # Rails). The prompt shows only while blank_value; `true` for either
    # takes the default text.
    def self.select_prefix(kwargs, blank_value, sep)
      out = +""
      prompt = kwargs["prompt"]
      if blank_value && !prompt.nil? && prompt != false
        text = prompt == true ? "Please select" : FormBuilder.html_text(prompt)
        out << "<option value=\"\">" << text << "</option>" << sep
      end
      blank = kwargs["include_blank"]
      unless blank.nil? || blank == false
        text = blank == true ? "" : FormBuilder.html_text(blank)
        out << (text.empty? ? "<option value=\"\" label=\" \"></option>" : "<option value=\"\">#{text}</option>") << sep
      end
      out
    end

    # `:id` or "id" as the Symbol a record is read by.
    def self.method_sym(v)
      case v
      when Symbol then v
      else
        text = FormBuilder.value_text(v)
        text.to_sym
      end
    end

    # A record's column, else its view method (as templates read it);
    # helper names the caller in the error for a name the record lacks.
    def self.record_value(rec, sym, helper)
      return rec.id if sym == :id

      v = rec.read_attribute(sym)
      return v unless v.nil?

      v = rec.call_view_method(sym)
      return v unless v.nil?

      unless rec.attribute_or_method?(sym)
        msg = "#{helper}: #{rec.model_name} has no attribute or view method '#{sym}'"
        raise ArgumentError, msg
      end
      nil
    end

    # One <option> per record, joined with "\n".
    def self.collection_options(records, value_sym, text_sym, selected, disabled, helper)
      out = +""
      case records
      when Time then nil
      when Array
        i = 0
        while i < records.size
          rec = records[i]
          case rec
          when Cybertrain::Model
            out << "\n" if i > 0
            value = FormBuilder.record_value(rec, value_sym, helper)
            text = FormBuilder.record_value(rec, text_sym, helper)
            out << FormBuilder.option_tag(text, value, selected, disabled)
          else
            msg = "#{helper} expects an Array of records, got #{FormBuilder.value_text(rec)}"
            raise ArgumentError, msg
          end
          i += 1
        end
        return out
      end
      msg = "#{helper} expects an Array of records, got #{FormBuilder.value_text(records)}"
      raise ArgumentError, msg
    end

    # An input's value attribute text: a Time as the date, datetime-local
    # and time inputs read it (Rails' formats), anything else as HTML.
    def self.input_value_html(type, value)
      case value
      when Time
        return value.strftime("%Y-%m-%dT%H:%M:%S") if type == "datetime-local"
        return value.strftime("%Y-%m-%d") if type == "date"
        return value.strftime("%H:%M:%S.%L") if type == "time"
      end
      FormBuilder.html_text(value)
    end

    # An <input> of the standalone tag helpers: id: replaces the id taken
    # from the name; tail (" autocomplete=\"off\"" or "") follows the value.
    def self.input_tag(type, name, value, kwargs, tail)
      given_id = kwargs["id"]
      id = given_id.nil? ? Html.escape(FormBuilder.tag_id(name)) : FormBuilder.html_text(given_id)
      shown = value.nil? ? "" : " value=\"#{FormBuilder.html_text(value)}\""
      "<input type=\"#{type}\" name=\"#{Html.escape(name)}\" id=\"#{id}\"#{shown}#{tail}#{FormBuilder.attrs_html(kwargs, TAG_INPUT_KEYS, "")}>"
    end

    # [-a-zA-Z0-9:.]: the bytes an id keeps as they are.
    def self.id_byte?(b)
      (b >= 97 && b <= 122) || (b >= 65 && b <= 90) || (b >= 48 && b <= 57) || b == 45 || b == 58 || b == 46
    end

    # The id of a standalone tag's name, as Rails' sanitize_to_id:
    # "q[term]" -> "q_term" (`]` dropped, other bytes outside
    # [-a-zA-Z0-9:.] become `_`). Reads its argument through a fresh local
    # (spikes/NOTES.md rule 62).
    def self.tag_id(name)
      s = name.to_s
      n = s.bytesize
      out = +""
      i = 0
      while i < n
        b = s.getbyte(i)
        if b != 93
          out << (FormBuilder.id_byte?(b) ? s.byteslice(i, 1) : "_")
        end
        i += 1
      end
      out
    end

    # A builder's id prefix, as Rails' sanitized_object_name:
    # "article[meta]" -> "article_meta" (`][` and other bytes outside
    # [-a-zA-Z0-9:.] become `_`, a trailing `_` is dropped). Fresh local:
    # rule 62.
    def self.scope_id(scope)
      s = scope.to_s
      n = s.bytesize
      out = +""
      i = 0
      while i < n
        b = s.getbyte(i)
        if b == 93 && i + 1 < n && s.getbyte(i + 1) == 91
          out << "_"
          i += 2
        else
          out << (FormBuilder.id_byte?(b) ? s.byteslice(i, 1) : "_")
          i += 1
        end
      end
      return out unless out.end_with?("_")

      out[0, out.length - 1]
    end

    # A radio button's value in its id, as Rails' sanitized_value:
    # whitespace and `.` become `_`, bytes outside [-\w] are dropped (bytes
    # of a multibyte character are kept), and it is downcased. Fresh
    # local: rule 62.
    def self.value_id(value)
      s = value.to_s
      n = s.bytesize
      out = +""
      i = 0
      while i < n
        b = s.getbyte(i)
        if b == 32 || (b >= 9 && b <= 13) || b == 46
          out << "_"
        elsif (b >= 97 && b <= 122) || (b >= 65 && b <= 90) || (b >= 48 && b <= 57) || b == 95 || b == 45 || b >= 128
          out << s.byteslice(i, 1)
        end
        i += 1
      end
      out.downcase
    end

    # model: a Cybertrain::Model, or nil for `form_with url: ...` (fields are
    # then named after the attribute alone). scope: form_with's `scope:`,
    # the name prefix ("q" names q[term]); "" takes the model's.
    def initialize(model, scope = "")
      @model = model
      @model_key = model.nil? ? "" : Inflector.underscore(model.model_name)
      @scope = scope.empty? ? @model_key : scope
      @id_scope = FormBuilder.scope_id(@scope)
    end

    def call_method(name_sym, args, kwargs)
      case name_sym
      when :label then label(args, kwargs)
      when :text_field then input_field("text", "text_field", args, kwargs)
      when :email_field then input_field("email", "email_field", args, kwargs)
      when :password_field then input_field("password", "password_field", args, kwargs)
      when :number_field then input_field("number", "number_field", args, kwargs)
      when :date_field then input_field("date", "date_field", args, kwargs)
      when :datetime_local_field then input_field("datetime-local", "datetime_local_field", args, kwargs)
      when :time_field then input_field("time", "time_field", args, kwargs)
      when :range_field then input_field("range", "range_field", args, kwargs)
      when :color_field then input_field("color", "color_field", args, kwargs)
      when :search_field then input_field("search", "search_field", args, kwargs)
      when :telephone_field then input_field("tel", "telephone_field", args, kwargs)
      when :url_field then input_field("url", "url_field", args, kwargs)
      when :hidden_field then input_field("hidden", "hidden_field", args, kwargs)
      when :file_field then file_field(args, kwargs)
      when :text_area then text_area(args, kwargs)
      when :check_box then check_box(args, kwargs)
      when :radio_button then radio_button(args, kwargs)
      when :select then select_field(args, kwargs)
      when :collection_select then collection_select(args, kwargs)
      when :submit then submit(args, kwargs)
      else raise ArgumentError, "undefined method '#{name_sym}' for FormBuilder"
      end
    end

    private

    # Explicit text is escaped unless it is a SafeString (`raw('<i>T</i>')`).
    def label(args, kwargs)
      attr = attribute_name(args, "label", "")
      text = args.size > 1 ? FormBuilder.html_text(args[1]) : Html.escape(label_text(attr))
      SafeString.of("<label for=\"#{Html.escape(field_id(attr))}\"#{option_attrs(kwargs, NO_KEYS, errors_on?(attribute_sym(args, attr)))}>#{text}</label>")
    end

    # nil values (and password fields) get no value attribute, as in Rails.
    # method: the builder method, for the arity error.
    def input_field(type, method, args, kwargs)
      attr = attribute_name(args, method, "")
      sym = attribute_sym(args, attr)
      value = read_value(sym)
      shown = value.nil? || type == "password" ? "" : " value=\"#{FormBuilder.input_value_html(type, value)}\""
      SafeString.of("<input type=\"#{Html.escape(type)}\" name=\"#{Html.escape(field_name(attr))}\" id=\"#{Html.escape(field_id(attr))}\"#{shown}#{option_attrs(kwargs, NO_KEYS, errors_on?(sym))}>")
    end

    # `<input type="file">`. No value attribute (a browser never prefills
    # one) and no read_value: the attribute is a form field, not a column,
    # so read_attribute would not know it. accept:/required: pass through
    # option_attrs. One file per field: a `multiple` input would need the
    # parser to collect several parts under one name.
    def file_field(args, kwargs)
      raise ArgumentError, "file_field multiple: true is not supported" if kwargs["multiple"] == true

      attr = attribute_name(args, "file_field", "")
      sym = attribute_sym(args, attr)
      SafeString.of("<input type=\"file\" name=\"#{Html.escape(field_name(attr))}\" id=\"#{Html.escape(field_id(attr))}\"#{option_attrs(kwargs, NO_KEYS, errors_on?(sym))}>")
    end

    # The newline after the opening tag is Rails' too: browsers drop the
    # first newline of a textarea, so a value starting with one survives.
    def text_area(args, kwargs)
      attr = attribute_name(args, "text_area", "")
      sym = attribute_sym(args, attr)
      SafeString.of("<textarea name=\"#{Html.escape(field_name(attr))}\" id=\"#{Html.escape(field_id(attr))}\"#{option_attrs(kwargs, NO_KEYS, errors_on?(sym))}>\n#{Html.escape(FormBuilder.value_text(read_value(sym)))}</textarea>")
    end

    # The hidden "0" makes an unchecked box submit a value at all;
    # include_hidden: false leaves it out.
    def check_box(args, kwargs)
      attr = attribute_name(args, "check_box", "")
      sym = attribute_sym(args, attr)
      name = Html.escape(field_name(attr))
      checked = checked?(read_value(sym)) ? " checked=\"checked\"" : ""
      hidden = kwargs["include_hidden"] == false ? "" : "<input type=\"hidden\" name=\"#{name}\" value=\"0\">"
      SafeString.of("#{hidden}<input type=\"checkbox\" name=\"#{name}\" id=\"#{Html.escape(field_id(attr))}\" value=\"1\"#{checked}#{option_attrs(kwargs, CHECK_BOX_KEYS, errors_on?(sym))}>")
    end

    # f.radio_button :status, "draft": checked when the attribute's value
    # reads as "draft" (checked: true/false overrides); the id ends in the
    # value (article_status_draft).
    def radio_button(args, kwargs)
      arity!(args, "radio_button", 2)
      attr = FormBuilder.value_text(args[0])
      sym = attribute_sym(args, attr)
      value = args[1]
      text = FormBuilder.value_text(value)
      current = read_value(sym)
      on = !current.nil? && FormBuilder.value_text(current) == text
      on = kwargs["checked"] == true if kwargs.key?("checked")
      checked = on ? " checked=\"checked\"" : ""
      SafeString.of("<input type=\"radio\" name=\"#{Html.escape(field_name(attr))}\" id=\"#{Html.escape(field_id(attr))}_#{FormBuilder.value_id(text)}\" value=\"#{FormBuilder.html_text(value)}\"#{checked}#{option_attrs(kwargs, RADIO_KEYS, errors_on?(sym))}>")
    end

    # f.select :status, choices, include_blank:, prompt:, selected:,
    # disabled:, multiple: (see FormBuilder.options_html for choices).
    def select_field(args, kwargs)
      arity!(args, "select", 2)
      attr = FormBuilder.value_text(args[0])
      sym = attribute_sym(args, attr)
      selected = selected_values(sym, kwargs)
      options = FormBuilder.options_html(args[1], selected, FormBuilder.text_list(kwargs["disabled"]))
      select_html(attr, sym, selected, options, kwargs)
    end

    # f.collection_select :author_id, authors, :id, :name: one option per
    # record, its value and text read by FormBuilder.record_value.
    def collection_select(args, kwargs)
      arity!(args, "collection_select", 4)
      attr = FormBuilder.value_text(args[0])
      sym = attribute_sym(args, attr)
      selected = selected_values(sym, kwargs)
      value_sym = FormBuilder.method_sym(args[2])
      text_sym = FormBuilder.method_sym(args[3])
      disabled = FormBuilder.text_list(kwargs["disabled"])
      options = FormBuilder.collection_options(args[1], value_sym, text_sym, selected, disabled, "collection_select")
      select_html(attr, sym, selected, options, kwargs)
    end

    # selected: when given, else the attribute's value.
    def selected_values(sym, kwargs)
      return FormBuilder.text_list(kwargs["selected"]) if kwargs.key?("selected")

      FormBuilder.text_list(read_value(sym))
    end

    # multiple: true names article[tags][] and puts a hidden "" first, so
    # that clearing every option still submits the field
    # (include_hidden: false leaves it out).
    def select_html(attr, sym, selected, options, kwargs)
      multiple = kwargs["multiple"] == true
      base = field_name(attr)
      name = Html.escape(multiple ? "#{base}[]" : base)
      blank = selected.empty? || (selected.size == 1 && selected[0].empty?)
      prefix = FormBuilder.select_prefix(kwargs, blank, "\n")
      hidden = multiple && kwargs["include_hidden"] != false ? "<input type=\"hidden\" name=\"#{name}\" value=\"\" autocomplete=\"off\">" : ""
      many = multiple ? " multiple=\"multiple\"" : ""
      SafeString.of("#{hidden}<select name=\"#{name}\" id=\"#{Html.escape(field_id(attr))}\"#{many}#{option_attrs(kwargs, SELECT_KEYS, errors_on?(sym))}>#{prefix}#{options}</select>")
    end

    def submit(args, kwargs)
      text = args.empty? ? default_submit_text : FormBuilder.value_text(args[0])
      SafeString.of("<input type=\"submit\" name=\"commit\" value=\"#{Html.escape(text)}\"#{option_attrs(kwargs, NO_KEYS, false)}>")
    end

    # Rails' label text: `helpers.label.<object name>.<attr>` (the object
    # name is the scope, the model's key unless scope: gives one), else the
    # model's human_attribute_name, else (no model) the attribute humanized.
    def label_text(attr)
      scope = @scope
      unless scope.empty?
        found = I18n.find_translation("helpers.label.#{scope}.#{attr}")
        return found unless found.nil?
      end
      key = @model_key
      key.empty? ? I18n.humanize_attribute(attr) : I18n.human_attribute_name(key, attr)
    end

    # helpers.submit.create / update ("Create Post" / "Update Post") with
    # %{model} the model's human name, or cybertrain.helpers.submit.no_model
    # ("Save changes") without a model. A scope: does not rename the model.
    def default_submit_text
      model = @model
      return I18n.t("cybertrain.helpers.submit.no_model") if model.nil?

      key = model.persisted? ? "helpers.submit.update" : "helpers.submit.create"
      I18n.t(key, { model: I18n.human_model_name(@model_key) })
    end

    # The method name for the error is method + suffix ("text" + "_field"),
    # joined only when it is raised.
    def attribute_name(args, method, suffix)
      raise ArgumentError, "wrong number of arguments for '#{method}#{suffix}'" if args.empty?

      FormBuilder.value_text(args[0])
    end

    def arity!(args, method, n)
      return nil if args.size == n

      msg = "wrong number of arguments for '#{method}' (given #{args.size}, expected #{n})"
      raise ArgumentError, msg
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
      @id_scope.empty? ? attr : "#{@id_scope}_#{attr}"
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

    # The keywords not in skip as attributes; the error class joins
    # `class:` (FormBuilder.attrs_html).
    def option_attrs(kwargs, skip, with_errors)
      FormBuilder.attrs_html(kwargs, skip, with_errors ? ERROR_CLASS : "")
    end
  end
end
