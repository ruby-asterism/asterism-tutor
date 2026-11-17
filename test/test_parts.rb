require_relative "test_helper"
require "fileutils"

# The pieces without the network: the answer's tags, the bundles, the talk,
# the limits and the log.
class TestParts < Minitest::Test
  ROOT = File.expand_path("../bundles", __dir__)

  def test_parse_tags
    t = "<explain>説明</explain>\n<hint line=\"3\">ここ</hint><hint line=12>そこ</hint>"
    r = Tutor::Prompt.parse(t)
    assert_equal "説明", r["explain"]
    assert_equal [{ "line" => 3, "comment" => "ここ" }, { "line" => 12, "comment" => "そこ" }], r["hints"]
    assert_nil r["code"]
    c = Tutor::Prompt.parse("<explain>x</explain><code>\n```ruby\nputs 1\n```\n</code>")
    assert_equal "puts 1\n", c["code"]
    assert_equal "ただの文", Tutor::Prompt.parse("ただの文")["explain"]
  end

  def test_request_has_numbered_doc_and_child_text
    m = Tutor::Prompt.request({ "mode" => "hint", "text" => "動かない", "cy" => 1, "error" => "NoMethodError" }, "a = 1\nb = 2\n")
    assert_includes m, "1| a = 1"
    assert_includes m, "2| b = 2"
    assert_includes m, "カーソルは 2 行目"
    assert_includes m, "<error>\nNoMethodError"
    assert_includes m, "<child>\n動かない\n</child>"
  end

  def test_bundle_pick_and_fallback
    assert_equal "3.1.0", Tutor::Bundle.pick(ROOT, "3.1.0")
    assert_equal "3.1.0", Tutor::Bundle.pick(ROOT, "3.2.5")   # newer device: nearest older bundle
    assert_equal "3.1.0", Tutor::Bundle.pick(ROOT, "2.0.0")   # older than all: the oldest
    bs = Tutor::Bundles.new(ROOT)
    refute bs.for("3.1.0").fallback?
    f = bs.for("3.2.5")
    assert f.fallback?
    assert_equal "3.1.0", f.fw
    assert_equal "3.2.5", f.asked
  end

  def test_bundle_text
    b = Tutor::Bundle.new(ROOT, "3.1.0")
    %w[app_guide.md api.rbs templates/window.rb pitfalls.tsv samples/pub_demo.app.rb].each do |part|
      assert b.text.include?(part), "#{part} is in the text"
    end
    assert b.text.include?("# AI: "), "the rules are in the text"
    refute b.text.include?("calls0"), "checks.json is not in the text"
    assert_operator b.checks.size, :>, 30
    assert_equal b.text, Tutor::Bundle.new(ROOT, "3.1.0").text # the same bytes each time (the prompt cache)
  end

  TMP = Dir.mktmpdir("fmrb-tutor-unit")
  Minitest.after_run { FileUtils.rm_rf(TMP) }

  def cfg(over = {})
    Tutor::Config.load(nil, Tutor::Config.deep_merge({ "store" => { "log_dir" => Dir.mktmpdir(nil, TMP) } }, over))
  end

  def test_talk_keeps_turns_and_forgets
    now = Time.now
    s = Tutor::Store.new(cfg, clock: -> { now })
    6.times { s.add_turn("d1", "u#{_1}", "a#{_1}") }
    assert_equal 4, s.talk("d1").size
    assert_equal %w[u2 a2], s.talk("d1").first
    now += 29 * 60
    assert_equal 4, s.talk("d1").size
    now += 31 * 60
    assert_empty s.talk("d1")
    s.add_turn("d1", "u", "a")
    s.forget_talk("d1")
    assert_empty s.talk("d1")
  end

  def test_results_kept_for_their_hours
    now = Time.now
    s = Tutor::Store.new(cfg, clock: -> { now })
    id = s.new_ticket("d1", "req" => {})
    s.update(id, "state" => "done")
    now += 23 * 3600
    assert_equal [[id, "done"]], s.pending("d1")
    now += 2 * 3600
    assert_empty s.pending("d1")
  end

  def test_limits_and_their_day
    now = Time.new(2026, 11, 17, 23, 0, 0)
    c = cfg("limits" => { "per_device_per_day" => 2, "cost_per_day_usd" => 0.01 })
    log = Tutor::Log.new(c.log_dir, clock: -> { now })
    l = Tutor::Limits.new(c, log, clock: -> { now })
    assert_nil l.refuse("d1")
    2.times { l.count("d1") }
    assert_equal "limit", l.refuse("d1")["error"]
    assert_nil l.refuse("d2")
    l.add_cost(0.02)
    assert_equal "limit", l.refuse("d2")["error"]
    now += 3600 # the next day
    assert_nil l.refuse("d1")
  end

  def test_limits_read_back_from_the_log
    now = Time.now
    c = cfg("limits" => { "per_device_per_day" => 2 })
    log = Tutor::Log.new(c.log_dir, clock: -> { now })
    2.times { log.write(:ask, device: "d1") }
    l = Tutor::Limits.new(c, log, clock: -> { now })
    assert_equal "limit", l.refuse("d1")["error"]
  end

  def test_log_scrubs_key_shapes
    c = cfg
    log = Tutor::Log.new(c.log_dir)
    log.write(:x, text: "my key is #{KEY_PREFIX}-api03-abcDEF_123 ok", nested: { "a" => ["#{KEY_PREFIX}-zz"] })
    body = File.read(log.path)
    refute_includes body, KEY_PREFIX
    assert_includes body, "[redacted]"
  end

  def test_cost
    c = cfg
    usd = c.cost({ "in" => 1_000_000, "out" => 1_000_000, "cache_write" => 0, "cache_read" => 0 })
    assert_in_delta 0.60, usd, 1e-9 # claude-haiku-5-5: 0.10 + 0.50
  end

  def test_fake_waits_for_the_marker
    llm = Tutor::LLM::Fake.new
    msg = Tutor::Prompt.request({ "mode" => "ask", "text" => "[[wait 1]] 待って" }, nil)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    r = llm.complete(system: "s", messages: [{ role: "user", content: msg }], meta: { mode: "ask" })
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, :>=, 0.9
    assert_includes r["text"], "<explain>"
  end
end
