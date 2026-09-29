# Cybertrain::Template::INode -- the tree the interpreter actually walks.
#
# The parser's class-per-node AST reads well but costs a polymorphic dispatch
# per node under Spinel (2.7x slower, spikes/NOTES.md spike 3). Compile
# converts it once into INodes: one class, an Integer kind, and typed slots
# whose meaning depends on the kind. Absent children are the LEAF / NO_KIDS
# sentinels, never nil, so every slot keeps a single static type.
#
# Every accessor carries an "i" prefix (ikind, istr, ia ...): the interpreter
# reads INodes out of polymorphic Arrays, and Spinel types `n.kind` as the
# union of every class's `kind` (Token#kind is a Symbol), which turned each
# kind test into a boxed comparison (spikes/NOTES.md rule 10).
#
#   ikind          slots used
#   K_TEXT         istr (the text)
#   K_OUT(_RAW)    ia (expression)
#   K_STMT         ia (expression, value discarded)
#   K_ASSIGN       istr (local name), ia (expression)
#   K_IF/K_UNLESS  ia (condition), ikids (then), ikids2 (else; an elsif is a nested K_IF)
#   K_EACH         ia (collection), inames (block params), ikids (body), iint (1 = each_with_index),
#                  ipairs (locals assigned in the body: block-local unless they exist outside)
#   K_BLOCK_CALL   ia (the K_CALL), inames (block params), ikids (body), iint (1 = <%= %>), ipairs (as K_EACH)
#   K_CALL         ia (receiver, LEAF for a helper call), istr/isym (method name),
#                  ikids (positional args), ipairs/ikids2 (keyword names/values), iint (1 = &.)
#   K_STR/INT/FLOAT/SYM   istr / iint / iflt / isym
#   K_IVAR/K_LVAR  istr (name without "@")
#   K_ARRAY        ikids ; K_HASH ipairs (keys) + ikids (values) ; K_INTERP ikids
#   binary ops     ia, ib ; istr (the operator, for error messages)
#   K_NOT          ia ; K_TERNARY ia ? ib : ic ; K_INDEX ia[ib]
# iline is the template line for error messages (0 where none is needed).
require "cybertrain/template/ast"

module Cybertrain
  module Template
    class INode
      # Frequent kinds first: the interpreter tests them in this order.
      K_TEXT = 0
      K_OUT = 1
      K_CALL = 2
      K_LVAR = 3
      K_IVAR = 4
      K_STR = 5
      K_OUT_RAW = 6
      K_IF = 7
      K_UNLESS = 8
      K_EACH = 9
      K_BLOCK_CALL = 10
      K_STMT = 11
      K_ASSIGN = 12
      K_INT = 13
      K_FLOAT = 14
      K_SYM = 15
      K_NIL = 16
      K_TRUE = 17
      K_FALSE = 18
      K_ARRAY = 19
      K_HASH = 20
      K_AND = 21
      K_OR = 22
      K_EQ = 23
      K_NEQ = 24
      K_LT = 25
      K_GT = 26
      K_LE = 27
      K_GE = 28
      K_ADD = 29
      K_SUB = 30
      K_MUL = 31
      K_DIV = 32
      K_MOD = 33
      K_NOT = 34
      K_TERNARY = 35
      K_INTERP = 36
      K_INDEX = 37
      K_NONE = 38   # LEAF: "no node here"

      # Shared, never mutated: Compile always builds new Arrays for real lists.
      # The seed blocks never run; they only give the Arrays their element
      # type (spikes/NOTES.md rule 9).
      NO_NAMES = Array.new(0) { "" }
      NO_KIDS = Array.new(0) { INode.new(K_NONE, 0) }

      attr_accessor :ikind, :istr, :iint, :iflt, :isym, :ia, :ib, :ic, :ikids, :ikids2, :inames, :ipairs, :iline

      # The child slots start out pointing at the node itself so that they
      # are never nil (LEAF is built this way); Compile.node then points them
      # at LEAF.
      def initialize(kind, line)
        @ikind = kind
        @iline = line
        @istr = ""
        @iint = 0
        @iflt = 0.0
        @isym = :_
        @ia = self
        @ib = self
        @ic = self
        @ikids = NO_KIDS
        @ikids2 = NO_KIDS
        @inames = NO_NAMES
        @ipairs = NO_NAMES
      end

      # A fresh, typed, empty Array<INode>.
      def self.list = Array.new(0) { INode.new(K_NONE, 0) }
    end

    INode::LEAF = INode.new(INode::K_NONE, 0)

    module Compile
      def self.convert(nodes)
        out = INode.list
        nodes.each { |n| out << convert_node(n) }
        out
      end

      def self.node(kind, line)
        n = INode.new(kind, line)
        n.ia = INode::LEAF
        n.ib = INode::LEAF
        n.ic = INode::LEAF
        n
      end

      def self.unary(kind, a, line)
        n = node(kind, line)
        n.ia = a
        n
      end

      def self.binary_kind(op)
        case op
        when "&&" then INode::K_AND
        when "||" then INode::K_OR
        when "==" then INode::K_EQ
        when "!=" then INode::K_NEQ
        when "<" then INode::K_LT
        when ">" then INode::K_GT
        when "<=" then INode::K_LE
        when ">=" then INode::K_GE
        when "+" then INode::K_ADD
        when "-" then INode::K_SUB
        when "*" then INode::K_MUL
        when "/" then INode::K_DIV
        else INode::K_MOD
        end
      end

      def self.convert_node(n)
        case n
        when TextNode
          t = node(INode::K_TEXT, 0)
          t.istr = n.text
          t
        when OutputNode
          unary(n.raw ? INode::K_OUT_RAW : INode::K_OUT, convert_node(n.expr), n.line)
        when StatementNode
          unary(INode::K_STMT, convert_node(n.expr), n.line)
        when AssignNode
          t = unary(INode::K_ASSIGN, convert_node(n.expr), 0)
          t.istr = n.var_name
          t
        when IfNode then convert_if(n)
        when UnlessNode
          t = unary(INode::K_UNLESS, convert_node(n.cond), n.line)
          t.ikids = convert(n.then_nodes)
          t.ikids2 = convert(n.else_nodes)
          t
        when EachNode
          t = unary(INode::K_EACH, convert_node(n.iter_expr), n.line)
          t.inames = n.vars
          t.ikids = convert(n.body_nodes)
          t.ipairs = assigned_names(t.ikids, t.inames)
          t.iint = n.with_index ? 1 : 0
          t
        when BlockCallNode
          t = unary(INode::K_BLOCK_CALL, convert_node(n.call_expr), n.line)
          t.inames = n.params
          t.ikids = convert(n.body_nodes)
          t.ipairs = assigned_names(t.ikids, t.inames)
          t.iint = n.output ? 1 : 0
          t
        when Call then convert_call(n)
        when LVar
          t = node(INode::K_LVAR, n.line)
          t.istr = n.name
          t
        when IVar
          t = node(INode::K_IVAR, 0)
          t.istr = n.name
          t
        when StrLit
          t = node(INode::K_STR, 0)
          t.istr = n.str_value
          t
        when IntLit
          t = node(INode::K_INT, 0)
          t.iint = n.int_value
          t
        when FloatLit
          t = node(INode::K_FLOAT, 0)
          t.iflt = n.float_value
          t
        when SymLit
          t = node(INode::K_SYM, 0)
          t.isym = n.sym_name.to_sym
          t
        when NilLit then node(INode::K_NIL, 0)
        when TrueLit then node(INode::K_TRUE, 0)
        when FalseLit then node(INode::K_FALSE, 0)
        when ArrayLit
          t = node(INode::K_ARRAY, 0)
          t.ikids = convert(n.items)
          t
        when HashLit
          t = node(INode::K_HASH, 0)
          t.ipairs = n.key_names
          t.ikids = convert(n.value_nodes)
          t
        when BinOp
          t = node(binary_kind(n.op), n.line)
          t.istr = n.op
          t.ia = convert_node(n.left)
          t.ib = convert_node(n.right)
          t
        when NotNode then unary(INode::K_NOT, convert_node(n.expr), 0)
        when Ternary
          t = unary(INode::K_TERNARY, convert_node(n.cond), 0)
          t.ib = convert_node(n.then_expr)
          t.ic = convert_node(n.else_expr)
          t
        when Interp
          t = node(INode::K_INTERP, 0)
          t.ikids = convert(n.parts)
          t
        when IndexNode
          t = unary(INode::K_INDEX, convert_node(n.index_target), n.line)
          t.ib = convert_node(n.index_expr)
          t
        else
          raise SyntaxError, "cannot compile #{n.to_sexp}"
        end
      end

      # The locals a block body assigns (through if/unless branches, but not
      # inside nested blocks, which track their own), minus its parameters.
      def self.assigned_names(kids, params)
        out = Array.new(0) { "" }
        collect_assigned(kids, params, out)
        out
      end

      def self.collect_assigned(kids, params, out)
        kids.each do |k|
          kind = k.ikind
          if kind == INode::K_ASSIGN
            name = k.istr
            out << name unless params.include?(name) || out.include?(name)
          elsif kind == INode::K_IF || kind == INode::K_UNLESS
            collect_assigned(k.ikids, params, out)
            collect_assigned(k.ikids2, params, out)
          end
        end
        nil
      end

      # The method Symbol is interned here, once per call site, so the
      # interpreter's dispatch `case`s compare Symbols instead of Strings.
      def self.convert_call(n)
        t = node(INode::K_CALL, n.line)
        t.istr = n.name
        t.isym = n.name.to_sym
        r = n.recv
        t.ia = convert_node(r) unless r.nil?
        t.ikids = convert(n.args)
        t.ipairs = n.kwarg_names
        t.ikids2 = convert(n.kwarg_values)
        t.iint = n.safe_nav ? 1 : 0
        t
      end

      # elsif chains become nested K_IFs in the else slot.
      def self.convert_if(n)
        t = unary(INode::K_IF, convert_node(n.cond), n.line)
        t.ikids = convert(n.then_nodes)
        tail = convert(n.else_nodes)
        i = n.elsif_conds.size - 1
        while i >= 0
          branch = unary(INode::K_IF, convert_node(n.elsif_conds[i]), n.line)
          branch.ikids = convert(n.elsif_bodies[i])
          branch.ikids2 = tail
          tail = INode.list
          tail << branch
          i -= 1
        end
        t.ikids2 = tail
        t
      end
    end
  end
end
