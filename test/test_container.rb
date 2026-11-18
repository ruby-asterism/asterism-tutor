require_relative "test_helper"
require "fileutils"

# What running in a container needs, without the network: the settings
# from the environment, the tickets kept on disk, the status file and the
# stop on SIGTERM (Jobs#shutdown).
class TestContainer < Minitest::Test
  TMP = Dir.mktmpdir("asterism-tutor-container")
  Minitest.after_run { FileUtils.rm_rf(TMP) }

  def dirs
    { "store" => { "log_dir" => Dir.mktmpdir(nil, TMP), "state_dir" => Dir.mktmpdir(nil, TMP) } }
  end

  def cfg(over = {}, env: {})
    Tutor::Config.load(nil, Tutor::Config.deep_merge(dirs, over), env: env)
  end

  # --- settings from the environment ---

  ENV_ALL = {
    "ASTERISM_TUTOR_ROUTER" => "tls/zenohd:7448",
    "ASTERISM_TUTOR_CREDENTIALS" => "/credentials/tutor.tar",
    "ASTERISM_TUTOR_NODE" => "tutor-vps",
    "ASTERISM_TUTOR_DEVICES" => "fmruby-aaaaaa, fmruby-bbbbbb wasm-alice",
    "ASTERISM_TUTOR_LLM" => "anthropic",
    "ASTERISM_TUTOR_MODEL" => "claude-sonnet-5-5",
    "ASTERISM_TUTOR_PER_DAY" => "20",
    "ASTERISM_TUTOR_COST_PER_DAY" => "0.5",
    "ASTERISM_TUTOR_LOG_DIR" => "/state/log",
    "ASTERISM_TUTOR_STATE_DIR" => "/state/store",
    "ASTERISM_TUTOR_MAKE" => "false",
    "ASTERISM_TUTOR_FIX" => "0",
    "ASTERISM_TUTOR_STOP_GRACE" => "3"
  }.freeze

  def test_every_setting_from_the_environment
    c = Tutor::Config.load(nil, {}, env: ENV_ALL)
    assert_equal "tls/zenohd:7448", c.dig("network", "router")
    assert_equal "/credentials/tutor.tar", c.dig("network", "credentials")
    assert_equal "tutor-vps", c.dig("network", "node")
    assert_equal %w[fmruby-aaaaaa fmruby-bbbbbb wasm-alice], c.dig("network", "devices")
    assert_equal "anthropic", c.dig("llm", "provider")
    assert_equal "claude-sonnet-5-5", c.dig("llm", "model")
    assert_equal 20, c.dig("limits", "per_device_per_day")
    assert_in_delta 0.5, c.dig("limits", "cost_per_day_usd")
    assert_equal "/state/log", c.log_dir
    assert_equal "/state/store", c.state_dir
    assert_equal %w[ask hint], c.modes
    assert_in_delta 3.0, c.dig("jobs", "stop_grace_s")
    assert_equal "AI helper", c.dig("network", "name")        # not in the environment: the default
    assert_equal ENV_ALL.keys.sort, Tutor::Config::ENV_KEYS.keys.sort
  end

  def test_options_over_environment_over_file_over_defaults
    file = File.join(Dir.mktmpdir(nil, TMP), "tutor.toml")
    File.write(file, <<~TOML)
      [network]
      node = "from-file"
      router = "tcp/192.0.2.1:7447"
      [limits]
      per_device_per_day = 7
      cost_per_day_usd = 3.0
    TOML
    env = { "ASTERISM_TUTOR_PER_DAY" => "9", "ASTERISM_TUTOR_NODE" => "from-env" }
    c = Tutor::Config.load(file, { "network" => { "node" => "from-option" } }, env: env)
    assert_equal "from-option", c.dig("network", "node")      # option
    assert_equal 9, c.dig("limits", "per_device_per_day")      # environment over file
    assert_in_delta 3.0, c.dig("limits", "cost_per_day_usd")   # file over default
    assert_equal "tcp/192.0.2.1:7447", c.dig("network", "router")
    assert_equal "claude-haiku-5-5", c.dig("llm", "model")     # default
  end

  def test_config_file_from_the_environment
    file = File.join(Dir.mktmpdir(nil, TMP), "tutor.toml")
    File.write(file, "[network]\nnode = \"named-in-env\"\n")
    assert_equal "named-in-env", Tutor::Config.load(nil, {}, env: { "ASTERISM_TUTOR_CONFIG" => file }).dig("network", "node")
    assert_raises(Tutor::Config::Error) { Tutor::Config.load(nil, {}, env: { "ASTERISM_TUTOR_CONFIG" => "#{file}.none" }) }
  end

  def test_empty_values
    c = Tutor::Config.load(nil, {}, env: { "ASTERISM_TUTOR_MODEL" => "", "ASTERISM_TUTOR_ROUTER" => "" })
    assert_equal "claude-haiku-5-5", c.dig("llm", "model")     # empty: as if unset
    assert_equal "", c.dig("network", "router")                # empty router: the credentials' router
  end

  def test_bad_values_are_told
    { "ASTERISM_TUTOR_PER_DAY" => "ten", "ASTERISM_TUTOR_COST_PER_DAY" => "1usd", "ASTERISM_TUTOR_MAKE" => "maybe" }.each do |k, v|
      e = assert_raises(Tutor::Config::Error) { Tutor::Config.load(nil, {}, env: { k => v }) }
      assert_includes e.message, k
    end
  end

  # --- tickets on disk ---

  def test_tickets_survive_a_new_store
    c = cfg
    now = Time.now
    s = Tutor::Store.new(c, clock: -> { now })
    done = s.new_ticket("d1", "req" => { "mode" => "ask" }, "doc" => "x = 1\n")
    s.update(done, "state" => "done", "result" => { "kind" => "answer", "explain" => "はい" }, "doc_pieces" => ["a"],
                   "done_at" => now)
    acked = s.new_ticket("d1", "req" => {})
    s.update(acked, "state" => "done")
    s.ack("d1", acked)
    s2 = Tutor::Store.new(c, clock: -> { now })
    assert_equal [[done, "done"]], s2.pending("d1")
    t = s2.ticket(done)
    assert_equal "はい", t["result"]["explain"]
    assert_equal ["a"], t["doc_pieces"]
    assert_kind_of Time, t["created"]
    assert_kind_of Time, t["done_at"]
    assert_empty Dir[File.join(s2.dir, "*.tmp")]
  end

  def test_purged_tickets_leave_the_disk
    c = cfg
    now = Time.now
    s = Tutor::Store.new(c, clock: -> { now })
    id = s.new_ticket("d1", "req" => {})
    s.update(id, "state" => "done")
    assert File.exist?(s.file(id))
    now += 25 * 3600
    assert_empty s.pending("d1")
    refute File.exist?(s.file(id))
  end

  def test_a_broken_ticket_file_is_skipped
    c = cfg
    s = Tutor::Store.new(c)
    File.write(File.join(s.dir, "t0000000a.json"), "{not json")
    _out, err = capture_io { Tutor::Store.new(c) }
    assert_includes err, "t0000000a.json"
  end

  def server(c, llm: Tutor::LLM::Fake.new)
    Tutor::Server.new(c, llm: llm)
  end

  # A request being worked on when the process went away (killed) is
  # failed at the next start, and the device reads why.
  def test_interrupted_requests_fail_at_start
    c = cfg
    s = Tutor::Store.new(c)
    id = s.new_ticket("d1", "req" => { "mode" => "ask" })
    s.update(id, "state" => "thinking")
    srv = nil
    _out, err = capture_io { srv = server(c) }
    assert_includes err, id
    r = srv.helper.result(id, from: "d1")
    assert_equal "stopped", r["error"]
    assert_equal Tutor::Jobs::STOPPED, r["message"]
    assert_equal [[id, "failed"]], srv.helper.pending(from: "d1")
    srv.jobs.stop
  end

  # --- the stop on SIGTERM ---

  def ask(srv, device, text)
    srv.helper.ask({ "mode" => "ask", "text" => text, "fw" => "3.1.0" }, from: device)
  end

  def wait_state(srv, id, states, max = 10)
    t = Time.now
    sleep 0.05 until states.include?(srv.store.ticket(id)["state"]) || Time.now - t > max
    srv.store.ticket(id)["state"]
  end

  def test_shutdown_waits_for_a_short_request
    srv = server(cfg)
    id = ask(srv, "d1", "[[wait 1]] まって")["ticket"]
    wait_state(srv, id, %w[thinking])
    left = srv.jobs.shutdown(5)
    assert_empty left
    assert_equal "done", srv.store.ticket(id)["state"]
    r = ask(srv, "d2", "あとから")
    assert_equal "stopping", r["error"]
    refute_empty r["message"]
    srv.jobs.stop
  end

  def test_shutdown_fails_what_does_not_end_in_time
    c = cfg({ "jobs" => { "workers" => 1 } })
    srv = server(c)
    long = ask(srv, "d1", "[[wait 5]] ながい")["ticket"]
    queued = ask(srv, "d2", "うしろ")["ticket"]
    wait_state(srv, long, %w[thinking])
    t0 = Time.now
    left = srv.jobs.shutdown(0.5)
    assert_operator Time.now - t0, :<, 3
    assert_equal [long, queued].sort, left.sort
    [long, queued].each do |id|
      t = srv.store.ticket(id)
      assert_equal "failed", t["state"]
      assert_equal "stopped", t["error"]
    end
    # The worker ends later and writes nothing over it; a new store (the
    # next start) reads the same.
    sleep 5.5
    assert_equal "failed", srv.store.ticket(long)["state"]
    again = Tutor::Store.new(c)
    assert_equal "failed", again.ticket(long)["state"]
    assert_empty again.interrupted
    recs = srv.log.records.select { _1["ev"] == "failed" && _1["error"] == "stopped" }
    assert_equal [long, queued].sort, recs.map { _1["ticket"] }.sort
  end

  # --- the status file ---

  def status(over = {})
    { "version" => "0.2.0", "path" => "tutor/tutor", "at" => Time.now.iso8601(3), "since" => Time.now.iso8601,
      "connected" => true, "reconnecting" => false, "exposed" => true, "stopping" => false, "llm" => "fake",
      "model" => "claude-haiku-5-5", "active" => 0, "requests_today" => 3, "cost_today" => 0.01 }.merge(over)
  end

  def test_status_check
    assert_equal 0, Tutor::Status.check(status)[0]
    assert_equal 1, Tutor::Status.check(status("connected" => false, "reconnecting" => true))[0]
    assert_includes Tutor::Status.check(status("connected" => false, "reconnecting" => true))[1], "router is away"
    assert_equal 1, Tutor::Status.check(status("exposed" => false))[0]
    assert_equal 1, Tutor::Status.check(status("stopping" => true))[0]
    assert_equal 2, Tutor::Status.check(status("at" => (Time.now - 60).iso8601(3)))[0]
    assert_equal 2, Tutor::Status.check(nil)[0]
  end

  def test_status_file_round_trip
    c = cfg
    path = Tutor::Status.path(c)
    Tutor::Status.write(path, status)
    assert_equal 0, Tutor::Status.check(Tutor::Status.read(path))[0]
    assert_empty Dir[File.join(c.state_dir, "*.tmp")]
  end

  def test_server_status_before_it_connects
    srv = server(cfg)
    s = srv.status_now
    refute s["connected"]
    assert_equal Tutor::VERSION, s["version"]
    assert_equal 1, Tutor::Status.check(s)[0]
    srv.jobs.stop
  end
end
