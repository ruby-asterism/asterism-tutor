require_relative "lib/tutor/version"

Gem::Specification.new do |s|
  s.name = "asterism-tutor"
  s.version = Tutor::VERSION
  s.summary = "The parent's side of Family mruby's AI helper: answers a device over Asterism"
  s.description = "Runs on a parent's PC. A Family mruby device asks it (over Asterism) for an " \
                  "answer, a hint as comments or a whole app; it calls an LLM with a knowledge " \
                  "bundle of the device's firmware version, checks the code with Prism and " \
                  "returns it. The LLM key, the knowledge, the checks, the limits and the log " \
                  "stay on the PC."
  s.authors = ["Katsuhiko Kageyama"]
  s.license = "MIT"
  s.required_ruby_version = ">= 3.4"
  s.files = Dir["lib/**/*.rb", "exe/*", "bundles/**/*", "data/*", "config/*.example",
                "tools/make_bundle.rb", "README.md", "README.ja.md", "LICENSE", "CHANGELOG.md"]
  s.require_paths = ["lib"]
  s.bindir = "exe"
  s.executables = ["asterism-tutor"]
  s.add_dependency "asterism", ">= 0.14"
  s.add_dependency "prism", "= 1.9.0"   # the Prism inside the device's mruby-compiler
  s.add_dependency "anthropic", "~> 1.80.0"
  s.add_dependency "msgpack", "~> 1.7"
  s.add_dependency "tomlrb", "~> 2.0"
end
