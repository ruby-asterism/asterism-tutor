require "securerandom"
require "json"
require "fileutils"
require "time"

module Tutor
  # What the gem keeps: documents being sent in pieces, the tickets
  # (requests and their results), and each device's talk. One Mutex; every
  # method returns copies or plain values, so the helper (on Asterism's
  # receiving thread) and the workers never share a Hash being changed.
  #
  # The tickets are also files, one per ticket (<state_dir>/tickets/<id>.json,
  # written again on every change), so that a result a device has not
  # fetched survives a restart (a container made again on the same volume).
  # The documents in pieces and the talk stay in memory only: a document
  # is sent again, and the talk is forgotten after talk.forget_min anyway.
  class Store
    ACTIVE = %w[queued thinking checking].freeze
    DOC_HOURS = 1
    TIME_KEYS = %w[created done_at].freeze
    ID = /\At[0-9a-f]{8}\z/

    attr_reader :dir

    def initialize(cfg, clock: -> { Time.now })
      @cfg = cfg
      @clock = clock
      @lock = Mutex.new
      @docs = {}
      @tickets = {}
      @talks = {}
      @dir = File.join(cfg.state_dir, "tickets")
      FileUtils.mkdir_p(@dir)
      load_tickets
    end

    # The tickets that were being worked on when the gem stopped (their
    # work is gone with the process): ids, oldest first.
    def interrupted
      @lock.synchronize do
        @tickets.values.select { ACTIVE.include?(_1["state"]) }.sort_by { _1["created"] }.map { _1["id"] }
      end
    end

    # The tickets being worked on now (queued or running), all devices.
    def active_ids
      @lock.synchronize { @tickets.values.select { ACTIVE.include?(_1["state"]) }.map { _1["id"] } }
    end

    def now = @clock.call

    # --- documents in pieces ---

    def new_doc(device, bytes)
      @lock.synchronize do
        purge
        id = "d#{SecureRandom.hex(4)}"
        @docs[id] = { "device" => device, "bytes" => bytes, "pieces" => {}, "at" => now }
        id
      end
    end

    # The bytes received so far, or nil for an unknown document.
    def put_piece(device, id, i, text)
      @lock.synchronize do
        d = @docs[id]
        return nil unless d && d["device"] == device
        d["pieces"][i] = text
        d["at"] = now
        d["pieces"].values.sum(&:bytesize)
      end
    end

    # [text, nil] or [nil, reason]
    def take_doc(device, id)
      @lock.synchronize do
        d = @docs[id]
        return [nil, "no such document"] unless d && d["device"] == device
        n = d["pieces"].size
        return [nil, "pieces missing"] unless (0...n).all? { d["pieces"].key?(_1) }
        text = (0...n).map { d["pieces"][_1] }.join
        return [nil, "document has #{text.bytesize} of #{d['bytes']} bytes"] unless text.bytesize == d["bytes"]
        [text, nil]
      end
    end

    # --- tickets ---

    def new_ticket(device, fields)
      @lock.synchronize do
        purge
        id = "t#{SecureRandom.hex(4)}"
        @tickets[id] = fields.merge("id" => id, "device" => device, "state" => "queued", "message" => "順番を待っています",
                                    "created" => now, "acked" => false, "cancel" => false)
        save(id)
        id
      end
    end

    def ticket(id)
      @lock.synchronize { (t = @tickets[id]) && t.dup }
    end

    # The ticket when it is this device's, else nil.
    def ticket_of(device, id)
      t = ticket(id)
      t && t["device"] == device ? t : nil
    end

    def update(id, fields)
      @lock.synchronize do
        next nil unless @tickets[id]
        @tickets[id].merge!(fields)
        save(id)
      end
    end

    def active?(device)
      @lock.synchronize { @tickets.values.any? { _1["device"] == device && ACTIVE.include?(_1["state"]) } }
    end

    def pending(device)
      @lock.synchronize do
        purge
        @tickets.values.select { _1["device"] == device && !_1["acked"] }.sort_by { _1["created"] }.map { [_1["id"], _1["state"]] }
      end
    end

    def ack(device, id)
      @lock.synchronize do
        t = @tickets[id]
        return false unless t && t["device"] == device
        t["acked"] = true
        save(id)
        true
      end
    end

    # The result's documents are dropped after result_hours; the log keeps them.
    def purge
      limit = now - @cfg.dig("store", "result_hours").to_f * 3600
      @tickets.delete_if do |id, t|
        old = t["created"] < limit && !ACTIVE.include?(t["state"])
        File.delete(file(id)) if old && File.exist?(file(id))
        old
      end
      @docs.delete_if { |_, d| d["at"] < now - DOC_HOURS * 3600 }
    end

    # --- the files ---

    def file(id) = File.join(@dir, "#{id}.json")

    # Written whole, then renamed over the old one: a reader (or a restart)
    # sees the old ticket or the new one, never half of one.
    def save(id)
      t = @tickets[id]
      data = t.to_h { |k, v| [k, TIME_KEYS.include?(k) && v.respond_to?(:iso8601) ? v.iso8601(3) : v] }
      tmp = "#{file(id)}.tmp"
      File.write(tmp, JSON.generate(data))
      File.rename(tmp, file(id))
    end

    def load_tickets
      Dir[File.join(@dir, "t*.json")].each do |f|
        id = File.basename(f, ".json")
        next unless ID.match?(id)
        t = JSON.parse(File.read(f))
        TIME_KEYS.each { t[_1] = Time.iso8601(t[_1]) if t[_1].is_a?(String) }
        next unless t["id"] == id && t["created"].is_a?(Time)
        @tickets[id] = t
      rescue JSON::ParserError, ArgumentError, SystemCallError => e
        warn "asterism-tutor: skipped the ticket file #{File.basename(f)} (#{e.class})"
      end
      Dir[File.join(@dir, "*.tmp")].each { File.delete(_1) rescue nil }
      @lock.synchronize { purge }
    end

    # --- the talk: the last turns of each device ---

    def talk(device)
      @lock.synchronize do
        t = @talks[device]
        return [] unless t
        if now - t["at"] > @cfg.dig("talk", "forget_min").to_f * 60
          @talks.delete(device)
          return []
        end
        t["turns"].map(&:dup)
      end
    end

    def add_turn(device, user, assistant)
      @lock.synchronize do
        t = (@talks[device] ||= { "turns" => [], "at" => now })
        t["turns"] << [user, assistant]
        t["turns"] = t["turns"].last(@cfg.dig("talk", "turns").to_i)
        t["at"] = now
      end
    end

    def forget_talk(device)
      @lock.synchronize { @talks.delete(device) }
    end
  end
end
