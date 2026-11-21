require "json"
require "fileutils"
require "open3"
require "time"

module Tutor
  # The Family mruby sources the gem keeps (sources.*): fmruby-core and
  # asterism, cloned from their public repositories, shallow, partial
  # (blob:none) and sparse (only the paths the bundle and the tools read; no
  # submodule, no components/). The bundle of every request is made from
  # them (BundleMaker) and the LLM's tools look into the core one (Lookup).
  #
  # The version: a device sends its firmware version (FmrbConst::OS_VERSION,
  # "3.1.0"); when fmruby-core has a tag of that name, the tag, else the
  # branch (develop). Each ref is a snapshot of its own on disk:
  #   <dir>/core/<ref>@<commit>/       a checkout
  #   <dir>/asterism/<branch>@<commit>/
  #   <dir>/bundles/<ref>@<core>-<asterism>/
  #   <dir>/state.json                 the current snapshot of each ref, the tags
  # A new commit is cloned beside the old one and swapped in when ready, so a
  # request keeps the snapshot it started with (acquire / release); an old
  # one is deleted once nothing uses it.
  #
  # When: at start (start), then every refresh_hours; a ref asked for the
  # first time (a tag) is fetched then. When a fetch fails, the snapshot on
  # disk stays in use; with none, the caller uses the bundle in the gem.
  class Sources
    class FetchError < StandardError; end

    # A ref's snapshot: the dirs are absolute.
    Snapshot = Struct.new(:ref, :fw, :core, :core_commit, :asterism, :asterism_commit, :bundle, :fetched_at, :checked_at,
                          keyword_init: true) do
      def key = "#{ref}@#{core_commit}-#{asterism_commit}"
      def to_h_rel(base) = to_h.to_h { |k, v| [k.to_s, v.is_a?(String) && v.start_with?("#{base}/") ? v.delete_prefix("#{base}/") : v] }
    end

    FW_SHAPE = /\A[0-9A-Za-z][0-9A-Za-z._-]{0,31}\z/
    LOCAL_ONLY = "ASTERISM_TUTOR_SOURCES_LOCAL_ONLY".freeze # the tests: no URL but file:// and paths

    attr_reader :dir, :log

    def initialize(cfg, log: nil, clock: -> { Time.now })
      @cfg = cfg
      @s = cfg["sources"]
      @dir = cfg.sources_dir
      @log = log
      @clock = clock
      @lock = Monitor.new
      @fetch_lock = Mutex.new # one fetch at a time; gc only between fetches
      @in_use = Hash.new(0)
      @in_use_snaps = {}
      @snaps = {}
      @tags = nil
      @tags_at = nil
      @errors = {}
      @stop_q = Queue.new
      @started = false
      FileUtils.mkdir_p(@dir)
      load_state
      gc
    end

    def branch = @s["branch"].to_s
    def asterism_branch = @s["asterism_branch"].to_s
    def scope = Array(@s["search"])
    def started? = @started

    # Fetches the branch (and the refs already on disk) now, in the
    # background, and again every refresh_hours.
    def start
      return if @started
      @started = true
      @thread = Thread.new do
        loop do
          refresh_all
          break if @stop_q.pop(timeout: @s["refresh_hours"].to_f * 3600)
        end
      rescue StandardError => e
        warn "asterism-tutor: sources: #{e.class}: #{e.message}"
      end
    end

    def stop
      @stop_q << :stop
      @thread&.join(1)
    end

    def refresh_all
      refresh_tags
      refs = @lock.synchronize { ([branch] + @snaps.keys).uniq }
      refs.each do |ref|
        refresh(ref)
      rescue FetchError
        nil # recorded by refresh
      end
    end

    # The ref for a device's version: its tag when fmruby-core has one, else
    # the branch. When the tags are unknown (never listed), a snapshot of the
    # tag on disk counts as the tag.
    def ref_for(fw)
      fw = fw.to_s
      return branch unless fw.match?(FW_SHAPE)
      tags = @lock.synchronize { @tags }
      if tags
        tags.include?(fw) ? fw : branch
      else
        @lock.synchronize { @snaps.key?(fw) } ? fw : branch
      end
    end

    # The snapshot for a device's version and why it is that one, held until
    # release(snapshot). nil when there is none (the caller uses the gem's
    # bundle). A ref with no snapshot is fetched first when started.
    def acquire(fw)
      ref = ref_for(fw)
      snap = @lock.synchronize { @snaps[ref] }
      if snap.nil? && @started
        begin
          snap = refresh(ref)
        rescue FetchError
          snap = nil
        end
      end
      return nil unless snap
      @lock.synchronize do
        @in_use[snap.key] += 1
        @in_use_snaps[snap.key] = snap
      end
      snap
    end

    def release(snap)
      return unless snap
      @lock.synchronize do
        @in_use[snap.key] -= 1
        if @in_use[snap.key] <= 0
          @in_use.delete(snap.key)
          @in_use_snaps.delete(snap.key)
        end
      end
      gc
    end

    def error_for(ref) = @lock.synchronize { @errors[ref] }

    # What the status shows: each ref's commits and times, the last errors.
    def status
      @lock.synchronize do
        { "refs" => @snaps.transform_values do |s|
          { "fw" => s.fw, "core" => s.core_commit.to_s[0, 12], "asterism" => s.asterism_commit.to_s[0, 12],
            "fetched_at" => s.fetched_at, "checked_at" => s.checked_at }
        end,
          "tags_at" => @tags_at, "errors" => @errors.dup }
      end
    end

    def refresh_tags
      out = git(["ls-remote", "--tags", "--refs", url("core")])
      tags = out.lines.filter_map { _1.split("\t", 2)[1]&.strip&.delete_prefix("refs/tags/") }.sort
      @lock.synchronize do
        @tags = tags
        @tags_at = now_s
        @errors.delete("tags")
        save_state
      end
      tags
    rescue FetchError => e
      record_error("tags", e)
      nil
    end

    # Makes the ref's snapshot current (cloning only when a commit changed).
    # Returns it; raises FetchError (and keeps the old one) when it cannot.
    def refresh(ref)
      raise FetchError, "bad ref #{ref.inspect}" unless ref.match?(FW_SHAPE)
      snap = @fetch_lock.synchronize { fetch(ref) }
      gc
      snap
    rescue FetchError => e
      record_error(ref, e)
      raise
    end

    def fetch(ref)
      begin
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        old = @lock.synchronize { @snaps[ref] }
        core_c = remote_commit(url("core"), ref)
        ast_c = remote_commit(url("asterism"), asterism_branch)
        if old && old.core_commit == core_c && old.asterism_commit == ast_c && File.directory?(old.bundle)
          @lock.synchronize do
            old.checked_at = now_s
            @errors.delete(ref)
            save_state
          end
          return old
        end
        core = checkout("core", url("core"), ref, core_c, core_paths)
        ast = checkout("asterism", url("asterism"), asterism_branch, ast_c, BundleMaker::ASTERISM_PATHS)
        fw = BundleMaker.core_version(core) || ref
        bundle = File.join(@dir, "bundles", "#{ref}@#{core_c[0, 12]}-#{ast_c[0, 12]}")
        unless File.file?(File.join(bundle, "manifest.json"))
          tmp = "#{bundle}.tmp#{Process.pid}"
          BundleMaker.make(core: core, asterism: ast, out: tmp, fw: fw,
                           made_from: { "core" => core_c, "asterism" => ast_c, "ref" => ref }, clock: @clock)
          FileUtils.rm_rf(bundle)
          File.rename(tmp, bundle)
        end
        snap = Snapshot.new(ref: ref, fw: fw, core: core, core_commit: core_c, asterism: ast, asterism_commit: ast_c,
                            bundle: bundle, fetched_at: now_s, checked_at: now_s)
        @lock.synchronize do
          @snaps[ref] = snap
          @errors.delete(ref)
          save_state
        end
        secs = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
        @log&.write(:sources, ref: ref, ok: true, fw: fw, core: core_c, asterism: ast_c, seconds: secs.round(2),
                              disk_bytes: disk_bytes(core) + disk_bytes(ast), bundle_bytes: disk_bytes(bundle))
        snap
      end
    end

    # The paths of fmruby-core to check out: the bundle's and the search scope's
    # (a glob's directory part, up to its first wildcard segment).
    def core_paths
      dirs = scope.map { sparse_path(_1) }
      # an excluded directory is not checked out either, unless the bundle reads it
      out = Array(@s["exclude"]).map { sparse_path(_1) }.select { _1.end_with?("/") }
                                .reject { |x| BundleMaker::CORE_PATHS.any? { _1.start_with?(x) } }
      (BundleMaker::CORE_PATHS + dirs).uniq + out.map { "!#{_1}" }
    end

    # A glob as a sparse-checkout path: "a/b/**/*" is the directory "a/b/".
    def sparse_path(g)
      segs = g.split("/")
      segs.pop while segs.size > 1 && %w[** *].include?(segs.last)
      segs.size == g.split("/").size ? g : "#{segs.join('/')}/"
    end

    def disk_bytes(path)
      return 0 unless File.exist?(path)
      total = 0
      stack = [path]
      until stack.empty?
        d = stack.pop
        Dir.children(d).each do |n|
          p = File.join(d, n)
          st = File.lstat(p)
          if st.directory? then stack << p
          else total += st.size
          end
        end
      end
      total
    rescue SystemCallError
      total
    end

    private

    def now_s = @clock.call.utc.iso8601

    def url(name)
      u = @s[name].to_s
      raise FetchError, "sources.#{name} is not set" if u.empty?
      if !ENV[LOCAL_ONLY].to_s.empty? && !(u.start_with?("file://") || u.start_with?("/"))
        raise FetchError, "remote sources are off (#{LOCAL_ONLY})"
      end
      u
    end

    def remote_commit(u, ref)
      out = git(["ls-remote", u, "refs/heads/#{ref}", "refs/tags/#{ref}", "refs/tags/#{ref}^{}"])
      rows = out.lines.map { _1.strip.split("\t", 2) }
      row = rows.find { _1[1] == "refs/tags/#{ref}^{}" } || rows.find { _1[1] == "refs/tags/#{ref}" } ||
            rows.find { _1[1] == "refs/heads/#{ref}" }
      raise FetchError, "no branch or tag #{ref} in #{safe(u)}" unless row
      row[0]
    end

    # A shallow, partial, sparse clone of one commit at <dir>/<name>/<ref>@<commit>.
    def checkout(name, u, ref, commit, paths)
      dest = File.join(@dir, name, "#{ref}@#{commit[0, 12]}")
      return dest if File.directory?(File.join(dest, ".git"))
      tmp = "#{dest}.tmp#{Process.pid}"
      FileUtils.rm_rf(tmp)
      FileUtils.mkdir_p(File.dirname(tmp))
      git(["clone", "--quiet", "--depth", "1", "--filter=blob:none", "--no-checkout", "--single-branch",
           "--no-tags", "--branch", ref, u, tmp])
      git(["-C", tmp, "config", "core.sparseCheckout", "true"])
      git(["-C", tmp, "config", "core.sparseCheckoutCone", "false"])
      File.write(File.join(tmp, ".git", "info", "sparse-checkout"), paths.map { _1.start_with?("!") ? "!/#{_1[1..]}" : "/#{_1}" }.join("\n") + "\n")
      git(["-C", tmp, "read-tree", "-mu", "HEAD"])
      got = git(["-C", tmp, "rev-parse", "HEAD"]).strip
      raise FetchError, "#{name} #{ref}: got #{got[0, 12]}, wanted #{commit[0, 12]}" unless got == commit
      FileUtils.rm_rf(dest)
      File.rename(tmp, dest)
      dest
    rescue SystemCallError => e
      raise FetchError, "#{name} #{ref}: #{e.message}"
    ensure
      FileUtils.rm_rf(tmp) if tmp && File.exist?(tmp)
    end

    # Runs git with no terminal and no credentials (the repositories are
    # public); a FetchError with git's last line when it fails or times out.
    def git(args)
      env = { "GIT_TERMINAL_PROMPT" => "0", "GIT_ASKPASS" => "", "SSH_ASKPASS" => "", "LC_ALL" => "C" }
      cmd = ["git", "-c", "credential.helper=", "-c", "protocol.file.allow=always", *args]
      limit = @s["git_timeout_s"].to_f
      out = +""
      err = +""
      status = nil
      Open3.popen3(env, *cmd, pgroup: true) do |i, o, e, w|
        i.close
        to = Thread.new { out << o.read.to_s }
        te = Thread.new { err << e.read.to_s }
        unless w.join(limit)
          begin
            Process.kill("KILL", -w.pid)
          rescue SystemCallError
            nil
          end
          w.join
          to.join(1)
          te.join(1)
          raise FetchError, "git #{args.first}: no answer in #{limit.round} s"
        end
        to.join
        te.join
        status = w.value
      end
      unless status.success?
        lines = err.lines.map(&:strip).reject(&:empty?)
        last = lines.find { _1.start_with?("fatal:", "error:") } || lines.last || "exit #{status.exitstatus}"
        raise FetchError, "git #{args.first}: #{safe(last)}"
      end
      out
    rescue Errno::ENOENT
      raise FetchError, "git is not installed"
    end

    # A URL with a user or a token in it never goes to a record.
    def safe(text) = text.to_s.gsub(%r{://[^/@\s]+@}, "://")

    def record_error(ref, e)
      @lock.synchronize do
        @errors[ref] = { "message" => safe(e.message), "at" => now_s }
        save_state
      end
      @log&.write(:sources, ref: ref, ok: false, error: safe(e.message))
    end

    def state_path = File.join(@dir, "state.json")

    def save_state
      data = { "tags" => @tags, "tags_at" => @tags_at, "errors" => @errors,
               "refs" => @snaps.transform_values { _1.to_h_rel(@dir) } }
      tmp = "#{state_path}.#{Process.pid}.tmp"
      File.write(tmp, JSON.pretty_generate(data) + "\n")
      File.rename(tmp, state_path)
    end

    def load_state
      return unless File.file?(state_path)
      data = JSON.parse(File.read(state_path))
      @tags = data["tags"]
      @tags_at = data["tags_at"]
      @errors = data["errors"] || {}
      (data["refs"] || {}).each do |ref, h|
        snap = Snapshot.new(**h.to_h { |k, v| [k.to_sym, %w[core asterism bundle].include?(k) ? File.join(@dir, v) : v] })
        next unless [snap.core, snap.asterism, snap.bundle].all? { File.directory?(_1) }
        @snaps[ref] = snap
      end
    rescue JSON::ParserError, ArgumentError, TypeError => e
      warn "asterism-tutor: sources: #{state_path} is broken (#{e.message}); starting again"
    end

    # Deletes the checkouts and bundles that no current or used snapshot has
    # (and what a fetch left half done).
    def gc
      # A fetch running now may have a new checkout that is not current yet.
      return unless @fetch_lock.try_lock
      begin
        sweep
      ensure
        @fetch_lock.unlock
      end
    end

    def sweep
      keep = @lock.synchronize do
        (@snaps.values + @in_use_snaps.values).flat_map { [_1.core, _1.asterism, _1.bundle] }
      end
      %w[core asterism bundles].each do |sub|
        Dir[File.join(@dir, sub, "*")].each { FileUtils.rm_rf(_1) unless keep.include?(_1) }
      end
    rescue SystemCallError
      nil
    end
  end
end
