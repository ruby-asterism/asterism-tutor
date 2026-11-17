require "prism"

module Tutor
  # The checks on the code before it goes back to a device (report a0.md 5):
  # syntax with Prism (the version inside the device's compiler), the things the
  # device's Ruby lacks (the bundle's checks.json), and whether an AI comment
  # can go above a line without changing the program.
  module Check
    MARK = "# AI: ".freeze
    SKIP = %i[COMMENT EMBDOC_BEGIN EMBDOC_LINE EMBDOC_END IGNORED_NEWLINE EOF].freeze
    MAX_HINT_LINES = 2
    MAX_HINT_CHARS = 120
    MOVE_UP = 3

    module_function

    # Prism's syntax errors: [{"line" => n, "message" => text}]
    def syntax(src)
      Prism.parse(src).errors.map { { "line" => _1.location.start_line, "message" => _1.message } }
    end

    # Things the device's Ruby lacks, found in the tree. checks: the bundle's
    # list. Names the document defines itself (def foo) are not reported.
    # Returns [{"line", "id", "what", "found"}].
    def pico(src, checks)
      result = Prism.parse(src)
      return [] unless result.errors.empty?
      own = []
      walk(result.value) { |n| own << n.name.to_s if n.is_a?(Prism::DefNode) }
      found = []
      walk(result.value) do |n|
        checks.each do |c|
          hit = match(n, c, own)
          found << { "line" => n.location.start_line, "id" => c["id"], "what" => c["what"], "found" => hit } if hit
        end
      end
      found.uniq { [_1["line"], _1["id"], _1["found"]] }
    end

    def match(n, c, own)
      kind = n.class.name.split("::").last
      return kind if c["nodes"]&.include?(kind)
      if c["consts"] && (n.is_a?(Prism::ConstantReadNode) || n.is_a?(Prism::ConstantPathNode))
        name = n.is_a?(Prism::ConstantReadNode) ? n.name.to_s : n.full_name.delete_prefix("::")
        return name if c["consts"].include?(name)
      end
      if n.is_a?(Prism::CallNode) && !own.include?(n.name.to_s)
        name = n.name.to_s
        return ".#{name}" if n.receiver && c["calls"]&.include?(name)
        return name if n.receiver.nil? && c["calls0"]&.include?(name)
        return ".#{name} without a block" if n.receiver && n.block.nil? && c["calls_noblock"]&.include?(name)
      end
      if c["endless_range"] && n.is_a?(Prism::RangeNode) && n.right.nil?
        return "endless range"
      end
      if c["multi_index"] && n.is_a?(Prism::MultiWriteNode) &&
         (n.lefts + [n.rest, *n.rights]).compact.any? { _1.is_a?(Prism::IndexTargetNode) }
        return "a[i], a[j] = ..."
      end
      nil
    end

    def walk(node, &blk)
      return unless node
      yield node
      node.compact_child_nodes.each { walk(_1, &blk) }
    end

    # --- AI comments (report a0.md 5.2) ---

    def code_tokens(src)
      r = Prism.lex(src)
      toks = r.value.map(&:first).reject { SKIP.include?(_1.type) }
      [toks.map { [_1.type, _1.value] }, r]
    end

    # The syntax tree without positions. Catches what the tokens miss (a COMMENT
    # token swallows the newline that ends a statement after a backslash).
    def shape(v)
      case v
      when Prism::Node
        h = v.deconstruct_keys(nil).reject { |k, x| k == :location || k == :node_id || x.is_a?(Prism::Location) }
        [v.class.name.split("::").last] + h.sort_by { |k, _| k.to_s }.map { |k, x| [k, shape(x)] }
      when Array then v.map { shape(_1) }
      when Prism::Location then nil
      else v
      end
    end

    def data_after_end(src) = Prism.parse(src).data_loc&.slice

    # The comment lines for a hint text: at most MAX_HINT_LINES lines of
    # MAX_HINT_CHARS characters, each starting with the mark.
    def comment_lines(text)
      parts = text.to_s.gsub("\r", "").split("\n").map(&:strip).reject(&:empty?)
      parts = parts.map { _1.delete_prefix("#").strip.delete_prefix("AI:").strip }
      parts = parts.first(MAX_HINT_LINES).map { _1.length > MAX_HINT_CHARS ? "#{_1[0, MAX_HINT_CHARS - 3]}..." : _1 }
      parts.empty? ? [] : parts.map { "#{MARK}#{_1}" }
    end

    # The document with the comment lines above line n (1-based), indented like
    # that line (a line past the end: at the end).
    def insert_comment(src, n, lines)
      all = src.lines
      all[-1] += "\n" if all.any? && !all[-1].end_with?("\n")
      target = all[n - 1] || ""
      indent = target[/\A[ \t]*/]
      all.insert(n - 1, *lines.map { "#{indent}#{_1}\n" })
      all.join
    end

    # Can these comment lines go above line n without changing the program?
    # [true/false, reason]. All four must hold (a0.md 5.2): no more parse
    # errors, the same tokens without comments, the same tree without
    # positions (and __END__ data), and each inserted line a COMMENT of its own.
    def insertable?(src, n, lines = ["#{MARK}hint"])
      line_count = src.lines.size
      return [false, "no such line"] if n < 1 || n > line_count + 1
      before_toks, = code_tokens(src)
      after = insert_comment(src, n, lines)
      after_toks, after_r = code_tokens(after)
      return [false, "parse errors grew"] if Prism.parse(after).errors.size > Prism.parse(src).errors.size
      return [false, "tokens differ"] if before_toks != after_toks
      return [false, "tree differs"] if shape(Prism.parse(src).value) != shape(Prism.parse(after).value)
      return [false, "__END__ data differs"] if data_after_end(src) != data_after_end(after)
      toks = after_r.value.map(&:first)
      lines.each_index do |k|
        ln = n + k
        on_line = toks.select { _1.location.start_line == ln && !%i[IGNORED_NEWLINE NEWLINE].include?(_1.type) }
        return [false, "inserted line is not a comment"] unless on_line.size == 1 && on_line[0].type == :COMMENT
      end
      [true, "ok"]
    end

    # Puts hints into a document. hints: [{"line" => n, "comment" => text, ...}]
    # (n of src). Each goes above its line, or up to MOVE_UP lines higher when
    # it cannot go there; else it is left out. Returns
    # {"doc" => new src, "placed" => [hint + "at"], "left_out" => [hint + "why"]}.
    def place_hints(src, hints)
      doc = src.dup
      placed = []
      left = []
      # bottom first: the lines above keep their numbers
      hints.sort_by { -_1["line"].to_i }.each do |h|
        lines = comment_lines(h["comment"])
        if lines.empty?
          left << h.merge("why" => "empty")
          next
        end
        n = h["line"].to_i
        ok = false
        why = "no such line"
        n.downto([n - MOVE_UP, 1].max) do |m|
          ok, why = insertable?(doc, m, lines)
          next unless ok
          doc = insert_comment(doc, m, lines)
          placed << h.merge("at" => m)
          break
        end
        left << h.merge("why" => why) unless ok
      end
      { "doc" => doc, "placed" => placed.reverse, "left_out" => left.reverse }
    end

    # The document without the AI comment lines this gem inserted (a line whose
    # text after the indent starts with the mark). For checks and tests.
    def strip_ai(src)
      src.lines.reject { _1.lstrip.start_with?(MARK) }.join
    end

    # The whole-document check after placing hints: the code is the same.
    def same_code?(a, b)
      code_tokens(a)[0] == code_tokens(b)[0] && shape(Prism.parse(a).value) == shape(Prism.parse(b).value) &&
        data_after_end(a) == data_after_end(b)
    end

    # Does the document define a subclass of FmrbApp?
    def app_class?(src)
      r = Prism.parse(src)
      found = false
      walk(r.value) do |n|
        next unless n.is_a?(Prism::ClassNode) && n.superclass
        sup = n.superclass
        name = sup.respond_to?(:full_name) ? sup.full_name.delete_prefix("::") : nil
        found = true if name == "FmrbApp"
      end
      found
    end
  end
end
