# Cybertrain::Template AST -- what the parser produces: one readable class
# per construct. The interpreter never walks these; Compile converts them
# once into monomorphic INodes (cybertrain/template/inode.rb), because
# evaluating a class-per-node tree costs a polymorphic dispatch per node
# under Spinel (2.7x slower, spikes/NOTES.md spike 3).
#
# Hash literal pairs and keyword arguments are kept as two parallel typed
# Arrays (keys Array<String>, values Array<Node>) rather than an Array of
# [String, Node] pairs, which Spinel would widen to a polymorphic Array.
module Cybertrain
  module Template
    class SyntaxError < StandardError
    end

    class RuntimeError < StandardError
    end

    class Node
      # A typed empty Array<Node> (spikes/NOTES.md rule 9).
      def self.list = Array.new(0) { Node.new }

      # "(+ a (* b c))": a compact dump the parser tests compare against.
      def to_sexp = "?"
    end

    def self.sexp_list(nodes)
      nodes.map { |n| n.to_sexp }.join(" ")
    end

    # --- template structure ----------------------------------------------

    class TextNode < Node
      attr_reader :text

      def initialize(text)
        @text = text
      end

      def to_sexp = "(text #{@text.inspect})"
    end

    # <%= expr %> (escaped) and <%== expr %> (raw)
    class OutputNode < Node
      attr_reader :expr, :raw, :line

      def initialize(expr, raw, line)
        @expr = expr
        @raw = raw
        @line = line
      end

      def to_sexp = "(#{@raw ? "raw" : "out"} #{@expr.to_sexp})"
    end

    # <% expr %>: evaluated for its side effect, output discarded.
    class StatementNode < Node
      attr_reader :expr, :line

      def initialize(expr, line)
        @expr = expr
        @line = line
      end

      def to_sexp = "(stmt #{@expr.to_sexp})"
    end

    # <% total = expr %>: sets a template local.
    class AssignNode < Node
      attr_reader :var_name, :expr

      def initialize(var_name, expr)
        @var_name = var_name
        @expr = expr
      end

      def to_sexp = "(= #{@var_name} #{@expr.to_sexp})"
    end

    # if/elsif/else: the elsif branches are two parallel typed Arrays.
    class IfNode < Node
      attr_reader :cond, :then_nodes, :elsif_conds, :elsif_bodies, :else_nodes, :line

      def initialize(cond, line)
        @cond = cond
        @line = line
        @then_nodes = Node.list
        @elsif_conds = Node.list
        @elsif_bodies = Array.new(0) { Node.list }
        @else_nodes = Node.list
      end

      def to_sexp
        s = +"(if #{@cond.to_sexp} (#{Cybertrain::Template.sexp_list(@then_nodes)})"
        @elsif_conds.each_with_index do |c, i|
          s << " (elsif #{c.to_sexp} (#{Cybertrain::Template.sexp_list(@elsif_bodies[i])}))"
        end
        s << " (else #{Cybertrain::Template.sexp_list(@else_nodes)})" unless @else_nodes.empty?
        s << ")"
        s
      end
    end

    class UnlessNode < Node
      attr_reader :cond, :then_nodes, :else_nodes, :line

      def initialize(cond, line)
        @cond = cond
        @line = line
        @then_nodes = Node.list
        @else_nodes = Node.list
      end

      def to_sexp
        s = +"(unless #{@cond.to_sexp} (#{Cybertrain::Template.sexp_list(@then_nodes)})"
        s << " (else #{Cybertrain::Template.sexp_list(@else_nodes)})" unless @else_nodes.empty?
        s << ")"
        s
      end
    end

    # x.each do |a| ... end, x.each do |k, v| ... end,
    # x.each_with_index do |item, i| ... end
    class EachNode < Node
      attr_reader :iter_expr, :vars, :body_nodes, :with_index, :line

      def initialize(iter_expr, vars, with_index, line)
        @iter_expr = iter_expr
        @vars = vars
        @with_index = with_index
        @line = line
        @body_nodes = Node.list
      end

      def to_sexp
        "(#{@with_index ? "each_with_index" : "each"} #{@iter_expr.to_sexp} |#{@vars.join(", ")}| (#{Cybertrain::Template.sexp_list(@body_nodes)}))"
      end
    end

    # helper(...) do |f| ... end, as <%= %> (output) or <% %> (discarded)
    class BlockCallNode < Node
      attr_reader :call_expr, :params, :body_nodes, :output, :line

      def initialize(call_expr, params, output, line)
        @call_expr = call_expr
        @params = params
        @output = output
        @line = line
        @body_nodes = Node.list
      end

      def to_sexp
        "(block #{@call_expr.to_sexp} |#{@params.join(", ")}| (#{Cybertrain::Template.sexp_list(@body_nodes)}))"
      end
    end

    # --- expressions -----------------------------------------------------

    # Literal accessors carry distinct names (str_value, int_value, ...):
    # one `value` returning String here and Integer there would share an
    # inferred return type across the Node hierarchy (spikes/NOTES.md rule 10).
    class StrLit < Node
      attr_reader :str_value

      def initialize(str_value)
        @str_value = str_value
      end

      def to_sexp = @str_value.inspect
    end

    class IntLit < Node
      attr_reader :int_value

      def initialize(int_value)
        @int_value = int_value
      end

      def to_sexp = @int_value.to_s
    end

    class FloatLit < Node
      attr_reader :float_value

      def initialize(float_value)
        @float_value = float_value
      end

      def to_sexp = @float_value.to_s
    end

    class SymLit < Node
      attr_reader :sym_name   # without the colon

      def initialize(sym_name)
        @sym_name = sym_name
      end

      def to_sexp = ":#{@sym_name}"
    end

    class NilLit < Node
      def to_sexp = "nil"
    end

    class TrueLit < Node
      def to_sexp = "true"
    end

    class FalseLit < Node
      def to_sexp = "false"
    end

    class ArrayLit < Node
      attr_reader :items

      def initialize(items)
        @items = items
      end

      def to_sexp = "[#{Cybertrain::Template.sexp_list(@items)}]"
    end

    # (not keys/values/index: accessors named like core Hash/String methods
    # confuse Spinel's dispatch on a polymorphic receiver)
    class HashLit < Node
      attr_reader :key_names, :value_nodes

      def initialize(key_names, value_nodes)
        @key_names = key_names
        @value_nodes = value_nodes
      end

      def to_sexp
        parts = Array.new(0) { "" }
        @key_names.each_with_index { |k, i| parts << "#{k}: #{@value_nodes[i].to_sexp}" }
        "{#{parts.join(", ")}}"
      end
    end

    class IVar < Node
      attr_reader :name   # without the "@"

      def initialize(name)
        @name = name
      end

      def to_sexp = "@#{@name}"
    end

    class LVar < Node
      attr_reader :name, :line

      def initialize(name, line)
        @name = name
        @line = line
      end

      def to_sexp = @name
    end

    # recv.name(args, key: value), recv&.name, or a helper call name(args)
    # when recv is nil.
    class Call < Node
      attr_reader :recv, :name, :args, :kwarg_names, :kwarg_values, :safe_nav, :line

      def initialize(recv, name, args, kwarg_names, kwarg_values, safe_nav, line)
        @recv = recv
        @name = name
        @args = args
        @kwarg_names = kwarg_names
        @kwarg_values = kwarg_values
        @safe_nav = safe_nav
        @line = line
      end

      def to_sexp
        s = +"(#{@safe_nav ? "&." : "."}#{@name}"
        r = @recv
        s << " #{r.nil? ? "_" : r.to_sexp}"
        @args.each { |a| s << " #{a.to_sexp}" }
        @kwarg_names.each_with_index { |k, i| s << " #{k}: #{@kwarg_values[i].to_sexp}" }
        s << ")"
        s
      end
    end

    # + - * / % == != < > <= >= && ||
    class BinOp < Node
      attr_reader :op, :left, :right, :line

      def initialize(op, left, right, line)
        @op = op
        @left = left
        @right = right
        @line = line
      end

      def to_sexp = "(#{@op} #{@left.to_sexp} #{@right.to_sexp})"
    end

    class NotNode < Node
      attr_reader :expr

      def initialize(expr)
        @expr = expr
      end

      def to_sexp = "(! #{@expr.to_sexp})"
    end

    class Ternary < Node
      attr_reader :cond, :then_expr, :else_expr

      def initialize(cond, then_expr, else_expr)
        @cond = cond
        @then_expr = then_expr
        @else_expr = else_expr
      end

      def to_sexp = "(?: #{@cond.to_sexp} #{@then_expr.to_sexp} #{@else_expr.to_sexp})"
    end

    # "a #{b} c": parts are StrLit pieces and expressions, in order.
    class Interp < Node
      attr_reader :parts

      def initialize(parts)
        @parts = parts
      end

      def to_sexp = "(str #{Cybertrain::Template.sexp_list(@parts)})"
    end

    # target[index] (not `recv`: Call#recv is nullable, this one is not)
    class IndexNode < Node
      attr_reader :index_target, :index_expr, :line

      def initialize(target, index_expr, line)
        @index_target = target
        @index_expr = index_expr
        @line = line
      end

      def to_sexp = "([] #{@index_target.to_sexp} #{@index_expr.to_sexp})"
    end
  end
end
