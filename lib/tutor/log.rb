require "json"
require "fileutils"

module Tutor
  # The record of everything (JSONL, one file a day, never deleted by the gem):
  # requests, the documents sent, the prompts, the answers, usage, cost and the
  # checks. Nothing here may hold the LLM key: the gem never puts it in a
  # record, and every string is scrubbed of anything shaped like a key.
  class Log
    KEY_SHAPE = Regexp.new("sk-" + "ant-[A-Za-z0-9_-]+")

    attr_reader :dir

    def initialize(dir, clock: -> { Time.now })
      @dir = dir
      @clock = clock
      @lock = Mutex.new
      FileUtils.mkdir_p(dir)
    end

    def path(time = @clock.call) = File.join(@dir, "tutor-#{time.strftime('%Y-%m-%d')}.jsonl")

    def write(ev, **fields)
      now = @clock.call
      rec = { "t" => now.iso8601(3), "ev" => ev.to_s }.merge(scrub(fields.transform_keys(&:to_s)))
      line = JSON.generate(rec)
      @lock.synchronize { File.open(path(now), "a") { _1.puts(line) } }
      rec
    end

    # The records of one day (for the limits after a restart, and for reading).
    def records(time = @clock.call)
      p = path(time)
      return [] unless File.exist?(p)
      File.readlines(p).filter_map { JSON.parse(_1) rescue nil }
    end

    def scrub(v)
      case v
      when String then v.dup.force_encoding("UTF-8").scrub.gsub(KEY_SHAPE, "[redacted]")
      when Hash then v.to_h { |k, x| [k.to_s, scrub(x)] }
      when Array then v.map { scrub(_1) }
      else v
      end
    end
  end
end
