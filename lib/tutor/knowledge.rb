module Tutor
  # What a request is answered with: the bundle (the LLM's fixed text) and,
  # when the sources are there, the tools that look into them.
  #
  #   1. bundle.dir set: the parent's own bundles (and the sources' tools)
  #   2. the sources' snapshot for the device's version (Sources)
  #   3. no snapshot (sources off, never fetched, the fetch failed): the
  #      bundles in the gem, without tools
  #
  # acquire holds the snapshot for the request (a refresh does not swap the
  # files under it); release lets it go.
  class Knowledge
    Use = Struct.new(:bundle, :lookup, :origin, :snapshot)

    attr_reader :sources

    def initialize(cfg, log: nil, clock: -> { Time.now })
      @cfg = cfg
      @gem = Bundles.new(cfg.bundle_dir)
      @own = !cfg.dig("bundle", "dir").to_s.empty?
      @sources = cfg.dig("sources", "enabled") ? Sources.new(cfg, log: log, clock: clock) : nil
      @lock = Mutex.new
      @bundles = {}
      @lookups = {}
    end

    def start = @sources&.start
    def stop = @sources&.stop
    def tools? = @cfg.dig("lookup", "rounds").to_i.positive?

    def acquire(fw)
      snap = @sources&.acquire(fw)
      lookup = snap && tools? ? lookup_for(snap) : nil
      if @own || snap.nil?
        bundle = @gem.for(fw)
        origin = { "kind" => @own ? "dir" : "gem", "bundle" => bundle.fw }
        if @sources && snap.nil?
          ref = @sources.ref_for(fw)
          err = @sources.error_for(ref)
          origin["why"] = err ? "#{ref}: #{err['message']}" : "#{ref}: not fetched yet"
        end
      else
        bundle = bundle_for(snap)
        bundle = FallbackView.new(bundle, fw.to_s) if bundle.fw != fw.to_s
        origin = { "kind" => "sources", "ref" => snap.ref, "bundle" => snap.fw, "core" => snap.core_commit.to_s[0, 12],
                   "asterism" => snap.asterism_commit.to_s[0, 12], "fetched_at" => snap.fetched_at }
      end
      origin["tools"] = !lookup.nil?
      Use.new(bundle, lookup, origin, snap)
    end

    def release(use)
      @sources&.release(use&.snapshot)
    end

    private

    def bundle_for(snap)
      @lock.synchronize do
        prune
        @bundles[snap.bundle] ||= Bundle.new(nil, snap.fw, dir: snap.bundle, source: snap.ref)
      end
    end

    def lookup_for(snap)
      l = @cfg["lookup"]
      @lock.synchronize do
        prune
        @lookups[snap.core] ||= Lookup.new(snap.core, Array(@cfg.dig("sources", "search")),
                                           exclude: Array(@cfg.dig("sources", "exclude")),
                                           rb_max: (@cfg.dig("sources", "rb_max_kb").to_f * 1024).to_i,
                                           hits: l["hits"].to_i, lines: l["lines"].to_i)
      end
    end

    # Forgets the ones of snapshots deleted since.
    def prune
      @bundles.delete_if { |d, _| !File.directory?(d) }
      @lookups.delete_if { |d, _| !File.directory?(d) }
    end
  end
end
