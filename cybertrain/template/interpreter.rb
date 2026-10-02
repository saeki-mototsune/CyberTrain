# Cybertrain::Template::Interpreter -- evaluates a compiled template.
#
# Values are plain Ruby objects (nil, true/false, Integer, Float, String,
# Symbol, SafeString, Time, Array, Hash, Model, Errors, Params) held in the
# environment Hash<String, value>: "post" is both @post and the local post.
# Method calls go through per-type allow-lists (call_method), because Spinel
# has no `send`; helper calls (no receiver) go to the HelperBase object.
require "cybertrain/html"
require "cybertrain/errors"
require "cybertrain/params"
require "cybertrain/model"
require "cybertrain/template/ast"
require "cybertrain/template/inode"

module Cybertrain
  # Templates ask a record whether a name it answered nil for exists at all
  # (a nil column vs. a typo). The permissive default keeps every nil a nil;
  # a model that knows its names overrides it with a `case`.
  # TODO(integrator): this stub belongs in cybertrain/model.rb, with the
  # model generator emitting the override (columns, associations, view
  # methods) and the default flipped to false. Until then a misspelt name on a
  # generated model renders empty instead of raising (a known gap, listed in
  # docs/design.md section 13).
  class Model
    def attribute_or_method?(name) = true
  end

  module Template
    # What templates call without a receiver (link_to, form_with, render ...).
    # Template::Helpers (cybertrain/template/helpers.rb) implements the real
    # set.
    class HelperBase
      # block: the K_BLOCK_CALL INode for `helper do |f| ... end`, else nil;
      # render its body with interp.capture(block, env, arg).
      def helper_call(name, args, kwargs, block, interp, env)
        raise RuntimeError, "undefined helper '#{name}'"
      end

      # A method call on a value the interpreter has no table for (a
      # FormBuilder): subclasses narrow `recv` with `case` and dispatch.
      def call_object_method(recv, name_sym, name_str, args, kwargs)
        raise RuntimeError, "undefined method '#{name_str}' for #{recv.class.name}"
      end
    end

    class Interpreter
      # How many renders may be nested (page -> partial -> partial ...). A
      # partial that renders itself, or two that render each other, would
      # otherwise recurse until the native stack is gone: SystemStackError is
      # not a StandardError (every rescue misses it) and under Spinel it is a
      # SIGSEGV of the whole process. Past the limit render raises a located
      # Template::RuntimeError like any other template error. Real pages nest
      # a handful of levels (layout, page, a partial or two). The limit is
      # low on purpose: a render costs about 14 frames under CRuby and more
      # under Spinel, whose thread stacks are small -- 50 nested renders
      # already overflowed one in CI (macOS, test/template_partial_depth.rb).
      MAX_RENDER_DEPTH = 12

      # max_depth: Views.configure(root, max_render_depth: n) for an app whose
      # partials legitimately recurse (threaded comments, a tree menu) past
      # the default; the page and the layout count as renders too.
      def initialize(helpers, max_depth = MAX_RENDER_DEPTH)
        @helpers = helpers
        @max_depth = max_depth
        @name = ""
        # Renders currently open on this interpreter (typed Integer counter).
        @depth = 0
        @last_error = ""
        # The output buffer lives in an ivar rather than being passed down:
        # Spinel strings are immutable C strings that `<<` replaces, and a
        # String parameter appended to inside a nested block call is not
        # written back to the caller.
        @out = String.new
        # Shared empty args/kwargs, seeded with a value and emptied so that
        # Spinel types them Array<value> / Hash<String, value> (rule 9).
        @no_args = []
        @no_args << nil
        @no_args.clear
        @no_kwargs = {}
        @no_kwargs[""] = @no_args
        @no_kwargs.clear
      end

      # Renders template into a fresh String. Re-entrant: a helper rendering
      # a partial calls render again on the same interpreter.
      def render(template, env)
        # Checked before anything is saved or changed, so the raise leaves
        # @depth/@name/@out untouched. @name is still the calling template
        # here; the caller's call_helper then adds its "name:line:" prefix.
        if @depth >= @max_depth
          raise RuntimeError, "partial nesting too deep (> #{@max_depth}): #{template.name} rendered from #{@name}"
        end

        saved_name = @name
        saved_out = @out
        @name = template.name
        @out = String.new
        @depth = @depth + 1
        begin
          exec_nodes(template.nodes, env)
          result = @out
        ensure
          @depth = @depth - 1
          @name = saved_name
          @out = saved_out
        end
        result
      end

      # Renders a helper block's body, binding its first block parameter
      # (`|f|`) to arg; the environment is restored afterwards.
      def capture(block, env, arg = nil)
        names = block.inames
        saved = save_locals(env, names)
        fresh = fresh_locals(env, block.ipairs)
        env[names[0]] = arg unless names.empty?
        saved_out = @out
        @out = String.new
        exec_nodes(block.ikids, env)
        result = @out
        @out = saved_out
        restore_locals(env, names, saved)
        drop_locals(env, fresh)
        result
      end

      # A `case` instead of `v == false`: `==` on a polymorphic value goes
      # through the generic (and, for models, user-defined) equality.
      def truthy?(v)
        case v
        when nil then false
        when false then false
        else true
        end
      end

      # <%= %>: nil prints nothing, SafeString passes through, the rest is escaped.
      def to_output(v)
        case v
        when nil then ""
        when SafeString then "#{v.to_s}"
        else escape_html(to_s_value(v))
        end
      end

      # Html.escape's parameter is polymorphic program-wide (SafeString#+
      # passes it one), which makes each of its byte comparisons a boxed
      # one. Most values need no escaping, so they are scanned here with a
      # String-typed parameter and only dirty ones go to Html.escape
      # (measured 286 -> 222 us for a 32 KB page).
      def escape_html(str)
        n = str.bytesize
        i = 0
        while i < n
          b = str.getbyte(i)
          return Html.escape(str) if b == 38 || b == 60 || b == 62 || b == 34 || b == 39
          i += 1
        end
        str
      end

      # Every branch is an interpolation or a literal, so the result is
      # statically a String: a bare `v` (or `v.to_s`, which may dispatch to
      # SafeString#to_s) stays polymorphic and drags every `<<` of the result
      # onto Spinel's boxed slow path. Spinel's interpolation does not call a
      # user-defined to_s, hence the explicit "#{v.to_s}" for objects.
      def to_s_value(v)
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
        when Array then "[#{v.map { |x| inspect_value(x) }.join(", ")}]"
        when Cybertrain::Model then "#<#{v.class.name} id: #{v.id}>"
        else "#{v.to_s}"
        end
      end

      def eval_expr(n, env)
        k = n.ikind
        if k == INode::K_CALL then eval_call(n, env)
        elsif k == INode::K_LVAR
          v = env[n.istr]
          return v unless v.nil? && !key_in?(env, n.istr)

          call_helper(n.istr, eval_args(n, env), eval_kwargs(n, env), nil, n, env)
        elsif k == INode::K_IVAR then env[n.istr]
        elsif k == INode::K_STR then n.istr
        elsif k == INode::K_INT then n.iint
        elsif k == INode::K_SYM then n.isym
        elsif k == INode::K_NIL then nil
        elsif k == INode::K_TRUE then true
        elsif k == INode::K_FALSE then false
        elsif k == INode::K_AND
          l = eval_expr(n.ia, env)
          truthy?(l) ? eval_expr(n.ib, env) : l
        elsif k == INode::K_OR
          l = eval_expr(n.ia, env)
          truthy?(l) ? l : eval_expr(n.ib, env)
        elsif k == INode::K_NOT then !truthy?(eval_expr(n.ia, env))
        elsif k == INode::K_EQ then eval_expr(n.ia, env) == eval_expr(n.ib, env)
        elsif k == INode::K_NEQ then !(eval_expr(n.ia, env) == eval_expr(n.ib, env))
        elsif k >= INode::K_LT && k <= INode::K_GE
          c = compare(eval_expr(n.ia, env), eval_expr(n.ib, env), n)
          case k
          when INode::K_LT then c < 0
          when INode::K_GT then c > 0
          when INode::K_LE then c <= 0
          else c >= 0
          end
        elsif k >= INode::K_ADD && k <= INode::K_MOD
          arithmetic(k, n.istr, eval_expr(n.ia, env), eval_expr(n.ib, env), n)
        elsif k == INode::K_TERNARY
          truthy?(eval_expr(n.ia, env)) ? eval_expr(n.ib, env) : eval_expr(n.ic, env)
        elsif k == INode::K_INTERP
          buf = +""
          n.ikids.each { |part| buf << to_s_value(eval_expr(part, env)) }
          buf
        elsif k == INode::K_INDEX then index(eval_expr(n.ia, env), eval_expr(n.ib, env), n)
        elsif k == INode::K_FLOAT then n.iflt
        elsif k == INode::K_ARRAY
          items = []
          n.ikids.each { |item| items << eval_expr(item, env) }
          items
        elsif k == INode::K_HASH
          hash = {}
          n.ipairs.each_with_index { |key, i| hash[key] = eval_expr(n.ikids[i], env) }
          hash
        else
          fail_at(n, "cannot evaluate node kind #{k}")
        end
      end

      def call_method(recv, name_sym, name_str, args, kwargs, node)
        case name_sym
        when :nil? then return recv.nil?
        when :present? then return !blank?(recv)
        when :blank? then return blank?(recv)
        end

        # nil/true/false last: Spinel tests them with a generic equality.
        case recv
        when SafeString then safe_string_method(recv, name_sym, name_str, node)
        when String then string_method(recv, name_sym, name_str, args, node)
        when Integer then integer_method(recv, name_sym, name_str, args, node)
        when Float then float_method(recv, name_sym, name_str, args, node)
        when Symbol
          return recv.to_s if name_sym == :to_s
          undefined(node, name_str, "Symbol")
        # Time before Array: a Time in a polymorphic slot also matches Array
        # (spikes/NOTES.md rule 8).
        when Time then time_method(recv, name_sym, name_str, args, node)
        when Array then array_method(recv, name_sym, name_str, args, node)
        when Hash then hash_method(recv, name_sym, name_str, args, node)
        when Cybertrain::Errors then errors_method(recv, name_sym, name_str, args, node)
        when Cybertrain::Params then params_method(recv, name_sym, name_str, args, node)
        when Cybertrain::Model then model_method(recv, name_sym, name_str, node)
        when nil
          return "" if name_sym == :to_s
          undefined(node, name_str, "nil")
        when true, false
          return recv.to_s if name_sym == :to_s
          undefined(node, name_str, recv.to_s)
        else
          result = nil
          begin
            result = @helpers.call_object_method(recv, name_sym, name_str, args, kwargs)
          rescue Cybertrain::Template::SyntaxError => e
            raise e
          rescue StandardError => e
            relocate(e, node)
          end
          result
        end
      end

      private

      def exec_nodes(nodes, env)
        nodes.each do |n|
          k = n.ikind
          if k == INode::K_TEXT then @out << n.istr
          elsif k == INode::K_OUT then @out << to_output(eval_expr(n.ia, env))
          elsif k == INode::K_OUT_RAW then @out << to_s_value(eval_expr(n.ia, env))
          elsif k == INode::K_IF
            exec_nodes(truthy?(eval_expr(n.ia, env)) ? n.ikids : n.ikids2, env)
          elsif k == INode::K_EACH then exec_each(n, env)
          elsif k == INode::K_UNLESS
            exec_nodes(truthy?(eval_expr(n.ia, env)) ? n.ikids2 : n.ikids, env)
          elsif k == INode::K_BLOCK_CALL
            call = n.ia
            v = call_helper(call.istr, eval_args(call, env), eval_kwargs(call, env), n, call, env)
            @out << to_output(v) if n.iint == 1
          elsif k == INode::K_STMT then eval_expr(n.ia, env)
          elsif k == INode::K_ASSIGN then env[n.istr] = eval_expr(n.ia, env)
          end
        end
        nil
      end

      def exec_each(n, env)
        coll = eval_expr(n.ia, env)
        names = n.inames
        two = names.size > 1
        saved = save_locals(env, names)
        fresh = fresh_locals(env, n.ipairs)
        case coll
        when Time then undefined(n, "each", "Time")
        when Array
          i = 0
          coll.each do |item|
            if n.iint == 1
              env[names[0]] = item
              env[names[1]] = i if two
            elsif two
              case item
              when Array
                env[names[0]] = item[0]
                env[names[1]] = item[1]
              else
                env[names[0]] = item
                env[names[1]] = nil
              end
            else
              env[names[0]] = item
            end
            reset_locals(env, fresh)
            exec_nodes(n.ikids, env)
            i += 1
          end
        when Hash
          i = 0
          coll.each do |key, value|
            if two && n.iint == 0
              env[names[0]] = key
              env[names[1]] = value
            else
              pair = []
              pair << key
              pair << value
              env[names[0]] = pair
              env[names[1]] = i if two
            end
            reset_locals(env, fresh)
            exec_nodes(n.ikids, env)
            i += 1
          end
        when nil then undefined(n, "each", "nil")
        else undefined(n, "each", type_name(coll))
        end
        restore_locals(env, names, saved)
        drop_locals(env, fresh)
        nil
      end

      # Block parameters shadow outer names only inside the block.
      def save_locals(env, names)
        saved = {}
        names.each { |name| saved[name] = env[name] if key_in?(env, name) }
        saved
      end

      def restore_locals(env, names, saved)
        names.each do |name|
          if saved.key?(name)
            env[name] = saved[name]
          else
            env.delete(name)
          end
        end
        nil
      end

      # Locals first assigned inside a block body (Compile lists them in the
      # block's ipairs) are block-local, as in Ruby: those that do not exist
      # yet when the block starts are nil at the start of every iteration and
      # gone afterwards. A name that already exists outside is the outer
      # variable, and assignments to it stay visible after the block.
      def fresh_locals(env, names)
        return names if names.empty?

        names.reject { |name| key_in?(env, name) }
      end

      def reset_locals(env, fresh)
        fresh.each { |name| env[name] = nil }
        nil
      end

      def drop_locals(env, fresh)
        fresh.each { |name| env.delete(name) }
        nil
      end

      def eval_call(n, env)
        return eval_helper_call(n, env) if n.ia.ikind == INode::K_NONE

        recv = eval_expr(n.ia, env)
        return nil if recv.nil? && n.iint == 1

        call_method(recv, n.isym, n.istr, eval_args(n, env), eval_kwargs(n, env), n)
      end

      def eval_helper_call(n, env)
        if n.istr == "yield"
          key = n.ikids.empty? ? "__content" : "__content_#{to_s_value(eval_expr(n.ikids[0], env))}"
          return env[key]
        end
        call_helper(n.istr, eval_args(n, env), eval_kwargs(n, env), nil, n, env)
      end

      def call_helper(name, args, kwargs, block, node, env)
        result = nil
        begin
          result = @helpers.helper_call(name, args, kwargs, block, self, env)
        rescue Cybertrain::Template::SyntaxError => e
          # A partial that failed to parse: already "<partial>:<line>: ...".
          raise e
        rescue StandardError => e
          relocate(e, node)
        end
        result
      end

      # Calls without arguments (most of them) share one empty Array / Hash
      # instead of allocating a fresh pair per call; helpers must not mutate
      # args or kwargs.
      def eval_args(n, env)
        return @no_args if n.ikids.empty?

        args = []
        n.ikids.each { |a| args << eval_expr(a, env) }
        args
      end

      def eval_kwargs(n, env)
        return @no_kwargs if n.ipairs.empty?

        kwargs = {}
        n.ipairs.each_with_index { |key, i| kwargs[key] = eval_expr(n.ikids2[i], env) }
        kwargs
      end

      # --- errors -----------------------------------------------------------

      def fail_at(node, message)
        @last_error = "#{@name}:#{node.iline}: #{message}"
        raise RuntimeError, @last_error
      end

      def undefined(node, name, type)
        fail_at(node, "undefined method '#{name}' for #{type}")
      end

      # Any StandardError raised by a helper (a plain `raise "no routes"`,
      # ArgumentError, KeyError, MissingTemplate ...) becomes a
      # Template::RuntimeError with this template's name and line and the
      # original message, unless it already carries a location (it came from
      # a nested render, which set @last_error).
      def relocate(error, node)
        raise error if error.message == @last_error

        fail_at(node, error.message)
      end

      def type_name(v)
        case v
        when nil then "nil"
        when SafeString then "SafeString"
        when String then "String"
        when Integer then "Integer"
        when Float then "Float"
        when true then "true"
        when false then "false"
        when Symbol then "Symbol"
        when Time then "Time"
        when Array then "Array"
        when Hash then "Hash"
        when Cybertrain::Errors then "Errors"
        when Cybertrain::Params then "Params"
        else v.class.name
        end
      end

      def inspect_value(v)
        case v
        when String then v.inspect
        when nil then "nil"
        when Symbol then ":#{v}"
        else to_s_value(v)
        end
      end

      def blank?(v)
        case v
        when nil then true
        when false then true
        when SafeString then v.to_s.strip.empty?
        when String then v.strip.empty?
        when Time then false
        when Array then v.empty?
        when Hash then v.empty?
        when Cybertrain::Errors then v.empty?
        when Cybertrain::Params then v.empty?
        else false
        end
      end

      # The trailing "" / 0 are never reached; with them the return type is
      # a plain String / Integer. Time#strftime with a polymorphic argument
      # compiles to a NoMethodError.
      def string_arg(args, i, node, name)
        fail_at(node, "wrong number of arguments for '#{name}'") if args.size <= i
        a = args[i]
        # Interpolated: a bare `a` or `a.to_s` would stay polymorphic.
        case a
        when SafeString then return "#{a.to_s}"
        when String then return "#{a}"
        end
        fail_at(node, "'#{name}' expects a String, got #{type_name(a)}")
        ""
      end

      def int_arg(args, i, node, name)
        fail_at(node, "wrong number of arguments for '#{name}'") if args.size <= i
        a = args[i]
        case a
        when Integer then return a
        end
        fail_at(node, "'#{name}' expects an Integer, got #{type_name(a)}")
        0
      end

      # Hash#key? on a polymorphic receiver mis-dispatches under Spinel once
      # a user class (Errors, Params) defines key?: it consults only user
      # classes and answers false for every Hash. Look the key up instead.
      def key_in?(hash, key)
        return true unless hash[key].nil?

        found = false
        hash.each_key { |k| found = true if k == key }
        found
      end

      # --- operators --------------------------------------------------------

      def arithmetic(kind, op, l, r, node)
        case l
        when Integer
          case r
          when Integer then return int_op(kind, l, r, node)
          when Float then return float_op(kind, l.to_f, r)
          end
        when Float
          case r
          when Integer then return float_op(kind, l, r.to_f)
          when Float then return float_op(kind, l, r)
          end
        when String
          if kind == INode::K_ADD
            case r
            when SafeString then return l + r.to_s
            when String then return l + r
            end
          end
        end
        fail_at(node, "undefined operation #{type_name(l)} #{op} #{type_name(r)}")
      end

      def int_op(kind, l, r, node)
        case kind
        when INode::K_ADD then l + r
        when INode::K_SUB then l - r
        when INode::K_MUL then l * r
        when INode::K_DIV
          fail_at(node, "divided by 0") if r == 0
          l / r
        else
          fail_at(node, "divided by 0") if r == 0
          l % r
        end
      end

      def float_op(kind, l, r)
        case kind
        when INode::K_ADD then l + r
        when INode::K_SUB then l - r
        when INode::K_MUL then l * r
        when INode::K_DIV then l / r
        else l % r
        end
      end

      # -1, 0 or 1; raises for values Ruby would not compare.
      def compare(l, r, node)
        case l
        when Integer
          case r
          when Integer then return l <=> r
          when Float then return l.to_f <=> r
          end
        when Float
          case r
          when Integer then return l <=> r.to_f
          when Float then return l <=> r
          end
        when String
          case r
          when String then return l <=> r
          end
        when Time
          case r
          when Time then return l <=> r
          end
        end
        fail_at(node, "comparison of #{type_name(l)} with #{type_name(r)} failed")
      end

      def index(recv, key, node)
        case recv
        when Time then undefined(node, "[]", "Time")
        when Array
          case key
          when Integer then return recv[key]
          end
          fail_at(node, "no implicit conversion of #{type_name(key)} into Integer")
        when Hash then return recv[hash_key(key)]
        when Cybertrain::Errors then return recv[symbol_key(key)]
        when Cybertrain::Params then return recv[hash_key(key)]
        when String
          case key
          when Integer then return recv[key]
          end
          fail_at(node, "no implicit conversion of #{type_name(key)} into Integer")
        when nil then undefined(node, "[]", "nil")
        else undefined(node, "[]", type_name(recv))
        end
      end

      # Template hashes are keyed by String; :key and "key" both find "key".
      def hash_key(key)
        case key
        when String then key
        when Symbol then key.to_s
        else to_s_value(key)
        end
      end

      def symbol_key(key)
        case key
        when Symbol then key
        when String then key.to_sym
        else to_s_value(key).to_sym
        end
      end

      # --- per-type method tables -------------------------------------------

      def safe_string_method(s, sym, name, node)
        case sym
        when :to_s then s
        when :html_safe? then true
        when :size, :length then s.to_s.length
        when :empty? then s.to_s.empty?
        else undefined(node, name, "SafeString")
        end
      end

      def string_method(s, sym, name, args, node)
        case sym
        when :to_s then s
        when :upcase then s.upcase
        when :downcase then s.downcase
        when :capitalize then s.capitalize
        when :strip then s.strip
        when :size, :length then s.length
        when :empty? then s.empty?
        when :to_i then s.to_i
        when :html_safe then SafeString.new(s)
        when :html_safe? then false
        # String#include? with a polymorphic argument mis-dispatches once
        # SafeString exists (spikes/NOTES.md rule 29): go through #index.
        when :include? then !s.index(string_arg(args, 0, node, name)).nil?
        when :start_with? then s.start_with?(string_arg(args, 0, node, name))
        when :end_with? then s.end_with?(string_arg(args, 0, node, name))
        else undefined(node, name, "String")
        end
      end

      def integer_method(n, sym, name, args, node)
        case sym
        when :to_s then n.to_s
        when :to_i then n
        when :to_f then n.to_f
        when :zero? then n == 0
        when :positive? then n > 0
        when :negative? then n < 0
        when :abs then n.abs
        else undefined(node, name, "Integer")
        end
      end

      def float_method(f, sym, name, args, node)
        case sym
        when :to_s then f.to_s
        when :to_i then f.to_i
        when :to_f then f
        when :zero? then f == 0.0
        when :positive? then f > 0.0
        when :negative? then f < 0.0
        when :abs then f.abs
        when :round then args.empty? ? f.round : f.round(int_arg(args, 0, node, name))
        when :floor then f.floor
        when :ceil then f.ceil
        else undefined(node, name, "Float")
        end
      end

      def time_method(t, sym, name, args, node)
        case sym
        when :year then t.year
        when :month then t.month
        when :day then t.day
        when :hour then t.hour
        when :min then t.min
        when :sec then t.sec
        when :strftime then t.strftime(string_arg(args, 0, node, name))
        when :to_s then t.to_s
        when :to_i then t.to_i
        else undefined(node, name, "Time")
        end
      end

      def array_method(a, sym, name, args, node)
        case sym
        when :size, :length, :count then a.size
        when :empty? then a.empty?
        when :any?
          found = false
          a.each { |x| found = true if truthy?(x) }
          found
        when :first then a.first
        when :last then a.last
        when :reverse then a.reverse
        # Array#include? on a polymorphic receiver mis-dispatches
        # (spikes/NOTES.md rule 14): compare element by element.
        when :include?
          fail_at(node, "wrong number of arguments for 'include?'") if args.empty?
          needle = args[0]
          found = false
          a.each { |x| found = true if x == needle }
          found
        when :join
          sep = args.empty? ? "" : string_arg(args, 0, node, name)
          a.map { |x| to_s_value(x) }.join(sep)
        when :to_a then a
        else undefined(node, name, "Array")
        end
      end

      def hash_method(h, sym, name, args, node)
        case sym
        when :[]
          fail_at(node, "wrong number of arguments for '[]'") if args.empty?
          h[hash_key(args[0])]
        when :key?
          fail_at(node, "wrong number of arguments for 'key?'") if args.empty?
          key_in?(h, hash_key(args[0]))
        when :fetch
          fail_at(node, "wrong number of arguments for 'fetch'") if args.empty?
          key = hash_key(args[0])
          return h[key] if key_in?(h, key)
          return args[1] if args.size > 1
          fail_at(node, "key not found: #{inspect_value(args[0])}")
        when :size, :length, :count then h.size
        when :empty? then h.empty?
        when :any? then !h.empty?
        when :keys then h.keys
        when :values then h.values
        else undefined(node, name, "Hash")
        end
      end

      def errors_method(e, sym, name, args, node)
        case sym
        when :any? then e.any?
        when :empty? then e.empty?
        when :count, :size then e.count
        when :full_messages then e.full_messages
        when :[]
          fail_at(node, "wrong number of arguments for '[]'") if args.empty?
          e[symbol_key(args[0])]
        when :key?, :include?
          fail_at(node, "wrong number of arguments for '#{name}'") if args.empty?
          e.key?(symbol_key(args[0]))
        else undefined(node, name, "Errors")
        end
      end

      def params_method(p, sym, name, args, node)
        case sym
        when :[]
          fail_at(node, "wrong number of arguments for '[]'") if args.empty?
          p[hash_key(args[0])]
        when :key?
          fail_at(node, "wrong number of arguments for 'key?'") if args.empty?
          p.key?(hash_key(args[0]))
        when :empty? then p.empty?
        else undefined(node, name, "Params")
        end
      end

      # Generated models answer by name: columns (read_attribute), then
      # associations (read_association), then the arity-0 methods the model
      # generator found in app/models (call_view_method).
      def model_method(rec, sym, name, node)
        case sym
        when :id then return rec.id
        when :persisted? then return rec.persisted?
        when :new_record? then return rec.new_record?
        when :to_param then return rec.to_param
        when :errors then return rec.errors
        end
        v = rec.read_attribute(sym)
        return v unless v.nil?

        v = rec.read_association(sym)
        return v unless v.nil?

        v = rec.call_view_method(sym)
        return v unless v.nil?

        undefined(node, name, rec.class.name) unless rec.attribute_or_method?(sym)
        nil
      end
    end
  end
end
