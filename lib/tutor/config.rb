require "tomlrb"

module Tutor
  # The settings (tutor.toml). Every key has a default; a file sets only what
  # it changes. The LLM key is never here: it comes from ANTHROPIC_API_KEY.
  class Config
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
        "model" => "claude-sonnet-5-5",
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
        "log_dir" => "~/.local/share/fmrb-tutor/log",
        "doc_max" => 65_536,
        "piece" => 8192,
        "text_max" => 2048,
        "error_max" => 1024
      },
      "bundle" => { "dir" => "" },     # "": the bundles in the gem
      "jobs" => { "workers" => 2 }
    }.freeze

    attr_reader :data

    def self.load(path = nil, overrides = {})
      data = path ? Tomlrb.load_file(path) : {}
      new(deep_merge(deep_merge(DEFAULTS, data), overrides))
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
