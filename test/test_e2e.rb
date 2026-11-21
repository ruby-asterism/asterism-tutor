require_relative "test_helper"
require "asterism"
require "open3"
require "fileutils"
require_relative "sender"
require_relative "sources_fixture"

# The gem as a process (exe/asterism-tutor, fake LLM) on a local router, called
# by test/sender.rb the way a device will. `rake e2e` starts the router.
#
# Two gems: "tutor-test" (the devices listed, everything on) and
# "tutor-off" (any device, make and fix turned off, 3 requests a day).
class TestE2E < Minitest::Test
  ROUTER = ENV["TUTOR_TEST_ROUTER"].to_s
  WORK = Dir.mktmpdir("asterism-tutor-e2e")
  EXE = File.expand_path("../exe/asterism-tutor", __dir__)
  MAIN = "tutor-test/tutor/helper".freeze
  OFF = "tutor-off/tutor/helper".freeze
  C = Tutor::Check

  APP_WITH_HEREDOC = <<~'RB'.freeze
    class Hello < FmrbApp
      MSG = <<~T
        hello
        world
      T

      def on_create
        @n = 0
        draw_screen
      end

      def draw_screen
        clear_user_area
        @gfx.draw_text(4, 4, MSG, theme_fg)
        @gfx.present
      end
    end
  RB

  def self.config(name, body)
    path = File.join(WORK, "#{name}.toml")
    File.write(path, body)
    path
  end

  def self.start(name, body)
    cfg = config(name, body)
    _in, out, wait = Open3.popen2e("bundle", "exec", "ruby", EXE, "--config", cfg)
    line = nil
    t = Time.now
    until (line = out.gets).nil? || line.include?("asterism-tutor: model ")
      raise "#{name} did not start" if Time.now - t > 20
    end
    raise "#{name} ended: #{out.read}" if line.nil?
    Thread.new { out.each_line { |l| File.write(File.join(WORK, "#{name}.out"), l, mode: "a") } }
    wait
  end

  @servers = []
  @nets = {}
  class << self
    attr_reader :servers, :nets
  end

  def self.setup_once
    return if @ready
    @ready = true
    skip_all = ROUTER.empty?
    return if skip_all
    @repos = SourcesFixture.build(WORK)
    @servers << start("main", <<~TOML)
      [network]
      router = "#{ROUTER}"
      node = "tutor-test"
      devices = ["fmruby-aaa001", "fmruby-aaa002", "fmruby-aaa003", "fmruby-aaa004"]
      name = "test helper"
      [llm]
      provider = "fake"
      [store]
      log_dir = "#{WORK}/log_main"
      state_dir = "#{WORK}/state_main"
      [sources]
      core = "#{@repos[:core]}"
      asterism = "#{@repos[:asterism]}"
    TOML
    @servers << start("off", <<~TOML)
      [network]
      router = "#{ROUTER}"
      node = "tutor-off"
      devices = ["*"]
      [llm]
      provider = "fake"
      [limits]
      per_device_per_day = 3
      [modes]
      make = false
      fix = false
      [store]
      log_dir = "#{WORK}/log_off"
      state_dir = "#{WORK}/state_off"
      [sources]
      enabled = false
    TOML
    Minitest.after_run do
      @nets.each_value { _1.close rescue nil }
      @servers.each { Process.kill("TERM", _1.pid) rescue nil }
      @servers.each { _1.join(10) }
      FileUtils.rm_rf(WORK) if ENV["KEEP_LOGS"].to_s.empty?
    end
  end

  def setup
    skip "no router (run `rake e2e`)" if ROUTER.empty?
    self.class.setup_once
  end

  def net(node)
    self.class.nets[node] ||= Asterism.connect(ROUTER, node: node, app: "aihelp")
  end

  def sender(node, path = MAIN) = Sender.new(net(node), path, timeout: 5.0)

  def req(mode, text, extra = {})
    { "mode" => mode, "text" => text, "fw" => "3.1.0", "lang" => "ja", "ver" => 7 }.merge(extra)
  end

  def log_records(name = "main")
    Dir[File.join(WORK, "log_#{name}", "*.jsonl")].flat_map { |f| File.readlines(f).map { JSON.parse(_1) } }
  end

  # --- the four uses ---

  def test_hello
    h = sender("fmruby-aaa001").hello
    assert h["ok"]
    assert_equal %w[ask hint make fix], h["modes"]
    assert_equal 8192, h["piece"]
    assert_equal "test helper", h["name"]
  end

  # The sources fetched at start (local repositories) and a request that
  # looks them up through the router.
  def test_ask_with_look_ups
    r = nil
    t = Time.now
    loop do # the first fetch runs in the background after start
      r = sender("fmruby-aaa001").run(req("ask", "絵を出すには? [[search draw_picture]]"))
      break if r["explain"].include?("調べた") || Time.now - t > 15
      sleep 0.5
    end
    assert_equal "answer", r["kind"], r.inspect
    assert_includes r["explain"], "(調べた: 1 matches:"
    tools = log_records.select { _1["ev"] == "tool" }
    assert(tools.any? { _1["info"]["pattern"] == "draw_picture" })
    k = log_records.select { _1["ev"] == "knowledge" }.last
    assert_equal "sources", k["origin"]["kind"]
  end

  def test_ask
    r = sender("fmruby-aaa001").run(req("ask", "変数って何?"))
    assert_equal "answer", r["kind"], r.inspect
    assert_includes r["explain"], "変数って何?"
    assert_equal 7, r["base_ver"]
    assert_nil r["doc"]
  end

  def test_hint_keeps_the_code_and_stays_out_of_the_heredoc
    r = sender("fmruby-aaa001").run(req("hint", "[[heredoc]] どこを直せばいい?"), doc: APP_WITH_HEREDOC)
    assert_equal "hint", r["kind"], r.inspect
    doc = r["doc"]
    assert_equal APP_WITH_HEREDOC, C.strip_ai(doc)          # every code line as it was
    assert C.same_code?(APP_WITH_HEREDOC, doc)
    heredoc = doc[/<<~T\n(.*?)\n  T\n/m, 1]
    refute_includes heredoc, "# AI:"                         # nothing went into the heredoc
    assert_equal 2, r["hints"].size
    r["hints"].each { |line, text, comment| assert_equal APP_WITH_HEREDOC.lines[line - 1].chomp, text; refute_empty comment }
  end

  def test_hint_far_line_is_told_in_the_answer
    r = sender("fmruby-aaa001").run(req("hint", "[[far]]"), doc: APP_WITH_HEREDOC)
    assert_equal 1, r["left_out"]
    assert_includes r["explain"], "入れられなかったヒント"
  end

  def test_fix_as_a_hint_carries_the_error
    r = sender("fmruby-aaa001").run(req("hint", "直して", "error" => "NoMethodError: undefined method 'drw'", "cy" => 12),
                                    doc: APP_WITH_HEREDOC)
    assert_equal "hint", r["kind"]
    ask = log_records.reverse.find { _1["ev"] == "ask" && _1["ticket"] == r["ticket"] }
    assert_includes ask["req"]["error"], "NoMethodError"
    llm = log_records.find { _1["ev"] == "llm" && _1["ticket"] == r["ticket"] }
    assert_includes llm["prompt"], "<error>\nNoMethodError"
  end

  def test_make
    r = sender("fmruby-aaa001").run(req("make", "クリックを数えるアプリを作って"))
    assert_equal "doc", r["kind"], r.inspect
    assert_empty C.syntax(r["doc"])
    assert C.app_class?(r["doc"])
    assert_equal r["doc"].bytesize, r["doc_bytes"]
  end

  def test_fix
    r = sender("fmruby-aaa001").run(req("fix", "動かない", "error" => "SyntaxError"), doc: APP_WITH_HEREDOC)
    assert_equal "doc", r["kind"], r.inspect
    assert_includes r["explain"], "直しました"
  end

  # --- checks that ask again ---

  def test_regexp_is_fixed_by_asking_again
    r = sender("fmruby-aaa001").run(req("make", "[[regexp]] アプリを作って"))
    assert_equal "doc", r["kind"], r.inspect
    refute_includes r["doc"], "=~"
    checks = log_records.select { _1["ev"] == "check" && _1["ticket"] == r["ticket"] }
    assert_equal [false, true], checks.map { _1["ok"] }
    assert_equal "regexp_literal", checks[0]["problems"][0]["id"]
    assert_includes r["explain"], "2 回目"
  end

  def test_regexp_that_stays_never_reaches_the_device
    s = sender("fmruby-aaa001")
    tk = s.ask(req("make", "[[regexp_always]] アプリを作って"))["ticket"]
    st = s.wait(tk)
    assert_equal "failed", st["state"]
    assert_includes st["message"], "検査に通らなかった"
    r = s.result(tk)
    assert_equal "check", r["error"]
    assert_nil r["pieces"]
    assert_equal({ "error" => "not_found" }, s.result_piece(tk, 0))
    assert_equal 3, log_records.count { _1["ev"] == "llm" && _1["ticket"] == tk } # first + 2 retries
    s.ack(tk)
  end

  def test_syntax_error_is_fixed
    r = sender("fmruby-aaa001").run(req("make", "[[syntax]] アプリを作って"))
    assert_equal "doc", r["kind"], r.inspect
    assert_empty C.syntax(r["doc"])
  end

  def test_make_without_an_app_class_fails
    r = sender("fmruby-aaa001").run(req("make", "[[noapp]]"))
    assert_equal "check", r["error"]
  end

  # --- pieces, coming back, versions ---

  def big_doc
    body = (1..700).map { "    @v#{_1} = #{_1} # filler line #{_1}\n" }.join
    "class Big < FmrbApp\n  def on_create\n#{body}  end\nend\n"
  end

  def test_document_in_8kb_pieces
    doc = big_doc
    assert_operator doc.bytesize, :>, 20_000
    s = sender("fmruby-aaa001")
    part = s.send_doc(doc)
    assert part["doc"], "sent in pieces"
    tk = s.ask(req("hint", "どう?", "cy" => 300).merge(part))["ticket"]
    s.wait(tk)
    r = s.fetch(tk)
    assert_equal "hint", r["kind"], r.inspect
    assert_operator r["pieces"], :>=, 3
    assert_equal doc, C.strip_ai(r["doc"])
    # the hint goes above the cursor's line (cy 300 is 0-based: line 301, @v299)
    assert_includes r["doc"], "    # AI: ここで何をしたいかを考えてみよう。\n    @v299 = 299"
    s.ack(tk)
    log = log_records.find { _1["ev"] == "ask" && _1["ticket"] == tk }
    assert_equal doc, log["doc_sent"]
  end

  def test_doc_limits
    s = sender("fmruby-aaa001")
    assert_equal "too_large", s.doc_begin(70_000)["error"]
    assert_equal "bad_request", s.ask(req("hint", "x", "doc_text" => "a" * 9000))["error"]
    id = s.doc_begin(10)["doc"]
    s.doc_piece(id, 0, "abc")
    assert_includes s.ask(req("hint", "x", "doc" => id))["message"], "3 of 10"
  end

  def test_pending_after_the_app_went_away
    n = Asterism.connect(ROUTER, node: "fmruby-aaa003", app: "aihelp")
    a = Sender.new(n, MAIN)
    tk = a.ask(req("ask", "[[slow]] 待って"))["ticket"]
    n.close # the app crashed before the answer
    n2 = nil
    20.times do
      n2 = Asterism.connect(ROUTER, node: "fmruby-aaa003", app: "aihelp")
      break
    rescue Asterism::Error
      sleep 0.2
    end
    b = Sender.new(n2, MAIN)
    assert_includes b.pending.map(&:first), tk
    b.wait(tk)
    assert_equal "answer", b.fetch(tk)["kind"]
    assert_equal [[tk, "done"]], b.pending.select { _1[0] == tk }
    b.ack(tk)
    refute_includes b.pending.map(&:first), tk
    n2.close
  end

  def test_rebase_after_the_document_changed
    s = sender("fmruby-aaa001")
    tk = s.ask(req("hint", "どう?", "cy" => 9, "doc_text" => APP_WITH_HEREDOC))["ticket"]
    s.wait(tk)
    first = s.fetch(tk)
    assert_equal 2, first["hints"].size
    # the child wrote three lines at the top while waiting
    now = "# my app\n# by me\n\n#{APP_WITH_HEREDOC}"
    nt = s.rebase(tk, { "doc_text" => now, "ver" => 9 })["ticket"]
    refute_nil nt
    r = s.fetch(nt)
    assert_equal "hint", r["kind"]
    assert_equal 9, r["base_ver"]
    assert_equal now, C.strip_ai(r["doc"])
    first["hints"].zip(r["hints"]).each do |(l1, t1, c1), (l2, t2, c2)|
      assert_equal l1 + 3, l2
      assert_equal t1, t2
      assert_equal c1, c2
    end
    refute_includes s.pending.map(&:first), tk # the old one is taken
    s.ack(nt)
  end

  def test_rebase_leaves_out_a_rewritten_line
    s = sender("fmruby-aaa001")
    tk = s.ask(req("hint", "どう?", "cy" => 9, "doc_text" => APP_WITH_HEREDOC))["ticket"]
    s.wait(tk)
    first = s.fetch(tk)
    line, text, = first["hints"].find { _2.include?("draw_screen") || _2.include?("@n") } || first["hints"].last
    changed = APP_WITH_HEREDOC.sub(text + "\n", "#{text} # changed\n")
    r = s.fetch(s.rebase(tk, { "doc_text" => changed, "ver" => 10 })["ticket"])
    assert_equal 1, r["left_out"], "the hint of line #{line} has no line to go to"
    assert_includes r["explain"], "書きかえたので入れなかったヒント"
    assert_equal changed, C.strip_ai(r["doc"])
  end

  def test_bundle_of_a_newer_firmware_falls_back
    r = sender("fmruby-aaa001").run(req("ask", "版", "fw" => "3.4.0"))
    assert_equal "3.1.0", r["bundle"]
    assert(log_records.any? { _1["ev"] == "bundle_fallback" && _1["ticket"] == r["ticket"] && _1["asked"] == "3.4.0" })
  end

  # --- the talk ---

  def test_talk_goes_on_and_new_talk_forgets
    s = sender("fmruby-aaa002")
    s.new_talk
    assert_includes s.run(req("ask", "1"))["explain"], "0 往復"
    assert_includes s.run(req("ask", "2"))["explain"], "1 往復"
    assert_includes s.run(req("ask", "3"))["explain"], "2 往復"
    s.new_talk
    assert_includes s.run(req("ask", "4"))["explain"], "0 往復"
  end

  # --- refusals ---

  def test_busy_and_cancel
    s = sender("fmruby-aaa004")
    tk = s.ask(req("ask", "[[slow]] 1"))["ticket"]
    assert_equal "busy", s.ask(req("ask", "2"))["error"]
    s.wait(tk)
    s.ack(tk)
    tk2 = s.ask(req("ask", "[[slow]] 3"))["ticket"]
    sleep 0.3
    assert_equal({ "ok" => true }, s.cancel(tk2))
    assert_equal "cancelled", s.wait(tk2)["state"]
    assert_equal "cancelled", s.result(tk2)["error"]
  end

  def test_device_not_listed
    s = sender("fmruby-bad999")
    assert_equal "not_allowed", s.hello["error"]
    assert_equal "not_allowed", s.ask(req("ask", "x"))["error"]
    assert_equal "not_allowed", s.pending["error"]
    assert(log_records.any? { _1["ev"] == "refused" && _1["device"] == "fmruby-bad999" })
  end

  def test_other_devices_tickets_are_not_seen
    a = sender("fmruby-aaa001")
    tk = a.ask(req("ask", "mine"))["ticket"]
    a.wait(tk)
    b = sender("fmruby-aaa002")
    assert_equal "not_found", b.result(tk)["error"]
    refute_includes b.pending.map(&:first), tk
    a.ack(tk)
  end

  def test_modes_turned_off
    s = sender("fmruby-zzz001", OFF)
    assert_equal %w[ask hint], s.hello["modes"]
    assert_equal "mode_off", s.ask(req("make", "x"))["error"]
    assert_equal "mode_off", s.ask(req("fix", "x", "doc_text" => "x = 1\n"))["error"]
  end

  def test_daily_limit
    s = sender("fmruby-lim001", OFF)
    3.times { |i| assert_equal "answer", s.run(req("ask", "q#{i}"))["kind"] }
    r = s.ask(req("ask", "one more"))
    assert_equal "limit", r["error"]
    assert_includes r["message"], "3 回"
    assert_equal 3, s.hello["used"]
    other = sender("fmruby-lim002", OFF)                     # another device still may
    assert_equal "answer", other.run(req("ask", "q"))["kind"]
  end

  # --- a restart on the same volume (the container made again) ---

  RS = "tutor-rs/tutor/helper".freeze
  RS_TOML = <<~TOML.freeze
    [network]
    router = "#{ROUTER}"
    node = "tutor-rs"
    devices = ["fmruby-rst001", "fmruby-rst002"]
    [llm]
    provider = "fake"
    [jobs]
    stop_grace_s = 1
    [store]
    log_dir = "#{WORK}/log_rs"
    state_dir = "#{WORK}/state_rs"
  TOML

  # The status command; want: retried for a few seconds until it says so
  # (the gem writes its status every 2 s).
  def status_cmd(cfg, want: nil)
    t = Time.now
    loop do
      out, code = Open3.capture2e("bundle", "exec", "ruby", EXE, "status", "--config", cfg)
      return [code.exitstatus, out] if want.nil? || code.exitstatus == want || Time.now - t > 6
      sleep 0.5
    end
  end

  def test_sigterm_and_restart_keep_results_counts_and_cost
    gem = self.class.start("rs", RS_TOML)
    cfg = File.join(WORK, "rs.toml")
    code, out = status_cmd(cfg, want: 0)
    assert_equal 0, code, out
    assert_includes out, "up, joined"
    a = sender("fmruby-rst001", RS)
    done = a.run(req("ask", "取りに来ない答え"), ack: false)
    assert_equal "answer", done["kind"]
    b = sender("fmruby-rst002", RS)
    long = b.ask(req("ask", "[[wait 20]] 長い頼み"))["ticket"]
    sleep 0.5
    used = a.hello["used"]
    cost = log_records("rs").select { _1["ev"] == "llm" }.sum { _1["cost_usd"].to_f }
    t0 = Time.now
    Process.kill("TERM", gem.pid)
    assert gem.join(15), "the gem ends after SIGTERM"
    assert_operator Time.now - t0, :<, 10
    assert_equal 0, gem.value.exitstatus
    code, out = status_cmd(cfg)
    assert_equal 1, code, out                                # stopped: not healthy

    gem = self.class.start("rs", RS_TOML)
    begin
      code, out = status_cmd(cfg, want: 0)
      assert_equal 0, code, out
      a = sender("fmruby-rst001", RS)
      assert_equal used, a.hello["used"]                     # the day's count came back
      assert_includes a.pending, [done["ticket"], "done"]    # the result not fetched
      assert_equal done["explain"], a.result(done["ticket"])["explain"]
      b = sender("fmruby-rst002", RS)
      r = b.result(long)                                     # the one cut by the stop
      assert_equal "stopped", r["error"]
      assert_equal Tutor::Jobs::STOPPED, r["message"]
      assert_equal 0, b.hello["used"]                       # the one cut by the stop is not counted
      after = Tutor::Status.read(File.join(WORK, "state_rs", "status.json"))
      assert_operator cost, :>, 0
      assert_in_delta cost, after["cost_today"], 1e-6        # the day's cost came back
    ensure
      Process.kill("TERM", gem.pid) rescue nil
      gem.join(15)
    end
  end

  # --- the record ---

  def test_record_has_everything_and_no_key
    r = sender("fmruby-aaa001").run(req("hint", "記録の試験"), doc: APP_WITH_HEREDOC)
    recs = log_records.select { _1["ticket"] == r["ticket"] }
    evs = recs.map { _1["ev"] }
    %w[ask llm check result].each { assert_includes evs, _1 }
    ask = recs.find { _1["ev"] == "ask" }
    assert_equal APP_WITH_HEREDOC, ask["doc_sent"]
    assert_equal "記録の試験", ask["req"]["text"]
    llm = recs.find { _1["ev"] == "llm" }
    assert llm["answer"]
    assert_includes llm["prompt"], "記録の試験"
    %w[in out cache_write cache_read].each { assert llm["usage"].key?(_1) }
    assert llm.key?("cost_usd")
    assert recs.find { _1["ev"] == "result" }["doc"]
    Dir[File.join(WORK, "**", "*")].select { File.file?(_1) }.each do |f|
      refute_includes File.read(f), KEY_PREFIX, f
    end
  end
end
