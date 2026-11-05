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
require "cybertrain/template/limits"

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
      # FormBuilder, the `tag` builder): subclasses narrow `recv` with `case`
      # and dispatch. block: the call's K_BLOCK INode (`tag.div do ... end`,
      # `x.y { |a| ... }`), else nil; render it with interp.capture(block, env).
      def call_object_method(recv, name_sym, name_str, args, kwargs, block, interp, env)
        raise RuntimeError, "undefined method '#{name_str}' for #{recv.class.name}"
      end
    end

    class Interpreter
      # max_depth: Views.configure(root, max_render_depth: n) for an app whose
      # partials legitimately recurse (threaded comments, a tree menu) past
      # the default; the page is depth 1 (the layout renders after the page
      # has returned, so it never nests on top of it). The
      # default is Template::MAX_RENDER_DEPTH (template/limits.rb, where the
      # reasoning for 12 lives), the one name the limit has: written bare
      # here and in Engine because `Template::` inside module
      # Cybertrain::Template names the Template class (engine.rb), not the
      # module; the lexical lookup reaches the constant.
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
          raise RuntimeError, "partial nesting too deep (> #{@max_depth}): #{template.name} rendered from #{@name} (max_render_depth is #{@max_depth}; raise Config#max_render_depth for partials that legitimately recurse deeper)"
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
        when SafeString then v.to_s
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

      # Every branch is statically a String: a bare `v` stays polymorphic and
      # drags every `<<` of the result onto Spinel's boxed slow path. Strings
      # and SafeStrings go through to_s, which is typed (every to_s in the
      # program returns a String, see Html.escape) and returns the String
      # itself where an interpolation would copy it. Spinel's interpolation
      # does not call a user-defined to_s, hence "#{v.to_s}" for objects.
      def to_s_value(v)
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
        when Array then "[#{v.map { |x| inspect_value(x) }.join(", ")}]"
        when Cybertrain::Model then "#<#{v.class.name} id: #{v.id}>"
        else "#{v.to_s}"
        end
      end

      # The value of expression node n in env: a literal, a local or ivar
      # of the template, a helper or method call, an operator, an Array or
      # Hash literal. Recursive, and called for every expression a template
      # evaluates, so it holds no block (see the Hash literal case). An
      # unknown node kind raises RuntimeError through fail_at.
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
          parts = n.ikids
          j = 0
          while j < parts.size
            buf << to_s_value(eval_expr(parts[j], env))
            j += 1
          end
          buf
        elsif k == INode::K_INDEX then index(eval_expr(n.ia, env), eval_expr(n.ib, env), n)
        elsif k == INode::K_FLOAT then n.iflt
        elsif k == INode::K_ARRAY
          items = []
          elems = n.ikids
          j = 0
          while j < elems.size
            items << eval_expr(elems[j], env)
            j += 1
          end
          items
        elsif k == INode::K_HASH
          # while, not each_with_index: a block that captures n, env and
          # hash makes Spinel allocate a heap cell for each of them on every
          # call of eval_expr, Hash literal or not (three objects per
          # expression evaluated; docs/performance-next.md 9).
          hash = {}
          keys = n.ipairs
          vals = n.ikids
          j = 0
          while j < keys.size
            hash[keys[j]] = eval_expr(vals[j], env)
            j += 1
          end
          hash
        else
          fail_at(n, "cannot evaluate node kind #{k}")
        end
      end

      # block: the call's K_BLOCK INode (`items.map { |x| ... }`), else nil.
      # Array and Hash take blocks on a fixed set of methods
      # (array_block_method, hash_block_method); objects with no table get
      # the block in call_object_method; any other block is a SyntaxError.
      def call_method(recv, name_sym, name_str, args, kwargs, block, env, node)
        case name_sym
        when :nil?, :present?, :blank?
          no_block(node, type_name(recv), name_str) unless block.nil?
        end
        case name_sym
        when :nil? then return recv.nil?
        when :present? then return !blank?(recv)
        when :blank? then return blank?(recv)
        end

        unless block.nil?
          # A method the type does not have at all is the ordinary
          # "undefined method" (the blockless call raises it); one it has
          # takes no block. Time before Array (spikes/NOTES.md rule 8).
          case recv
          when Time
            call_method(recv, name_sym, name_str, args, kwargs, nil, env, node)
            no_block(node, "Time", name_str)
          when Array then return array_block_method(recv, name_sym, name_str, args, block, env, node)
          when Hash then return hash_block_method(recv, name_sym, name_str, args, block, env, node)
          when SafeString, String, Integer, Float, Symbol, Cybertrain::Errors, Cybertrain::Params, Cybertrain::Model, nil, true, false
            call_method(recv, name_sym, name_str, args, kwargs, nil, env, node)
            no_block(node, type_name(recv), name_str)
          end
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
            result = @helpers.call_object_method(recv, name_sym, name_str, args, kwargs, block, self, env)
          rescue Cybertrain::Template::CallSyntaxError => e
            raise SyntaxError, "#{@name}:#{node.iline}: #{e.message}"
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
        idx = 0
        count = nodes.size
        while idx < count
          n = nodes[idx]
          idx += 1
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
          elsif k == INode::K_CASE then exec_case(n, env)
          end
        end
        nil
      end

      # case/when: the subject is evaluated once, then each branch's values in
      # order until one equals it (case_equal?); else runs when none does.
      # The slot layout is in cybertrain/template/inode.rb.
      def exec_case(n, env)
        subject = eval_expr(n.ia, env)
        branches = n.ikids
        i = 0
        while i + 1 < branches.size
          values = branches[i].ikids
          j = 0
          while j < values.size
            if case_equal?(subject, eval_expr(values[j], env))
              exec_nodes(branches[i + 1].ikids, env)
              return nil
            end
            j += 1
          end
          i += 2
        end
        exec_nodes(n.ikids2, env)
        nil
      end

      # The template's `==`, with numbers compared by value (Integer 1
      # matches Float 1.0, as Ruby's `1.0 === 1` does).
      def case_equal?(l, r)
        case l
        when SafeString, String
          case r
          when SafeString, String then return l.to_s == r.to_s
          end
        when Integer
          case r
          when Integer then return l == r
          when Float then return l.to_f == r
          end
        when Float
          case r
          when Integer then return l == r.to_f
          when Float then return l == r
          end
        end
        l == r
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
          while i < coll.size
            item = coll[i]
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
        i = 0
        while i < names.size
          name = names[i]
          saved[name] = env[name] if key_in?(env, name)
          i += 1
        end
        saved
      end

      def restore_locals(env, names, saved)
        i = 0
        while i < names.size
          name = names[i]
          if saved.key?(name)
            env[name] = saved[name]
          else
            env.delete(name)
          end
          i += 1
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
        i = 0
        while i < fresh.size
          env[fresh[i]] = nil
          i += 1
        end
        nil
      end

      def drop_locals(env, fresh)
        i = 0
        while i < fresh.size
          env.delete(fresh[i])
          i += 1
        end
        nil
      end

      def eval_call(n, env)
        return eval_helper_call(n, env) if n.ia.ikind == INode::K_NONE

        recv = eval_expr(n.ia, env)
        return nil if recv.nil? && n.iint == 1

        blk = n.ib
        block = blk.ikind == INode::K_BLOCK ? blk : nil
        call_method(recv, n.isym, n.istr, eval_args(n, env), eval_kwargs(n, env), block, env, n)
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
        rescue Cybertrain::Template::CallSyntaxError => e
          raise SyntaxError, "#{@name}:#{node.iline}: #{e.message}"
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

        # while, not each: a block here was a Proc and its closure cells per
        # call, and this runs for nearly every call in a template.
        kids = n.ikids
        args = []
        i = 0
        while i < kids.size
          args << eval_expr(kids[i], env)
          i += 1
        end
        args
      end

      def eval_kwargs(n, env)
        return @no_kwargs if n.ipairs.empty?

        keys = n.ipairs
        values = n.ikids2
        kwargs = {}
        i = 0
        while i < keys.size
          kwargs[keys[i]] = eval_expr(values[i], env)
          i += 1
        end
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

      # A block given to a method that takes none: the template is wrong
      # whatever the data, so it is reported as a SyntaxError (at run time:
      # only then is the receiver's type known).
      def no_block(node, type, name)
        raise SyntaxError, "#{@name}:#{node.iline}: #{type}##{name} takes no block"
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
        when :html_safe then SafeString.of(s.to_s)
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
        when :sum
          no_args(args, node, name)
          sum_values(a, node)
        when :min
          no_args(args, node, name)
          extreme(a, a, -1, node)
        when :max
          no_args(args, node, name)
          extreme(a, a, 1, node)
        when :sort
          no_args(args, node, name)
          pick(a, sorted_indices(a, node))
        when :uniq
          no_args(args, node, name)
          uniq_values(a)
        when :compact
          no_args(args, node, name)
          out = []
          a.each do |x|
            case x
            when nil then nil
            else out << x
            end
          end
          out
        when :flatten
          no_args(args, node, name)
          out = []
          flatten_into(out, a)
          out
        when :take
          n = size_arg(args, node, name)
          out = []
          i = 0
          while i < n && i < a.size
            out << a[i]
            i += 1
          end
          out
        when :drop
          out = []
          i = size_arg(args, node, name)
          while i < a.size
            out << a[i]
            i += 1
          end
          out
        when :each_slice then slices(a, args, node)
        when :zip
          fail_at(node, "wrong number of arguments for 'zip'") if args.empty?
          other = args[0]
          case other
          when Time then fail_at(node, "'zip' expects an Array, got Time")
          when Array then return zip_values(a, other)
          end
          fail_at(node, "'zip' expects an Array, got #{type_name(other)}")
        else undefined(node, name, "Array")
        end
      end

      # --- blocks ------------------------------------------------------------

      # The methods an Array takes a block on. The block's value for an
      # element is block_value's; `each` and `each_slice` iterate with a
      # `do` block in a <% %> tag instead (EachNode).
      def array_block_method(a, sym, name, args, block, env, node)
        # None of the block methods takes an argument: `sum(0.0) { ... }`
        # would silently drop the 0.0, so it is refused as `sum(10)` is.
        case sym
        when :map, :collect, :select, :filter, :reject, :find, :detect, :any?, :all?, :none?, :count, :sum, :sort_by, :min_by, :max_by, :group_by
          no_args(args, node, name)
        end
        case sym
        when :map, :collect then block_values(block, env, a, name, node)
        when :select, :filter then pick_truthy(a, block_values(block, env, a, name, node), true)
        when :reject then pick_truthy(a, block_values(block, env, a, name, node), false)
        when :find, :detect
          i = block_find(block, env, a, true, name, node)
          i < 0 ? nil : a[i]
        when :any? then block_find(block, env, a, true, name, node) >= 0
        when :all? then block_find(block, env, a, false, name, node) < 0
        when :none? then block_find(block, env, a, true, name, node) < 0
        when :count then pick_truthy(a, block_values(block, env, a, name, node), true).size
        when :sum then sum_values(block_values(block, env, a, name, node), node)
        when :sort_by then pick(a, sorted_indices(block_values(block, env, a, name, node), node))
        when :min_by then extreme(a, block_values(block, env, a, name, node), -1, node)
        when :max_by then extreme(a, block_values(block, env, a, name, node), 1, node)
        when :group_by then group_values(a, block_values(block, env, a, name, node))
        when :each, :each_with_index, :each_slice
          raise SyntaxError, "#{@name}:#{node.iline}: #{name} takes a do block in a <% %> tag (<% x.each_slice(n) do |y| %>...<% end %> for each_slice)"
        else
          array_method(a, sym, name, args, node)
          no_block(node, "Array", name)
        end
      end

      # A Hash's block methods see [key, value] pairs (two block parameters
      # take them apart); select and reject answer a Hash, the rest what the
      # Array method does over the pairs.
      def hash_block_method(h, sym, name, args, block, env, node)
        case sym
        when :select, :filter, :reject
          no_args(args, node, name)
          pairs = hash_pairs(h)
          keep = pick_truthy(pairs, block_values(block, env, pairs, name, node), sym != :reject)
          out = {}
          keep.each do |pair|
            case pair
            when Array then out[hash_key(pair[0])] = pair[1]
            end
          end
          out
        when :map, :collect, :find, :detect, :any?, :all?, :none?, :count, :sum, :sort_by, :min_by, :max_by, :group_by
          array_block_method(hash_pairs(h), sym, name, args, block, env, node)
        else
          hash_method(h, sym, name, args, node)
          no_block(node, "Hash", name)
        end
      end

      def hash_pairs(h)
        pairs = []
        h.each do |key, value|
          pair = []
          pair << key
          pair << value
          pairs << pair
        end
        pairs
      end

      # The block's value for every item, in order. Block parameters shadow
      # outer names for the call and are restored after it, as each's are.
      # A block that raises still restores them (and the output buffer):
      # the console keeps one environment from line to line. Plain methods,
      # not yielding ones, so the rescue is allowed (spikes/NOTES.md rules
      # 32 and 45).
      def block_values(block, env, items, name, node)
        names = block.inames
        saved = save_locals(env, names)
        fresh = fresh_locals(env, block.ipairs)
        saved_out = @out
        out = []
        begin
          i = 0
          while i < items.size
            out << block_value(block, env, fresh, items[i], name, node)
            i += 1
          end
        rescue StandardError => e
          @out = saved_out
          restore_locals(env, names, saved)
          drop_locals(env, fresh)
          raise e
        end
        restore_locals(env, names, saved)
        drop_locals(env, fresh)
        out
      end

      # The index of the first item whose block value is truthy (want true)
      # or falsy (want false), or -1; stops there, as Ruby's find and any? do.
      def block_find(block, env, items, want, name, node)
        names = block.inames
        saved = save_locals(env, names)
        fresh = fresh_locals(env, block.ipairs)
        saved_out = @out
        found = -1
        begin
          i = 0
          while found < 0 && i < items.size
            found = i if truthy?(block_value(block, env, fresh, items[i], name, node)) == want
            i += 1
          end
        rescue StandardError => e
          @out = saved_out
          restore_locals(env, names, saved)
          drop_locals(env, fresh)
          raise e
        end
        restore_locals(env, names, saved)
        drop_locals(env, fresh)
        found
      end

      # Binds item to the block's parameters (two parameters take an Array
      # item apart, as each does) and evaluates the block: a { } block's
      # expression, or a do block's statements and then its last one, whose
      # value it is. What the statements print is discarded.
      def block_value(block, env, fresh, item, name, node)
        names = block.inames
        if names.size > 1
          # Time before Array (spikes/NOTES.md rule 8).
          case item
          when Time
            env[names[0]] = item
            env[names[1]] = nil
          when Array
            env[names[0]] = item[0]
            env[names[1]] = item[1]
          else
            env[names[0]] = item
            env[names[1]] = nil
          end
        elsif names.size == 1
          env[names[0]] = item
        end
        reset_locals(env, fresh)
        value = block.ic
        fail_at(node, "#{name}'s block must end in a value") if value.ikind == INode::K_NONE
        before = block.ikids2
        unless before.empty?
          saved_out = @out
          @out = String.new
          exec_nodes(before, env)
          @out = saved_out
        end
        eval_expr(value, env)
      end

      def pick_truthy(items, values, want)
        out = []
        i = 0
        while i < items.size
          out << items[i] if truthy?(values[i]) == want
          i += 1
        end
        out
      end

      def pick(items, indices)
        out = []
        i = 0
        while i < indices.size
          out << items[indices[i]]
          i += 1
        end
        out
      end

      # Integers add to an Integer; from the first Float on the sum is a
      # Float, added with Kahan-Babuska compensation as CRuby's Array#sum
      # does (so [0.1, 0.2, 0.3].sum is 0.6 on both runtimes); an empty list
      # is 0. Strings are refused (Ruby's sum would need a "" start).
      def sum_values(values, node)
        int_total = 0
        f = 0.0
        c = 0.0
        float = false
        i = 0
        while i < values.size
          v = values[i]
          x = 0.0
          case v
          when Integer
            if float
              x = v.to_f
            else
              int_total += v
            end
          when Float
            unless float
              float = true
              f = int_total.to_f
            end
            x = v
          when SafeString, String then fail_at(node, "sum: use join for Strings")
          else fail_at(node, "sum: cannot add #{type_name(v)}")
          end
          if float
            # NaN and infinities as CRuby: x - x is NaN for both.
            if f != f
              nil
            elsif x != x
              f = x
            elsif x - x != 0.0
              f = (f - f != 0.0 && (f > 0.0) != (x > 0.0)) ? 0.0 / 0.0 : x
            elsif f - f != 0.0
              nil
            else
              t = f + x
              if f.abs >= x.abs
                c += (f - t) + x
              else
                c += (x - t) + f
              end
              f = t
            end
          end
          i += 1
        end
        return f + c if float

        int_total
      end

      def no_args(args, node, name)
        fail_at(node, "wrong number of arguments for '#{name}'") unless args.empty?
        nil
      end

      # The item whose key is smallest (dir -1) or largest (dir 1), the first
      # of equals, or nil for no items; keys compare as `<` does.
      def extreme(items, keys, dir, node)
        return nil if items.empty?

        best = 0
        i = 1
        while i < keys.size
          best = i if compare(keys[i], keys[best], node) * dir > 0
          i += 1
        end
        items[best]
      end

      # The indices of keys in ascending order, equal keys keeping their
      # order: a merge sort of our own, so that CRuby and Spinel agree on
      # ties (neither runtime's sort is stable).
      def sorted_indices(keys, node)
        n = keys.size
        src = Array.new(0) { 0 }
        i = 0
        while i < n
          src << i
          i += 1
        end
        width = 1
        while width < n
          dst = Array.new(0) { 0 }
          lo = 0
          while lo < n
            mid = lo + width
            mid = n if mid > n
            hi = lo + width + width
            hi = n if hi > n
            a = lo
            b = mid
            while a < mid && b < hi
              if compare(keys[src[a]], keys[src[b]], node) > 0
                dst << src[b]
                b += 1
              else
                dst << src[a]
                a += 1
              end
            end
            while a < mid
              dst << src[a]
              a += 1
            end
            while b < hi
              dst << src[b]
              b += 1
            end
            lo = hi
          end
          src = dst
          width += width
        end
        src
      end

      # group_by: a Hash from each key (as a String, like every template
      # Hash) to the items with that key, in first-seen order.
      def group_values(items, keys)
        groups = {}
        i = 0
        while i < items.size
          key = hash_key(keys[i])
          list = groups[key]
          if list.nil?
            list = []
            groups[key] = list
          end
          list << items[i]
          i += 1
        end
        groups
      end

      # Ruby's uniq compares with eql?: 1 and 1.0 stay apart.
      def uniq_values(a)
        out = []
        a.each do |x|
          seen = false
          out.each { |y| seen = true if type_name(x) == type_name(y) && x == y }
          out << x unless seen
        end
        out
      end

      def flatten_into(out, a)
        a.each do |x|
          case x
          when Time then out << x
          when Array then flatten_into(out, x)
          else out << x
          end
        end
        nil
      end

      def slices(a, args, node)
        n = int_arg(args, 0, node, "each_slice")
        fail_at(node, "'each_slice' expects a positive size, got #{n}") if n <= 0
        out = []
        i = 0
        while i < a.size
          slice = []
          j = i
          while j < i + n && j < a.size
            slice << a[j]
            j += 1
          end
          out << slice
          i += n
        end
        out
      end

      def zip_values(a, other)
        out = []
        i = 0
        while i < a.size
          pair = []
          pair << a[i]
          pair << other[i]
          out << pair
          i += 1
        end
        out
      end

      def size_arg(args, node, name)
        n = int_arg(args, 0, node, name)
        fail_at(node, "'#{name}' expects a non-negative size, got #{n}") if n < 0
        n
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
        when :to_a then hash_pairs(h)
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
