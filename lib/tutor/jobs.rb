module Tutor
  # The work behind a ticket, on worker threads (never on Asterism's
  # receiving thread): the LLM, the checks, asking again when a check fails,
  # and the result the device fetches.
  class Jobs
    STATE_TEXT = {
      "thinking" => "考えています",
      "checking" => "検査しています",
      "done" => "できました",
      "failed" => "うまくいきませんでした",
      "cancelled" => "やめました"
    }.freeze
    EXPLAIN_MAX = 4096
    # What a device reads for a request the gem could not finish because it
    # stopped (SIGTERM after jobs.stop_grace_s, or a crash found at start).
    STOPPED = "AI ホストが止まったので、答えを作れませんでした。もう一度送ってください。".freeze

    def initialize(cfg, store:, log:, limits:, knowledge:, llm:)
      @cfg = cfg
      @store = store
      @log = log
      @limits = limits
      @knowledge = knowledge
      @llm = llm
      @queue = Queue.new
      @threads = Array.new(cfg.dig("jobs", "workers").to_i.clamp(1, 8)) do
        Thread.new do
          while (id = @queue.pop)
            run(id)
          end
        end
      end
    end

    def push(id) = @queue << id

    # After shutdown a worker may still be inside a call to the LLM; its
    # ticket is already failed, so it is not waited for long.
    def stop
      @threads.size.times { @queue << nil }
      @threads.each { _1.join(@halted ? 0.2 : 5) }
    end

    # True from shutdown on: the helper takes no new request.
    def closing? = @closing ? true : false

    # On SIGTERM (Server#run): no new request is taken (Helper#ask), the
    # requests being worked on (and those queued behind them) get up to
    # grace seconds to end, and what is left is failed with STOPPED, so a
    # device reads that from status / result / pending once the gem is back.
    # Returns the ids failed.
    def shutdown(grace = @cfg.dig("jobs", "stop_grace_s").to_f, every: 0.1)
      @closing = true
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      while !@store.active_ids.empty? && Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0 < grace
        sleep every
      end
      @halted = true
      left = @store.active_ids
      left.each { stopped(_1, "shutdown") }
      @threads.size.times { @queue << nil }
      left
    end

    # The tickets a gem that stopped without its shutdown (killed, out of
    # memory) left being worked on: failed with STOPPED at start.
    def fail_interrupted
      ids = @store.interrupted
      ids.each { stopped(_1, "restart") }
      ids
    end

    def stopped(id, when_)
      t = @store.ticket(id)
      return unless t
      @store.update(id, "state" => "failed", "message" => STATE_TEXT["failed"], "error" => "stopped", "fail_message" => STOPPED)
      @log.write(:failed, device: t["device"], ticket: id, error: "stopped", message: STOPPED, detail: when_)
      # Not the device's fault: the request is not counted (its LLM cost is).
      @limits.uncount(t["device"], t["created"])
    end

    # After shutdown gave up on them, a worker that is still running writes
    # nothing more (the ticket says STOPPED).
    def set(id, state, extra = {})
      return if @halted
      @store.update(id, { "state" => state, "message" => STATE_TEXT[state] }.merge(extra))
    end

    def cancelled?(id) = @store.ticket(id)&.fetch("cancel")

    def run(id)
      t = @store.ticket(id)
      return unless t && t["state"] == "queued"
      return finish_cancel(t) if t["cancel"]
      work(t)
    rescue LLM::Error => e
      fail_ticket(t, e.kind == "auth" || e.kind == "config" ? "llm_setup" : "llm", llm_message(e), e.message)
    rescue StandardError => e
      fail_ticket(t, "internal", "親の PC の側でエラーが起きました。", "#{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    end

    def llm_message(e)
      case e.kind
      when "rate" then "AI が混んでいます。少し待ってからもう一度聞いてください。"
      when "network" then "親の PC から AI につながりません。"
      when "timeout" then "AI の答えが時間内に返りませんでした。もう一度聞いてください。"
      when "auth", "config" then "親の PC の AI の設定に問題があります。親に知らせてください。"
      else "AI がうまく答えられませんでした。"
      end
    end

    def finish_cancel(t)
      return if @halted
      set(t["id"], "cancelled")
      @log.write(:cancelled, device: t["device"], ticket: t["id"])
    end

    def fail_ticket(t, error, message, detail = nil, problems: nil)
      return unless t
      return if @halted
      set(t["id"], "failed", "error" => error, "fail_message" => message, "problems" => problems)
      @log.write(:failed, device: t["device"], ticket: t["id"], error: error, message: message, detail: detail, problems: problems)
    end

    def work(t)
      use = @knowledge.acquire(t["req"]["fw"])
      begin
        answer(t, use)
      ensure
        @knowledge.release(use)
      end
    end

    def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # One request: the LLM (with its rounds of look-ups), the checks, and
    # asking again when they fail.
    def answer(t, use)
      id = t["id"]
      req = t["req"]
      mode = req["mode"]
      doc = t["doc"]
      bundle = use.bundle
      if bundle.fallback?
        @log.write(:bundle_fallback, device: t["device"], ticket: id, asked: bundle.asked, used: bundle.fw)
      end
      @log.write(:knowledge, device: t["device"], ticket: id, origin: use.origin)
      lookup = use.lookup
      system = Prompt.system(bundle.text, tools: !lookup.nil?)
      tools = lookup&.tools
      history = @store.talk(t["device"]).flat_map { [{ role: "user", content: _1 }, { role: "assistant", content: _2 }] }
      messages = history + [{ role: "user", content: Prompt.request(req, doc) }]
      retries = @cfg.dig("limits", "retries").to_i
      max_rounds = @cfg.dig("lookup", "rounds").to_i
      timeout = @cfg.dig("llm", "timeout_s").to_f
      used = { "rounds" => 0, "calls" => 0, "usage" => Hash.new(0), "cost_usd" => 0.0, "tools" => [] }
      attempt = 0
      loop do
        return finish_cancel(t) if cancelled?(id)
        set(id, "thinking")
        # One answer: its look-ups and the answer share timeout_s; with less
        # than a third of it left, no more look-ups.
        deadline = mono + timeout
        res = nil
        loop do
          left = deadline - mono
          raise LLM::Error.new("timeout", "no time left for the LLM (#{timeout} s)") if left <= 0
          can_look = tools && used["rounds"] < max_rounds && left > timeout / 3
          res = @llm.complete(system: system, messages: messages, meta: { mode: mode, attempt: attempt, round: used["rounds"] },
                              tools: tools, tool_choice: tools && (can_look ? "auto" : "none"), timeout: left)
          cost = @cfg.cost(res["usage"])
          @limits.add_cost(cost)
          used["calls"] += 1
          used["cost_usd"] += cost
          res["usage"].each { |k, v| used["usage"][k] += v.to_i }
          calls = can_look ? Array(res["tool_calls"]) : []
          first = messages.last[:content].is_a?(String)
          @log.write(:llm, device: t["device"], ticket: id, attempt: attempt, round: used["rounds"], model: res["model"],
                           bundle: bundle.fw, prompt: first ? messages.last[:content] : nil, history_turns: history.size / 2,
                           answer: res["text"], tool_calls: calls.empty? ? nil : calls, stop: res["stop"],
                           usage: res["usage"], cost_usd: cost.round(6))
          break if calls.empty?
          return finish_cancel(t) if cancelled?(id)
          used["rounds"] += 1
          results = calls.map do |c|
            r = lookup.call(c["name"], c["input"])
            used["tools"] << { "name" => c["name"] }.merge(r["info"])
            @log.write(:tool, device: t["device"], ticket: id, round: used["rounds"], name: c["name"], input: c["input"],
                              error: r["error"], info: r["info"], bytes: r["text"].bytesize, text: r["text"])
            { type: "tool_result", tool_use_id: c["id"], content: r["text"], is_error: r["error"] }
          end
          if used["rounds"] >= max_rounds
            results << { type: "text", text: Prompt::LOOKUP_DONE }
          elsif deadline - mono <= timeout / 3
            results << { type: "text", text: Prompt::LOOKUP_LATE }
          end
          messages += [{ role: "assistant", content: res["content"] }, { role: "user", content: results }]
        end
        return finish_cancel(t) if cancelled?(id)
        set(id, "checking")
        parsed = Prompt.parse(res["text"])
        problems, outcome = evaluate(mode, parsed, doc, bundle, last: attempt >= retries)
        @log.write(:check, device: t["device"], ticket: id, attempt: attempt, ok: problems.empty?, problems: problems,
                           placed: outcome && outcome["placed"], left_out: outcome && outcome["left_out"],
                           meta: outcome && outcome["meta"])
        if problems.empty?
          finish(t, parsed, outcome, bundle, used)
          return
        end
        attempt += 1
        if attempt > retries
          lines = problems.first(3).map { "#{_1['line']} 行目: #{_1['message'] || _1['what']}" }
          fail_ticket(t, "check", "AI のコードが検査に通らなかったので、送りません (#{lines.join(' / ')})。", problems: problems)
          return
        end
        messages += [{ role: "assistant", content: res["content"] || res["text"] },
                     { role: "user", content: Prompt.fix_request(mode, problems) }]
      end
    end

    # [problems, outcome]. Problems make the LLM answer again. last: this is
    # the last answer the LLM is asked for (no retry is left).
    def evaluate(mode, parsed, doc, bundle, last: false)
      case mode
      when "ask"
        return [[{ "line" => 0, "message" => "<explain> が無い" }], nil] if parsed["explain"].empty?
        [[], nil]
      when "hint"
        if parsed["hints"].empty? && parsed["explain"].empty?
          return [[{ "line" => 0, "message" => "<explain> も <hint> も無い" }], nil]
        end
        out = Check.place_hints(doc, parsed["hints"])
        unless Check.same_code?(doc, out["doc"])
          # Never expected (each comment was checked); keep the code as it was.
          out = { "doc" => doc, "placed" => [], "left_out" => parsed["hints"].map { _1.merge("why" => "whole check") } }
        end
        [[], out]
      else
        code = parsed["code"]
        return [[{ "line" => 0, "message" => "<code> が無い" }], nil] if code.nil? || code.strip.empty?
        probs = []
        if code.bytesize > @cfg.dig("store", "doc_max").to_i
          probs << { "line" => 0, "message" => "文書が大きすぎる (#{code.bytesize} バイト)" }
        end
        probs += Check.syntax(code).map { _1.merge("message" => "構文の誤り: #{_1['message']}") }
        probs += Check.pico(code, bundle.checks).map { _1.merge("message" => "端末の Ruby に無い: #{_1['what']} (#{_1['found']})") }
        need_app = mode == "make" || (doc && Check.app_class?(doc))
        if probs.empty? && need_app && !Check.app_class?(code)
          probs << { "line" => 0, "message" => "FmrbApp を継承したクラスが無い" }
        end
        meta = nil
        code, meta, prob = keep_meta(mode, code, doc, last) if probs.empty? && need_app
        probs << prob if prob
        [probs, { "doc" => code, "meta" => meta }]
      end
    end

    # The "#---fmrb" comment at the head of an app (its name and its window's
    # size: the device reads them from there). The LLM leaves it out of a new
    # app at times, and drops it as "a comment nobody needs" when asked to fix
    # one, so it is not left to the LLM alone. Returns [code, what was done
    # (nil, "kept", "restored", "default"), a problem or nil].
    #
    #   fix   the document had one and the answer has none: the document's own
    #         is put back as it was (no question to the LLM). A document
    #         without one is left as it is (its .app.toml may say it all).
    #   make  none: the LLM is asked again (it knows the size its drawing
    #         wants); on the last answer the old document's is used, else a
    #         default one.
    # One opened and not closed where the device looks is the LLM's to mend.
    def keep_meta(mode, code, doc, last)
      state, = Check.meta_fence(code)
      return [code, "kept", nil] if state == :ok
      old_state, old = doc && !doc.empty? ? Check.meta_fence(doc) : [:none, nil]
      return [code, nil, nil] if mode == "fix" && old_state == :none && state == :none
      problem = { "line" => 1, "message" => Check::META_PROBLEM }
      return [code, nil, problem] if state == :broken
      return ["#{old}#{code}", "restored", nil] if old_state == :ok && (mode == "fix" || last)
      return [code, nil, problem] unless last
      ["#{Check.default_meta(code)}#{code}", "default", nil]
    end

    def pieces(text)
      size = @cfg.dig("store", "piece").to_i
      out = []
      cur = +""
      text.each_line do |l|
        while l.bytesize > size # a line longer than a piece: cut it on a character boundary
          head = l.byteslice(0, size).scrub("")
          out << cur unless cur.empty?
          cur = +""
          out << head
          l = l.byteslice(head.bytesize..)
        end
        if cur.bytesize + l.bytesize > size
          out << cur
          cur = +""
        end
        cur << l
      end
      out << cur unless cur.empty?
      out
    end

    def cut(text, max)
      return text if text.bytesize <= max
      "#{text.byteslice(0, max - 3).scrub('')}..."
    end

    def finish(t, parsed, outcome, bundle, used = nil)
      id = t["id"]
      mode = t["req"]["mode"]
      explain = parsed["explain"].dup
      result = { "base_ver" => t["req"]["ver"], "bundle" => bundle.fw }
      full_hints = nil
      case mode
      when "ask"
        result["kind"] = "answer"
      when "hint"
        result["kind"] = "hint"
        orig = t["doc"].lines
        full_hints = outcome["placed"].map do |h|
          at = h["at"]
          { "line" => at, "text" => orig[at - 1].to_s.chomp, "prev" => at > 1 ? orig[at - 2].to_s.chomp : nil,
            "comment" => h["comment"] }
        end
        result["hints"] = full_hints.map { [_1["line"], _1["text"], _1["comment"]] }
        unless outcome["left_out"].empty?
          explain << "\n\n入れられなかったヒント:\n" + outcome["left_out"].map { "- #{_1['line']} 行目: #{_1['comment']}" }.join("\n")
        end
        result["left_out"] = outcome["left_out"].size
      else
        result["kind"] = "doc"
      end
      text = outcome && outcome["doc"]
      ps = text ? pieces(text) : []
      if text
        result["doc_bytes"] = text.bytesize
        result["pieces"] = ps.size
      end
      result["explain"] = cut(explain, EXPLAIN_MAX)
      if cancelled?(id)
        finish_cancel(t)
        return
      end
      return if @halted
      set(id, "done", "result" => result, "doc_pieces" => ps, "full_hints" => full_hints, "done_at" => Time.now)
      @store.add_turn(t["device"], Prompt.talk_user(t["req"], t["doc"]), Prompt.talk_assistant(parsed, result["kind"]))
      @log.write(:result, device: t["device"], ticket: id, result: result, doc: text, used: used)
    end

    # A hint result again on the document as it is now (report a0.md 4):
    # each hint goes above the line with the same text (the nearest to where
    # it was when several have it; a blank or an "end" line is matched with
    # the line above it too). No LLM. Returns the new ticket's id.
    def rebase(t, doc, ver)
      lines = doc.lines.map(&:chomp)
      hints = []
      left = []
      t["full_hints"].each do |h|
        common = h["text"].strip.empty? || h["text"].strip == "end"
        cands = lines.each_index.select do |i|
          lines[i].rstrip == h["text"].rstrip && (!common || h["prev"].nil? || (i.positive? && lines[i - 1].rstrip == h["prev"].rstrip))
        end
        if cands.empty?
          left << h
          next
        end
        dist = cands.map { ((_1 + 1) - h["line"]).abs }
        best = dist.min
        if dist.count(best) > 1
          left << h
          next
        end
        hints << { "line" => cands[dist.index(best)] + 1, "comment" => h["comment"] }
      end
      out = Check.place_hints(doc, hints)
      out = { "doc" => doc, "placed" => [], "left_out" => hints } unless Check.same_code?(doc, out["doc"])
      left_all = left.map { { "line" => _1["line"], "comment" => _1["comment"] } } + out["left_out"]
      full = out["placed"].map do |h|
        at = h["at"]
        { "line" => at, "text" => lines[at - 1].to_s, "prev" => at > 1 ? lines[at - 2] : nil, "comment" => h["comment"] }
      end
      old = t["result"]
      explain = old["explain"].to_s.sub(/\n\n入れられなかったヒント:.*\z/m, "")
      unless left_all.empty?
        explain += "\n\n書きかえたので入れなかったヒント:\n" + left_all.map { "- #{_1['comment']}" }.join("\n")
      end
      ps = pieces(out["doc"])
      result = { "kind" => "hint", "base_ver" => ver, "bundle" => old["bundle"],
                 "hints" => full.map { [_1["line"], _1["text"], _1["comment"]] }, "left_out" => left_all.size,
                 "doc_bytes" => out["doc"].bytesize, "pieces" => ps.size, "explain" => cut(explain, EXPLAIN_MAX) }
      nid = @store.new_ticket(t["device"], "req" => t["req"].merge("ver" => ver), "doc" => doc, "rebased_from" => t["id"])
      set(nid, "done", "result" => result, "doc_pieces" => ps, "full_hints" => full, "done_at" => Time.now)
      @store.ack(t["device"], t["id"])
      @log.write(:rebase, device: t["device"], ticket: nid, from: t["id"], doc_sent: doc, result: result, doc: out["doc"])
      nid
    end
  end
end
