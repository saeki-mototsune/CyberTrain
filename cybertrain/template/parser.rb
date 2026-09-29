# Cybertrain::Template::Parser -- turns lexer tokens into the AST.
#
# Two levels: TreeBuilder nests the template's tags (if/elsif/else/unless,
# each, helper blocks, end) into a node tree, and ExprParser parses the Ruby
# subset inside one tag (docs/design.md section 7) with Ruby's precedence:
#
#   ?:  <  ||  <  &&  <  == !=  <  < > <= >=  <  + -  <  * / %  <  ! -  <  . &. []
#
# Anything outside the subset is a SyntaxError "<name>:<line>: <what>".
require "cybertrain/template/ast"
require "cybertrain/template/lexer"

module Cybertrain
  module Template
    module Parser
      def self.parse(tokens, name)
        TreeBuilder.new(name).build(tokens)
      end
    end

    # One token of an expression. `spaced` records whitespace before it,
    # which separates `foo (x)`/`foo [x]` from `foo(x)`/`foo[x]` and marks
    # the start of a parenthesis-free argument list (`link_to "Show", post`).
    class ExprToken
      attr_reader :tok_kind, :tok_text, :spaced   # tok_kind: :int :float :str :dstr :sym :ivar :ident :label :op :eof

      def initialize(tok_kind, tok_text, spaced)
        @tok_kind = tok_kind
        @tok_text = tok_text
        @spaced = spaced
      end
    end

    class ExprParser
      KEYWORDS = %w[and or not do end if unless elsif else then while until case when def class module begin rescue return]

      def initialize(source, name, line)
        @src = source
        @name = name
        @line = line
        @toks = Array.new(0) { ExprToken.new(:eof, "", false) }
        @pos = 0
        @command_depth = 0
        tokenize_source
      end

      def parse_all
        e = parse_ternary
        unexpected(peek) unless peek.tok_kind == :eof
        e
      end

      # A code tag's content: `name = expr` or an expression.
      def parse_statement
        if @toks.size > 2 && @toks[0].tok_kind == :ident && op_token?(@toks[1], "=")
          name = @toks[0].tok_text
          @pos = 2
          return AssignNode.new(name, parse_all)
        end
        parse_all
      end

      private

      def error(message)
        raise SyntaxError, "#{@name}:#{@line}: #{message}"
      end

      def unexpected(tok)
        if tok.tok_kind == :eof
          error("unexpected end of expression in '#{@src}'")
        else
          error("unexpected '#{tok.tok_text}' in '#{@src}'")
        end
      end

      # --- tokenizer ------------------------------------------------------

      def digit?(c) = c >= "0" && c <= "9"
      def ident_start?(c) = (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c == "_"
      def ident_char?(c) = ident_start?(c) || digit?(c)

      def push(kind, text, spaced)
        @toks << ExprToken.new(kind, text, spaced)
        nil
      end

      def tokenize_source
        s = @src
        n = s.length
        i = 0
        spaced = false
        while i < n
          c = s[i]
          if c == " " || c == "\t" || c == "\n" || c == "\r"
            spaced = true
            i += 1
            next
          end
          if digit?(c)
            j = i
            j += 1 while j < n && (digit?(s[j]) || s[j] == "_")
            kind = :int
            if j + 1 < n && s[j] == "." && digit?(s[j + 1])
              kind = :float
              j += 1
              j += 1 while j < n && (digit?(s[j]) || s[j] == "_")
            end
            push(kind, s[i, j - i].delete("_"), spaced)
            i = j
          elsif c == "\""
            j = skip_double_quoted(s, i + 1)
            push(:dstr, s[i + 1, j - i - 1], spaced)
            i = j + 1
          elsif c == "'"
            buf = +""
            j = i + 1
            while j < n && s[j] != "'"
              if s[j] == "\\" && j + 1 < n && (s[j + 1] == "'" || s[j + 1] == "\\")
                buf << s[j + 1]
                j += 2
              else
                buf << s[j]
                j += 1
              end
            end
            error("unterminated string") if j >= n
            push(:str, buf, spaced)
            i = j + 1
          elsif c == "@"
            j = i + 1
            j += 1 while j < n && ident_char?(s[j])
            error("unexpected character '@'") if j == i + 1
            push(:ivar, s[i + 1, j - i - 1], spaced)
            i = j
          elsif ident_start?(c)
            j = name_end(s, i)
            word = s[i, j - i]
            if j < n && s[j] == ":" && !(j + 1 < n && s[j + 1] == ":")
              push(:label, word, spaced)
              i = j + 1
            else
              push(:ident, word, spaced)
              i = j
            end
          elsif c == ":" && i + 1 < n && ident_start?(s[i + 1])
            j = name_end(s, i + 1)
            push(:sym, s[i + 1, j - i - 1], spaced)
            i = j
          else
            two = i + 1 < n ? s[i, 2] : ""
            if two == "==" || two == "!=" || two == "<=" || two == ">=" || two == "&&" || two == "||" || two == "&."
              push(:op, two, spaced)
              i += 2
            elsif "<>+-*/%!?:.,()[]{}=".index(c)
              push(:op, c, spaced)
              i += 1
            else
              error("unexpected character '#{c}'")
            end
          end
          spaced = false
        end
        push(:eof, "", spaced)
      end

      # The end of a method/variable name starting at i, including a trailing
      # ? or ! (`empty?`, `save!`) unless it starts `?x`, `!=` and the like.
      def name_end(s, i)
        n = s.length
        j = i
        j += 1 while j < n && ident_char?(s[j])
        if j < n && (s[j] == "?" || s[j] == "!")
          nxt = j + 1 < n ? s[j + 1] : " "
          j += 1 unless ident_char?(nxt) || nxt == "=" || nxt == "\"" || nxt == "'" || nxt == "@"
        end
        j
      end

      # Index of the closing quote of a "..." literal whose content starts at i.
      def skip_double_quoted(s, i)
        n = s.length
        j = i
        while j < n
          c = s[j]
          if c == "\\"
            j += 2
          elsif c == "\""
            return j
          elsif c == "#" && j + 1 < n && s[j + 1] == "{"
            j = skip_interpolation(s, j + 2)
          else
            j += 1
          end
        end
        error("unterminated string")
        j
      end

      # Index just past the "}" closing an interpolation whose code starts at i.
      def skip_interpolation(s, i)
        n = s.length
        depth = 1
        j = i
        while j < n
          c = s[j]
          if c == "{"
            depth += 1
          elsif c == "}"
            depth -= 1
            return j + 1 if depth == 0
          elsif c == "\"" || c == "'"
            j += 1
            j += (s[j] == "\\" ? 2 : 1) while j < n && s[j] != c
          end
          j += 1
        end
        error("unterminated string")
        j
      end

      # "text #{expr} more" -> StrLit, or Interp of StrLit pieces and expressions.
      def string_node(raw)
        parts = Node.list
        buf = +""
        interpolated = false
        n = raw.length
        i = 0
        while i < n
          c = raw[i]
          if c == "\\" && i + 1 < n
            buf << unescape(raw[i + 1])
            i += 2
          elsif c == "#" && i + 1 < n && raw[i + 1] == "{"
            close = skip_interpolation(raw, i + 2)
            parts << StrLit.new(buf) unless buf.empty?
            buf = +""
            parts << ExprParser.new(raw[i + 2, close - i - 3], @name, @line).parse_all
            interpolated = true
            i = close
          else
            buf << c
            i += 1
          end
        end
        return StrLit.new(buf) unless interpolated

        parts << StrLit.new(buf) unless buf.empty?
        Interp.new(parts)
      end

      def unescape(c)
        case c
        when "n" then "\n"
        when "t" then "\t"
        when "r" then "\r"
        when "0" then "\0"
        when "e" then "\e"
        when "s" then " "
        else c
        end
      end

      # --- parser ---------------------------------------------------------

      def peek = @toks[@pos]

      def advance
        t = @toks[@pos]
        @pos += 1 if @pos < @toks.size - 1
        t
      end

      def op_token?(tok, text) = tok.tok_kind == :op && tok.tok_text == text

      def accept_op(text)
        return false unless op_token?(peek, text)

        advance
        true
      end

      def expect_op(text)
        unexpected(peek) unless accept_op(text)
      end

      def parse_ternary
        cond = parse_or
        return cond unless accept_op("?")

        a = parse_ternary
        expect_op(":")
        Ternary.new(cond, a, parse_ternary)
      end

      def parse_or
        left = parse_and
        left = BinOp.new("||", left, parse_and, @line) while accept_op("||")
        left
      end

      def parse_and
        left = parse_equality
        left = BinOp.new("&&", left, parse_equality, @line) while accept_op("&&")
        left
      end

      def parse_equality
        left = parse_comparison
        while op_token?(peek, "==") || op_token?(peek, "!=")
          op = advance.tok_text
          left = BinOp.new(op, left, parse_comparison, @line)
        end
        left
      end

      def parse_comparison
        left = parse_additive
        while op_token?(peek, "<") || op_token?(peek, ">") || op_token?(peek, "<=") || op_token?(peek, ">=")
          op = advance.tok_text
          left = BinOp.new(op, left, parse_additive, @line)
        end
        left
      end

      def parse_additive
        left = parse_multiplicative
        while op_token?(peek, "+") || op_token?(peek, "-")
          op = advance.tok_text
          left = BinOp.new(op, left, parse_multiplicative, @line)
        end
        left
      end

      def parse_multiplicative
        left = parse_unary
        while op_token?(peek, "*") || op_token?(peek, "/") || op_token?(peek, "%")
          op = advance.tok_text
          left = BinOp.new(op, left, parse_unary, @line)
        end
        left
      end

      def parse_unary
        return NotNode.new(parse_unary) if accept_op("!")
        return parse_postfix(parse_primary) unless accept_op("-")

        t = peek
        if t.tok_kind == :int && !t.spaced
          advance
          return parse_postfix(IntLit.new(-t.tok_text.to_i))
        end
        if t.tok_kind == :float && !t.spaced
          advance
          return parse_postfix(FloatLit.new(-t.tok_text.to_f))
        end
        BinOp.new("-", IntLit.new(0), parse_unary, @line)
      end

      def parse_postfix(start)
        e = start
        loop do
          if op_token?(peek, ".") || op_token?(peek, "&.")
            safe = advance.tok_text == "&."
            t = advance
            unexpected(t) unless t.tok_kind == :ident
            e = parse_call(e, t.tok_text, safe)
          elsif op_token?(peek, "[") && !peek.spaced
            advance
            index = parse_ternary
            expect_op("]")
            e = IndexNode.new(e, index, @line)
          else
            break
          end
        end
        e
      end

      def parse_primary
        t = advance
        case t.tok_kind
        when :int then IntLit.new(t.tok_text.to_i)
        when :float then FloatLit.new(t.tok_text.to_f)
        when :str then StrLit.new(t.tok_text)
        when :dstr then string_node(t.tok_text)
        when :sym then SymLit.new(t.tok_text)
        when :ivar then IVar.new(t.tok_text)
        when :ident then identifier(t.tok_text)
        when :op then bracketed(t)
        else
          unexpected(t)
          NilLit.new
        end
      end

      def identifier(word)
        case word
        when "nil" then return NilLit.new
        when "true" then return TrueLit.new
        when "false" then return FalseLit.new
        end
        error("constants are not supported: '#{word}'") if word[0] >= "A" && word[0] <= "Z"
        error("'#{word}' is not supported in templates") if KEYWORDS.include?(word)
        t = peek
        if word == "yield" || (op_token?(t, "(") && !t.spaced) || command_arg_start?(t)
          return parse_call(nil, word, false)
        end
        LVar.new(word, @line)
      end

      def bracketed(t)
        if t.tok_text == "("
          e = parse_ternary
          expect_op(")")
          return e
        end
        if t.tok_text == "["
          items = Node.list
          unless accept_op("]")
            items << parse_ternary
            items << parse_ternary while accept_op(",")
            expect_op("]")
          end
          return ArrayLit.new(items)
        end
        if t.tok_text == "{"
          keys = Array.new(0) { "" }
          values = Node.list
          unless accept_op("}")
            loop do
              k = advance
              unexpected(k) unless k.tok_kind == :label
              keys << k.tok_text
              values << parse_ternary
              break unless accept_op(",")
            end
            expect_op("}")
          end
          return HashLit.new(keys, values)
        end
        unexpected(t)
        NilLit.new
      end

      # `link_to "Show", post`: a name followed by a spaced argument opens a
      # parenthesis-free argument list. Only the outermost call gets one, so
      # `link_to "x", post_path post` is not guessed at.
      def command_arg_start?(t)
        return false unless t.spaced && @command_depth == 0

        case t.tok_kind
        when :int, :float, :str, :dstr, :sym, :ivar, :label then true
        when :ident then !KEYWORDS.include?(t.tok_text)
        else false
        end
      end

      def parse_call(recv, name, safe)
        args = Node.list
        kw_names = Array.new(0) { "" }
        kw_values = Node.list
        t = peek
        if op_token?(t, "(") && !t.spaced
          advance
          @command_depth += 1
          unless accept_op(")")
            loop do
              parse_argument(args, kw_names, kw_values)
              break unless accept_op(",")
            end
            expect_op(")")
          end
          @command_depth -= 1
        elsif command_arg_start?(t)
          @command_depth += 1
          loop do
            parse_argument(args, kw_names, kw_values)
            break unless accept_op(",")
          end
          @command_depth -= 1
        end
        Call.new(recv, name, args, kw_names, kw_values, safe, @line)
      end

      def parse_argument(args, kw_names, kw_values)
        if peek.tok_kind == :label
          kw_names << advance.tok_text
          kw_values << parse_ternary
        else
          error("positional argument after keyword arguments in '#{@src}'") unless kw_names.empty?
          args << parse_ternary
        end
        nil
      end
    end

    # An open block while building the tree: what opened it and the node
    # list that tags are currently appended to (then/elsif/else bodies).
    class Frame
      attr_reader :opener, :word, :line
      attr_accessor :frame_target, :in_else

      def initialize(opener, word, line, target)
        @opener = opener
        @word = word
        @line = line
        @frame_target = target
        @in_else = false
      end
    end

    class TreeBuilder
      def initialize(name)
        @name = name
        @root = Node.list
        @stack = Array.new(0) { Frame.new(Node.new, "", 0, Node.list) }
        @stack << Frame.new(Node.new, "root", 0, @root)
      end

      def build(tokens)
        tokens.each do |t|
          case t.kind
          when :text then @stack.last.frame_target << TextNode.new(t.tag_text)
          when :output then output(t.tag_text, false, t.line)
          when :output_raw then output(t.tag_text, true, t.line)
          when :code then statement(t.tag_text, t.line)
          end
        end
        if @stack.size > 1
          open = @stack.last
          error(open.line, "'#{open.word}' without 'end'")
        end
        @root
      end

      private

      def error(line, message)
        raise SyntaxError, "#{@name}:#{line}: #{message}"
      end

      def expression(source, line) = ExprParser.new(source, @name, line).parse_all

      def output(code, raw, line)
        error(line, raw ? "empty <%== %> tag" : "empty <%= %> tag") if code.empty?
        at = do_index(code)
        if at >= 0
          open_block(code, at, true, line)
        else
          @stack.last.frame_target << OutputNode.new(expression(code, line), raw, line)
        end
      end

      def statement(code, line)
        return if code.empty?
        # `<% # note %>`: a Ruby comment filling the whole tag (ERB accepts
        # it). A trailing comment after code (`<% x = 1 # note %>`) is not
        # supported and stays a SyntaxError.
        return if code.start_with?("#")

        space = code.index(" ")
        word = space.nil? ? code : code[0, space]
        rest = space.nil? ? "" : code[space + 1, code.length - space - 1].strip
        top = @stack.last
        if code == "end"
          error(line, "'end' without an opening block") if @stack.size == 1
          @stack.pop
        elsif code == "else"
          start_else(top, line)
        elsif word == "elsif"
          start_elsif(top, rest, line)
        elsif word == "if" || word == "unless"
          error(line, "'#{word}' without a condition") if rest.empty?
          cond = expression(rest, line)
          if word == "if"
            node = IfNode.new(cond, line)
            top.frame_target << node
            @stack << Frame.new(node, "if", line, node.then_nodes)
          else
            node = UnlessNode.new(cond, line)
            top.frame_target << node
            @stack << Frame.new(node, "unless", line, node.then_nodes)
          end
        else
          at = do_index(code)
          if at >= 0
            open_block(code, at, false, line)
          else
            parsed = ExprParser.new(code, @name, line).parse_statement
            case parsed
            when AssignNode then top.frame_target << parsed
            else top.frame_target << StatementNode.new(parsed, line)
            end
          end
        end
      end

      def start_else(top, line)
        op = top.opener
        error(line, "'else' after 'else'") if top.in_else
        case op
        when IfNode then top.frame_target = op.else_nodes
        when UnlessNode then top.frame_target = op.else_nodes
        else error(line, "'else' without 'if'")
        end
        top.in_else = true
      end

      def start_elsif(top, rest, line)
        op = top.opener
        case op
        when IfNode
          error(line, "'elsif' after 'else'") if top.in_else
          error(line, "'elsif' without a condition") if rest.empty?
          body = Node.list
          op.elsif_conds << expression(rest, line)
          op.elsif_bodies << body
          top.frame_target = body
        else
          error(line, "'elsif' without 'if'")
        end
      end

      # Where " do" (optionally followed by |params|) ends the tag, or -1.
      def do_index(code)
        if code.end_with?("|")
          at = code.rindex(" do |")
          return at.nil? ? -1 : at
        end
        return code.length - 3 if code.end_with?(" do")
        -1
      end

      def open_block(code, at, output, line)
        head = code[0, at].strip
        params = block_params(code[at + 3, code.length - at - 3].strip, line)
        top = @stack.last
        each_word = ""
        each_word = "each" if head.end_with?(".each")
        each_word = "each_with_index" if head.end_with?(".each_with_index")
        unless each_word.empty?
          iter = expression(head[0, head.length - each_word.length - 1], line)
          error(line, "'#{each_word}' takes one or two block parameters") if params.empty? || params.size > 2
          node = EachNode.new(iter, params, each_word == "each_with_index", line)
          top.frame_target << node
          @stack << Frame.new(node, each_word, line, node.body_nodes)
          return
        end

        call = expression(head, line)
        case call
        when LVar
          call = Call.new(nil, call.name, Node.list, Array.new(0) { "" }, Node.list, false, line)
        end
        case call
        when Call
          error(line, "blocks are only supported on each, each_with_index and helper calls") unless call.recv.nil?
          node = BlockCallNode.new(call, params, output, line)
          top.frame_target << node
          @stack << Frame.new(node, call.name, line, node.body_nodes)
        else
          error(line, "blocks are only supported on each, each_with_index and helper calls")
        end
      end

      # "|a, b|" -> ["a", "b"]; "" -> []
      def block_params(src, line)
        names = Array.new(0) { "" }
        return names if src.empty?

        unless src.start_with?("|") && src.end_with?("|") && src.length >= 2
          error(line, "bad block parameters '#{src}'")
        end
        src[1, src.length - 2].split(",").each do |p|
          name = p.strip
          error(line, "bad block parameter '#{name}'") unless Lexer.identifier?(name)
          names << name
        end
        names
      end
    end
  end
end
