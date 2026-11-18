module Tutor
  # The gem as one Asterism application "tutor" with one object "helper".
  #
  # Alone (exe/asterism-tutor):  Tutor::Server.new(cfg).run
  # Inside another program that already has a connection (the console):
  #   server = Tutor::Server.new(cfg)
  #   server.attach(net)        # exposes "helper" on that connection
  class Server
    APP = "tutor".freeze
    OBJECT = "helper".freeze

    attr_reader :cfg, :store, :log, :limits, :jobs, :helper, :llm

    def initialize(cfg, llm: nil, clock: -> { Time.now })
      @cfg = cfg
      @log = Log.new(cfg.log_dir, clock: clock)
      @store = Store.new(cfg, clock: clock)
      @limits = Limits.new(cfg, @log, clock: clock)
      @llm = llm || LLM.make(cfg)
      @jobs = Jobs.new(cfg, store: @store, log: @log, limits: @limits, bundles: Bundles.new(cfg.bundle_dir), llm: @llm)
      @helper = Helper.new(cfg, store: @store, log: @log, limits: @limits, jobs: @jobs)
      @stop_q = Queue.new
      @since = Time.now
      left = @jobs.fail_interrupted
      warn "asterism-tutor: #{left.size} request(s) left unfinished by the last run: failed (#{left.join(' ')})" unless left.empty?
    end

    def attach(net)
      path = net.expose(OBJECT, @helper, caller: :from, methods: Helper::METHODS,
                                         doc: "Family mruby AI helper: ask, hint, make and fix over Asterism")
      @log.write(:start, path: path, llm: @cfg.dig("llm", "provider"), model: @cfg.dig("llm", "model"),
                         devices: @cfg.dig("network", "devices"), modes: @cfg.modes, version: VERSION)
      path
    end

    def connect_args
      n = @cfg["network"]
      args = { app: APP }
      args[:node] = n["node"] unless n["node"].to_s.empty?
      args[:credentials] = File.expand_path(n["credentials"]) unless n["credentials"].to_s.empty?
      router = n["router"].to_s
      [router.empty? ? nil : router, args]
    end

    # Asks run to end (a signal's trap may call it: a Queue push only).
    def request_stop(why = "stop") = @stop_q << why

    # Connects, exposes the helper and answers until request_stop (SIGTERM,
    # Ctrl-C) or the connection ends; writes the status file meanwhile.
    # On request_stop the requests being worked on get jobs.stop_grace_s
    # (Jobs#shutdown) while the helper still answers status and result.
    # Returns the exit code: 0 stopped as asked, 1 the connection ended.
    def run
      require "asterism"
      locator, args = connect_args
      code = 0
      Asterism.connect(locator, **args) do |net|
        @net = net
        @path = attach(net)
        @router = locator || "the credentials' router"
        warn "asterism-tutor #{VERSION}: #{@path} on #{@router} (llm: #{@cfg.dig('llm', 'provider')})"
        model = @cfg.dig("llm", "model")
        warn "asterism-tutor: model #{model}, #{@cfg.dig('limits', 'per_device_per_day')} requests a device a day, " \
             "$#{@cfg.dig('limits', 'cost_per_day_usd')} a day in all"
        unless @cfg.dig("llm", "prices", model)
          warn "asterism-tutor: no price for #{model} in llm.prices; the cost limit will not count it"
        end
        $stderr.flush
        net.start
        why = nil
        loop do
          write_status
          unless net.running?
            warn "asterism-tutor: the connection ended (#{net.lost_reason || 'closed'})"
            code = 1
            break
          end
          why = @stop_q.pop(timeout: Status::EVERY)
          break if why
        end
        stop_work(why) if why
      end
      code
    ensure
      @jobs.stop
      write_status(stopped: true) if @path
    end

    def stop_work(why)
      write_status(stopping: true)
      grace = @cfg.dig("jobs", "stop_grace_s").to_f
      busy = @store.active_ids.size
      warn "asterism-tutor: #{why}: no new requests; waiting up to #{grace} s for #{busy} request(s)" if busy.positive?
      left = @jobs.shutdown(grace)
      @log.write(:stop, why: why, failed: left)
      warn "asterism-tutor: stopped (#{left.size} request(s) failed as stopped)"
      $stderr.flush
    end

    def status_now(stopping: false, stopped: false)
      net = @net
      connected = false
      reconnecting = false
      exposed = false
      if net && !stopped
        begin
          reconnecting = net.reconnecting? ? true : false
          connected = net.connected? && !reconnecting ? true : false
          exposed = net.exposed.include?(OBJECT)
        rescue StandardError
          connected = false
        end
      end
      { "version" => VERSION, "pid" => Process.pid, "at" => Time.now.iso8601(3), "since" => @since.iso8601,
        "path" => @path, "router" => @router, "connected" => connected, "reconnecting" => reconnecting,
        "exposed" => exposed, "stopping" => stopping || stopped, "stopped" => stopped,
        "llm" => @cfg.dig("llm", "provider"), "model" => @cfg.dig("llm", "model"),
        "active" => @store.active_ids.size, "requests_today" => @limits.requests_today,
        "cost_today" => @limits.cost_today.round(6) }
    end

    def write_status(**kw)
      Status.write(Status.path(@cfg), status_now(**kw))
    rescue SystemCallError => e
      warn "asterism-tutor: cannot write the status (#{e.message})"
    end

    def stop = request_stop("stop")
  end
end
