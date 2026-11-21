require "minitest/autorun"
require "tmpdir"
require_relative "../lib/tutor"

# The shape of an Anthropic key, made at run time so that this file does not
# hold it (the repository is checked with grep for that shape).
KEY_PREFIX = "sk-" + "ant"

# No test goes to GitHub: the sources' URLs must be local (file:// or a
# path); the gems the e2e test starts inherit this.
ENV["ASTERISM_TUTOR_SOURCES_LOCAL_ONLY"] = "1"
