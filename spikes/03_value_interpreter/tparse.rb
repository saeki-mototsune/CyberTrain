# SPIKE (throwaway): can an ERB-style lexer + Ruby-subset expression parser compile under Spinel?
# Shared by interp_poly.rb and interp_value.rb (require_relative).

# ---------- AST ----------
class Node
  # WORKAROUND: a bare [] later aliased through accessors is inferred Array[Integer]; seed the element type.
  def self.list = Array.new(0) { Node.new }
end

class TextNode < Node
  attr_reader :text
  def initialize(text) = @text = text
end

class OutNode < Node
  attr_reader :expr, :escape
  def initialize(expr, escape)
    @expr = expr
    @escape = escape
  end
end

class StmtNode < Node
  attr_reader :expr
  def initialize(expr) = @expr = expr
end

class IfNode < Node
  attr_reader :cond, :then_body, :else_body
  def initialize(cond)
    @cond = cond
    @then_body = Node.list
    @else_body = Node.list
  end
end

class EachNode < Node
  attr_reader :coll, :var, :nodes
  def initialize(coll, var)
    @coll = coll
    @var = var
    @nodes = Node.list
  end
end

class StrLit < Node
  attr_reader :value
  def initialize(v) = @value = v
end

class IntLit < Node
  attr_reader :value
  def initialize(v) = @value = v
end

class NilLit < Node
end

class BoolLit < Node
  attr_reader :value
  def initialize(v) = @value = v
end

class IVarRef < Node
  attr_reader :name
  def initialize(n) = @name = n
end

class LVarRef < Node
  attr_reader :name
  def initialize(n) = @name = n
end

# recv is nil for a helper call
class CallNode < Node
  attr_reader :recv, :name, :sym, :args
  def initialize(recv, name, args)
    @recv = recv
    @name = name
    @sym = name.to_sym
    @args = args
  end
end

class BinNode < Node
  attr_reader :op, :lhs, :rhs
  def initialize(op, lhs, rhs)
    @op = op
    @lhs = lhs
    @rhs = rhs
  end
end

class NotNode < Node
  attr_reader :expr
  def initialize(e) = @expr = e
end

# ---------- template lexer ----------
class Chunk
  attr_reader :kind, :text # 0 text, 1 code, 2 output(escaped), 3 comment, 4 raw output
  def initialize(kind, text)
    @kind = kind
    @text = text
  end
end

def lex_template(src)
  chunks = []
  pos = 0
  n = src.length
  while pos < n
    i = src.index("<%", pos)
    if i.nil?
      chunks << Chunk.new(0, src[pos, n - pos])
      break
    end
    chunks << Chunk.new(0, src[pos, i - pos]) if i > pos
    j = src.index("%>", i + 2)
    raise "unterminated <% at #{i}" if j.nil?
    inner = src[i + 2, j - i - 2]
    kind = 1
    if inner.start_with?("==")
      kind = 4
      inner = inner[2, inner.length - 2]
    elsif inner.start_with?("=")
      kind = 2
      inner = inner[1, inner.length - 1]
    elsif inner.start_with?("#")
      kind = 3
    end
    pos = j + 2
    # trim newline after code / comment tags
    if (kind == 1 || kind == 3) && pos < n && src[pos] == "\n"
      pos += 1
    end
    chunks << Chunk.new(kind, inner.strip)
  end
  chunks
end

# ---------- expression tokenizer ----------
class Tok
  attr_reader :kind, :text # kinds: :id :ivar :int :str :op :eof
  def initialize(kind, text)
    @kind = kind
    @text = text
  end
end

def ident_char?(c)
  (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_" || c == "?"
end

def tokenize_expr(s)
  toks = []
  i = 0
  n = s.length
  while i < n
    c = s[i]
    if c == " " || c == "\t" || c == "\n"
      i += 1
    elsif c >= "0" && c <= "9"
      j = i
      j += 1 while j < n && s[j] >= "0" && s[j] <= "9"
      toks << Tok.new(:int, s[i, j - i])
      i = j
    elsif c == "\"" || c == "'"
      j = s.index(c, i + 1)
      raise "unterminated string" if j.nil?
      toks << Tok.new(:str, s[i + 1, j - i - 1])
      i = j + 1
    elsif c == "@"
      j = i + 1
      j += 1 while j < n && ident_char?(s[j])
      toks << Tok.new(:ivar, s[i + 1, j - i - 1])
      i = j
    elsif ident_char?(c)
      j = i
      j += 1 while j < n && ident_char?(s[j])
      toks << Tok.new(:id, s[i, j - i])
      i = j
    else
      two = i + 1 < n ? s[i, 2] : ""
      if two == "==" || two == "!=" || two == "&&" || two == "||"
        toks << Tok.new(:op, two)
        i += 2
      else
        toks << Tok.new(:op, c)
        i += 1
      end
    end
  end
  toks << Tok.new(:eof, "")
  toks
end

# ---------- expression parser ----------
class ExprParser
  def initialize(src)
    @toks = tokenize_expr(src)
    @pos = 0
  end

  def peek = @toks[@pos]
  def advance
    t = @toks[@pos]
    @pos += 1
    t
  end
  def accept_op(o)
    t = peek
    if t.kind == :op && t.text == o
      @pos += 1
      return true
    end
    false
  end
  def expect_op(o)
    raise "expected #{o} got #{peek.text}" unless accept_op(o)
  end

  def parse
    e = parse_or
    raise "trailing tokens: #{peek.text}" unless peek.kind == :eof
    e
  end

  def parse_or
    l = parse_and
    while accept_op("||")
      l = BinNode.new("||", l, parse_and)
    end
    l
  end

  def parse_and
    l = parse_not
    while accept_op("&&")
      l = BinNode.new("&&", l, parse_not)
    end
    l
  end

  def parse_not
    return NotNode.new(parse_not) if accept_op("!")
    parse_eq
  end

  def parse_eq
    l = parse_postfix
    if accept_op("==")
      return BinNode.new("==", l, parse_postfix)
    elsif accept_op("!=")
      return BinNode.new("!=", l, parse_postfix)
    end
    l
  end

  def parse_args
    args = Node.list
    if accept_op("(")
      unless accept_op(")")
        args << parse_or
        args << parse_or while accept_op(",")
        expect_op(")")
      end
    end
    args
  end

  def parse_postfix
    e = parse_primary
    while accept_op(".")
      t = advance
      raise "expected method name" unless t.kind == :id
      e = CallNode.new(e, t.text, parse_args)
    end
    e
  end

  def parse_primary
    t = advance
    case t.kind
    when :int then IntLit.new(t.text.to_i)
    when :str then StrLit.new(t.text)
    when :ivar then IVarRef.new("@" + t.text)
    when :id
      if t.text == "nil" then NilLit.new
      elsif t.text == "true" then BoolLit.new(true)
      elsif t.text == "false" then BoolLit.new(false)
      elsif peek.kind == :op && peek.text == "("
        CallNode.new(nil, t.text, parse_args)
      else
        LVarRef.new(t.text)
      end
    else
      if t.kind == :op && t.text == "("
        e = parse_or
        expect_op(")")
        e
      else
        raise "unexpected token #{t.text}"
      end
    end
  end
end

def parse_expr(src) = ExprParser.new(src).parse

# ---------- template parser (tree builder) ----------
class Frame
  attr_accessor :nodes, :if_node, :implicit
  def initialize(nodes, if_node, implicit)
    @nodes = nodes
    @if_node = if_node
    @implicit = implicit
  end
end

def parse_template(src)
  root = Node.list
  stack = [Frame.new(root, nil, false)]
  lex_template(src).each do |ch|
    top = stack.last
    case ch.kind
    when 0 then top.nodes << TextNode.new(ch.text)
    when 2 then top.nodes << OutNode.new(parse_expr(ch.text), true)
    when 4 then top.nodes << OutNode.new(parse_expr(ch.text), false)
    when 3 then nil
    when 1
      code = ch.text
      if code.start_with?("if ")
        node = IfNode.new(parse_expr(code[3, code.length - 3]))
        top.nodes << node
        stack << Frame.new(node.then_body, node, false)
      elsif code.start_with?("elsif ")
        prev = top.if_node
        raise "elsif without if" if prev.nil?
        node = IfNode.new(parse_expr(code[6, code.length - 6]))
        prev.else_body << node
        top.nodes = prev.else_body
        stack << Frame.new(node.then_body, node, true)
      elsif code == "else"
        prev = top.if_node
        raise "else without if" if prev.nil?
        top.nodes = prev.else_body
      elsif code == "end"
        stack.pop while stack.last.implicit
        stack.pop
        raise "unbalanced end" if stack.empty?
      else
        di = code.index(" do |")
        if di && code.end_with?("|")
          recv_src = code[0, di]
          raise "only .each blocks supported" unless recv_src.end_with?(".each")
          var = code[di + 5, code.length - di - 6].strip
          node = EachNode.new(parse_expr(recv_src[0, recv_src.length - 5]), var)
          top.nodes << node
          stack << Frame.new(node.nodes, nil, false)
        else
          top.nodes << StmtNode.new(parse_expr(code))
        end
      end
    end
  end
  raise "missing end" unless stack.length == 1
  root
end
