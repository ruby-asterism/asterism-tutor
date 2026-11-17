require_relative "test_helper"

# The comment check of report a0.md 5.2: the 20 samples, a mixed document,
# hints placed into a document, and what the device's Ruby lacks.
class TestCheck < Minitest::Test
  C = Tutor::Check

  # name => [source, line, may a comment go above that line?]
  SAMPLES = {
    "plain" => [<<~'RB', 2, true],
      x = 1
      y = x + 2
      puts y
    RB
    "inside heredoc" => [<<~'RB', 3, false],
      s = <<~TXT
        line one
        line two
      TXT
      puts s
    RB
    "after heredoc body (above its terminator)" => [<<~'RB', 3, false],
      s = <<-TXT
        a
      TXT
    RB
    "line after heredoc" => [<<~'RB', 4, true],
      s = <<~TXT
        a
      TXT
      puts s
    RB
    "multi-line string" => [<<~'RB', 2, false],
      s = "first
      second"
      puts s
    RB
    "%w[] across lines" => [<<~'RB', 3, false],
      names = %w[
        alice
        bob
      ]
    RB
    "array literal across lines" => [<<~'RB', 3, true],
      names = [
        "alice",
        "bob",
      ]
    RB
    "=begin/=end" => [<<~'RB', 3, false],
      =begin
      doc line
      more doc
      =end
      x = 1
    RB
    "backslash, operator before" => [<<~'RB', 2, true],
      total = 1 + \
        2
      puts total
    RB
    "backslash, operator after" => [<<~'RB', 2, false],
      total = 1 \
        + 2
      puts total
    RB
    "backslash in a call's arguments" => [<<~'RB', 2, false],
      puts "a" \
        "b"
    RB
    "method chain (leading dot)" => [<<~'RB', 2, true],
      r = [3, 1, 2]
        .sort
        .map { |v| v * 2 }
    RB
    "method chain, above second dot" => [<<~'RB', 3, true],
      r = [3, 1, 2]
        .sort
        .map { |v| v * 2 }
    RB
    "after __END__" => [<<~'RB', 3, false],
      puts DATA.read
      __END__
      data line
    RB
    "above __END__" => [<<~'RB', 2, true],
      puts 1
      __END__
      data line
    RB
    "inside %q{} multi-line" => [<<~'RB', 2, false],
      s = %q{a
      b}
    RB
    "inside block, normal line" => [<<~'RB', 3, true],
      3.times do |i|
        x = i
        puts x
      end
    RB
    "line already a comment" => [<<~'RB', 2, true],
      # mine
      # more
      x = 1
    RB
    "inside regexp /x across lines" => [<<~'RB', 2, false],
      re = /a
      b/x
    RB
    "squiggly heredoc indentation" => [<<~'RB', 2, false],
      s = <<~T
          deep
        shallow
      T
    RB
  }.freeze

  def test_twenty_samples
    assert_equal 20, SAMPLES.size
    SAMPLES.each do |name, (src, line, expect)|
      got, why = C.insertable?(src, line)
      assert_equal expect, got, "#{name}: #{why}"
    end
  end

  # Each sample: put a hint on every line; the code lines stay byte for byte,
  # and no comment lands where it cannot.
  def test_samples_hint_every_line
    SAMPLES.each do |name, (src, _, _)|
      hints = (1..src.lines.size).map { { "line" => _1, "comment" => "hint #{_1}" } }
      out = C.place_hints(src, hints)
      assert_equal src, C.strip_ai(out["doc"]), name
      assert C.same_code?(src, out["doc"]), name
    end
  end

  MIXED = <<~'RB'.freeze
    class Foo < FmrbApp
      MSG = <<~T
        hello
      T
      def on_create
        @n = 1 + \
          2
        @a = %w[
          x y
        ]
        @gfx.draw_text(0, 0, "a
    b", 1)
      end
    end
    __END__
    tail
  RB

  def test_mixed_document
    ok = (1..MIXED.lines.size).select { C.insertable?(MIXED, _1)[0] }
    assert_equal [1, 2, 5, 6, 7, 8, 11, 13, 14, 15], ok
  end

  def test_place_hints_moves_up_or_leaves_out
    src = <<~RB
      x = 1
      s = <<~TXT
        inside
      TXT
      puts s
    RB
    out = C.place_hints(src, [{ "line" => 3, "comment" => "inside the heredoc" }, { "line" => 5, "comment" => "print it" }])
    assert_equal src, C.strip_ai(out["doc"])
    assert_equal [2, 5], out["placed"].map { _1["at"] }.sort # line 3 moved up to 2 (above the heredoc's start)
    assert_includes out["doc"], "# AI: inside the heredoc\ns = <<~TXT"
    assert_includes out["doc"], "# AI: print it\nputs s"
  end

  def test_place_hints_far_line_left_out
    out = C.place_hints("x = 1\n", [{ "line" => 40, "comment" => "far" }])
    assert_empty out["placed"]
    assert_equal 1, out["left_out"].size
  end

  def test_comment_lines
    assert_equal ["# AI: a", "# AI: b"], C.comment_lines("# AI: a\nb\nc")
    assert_equal [], C.comment_lines("  \n")
    assert C.comment_lines("x" * 300)[0].length < 140
  end

  # The device's editor sends its document without a newline at the end.
  def test_document_without_a_final_newline
    src = "class A < FmrbApp\n  MSG = <<~T\n    hi\n  T\n  def on_create\n    x = 1\n  end\nend"
    out = C.place_hints(src, [{ "line" => 1, "comment" => "top" }, { "line" => 8, "comment" => "last" },
                              { "line" => 3, "comment" => "in the heredoc" }])
    assert_equal [1, 2, 8], out["placed"].map { _1["at"] }.sort   # the heredoc's moves above it
    assert_empty out["left_out"]
    refute out["doc"].end_with?("\n")
    assert_equal src, C.strip_ai(out["doc"])
  end

  def test_indent_follows_the_line
    out = C.place_hints("def f\n  x = 1\nend\n", [{ "line" => 2, "comment" => "set x" }])
    assert_equal "def f\n  # AI: set x\n  x = 1\nend\n", out["doc"]
  end

  def bundle_checks = Tutor::Bundle.new(File.expand_path("../bundles", __dir__), "3.1.0").checks

  def test_pico_finds_what_the_device_lacks
    src = <<~'RB'
      class A < FmrbApp
        def on_create
          x = "abc" =~ /b/
          s = Struct.new(:a)
          t = [1, 2].sum
          a = [1, 2]
          a[0], a[1] = a[1], a[0]
          p defined?(x)
          r = (1..)
          v = [3, 1].sort_by { _1 }
          w = [3, 1].each_with_index.map { |x, i| x + i }
          1.step(10, 2) { |k| p k }
        end
      end
    RB
    ids = C.pico(src, bundle_checks).map { _1["id"] }.uniq.sort
    %w[regexp_literal struct array_sum skill_multi_index skill_defined range_endless array_sort_by enumerator_next].each do |id|
      assert_includes ids, id
    end
    refute_includes ids, "range_step" # step with a block is fine
  end

  def test_pico_skips_own_methods_and_plain_code
    src = <<~RB
      class A < FmrbApp
        def sum(a) = a
        def on_create
          @t = sum(3)
          @gfx.draw_text(0, 0, "ok", theme_fg)
          i = 0
          while i < 3
            i += 1
          end
        end
      end
    RB
    assert_empty C.pico(src, bundle_checks)
    assert C.app_class?(src)
    refute C.app_class?("puts 1\n")
  end

  def test_syntax
    assert_empty C.syntax("x = 1\n")
    refute_empty C.syntax("def f\n")
  end
end
