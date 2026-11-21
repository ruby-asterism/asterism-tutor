require_relative "test_helper"
require_relative "sources_fixture"
require "fileutils"

# The rounds of look-ups with the fake LLM, through the helper as a device
# calls it (no router): what is called, the cap, the record, the cost.
class TestLookupFlow < Minitest::Test
  TMP = Dir.mktmpdir("asterism-tutor-lookup")
  Minitest.after_run { FileUtils.rm_rf(TMP) }

  def setup
    @work = Dir.mktmpdir(nil, TMP)
    @repos = SourcesFixture.build(@work)
  end

  def server(over = {})
    base = {
      "store" => { "log_dir" => File.join(@work, "log"), "state_dir" => File.join(@work, "state") },
      "sources" => { "core" => @repos[:core], "asterism" => @repos[:asterism], "git_timeout_s" => 60 }
    }
    c = Tutor::Config.load(nil, Tutor::Config.deep_merge(base, over), env: {})
    srv = Tutor::Server.new(c, llm: Tutor::LLM::Fake.new)
    srv.knowledge.sources&.refresh("develop")
    @srv = srv
  end

  def teardown
    @srv&.jobs&.stop
  end

  def run_req(text, mode: "ask", doc: nil)
    req = { "mode" => mode, "text" => text, "fw" => "3.1.0" }
    req["doc_text"] = doc if doc
    id = @srv.helper.ask(req, from: "d1")["ticket"]
    assert id
    t0 = Time.now
    sleep 0.05 until %w[done failed].include?(@srv.store.ticket(id)["state"]) || Time.now - t0 > 20
    [id, @srv.helper.result(id, from: "d1")]
  end

  def recs(id, ev) = @srv.log.records.select { _1["ticket"] == id && _1["ev"] == ev }

  def test_a_plain_question_looks_nothing_up
    server
    id, r = run_req("変数って何?")
    assert_equal "answer", r["kind"]
    refute_includes r["explain"], "調べた"
    assert_equal 1, recs(id, "llm").size
    assert_empty recs(id, "tool")
    k = recs(id, "knowledge").first["origin"]
    assert_equal "sources", k["kind"]
    assert_equal "develop", k["ref"]
    assert k["tools"]
    assert_equal 0, recs(id, "result").first["used"]["rounds"]
  end

  def test_search_then_read
    server
    id, r = run_req("絵を出したい [[search draw_picture]] [[read sig/fmrb_gfx.rbs]]")
    assert_equal "answer", r["kind"], r.inspect
    assert_includes r["explain"], "(調べた: 1 matches: / sig/fmrb_gfx.rbs lines 1-5 of 6)"
    llm = recs(id, "llm")
    assert_equal [0, 1, 2], llm.map { _1["round"] }
    assert_equal ["search_source"], llm[0]["tool_calls"].map { _1["name"] }
    assert_nil llm[1]["prompt"], "the tool results are in the tool records, not again in the prompt"
    tools = recs(id, "tool")
    assert_equal %w[search_source read_source], tools.map { _1["name"] }
    assert_equal 1, tools[0]["info"]["matches"]
    assert_includes tools[0]["text"], "sig/fmrb_gfx.rbs:5:"
    assert_equal "sig/fmrb_gfx.rbs", tools[1]["info"]["path"]
    used = recs(id, "result").first["used"]
    assert_equal 2, used["rounds"]
    assert_equal 3, used["calls"]
    assert_equal llm.sum { _1["usage"]["in"] }, used["usage"]["in"]
    assert_in_delta llm.sum { _1["cost_usd"] }, @srv.limits.cost_today, 1e-6
  end

  def test_rounds_stop_at_the_cap
    server
    id, r = run_req("[[lookup_loop]] ずっと調べる")
    assert_equal "answer", r["kind"]
    assert_equal 4, recs(id, "tool").size
    assert_equal 5, recs(id, "llm").size
    assert_nil recs(id, "llm").last["tool_calls"]
    assert_equal 4, recs(id, "result").first["used"]["rounds"]
  end

  def test_the_cap_is_a_setting
    server("lookup" => { "rounds" => 1 })
    id, = run_req("[[lookup_loop]] ずっと調べる")
    assert_equal 1, recs(id, "tool").size
    assert_equal 2, recs(id, "llm").size
  end

  def test_no_tools_when_rounds_is_zero
    server("lookup" => { "rounds" => 0 })
    id, r = run_req("[[search draw_picture]] 調べて")
    assert_equal "answer", r["kind"]
    assert_empty recs(id, "tool")
    refute recs(id, "knowledge").first["origin"]["tools"]
  end

  def test_a_path_outside_comes_back_as_an_error
    server
    id, r = run_req("[[read ../../etc/passwd]] 読んで")
    assert_equal "answer", r["kind"]
    t = recs(id, "tool").first
    assert t["error"]
    assert_includes r["explain"], "no such file in scope"
  end

  def test_look_ups_and_a_fix_after_the_check
    server
    id, r = run_req("[[regexp]] [[search draw_picture]] 作って", mode: "make")
    assert_equal "doc", r["kind"], r.inspect
    llm = recs(id, "llm")
    assert_equal [0, 0, 1], llm.map { _1["attempt"] }
    assert_equal 1, recs(id, "tool").size, "the look-up is not made again for the fix"
    assert_equal [false, true], recs(id, "check").map { _1["ok"] }
  end

  def test_without_sources_the_gem_bundle_answers
    server("sources" => { "enabled" => false })
    id, r = run_req("[[search draw_picture]] 調べて")
    assert_equal "answer", r["kind"]
    assert_equal "gem", recs(id, "knowledge").first["origin"]["kind"]
    assert_empty recs(id, "tool")
  end
end
