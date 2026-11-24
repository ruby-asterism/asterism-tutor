require "monitor"

module Tutor
  # The two tools the LLM may use to look into the sources (read only):
  # search_source (a string or a regular expression, over the files in scope)
  # and read_source (a range of lines of one file in scope).
  #
  # The scope is a list of glob patterns relative to the source's root
  # (sources.search). Only regular files that match one are indexed; the
  # tools take a path only by looking it up in that index, so "..", an
  # absolute path or a symbolic link (a file or a directory on the way) can
  # never reach a file outside. Everything runs in Ruby: no string from the
  # LLM goes to a command.
  class Lookup
    SEARCH = "search_source".freeze
    READ = "read_source".freeze
    # Defaults of sources.* (Config); the limits are per call.
    SCOPE = ["sig/**/*", "flash/app/**/*", "lib/gems/*/mrblib/**/*", "flash/usr/share/doc/**/*",
             "doc/reference/**/*"].freeze
    # Left out of the scope: the regression tools' apps (odd code on purpose)
    # and the big apps (too much for a light model to read).
    EXCLUDE = ["flash/app/test/**/*", "flash/app/game/mahjong/**/*"].freeze
    # An app (.rb under RB_MAX_UNDER) bigger than this is left out too: a big
    # app is not a sample to copy, and too much for a light model to read. The
    # libraries (lib/gems/*/mrblib) are searched whatever their size: the
    # Ruby side of FmrbApp and FmrbUI is there.
    RB_MAX = 32 * 1024
    RB_MAX_UNDER = "flash/app/".freeze
    FILE_MAX = 512 * 1024        # bigger files are left out of the index
    PATTERN_MAX = 200
    REGEXP_TIMEOUT = 0.5         # seconds for one line (Regexp timeout)
    SEARCH_TIME = 3.0            # seconds for one search

    # The tools as the LLM sees them (a fixed text: it is part of the cached prefix).
    def self.tools(hits:, lines:)
      [
        { name: SEARCH,
          description: "Search the Family mruby sources (API types in sig/, the apps in flash/app/, the Ruby side " \
                       "of the libraries in lib/gems/*/mrblib/, the device's guides, doc/reference/) for a string. " \
                       "Returns up to #{hits} matching lines as \"path:line: text\". Use it only when the knowledge " \
                       "above is not enough.",
          input_schema: {
            type: "object",
            properties: {
              pattern: { type: "string", description: "What to look for: a Ruby regular expression (a|b finds either), " \
                                                      "or plain text. Text that is not a valid expression, or that " \
                                                      "finds nothing as one, is looked for as it is written" },
              regexp: { type: "boolean", description: "false: look for pattern exactly as written, never as a regular expression" },
              ignore_case: { type: "boolean", description: "Ignore case (default false)" },
              path: { type: "string", description: "Only files whose path starts with this (e.g. \"sig/\" or \"flash/app/\")" }
            },
            required: ["pattern"],
            additionalProperties: false
          } },
        { name: READ,
          description: "Read lines of one file found by #{SEARCH} (its path as shown there). " \
                       "Returns up to #{lines} lines with their numbers.",
          input_schema: {
            type: "object",
            properties: {
              path: { type: "string", description: "The file's path, as #{SEARCH} shows it" },
              from: { type: "integer", description: "The first line (from 1; default 1)" },
              to: { type: "integer", description: "The last line (default from + #{lines - 1})" }
            },
            required: ["path"],
            additionalProperties: false
          } }
      ]
    end

    attr_reader :root, :hits_max, :lines_max, :line_chars

    # root: the source's directory; scope: glob patterns relative to it.
    def initialize(root, scope = SCOPE, exclude: EXCLUDE, rb_max: RB_MAX, hits: 30, lines: 120, line_chars: 200)
      @root = File.realpath(root)
      @rb_max = rb_max
      @scope = scope
      @exclude = exclude
      @hits_max = hits
      @lines_max = lines
      @line_chars = line_chars
      @lock = Monitor.new
    end

    def tools = Lookup.tools(hits: @hits_max, lines: @lines_max)

    # {relative path => absolute path} of the files in scope (made once).
    def files
      @lock.synchronize { @files ||= index }
    end

    def file_count = files.size
    def bytes = files.sum { |_, f| File.size(f) }

    def in_scope?(rel) = @scope.any? { glob?(_1, rel) } && @exclude.none? { glob?(_1, rel) }

    def glob?(pattern, rel) = File.fnmatch?(pattern, rel, File::FNM_PATHNAME | File::FNM_EXTGLOB)

    # Runs one tool call. Returns {"text" => what goes back to the LLM,
    # "error" => true/false, "info" => what the record keeps}.
    def call(name, input)
      input = input.is_a?(Hash) ? input.transform_keys(&:to_s) : {}
      case name
      when SEARCH then search(input["pattern"], regexp: input["regexp"] == false ? false : nil,
                                                ignore_case: input["ignore_case"] == true, path: input["path"])
      when READ then read(input["path"], input["from"], input["to"])
      else fail_with("unknown tool #{name}")
      end
    end

    # regexp: nil (the default) reads the pattern as a regular expression and,
    # when it is not a valid one or finds nothing, as plain text; false reads
    # it as plain text only; true as an expression only (a bad one is an error).
    #
    # The LLM used to have to say regexp: true and did not always: "a|b|c"
    # then found nothing as text, and a round of the few a request has was
    # gone. Names with marks in them ("draw_text(", "conn[") are not valid
    # expressions, or find nothing as one ("arr[0]"), and are found as text.
    def search(pattern, regexp: nil, ignore_case: false, path: nil)
      pattern = pattern.to_s
      return fail_with("pattern is empty") if pattern.strip.empty?
      return fail_with("pattern is longer than #{PATTERN_MAX} characters") if pattern.length > PATTERN_MAX
      prefix = path.to_s
      flags = ignore_case ? Regexp::IGNORECASE : 0
      plain = Regexp.new(Regexp.escape(pattern), flags, timeout: REGEXP_TIMEOUT)
      re = nil
      unless regexp == false
        begin
          re = Regexp.new(pattern, flags, timeout: REGEXP_TIMEOUT)
        rescue RegexpError => e
          return fail_with("bad regular expression: #{e.message}") if regexp == true
        end
      end
      as = re ? "regexp" : "text"
      r = scan(re || plain, prefix)
      if regexp.nil? && re && r[:total].zero? && !r[:cut]
        as = "text"
        r = scan(plain, prefix)
      end
      total = r[:total]
      found = r[:found]
      head =
        if total.zero? then "no match"
        elsif total > found.size then "#{total} matches, the first #{found.size}:"
        else "#{total} matches:"
        end
      head += " (the search stopped after #{SEARCH_TIME} s)" if r[:cut]
      { "text" => ([head] + found).join("\n"), "error" => false,
        "info" => { "pattern" => pattern, "regexp" => as == "regexp", "path" => prefix, "matches" => total,
                    "shown" => found.size, "cut" => r[:cut] } }
    end

    # The lines of the files under prefix that match re.
    def scan(re, prefix)
      found = []
      total = 0
      cut = false
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      files.keys.sort.each do |rel|
        next unless rel.start_with?(prefix)
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0 > SEARCH_TIME
          cut = true
          break
        end
        lines(rel).each_with_index do |l, i|
          next unless (l.match?(re) rescue false) # Regexp::TimeoutError: that line does not match
          total += 1
          found << "#{rel}:#{i + 1}: #{short(l)}" if found.size < @hits_max
        end
      end
      { total: total, found: found, cut: cut }
    end

    def read(path, from, to)
      rel = path.to_s.sub(%r{\A\./}, "")
      return fail_with("no such file in scope: #{path} (use a path #{SEARCH} shows)") unless files.key?(rel)
      all = lines(rel)
      from = from.is_a?(Integer) && from.positive? ? from : 1
      to = to.is_a?(Integer) && to >= from ? to : from + @lines_max - 1
      to = [to, from + @lines_max - 1, all.size].min
      return fail_with("#{rel} has #{all.size} lines") if from > all.size
      w = to.to_s.size
      body = (from..to).map { format("%#{w}d| %s", _1, short(all[_1 - 1], @line_chars * 2)) }
      head = "#{rel} lines #{from}-#{to} of #{all.size}"
      { "text" => ([head] + body).join("\n"), "error" => false,
        "info" => { "path" => rel, "from" => from, "to" => to, "lines" => all.size } }
    end

    private

    def fail_with(why) = { "text" => why, "error" => true, "info" => { "why" => why } }

    def short(line, max = @line_chars)
      l = line.chomp
      l.length > max ? "#{l[0, max]}..." : l
    end

    def lines(rel)
      @lock.synchronize do
        @lines ||= {}
        @lines[rel] ||= File.read(files.fetch(rel)).force_encoding("UTF-8").scrub.lines.freeze
      end
    end

    # Walks the tree without following any symbolic link and keeps the
    # regular text files in scope.
    def index
      out = {}
      walk(@root, "") do |abs, rel|
        next unless in_scope?(rel)
        st = File.lstat(abs)
        next unless st.file? && st.size <= FILE_MAX
        next if rel.start_with?(RB_MAX_UNDER) && rel.end_with?(".rb") && st.size > @rb_max
        head = File.binread(abs, 8192) || ""
        next if head.include?("\x00")
        out[rel] = abs
      end
      out
    end

    def walk(dir, rel, &blk)
      Dir.children(dir).sort.each do |name|
        next if name == ".git"
        abs = File.join(dir, name)
        r = rel.empty? ? name : "#{rel}/#{name}"
        st = File.lstat(abs)
        next if st.symlink?
        if st.directory?
          walk(abs, r, &blk)
        elsif st.file?
          yield abs, r
        end
      end
    end
  end
end
