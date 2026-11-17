require "json"

module Tutor
  # A knowledge bundle of one firmware version (bundles/<fw>/, made by
  # tools/make_bundle.rb). A device sends its version; when there is no bundle
  # for it, the nearest older one is used (or the oldest, for a version older
  # than all), and the answer records that.
  class Bundle
    # The files that go to the LLM, in this order (a fixed text, so that the
    # prompt cache holds it).
    PARTS = [
      ["rules_ja.md", "決まり"],
      ["app_guide.md", "アプリの書き方 (app_guide.md)"],
      ["api.rbs", "API の型 (api.rbs)"],
      ["templates", "雛形 (templates)"],
      ["pitfalls.tsv", "罠の表 (pitfalls.tsv): 端末の Ruby に無いもの・違う動きをするもの"],
      ["samples", "見本のアプリ (samples)"]
    ].freeze

    attr_reader :fw, :asked, :dir, :checks, :text

    def self.pick(root, fw)
      versions = JSON.parse(File.read(File.join(root, "index.json")))["versions"]
      raise "no bundles in #{root}" if versions.empty?
      want = Gem::Version.new(fw.to_s.empty? ? "0" : fw.to_s) rescue Gem::Version.new("0")
      sorted = versions.sort_by { Gem::Version.new(_1) }
      exact = sorted.find { Gem::Version.new(_1) == want }
      exact || sorted.reverse.find { Gem::Version.new(_1) <= want } || sorted.first
    end

    def initialize(root, fw)
      @asked = fw.to_s
      @fw = Bundle.pick(root, fw)
      @dir = File.join(root, @fw)
      @checks = JSON.parse(File.read(File.join(@dir, "checks.json")))["checks"]
      @text = build_text.freeze
    end

    def fallback? = @fw != @asked

    def build_text
      out = +"# Family mruby の知識 (ファームの版 #{@fw})\n\n"
      PARTS.each do |name, title|
        path = File.join(@dir, name)
        out << "## #{title}\n\n"
        if File.directory?(path)
          Dir[File.join(path, "*")].sort.each do |f|
            out << "### #{name}/#{File.basename(f)}\n\n```ruby\n#{File.read(f).rstrip}\n```\n\n"
          end
        else
          body = File.read(path).rstrip
          out << (name.end_with?(".md") ? "#{body}\n\n" : "```\n#{body}\n```\n\n")
        end
      end
      out
    end
  end

  # Bundles by version, made once each.
  class Bundles
    def initialize(root)
      @root = root
      @lock = Mutex.new
      @by = {}
    end

    def for(fw)
      @lock.synchronize do
        name = Bundle.pick(@root, fw)
        b = (@by[name] ||= Bundle.new(@root, name))
        # the same files, but remember what the device asked for
        b.fw == fw.to_s ? b : FallbackView.new(b, fw.to_s)
      end
    end
  end

  # A bundle given for another version than the device's.
  class FallbackView < SimpleDelegator
    def initialize(bundle, asked)
      super(bundle)
      @asked_fw = asked
    end

    def asked = @asked_fw
    def fallback? = true
  end
end
