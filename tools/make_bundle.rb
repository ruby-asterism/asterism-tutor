#!/usr/bin/env ruby
# Makes the knowledge bundle the gem carries (bundles/<fw>/ and
# bundles/index.json) from a family-mruby checkout (read only). The gem's
# copy of the app guide (data/app_guide.md) is refreshed from the checkout's
# skill too: the skill is not in the public repositories, so a gem that takes
# its sources from GitHub (Tutor::Sources) uses that copy.
#
#   ruby tools/make_bundle.rb --root /path/to/family-mruby [--out bundles] [--fw 3.1.0]
#
# What goes in: lib/tutor/bundle_maker.rb.
require "json"
require "optparse"
require_relative "../lib/tutor/bundle_maker"

opts = { out: File.expand_path("../bundles", __dir__) }
OptionParser.new do |o|
  o.on("--root DIR", "family-mruby checkout") { opts[:root] = File.expand_path(_1) }
  o.on("--out DIR", "bundles directory") { opts[:out] = File.expand_path(_1) }
  o.on("--fw VERSION", "firmware version (default: FMRB_OS_VERSION of fmrb.h)") { opts[:fw] = _1 }
end.parse!
root = opts[:root] or abort("--root is needed")
core = File.join(root, "fmruby-core")
asterism = File.join(root, "asterism")

# The commit of a checkout, read from .git without running git.
def head_commit(dir)
  head = File.read(File.join(dir, ".git", "HEAD")).strip
  return head unless head.start_with?("ref: ")
  ref = head.sub("ref: ", "")
  loose = File.join(dir, ".git", ref)
  return File.read(loose).strip if File.exist?(loose)
  packed = File.join(dir, ".git", "packed-refs")
  line = File.exist?(packed) && File.readlines(packed).find { _1.end_with?(" #{ref}\n") }
  line ? line.split(" ").first : "unknown"
rescue Errno::ENOENT
  "unknown"
end

skill = File.join(root, ".claude/skills/fmrb-app-new/SKILL.md")
guide = nil
if File.file?(skill)
  guide = Tutor::BundleMaker.app_guide_from_skill(File.read(skill))
  File.write(File.join(Tutor::BundleMaker::DATA, "app_guide.md"), guide)
  puts "data/app_guide.md: from the skill (#{guide.bytesize} bytes)"
end

fw = opts[:fw] || Tutor::BundleMaker.core_version(core) or abort("cannot find FMRB_OS_VERSION")
made_from = { "core" => head_commit(core), "root" => head_commit(root), "asterism" => head_commit(asterism) }
m = Tutor::BundleMaker.make(core: core, asterism: asterism, out: File.join(opts[:out], fw), fw: fw,
                            app_guide: guide, made_from: made_from)

# index.json: every bundle directory there
versions = Dir[File.join(opts[:out], "*/manifest.json")].map { File.basename(File.dirname(_1)) }
versions.sort_by! { Gem::Version.new(_1) }
File.write(File.join(opts[:out], "index.json"), JSON.pretty_generate({ "versions" => versions }) + "\n")

puts "bundle #{fw}: #{m['files'].size} files, #{m['bytes']} bytes, ~#{m['tokens_est']} tokens (estimate)"
puts "  checks: #{m['checks']}, pitfalls: #{m['pitfalls']}"
