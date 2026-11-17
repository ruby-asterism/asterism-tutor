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
    end

    def attach(net)
      path = net.expose(OBJECT, @helper, caller: :from, methods: Helper::METHODS,
                                         doc: "Family mruby AI helper: ask, hint, make and fix over Asterism")
      @log.write(:start, path: path, llm: @cfg.dig("llm", "provider"), model: @cfg.dig("llm", "model"),
                         devices: @cfg.dig("network", "devices"), modes: @cfg.modes)
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

    # Connects, exposes the helper and answers until Ctrl-C (or stop).
    def run
      require "asterism"
      locator, args = connect_args
      Asterism.connect(locator, **args) do |net|
        @net = net
        path = attach(net)
        warn "asterism-tutor: #{path} on #{locator || 'the credentials router'} (llm: #{@cfg.dig('llm', 'provider')})"
        model = @cfg.dig("llm", "model")
        warn "asterism-tutor: model #{model}, #{@cfg.dig('limits', 'per_device_per_day')} requests a device a day, " \
             "$#{@cfg.dig('limits', 'cost_per_day_usd')} a day in all"
        unless @cfg.dig("llm", "prices", model)
          warn "asterism-tutor: no price for #{model} in llm.prices; the cost limit will not count it"
        end
        $stderr.flush
        net.run
      end
    ensure
      @jobs.stop
    end

    def stop = @net&.stop
  end
end
