module Tutor
  # The daily limits: requests per device and the estimated cost of all
  # devices. A day is the local date of the process (TZ). After a restart
  # (a container made again on the same volume too) the counts of the day
  # are read back from the log. A request that failed only because the gem
  # stopped (error "stopped", Jobs#stopped) is not counted; what the LLM
  # cost for it is.
  class Limits
    def initialize(cfg, log, clock: -> { Time.now })
      @cfg = cfg
      @clock = clock
      @lock = Mutex.new
      @day = nil
      @count = Hash.new(0)
      @cost = 0.0
      roll
      recs = log.records
      stopped = recs.select { _1["ev"] == "failed" && _1["error"] == "stopped" }.map { _1["ticket"] }
      recs.each do |r|
        @count[r["device"]] += 1 if r["ev"] == "ask" && !stopped.include?(r["ticket"])
        @cost += r["cost_usd"].to_f if r["ev"] == "llm"
      end
    end

    def max = @cfg.dig("limits", "per_device_per_day").to_i
    def cost_max = @cfg.dig("limits", "cost_per_day_usd").to_f

    def roll
      d = @clock.call.strftime("%Y-%m-%d")
      return if d == @day
      @day = d
      @count.clear
      @cost = 0.0
    end

    def used(device) = @lock.synchronize { roll; @count[device] }
    # All devices' requests of the day (for the status).
    def requests_today = @lock.synchronize { roll; @count.values.sum }
    def cost_today = @lock.synchronize { roll; @cost }

    # nil when the device may ask now, else the reason (an error Hash).
    def refuse(device)
      @lock.synchronize do
        roll
        if @count[device] >= max
          return { "error" => "limit", "message" => "今日使える回数 (#{max} 回) を使い切りました。また明日使えます。" }
        end
        if @cost >= cost_max
          return { "error" => "limit", "message" => "今日使える量を使い切りました。また明日使えます。" }
        end
        nil
      end
    end

    def count(device) = @lock.synchronize { roll; @count[device] += 1 }

    # A request asked at `asked` (a Time) given back: it failed because the
    # gem stopped. Only a request of today is in today's count.
    def uncount(device, asked)
      @lock.synchronize do
        roll
        next unless asked.respond_to?(:strftime) && asked.strftime("%Y-%m-%d") == @day
        @count[device] -= 1 if @count[device].positive?
      end
    end
    def add_cost(usd) = @lock.synchronize { roll; @cost += usd }
  end
end
