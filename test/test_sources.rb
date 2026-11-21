require_relative "test_helper"
require_relative "sources_fixture"
require "fileutils"

# The sources (clone, versions, snapshots, failures), the bundle made from
# them, and the two tools' limits. Local git repositories only.
class TestSources < Minitest::Test
  TMP = Dir.mktmpdir("asterism-tutor-sources")
  Minitest.after_run { FileUtils.rm_rf(TMP) }

  def setup
    @work = Dir.mktmpdir(nil, TMP)
    @repos = SourcesFixture.build(@work)
  end

  def cfg(over = {})
    base = {
      "store" => { "log_dir" => File.join(@work, "log"), "state_dir" => File.join(@work, "state") },
      "sources" => { "core" => @repos[:core], "asterism" => @repos[:asterism], "git_timeout_s" => 60 }
    }
    Tutor::Config.load(nil, Tutor::Config.deep_merge(base, over), env: {})
  end

  def sources(c = cfg) = Tutor::Sources.new(c, log: Tutor::Log.new(c.log_dir))

  # --- versions ---

  def test_the_tag_for_a_released_version_and_develop_for_others
    s = sources
    s.refresh_tags
    assert_equal "3.0.0", s.ref_for("3.0.0")
    assert_equal "develop", s.ref_for("3.1.0")      # no tag yet: a version being developed
    assert_equal "develop", s.ref_for("")
    assert_equal "develop", s.ref_for("../../x")     # not a version's shape
    assert_equal "develop", s.ref_for("-u")
    old = s.refresh("3.0.0")
    dev = s.refresh("develop")
    assert_equal "3.0.0", old.fw
    assert_equal "3.1.0", dev.fw
    refute_equal old.core_commit, dev.core_commit
    refute_includes File.read(File.join(old.bundle, "api.rbs")), "draw_picture"
    assert_includes File.read(File.join(dev.bundle, "api.rbs")), "draw_picture"
  end

  def test_tags_unknown_uses_a_tag_on_disk
    c = cfg
    s = sources(c)
    s.refresh_tags
    s.refresh("3.0.0")
    broken = cfg("sources" => { "core" => "file://#{@work}/nothing" })
    s2 = sources(broken) # the same dir, the tags remembered
    assert_equal "3.0.0", s2.ref_for("3.0.0")
    File.delete(File.join(c.sources_dir, "state.json"))
    s3 = sources(broken) # nothing remembered: a snapshot of the tag is not known either
    assert_equal "develop", s3.ref_for("3.0.0")
  end

  # --- what is fetched ---

  def test_sparse_and_shallow
    snap = sources.refresh("develop")
    assert File.file?(File.join(snap.core, "sig/fmrb_gfx.rbs"))
    assert File.file?(File.join(snap.core, "flash/app/modern/chat.app.rb"))
    assert File.file?(File.join(snap.core, "lib/gems/picoruby-fmrb-asterism/mrblib/asterism.rb"))
    refute File.exist?(File.join(snap.core, "components/big")), "components/ is not checked out"
    refute File.exist?(File.join(snap.core, "flash/app/test")), "an excluded directory is not checked out"
    refute File.exist?(File.join(snap.core, "lib/gems/picoruby-fmrb-asterism/src")), "C sources are not checked out"
    refute File.exist?(File.join(snap.core, "doc/plan.md"))
    assert_equal "1", SourcesFixture.git(snap.core, "rev-list", "--count", "HEAD").strip # shallow
    refute File.exist?(File.join(snap.asterism, "lib/big.rb"))
  end

  def test_the_same_sources_give_the_same_bundle_text
    a = sources(cfg).refresh("develop")
    other = cfg("sources" => { "dir" => File.join(@work, "other") })
    b = sources(other).refresh("develop")
    refute_equal a.bundle, b.bundle
    ta = Tutor::Bundle.new(nil, a.fw, dir: a.bundle, source: a.ref).text
    tb = Tutor::Bundle.new(nil, b.fw, dir: b.bundle, source: b.ref).text
    assert_equal ta, tb
    assert_includes ta, "draw_picture"
    checks = JSON.parse(File.read(File.join(a.bundle, "checks.json")))["checks"].map { _1["id"] }
    assert_includes checks, "regexp_literal"
    assert_includes checks, "array_sum"
    refute_includes checks, "string_upcase"
  end

  def test_no_clone_when_nothing_changed
    s = sources
    a = s.refresh("develop")
    mark = File.join(a.core, "untouched")
    File.write(mark, "")
    b = s.refresh("develop")
    assert_equal a.core, b.core
    assert File.exist?(mark)
  end

  # --- updates under a request ---

  def test_a_request_keeps_its_snapshot_through_an_update
    s = sources
    first = s.refresh("develop")
    held = s.acquire("3.1.0")
    assert_equal first.core, held.core
    SourcesFixture.move_develop(@repos[:core_dir])
    second = s.refresh("develop")
    refute_equal first.core, second.core
    assert File.directory?(first.core), "the old snapshot stays while a request has it"
    assert File.file?(File.join(second.core, "sig/fmrb_net.rbs"))
    assert_equal second.core, s.acquire("3.1.0").core
    s.release(held)
    refute File.exist?(first.core), "deleted once nothing uses it"
    refute File.exist?(first.bundle)
  end

  # --- failures ---

  def test_a_failed_fetch_keeps_the_snapshot_on_disk
    c = cfg
    s = sources(c)
    good = s.refresh("develop")
    FileUtils.mv(@repos[:core_dir], "#{@repos[:core_dir]}.away") # the network is down
    e = assert_raises(Tutor::Sources::FetchError) { s.refresh("develop") }
    assert_match(/git ls-remote/, e.message)
    held = s.acquire("3.1.0")
    assert_equal good.core, held.core
    st = s.status
    assert st["errors"]["develop"]["message"]
    assert_equal good.core_commit[0, 12], st["refs"]["develop"]["core"]
    # and after a restart, offline: the same snapshot from state.json
    s2 = sources(c)
    assert_equal good.core, s2.acquire("3.1.0").core
    recs = File.readlines(Tutor::Log.new(c.log_dir).path).map { JSON.parse(_1) }.select { _1["ev"] == "sources" }
    assert(recs.any? { _1["ok"] == false })
    assert(recs.any? { _1["ok"] == true && _1["disk_bytes"].positive? })
  end

  def test_nothing_on_disk_and_no_fetch_gives_the_gem_bundle
    c = cfg("sources" => { "core" => "file://#{@work}/nothing" })
    k = Tutor::Knowledge.new(c, log: Tutor::Log.new(c.log_dir))
    k.sources.instance_variable_set(:@started, true) # fetch on demand, as after start
    use = k.acquire("3.1.0")
    assert_equal "gem", use.origin["kind"]
    assert_match(/develop: git ls-remote/, use.origin["why"])
    assert_nil use.lookup
    assert_equal "3.1.0", use.bundle.fw
    k.release(use)
  end

  def test_remote_urls_are_off_in_the_tests
    c = cfg("sources" => { "core" => "https://example.org/x.git" })
    e = assert_raises(Tutor::Sources::FetchError) { sources(c).refresh("develop") }
    assert_match(/remote sources are off/, e.message)
  end

  def test_knowledge_from_sources_and_from_the_parents_dir
    c = cfg
    k = Tutor::Knowledge.new(c, log: Tutor::Log.new(c.log_dir))
    k.sources.refresh("develop")
    use = k.acquire("3.1.0")
    assert_equal "sources", use.origin["kind"]
    assert_equal "develop", use.origin["ref"]
    assert use.lookup
    refute use.bundle.fallback?
    assert_includes use.bundle.text, "draw_picture"
    k.release(use)
    own = cfg("bundle" => { "dir" => File.expand_path("../bundles", __dir__) })
    k2 = Tutor::Knowledge.new(own, log: Tutor::Log.new(own.log_dir))
    use2 = k2.acquire("3.1.0")
    assert_equal "dir", use2.origin["kind"]
    assert use2.lookup, "the parent's bundle, and the tools on the sources"
    k2.release(use2)
    off = cfg("lookup" => { "rounds" => 0 })
    use3 = Tutor::Knowledge.new(off, log: Tutor::Log.new(off.log_dir)).acquire("3.1.0")
    assert_nil use3.lookup
  end

  # --- the tools ---

  def lookup(over = {})
    snap = sources.refresh("develop")
    Tutor::Lookup.new(snap.core, Tutor::Lookup::SCOPE, **over)
  end

  def test_scope_leaves_out_tests_mahjong_big_rb_and_c
    l = lookup
    files = l.files.keys
    assert_includes files, "flash/app/modern/chat.app.rb"
    assert_includes files, "lib/gems/picoruby-fmrb-asterism/mrblib/asterism.rb"
    assert_includes files, "flash/usr/share/doc/chat.md"
    r = l.search("FmrbAsterism")
    assert_includes r["text"], "flash/app/modern/chat.app.rb:2:"
    refute_includes r["text"], "flash/app/test/"
    refute_includes r["text"], "mahjong"
    refute_includes r["text"], "huge.app.rb"
    refute_includes r["text"], ".c:"
    refute_includes r["text"], "doc/plan.md"
  end

  def test_reading_outside_is_refused
    l = lookup
    root = l.root
    File.write(File.join(@work, "secret.txt"), "TOP-SECRET-CONTENT\n")
    File.symlink(File.join(@work, "secret.txt"), File.join(root, "sig", "link.rbs"))
    FileUtils.mkdir_p(File.join(root, "flash/app/x"))
    File.symlink(@work, File.join(root, "flash/app/x/dirlink"))
    ["../secret.txt", "sig/../../secret.txt", File.join(@work, "secret.txt"), "/etc/passwd", "sig/link.rbs",
     "flash/app/x/dirlink/secret.txt", "components/fmrb_common/include/fmrb.h", "flash/app/test/odd.app.rb"].each do |p|
      r = l.read(p, 1, 10)
      assert r["error"], "#{p} is refused"
      refute_includes r["text"], "TOP-SECRET"
    end
    assert l.search("TOP-SECRET")["text"].start_with?("no match")
  end

  def test_limits_of_search_and_read
    l = lookup(hits: 3, lines: 4, line_chars: 20)
    r = l.search("e")
    assert_equal 4, r["text"].lines.size # the head and 3
    assert_match(/\A\d+ matches, the first 3:/, r["text"])
    assert_operator r["info"]["matches"], :>, 3
    huge = File.join(l.root, "flash/app/modern/long.app.rb")
    File.write(huge, "#{'y' * 300}\n" * 50)
    l2 = Tutor::Lookup.new(l.root, Tutor::Lookup::SCOPE, hits: 3, lines: 4, line_chars: 20)
    rd = l2.read("flash/app/modern/long.app.rb", 10, 40)
    assert_equal "flash/app/modern/long.app.rb lines 10-13 of 50", rd["text"].lines.first.strip
    assert_equal 5, rd["text"].lines.size
    assert_operator rd["text"].lines.map(&:size).max, :<, 60
    assert l2.search("x", regexp: true, path: "nowhere/")["text"].start_with?("no match")
    assert l2.search("(", regexp: true)["error"]
    assert l2.search("")["error"]
    assert l2.search("a" * 300)["error"]
    assert l2.call("rm_rf", {})["error"]
    assert_includes l2.search("FMRBASTERISM", ignore_case: true)["text"], "matches"
  end
end
