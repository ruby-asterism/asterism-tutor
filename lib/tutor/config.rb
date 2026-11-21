require "tomlrb"
require_relative "lookup"

module Tutor
  # The settings (tutor.toml). Every key has a default; a file sets only what
  # it changes, the environment (ASTERISM_TUTOR_*, ENV_KEYS) goes over the
  # file and the options of exe/asterism-tutor over both. The LLM key is
  # never here: it comes from ANTHROPIC_API_KEY.
  class Config
    class Error < StandardError; end

    # Environment variable => [section, key, kind]. An empty value is the
    # same as no variable, except ASTERISM_TUTOR_ROUTER, where it means
    # "the router the credentials name".
    ENV_KEYS = {
      "ASTERISM_TUTOR_ROUTER" => ["network", "router", :s],
      "ASTERISM_TUTOR_CREDENTIALS" => ["network", "credentials", :s],
      "ASTERISM_TUTOR_NODE" => ["network", "node", :s],
      "ASTERISM_TUTOR_DEVICES" => ["network", "devices", :list],
      "ASTERISM_TUTOR_LLM" => ["llm", "provider", :s],
      "ASTERISM_TUTOR_MODEL" => ["llm", "model", :s],
      "ASTERISM_TUTOR_PER_DAY" => ["limits", "per_device_per_day", :i],
      "ASTERISM_TUTOR_COST_PER_DAY" => ["limits", "cost_per_day_usd", :f],
      "ASTERISM_TUTOR_LOG_DIR" => ["store", "log_dir", :s],
      "ASTERISM_TUTOR_STATE_DIR" => ["store", "state_dir", :s],
      "ASTERISM_TUTOR_MAKE" => ["modes", "make", :b],
      "ASTERISM_TUTOR_FIX" => ["modes", "fix", :b],
      "ASTERISM_TUTOR_STOP_GRACE" => ["jobs", "stop_grace_s", :f],
      "ASTERISM_TUTOR_SOURCES" => ["sources", "enabled", :b],
      "ASTERISM_TUTOR_SOURCES_DIR" => ["sources", "dir", :s],
      "ASTERISM_TUTOR_LOOKUP_ROUNDS" => ["lookup", "rounds", :i]
    }.freeze
    # The settings file when --config is not given.
    ENV_CONFIG = "ASTERISM_TUTOR_CONFIG".freeze
    EMPTY_MEANS = { "ASTERISM_TUTOR_ROUTER" => "" }.freeze
    DEFAULTS = {
      "network" => {
        "router" => "tcp/127.0.0.1:7447",
        "node" => "tutor",
        "credentials" => "",           # an Asterism console's .tar (mTLS); empty: plain TCP
        "devices" => ["*"],            # node IDs that may ask; "*" lets every node ask
        "name" => "AI helper"          # shown on the device
      },
      "llm" => {
        "provider" => "fake",          # "fake" or "anthropic"
        "model" => "claude-haiku-5-5",
        "max_tokens" => 8000,
        "effort" => "",                # "", "low", "medium", "high" ("": the model's default)
        "timeout_s" => 120,
        # USD per million tokens, by model (for the daily cost limit)
        "prices" => {
          "claude-haiku-5-5" => { "input" => 0.10, "cache_write" => 0.125, "cache_read" => 0.01, "output" => 0.50 },
          "claude-sonnet-5-5" => { "input" => 2.0, "cache_write" => 2.5, "cache_read" => 0.10, "output" => 10.0 }
        }
      },
      "limits" => {
        "per_device_per_day" => 50,
        "cost_per_day_usd" => 1.0,     # all devices together, by the estimate from usage
        "retries" => 2                 # times the LLM is asked to fix code that failed a check
      },
      "modes" => { "make" => true, "fix" => true },
      "talk" => { "turns" => 4, "forget_min" => 30 },
      "store" => {
        "result_hours" => 24,
        "log_dir" => "~/.local/share/asterism-tutor/log",
        "state_dir" => "~/.local/share/asterism-tutor/state", # the tickets and the status
        "doc_max" => 65_536,
        "piece" => 8192,
        "text_max" => 2048,
        "error_max" => 1024
      },
      # "": the bundle made from the sources (or, without them, the bundles in
      # the gem); a directory: the parent's own bundles (index.json, <fw>/)
      "bundle" => { "dir" => "" },
      # The Family mruby sources the gem clones and keeps (Tutor::Sources).
      "sources" => {
        "enabled" => true,
        "dir" => "",                   # "": "sources" next to store.state_dir
        "core" => "https://github.com/family-mruby/fmruby-core.git",
        "asterism" => "https://github.com/ruby-asterism/asterism.git",
        "branch" => "develop",         # core, for a version with no tag
        "asterism_branch" => "main",
        "search" => Lookup::SCOPE,     # what the LLM may search and read (globs in fmruby-core)
        "exclude" => Lookup::EXCLUDE,  # left out of search (globs)
        "rb_max_kb" => Lookup::RB_MAX / 1024, # a bigger .rb is left out of search
        "refresh_hours" => 24,
        "git_timeout_s" => 300
      },
      # The LLM's tools (search_source, read_source). rounds: the rounds of
      # look-ups in one request (0: no tools); then it answers with what it has.
      "lookup" => { "rounds" => 4, "hits" => 30, "lines" => 120 },
      # stop_grace_s: on SIGTERM, how long the requests being worked on are
      # waited for before they are failed (Jobs#shutdown)
      "jobs" => { "workers" => 2, "stop_grace_s" => 8 }
    }.freeze

    attr_reader :data

    # options > environment > file > defaults. path nil: ASTERISM_TUTOR_CONFIG
    # when it is set (env: ENV by default, a Hash in the tests).
    def self.load(path = nil, overrides = {}, env: ENV)
      path ||= env[ENV_CONFIG] unless env[ENV_CONFIG].to_s.empty?
      data = path ? Tomlrb.load_file(path) : {}
      new(deep_merge(deep_merge(deep_merge(DEFAULTS, data), from_env(env)), overrides))
    rescue Errno::ENOENT, Tomlrb::ParseError => e
      raise Error, "#{path}: #{e.message}"
    end

    # The settings the environment gives, as a Hash shaped like the file.
    def self.from_env(env)
      out = {}
      ENV_KEYS.each do |name, (section, key, kind)|
        next unless env.key?(name)
        raw = env[name].to_s.strip
        next if raw.empty? && !EMPTY_MEANS.key?(name)
        (out[section] ||= {})[key] = raw.empty? ? EMPTY_MEANS[name] : env_value(name, raw, kind)
      end
      out
    end

    def self.env_value(name, raw, kind)
      case kind
      when :s then raw
      when :list then raw.split(/[,\s]+/).reject(&:empty?)
      when :i then Integer(raw, 10)
      when :f then Float(raw)
      when :b
        case raw.downcase
        when "1", "true", "yes", "on" then true
        when "0", "false", "no", "off" then false
        else raise ArgumentError
        end
      end
    rescue ArgumentError, TypeError
      want = { i: "a whole number", f: "a number", b: "true or false" }.fetch(kind, "a value")
      raise Error, "#{name}=#{raw.inspect} is not #{want}"
    end

    def self.deep_merge(a, b)
      a.merge(b) { |_, x, y| x.is_a?(Hash) && y.is_a?(Hash) ? deep_merge(x, y) : y }
    end

    def initialize(data)
      @data = data
    end

    def [](section) = @data.fetch(section)
    def dig(*keys) = @data.dig(*keys)

    def log_dir = File.expand_path(dig("store", "log_dir"))
    def state_dir = File.expand_path(dig("store", "state_dir"))

    def sources_dir
      d = dig("sources", "dir").to_s
      d.empty? ? File.join(File.dirname(state_dir), "sources") : File.expand_path(d)
    end

    def bundle_dir
      d = dig("bundle", "dir").to_s
      d.empty? ? File.expand_path("../../bundles", __dir__) : File.expand_path(d)
    end

    def modes
      m = %w[ask hint]
      m << "make" if dig("modes", "make")
      m << "fix" if dig("modes", "fix")
      m
    end

    def device_allowed?(node)
      list = Array(dig("network", "devices"))
      list.include?("*") || list.include?(node)
    end

    def price
      dig("llm", "prices", dig("llm", "model")) || { "input" => 0, "cache_write" => 0, "cache_read" => 0, "output" => 0 }
    end

    # USD for one usage Hash ("in", "out", "cache_write", "cache_read").
    def cost(usage)
      p = price
      (usage["in"].to_i * p["input"] + usage["cache_write"].to_i * p["cache_write"] +
       usage["cache_read"].to_i * p["cache_read"] + usage["out"].to_i * p["output"]) / 1_000_000.0
    end
  end
end
