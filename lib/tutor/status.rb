require "json"
require "fileutils"
require "time"

module Tutor
  # Whether the gem is joined to its router with the helper exposed, for a
  # healthcheck (asterism-tutor status). The running gem writes
  # <state_dir>/status.json every EVERY seconds (Server#run); the command
  # reads it. No port is opened for it: the command runs in the same
  # container (or on the same PC) and reads the file.
  module Status
    FILE = "status.json".freeze
    EVERY = 2.0
    # Older than this, the file says nothing: the gem has stopped or hangs.
    MAX_AGE = 15.0

    def self.path(cfg) = File.join(cfg.state_dir, FILE)

    def self.write(path, data)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.#{Process.pid}.tmp"
      File.write(tmp, JSON.generate(data))
      File.rename(tmp, path)
    end

    def self.read(path)
      JSON.parse(File.read(path))
    rescue SystemCallError, JSON::ParserError
      nil
    end

    # [exit code, text]: 0 joined with the helper exposed, 1 running but not
    # (the router is away, the gem is stopping), 2 no fresh status (not
    # running, hung, or another state_dir).
    def self.check(data, now: Time.now, max_age: MAX_AGE)
      return [2, "no status (is asterism-tutor running with this state_dir?)"] unless data.is_a?(Hash)
      at = Time.iso8601(data["at"].to_s) rescue nil
      return [2, "no status time"] unless at
      age = now - at
      head = "asterism-tutor #{data['version']} #{data['path']}"
      return [2, "#{head}: the status is #{age.round} s old (the gem has stopped or hangs)"] if age > max_age
      tail = "since #{data['since']}, llm #{data['llm']} (#{data['model']}), #{data['active'].to_i} working, " \
             "today #{data['requests_today'].to_i} requests, $#{format('%.4f', data['cost_today'].to_f)}"
      return [1, "#{head}: stopping (#{tail})"] if data["stopping"]
      unless data["connected"]
        why = data["reconnecting"] ? "the router is away, joining it again" : "not joined to the router"
        return [1, "#{head}: #{why} (#{tail})"]
      end
      return [1, "#{head}: joined, but the helper is not exposed (#{tail})"] unless data["exposed"]
      [0, "#{head}: up, joined to #{data['router']} (#{tail})"]
    end
  end
end
