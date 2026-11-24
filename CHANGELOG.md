# Changelog

## 0.3.0

The knowledge comes from the Family mruby sources, and the LLM can look things up.

- The gem clones fmruby-core and asterism from their public repositories (shallow, partial,
  sparse: only the bundle's paths and the search scope; no `components/`, no submodules) and
  makes each request's bundle from them (`Tutor::Sources`, `Tutor::BundleMaker`). The device's
  firmware version picks fmruby-core's ref: the release tag of that name, else `develop`.
  One snapshot per ref in `sources.dir`; a changed commit is cloned beside the old one and
  swapped in, and a request keeps the snapshot it started with. Fetched at start, once a day
  (`sources.refresh_hours`) and when a version is asked for the first time. When the fetch
  fails, the snapshot on disk; with none, the bundle in the gem (kept, made again from
  develop with the picture API and the types of Asterism for apps). The same sources give the same bundle byte for byte.
- The app guide (the skill `fmrb-app-new`) is not in a public repository: the gem keeps a copy
  in `data/app_guide.md`, which `tools/make_bundle.rb` refreshes from a local checkout.
- Two tools for the LLM, read only: `search_source` and `read_source`, over `sources.search`
  (sig, flash/app, the mrblib of lib/gems, the device's guides, doc/reference) minus
  `sources.exclude` (flash/app/test, the mahjong app) and the apps (`.rb` files in
  `flash/app/`) over `sources.rb_max_kb` (32); the libraries are searched whatever their size. Paths are looked up in an index made without following links, so nothing outside can
  be read; the search runs in Ruby. Up to `lookup.rounds` (4) rounds a request, then it
  answers with what it has; no new look-up with less than a third of `llm.timeout_s` left
  (the time limit is now for one answer with its look-ups). Their rules are
  `data/tools_ja.md`. The fake LLM can call them (`[[search ...]]`, `[[read ...]]`,
  `[[lookup_loop]]`).
- The log: `knowledge` (the bundle a request used), `sources` (each fetch), `tool` (each look-up),
  `llm` with `round` and `tool_calls`, `result` with `used` (rounds, calls, tokens, cost); every
  round's cost counts in the daily limit. `asterism-tutor status` shows the snapshots and the
  last errors.
- Settings: `[sources]` and `[lookup]`; `ASTERISM_TUTOR_SOURCES`, `ASTERISM_TUTOR_SOURCES_DIR`,
  `ASTERISM_TUTOR_LOOKUP_ROUNDS`. An LLM call that times out is the error `timeout`.
- The image has git and a volume `sources` (`/sources`).
- The comment at the head of an app that says its name and its window's size (`#---fmrb` to
  `#---`, which the device reads) is no longer left to the LLM alone. It left it out of new
  apps at times, and dropped it as an unneeded comment when asked to fix one. The rules and
  the make/fix prompts now say what it is and that it stays; the check reads it the way the
  device does (the first 512 bytes, before the first line of code, closed). Fix: when the
  document had one and the answer has none, the document's own is put back with no question
  to the LLM. Make: the LLM is asked again, and after the last retry the old document's or
  a default one (the class's name, 200x140) is put in. A fix to a document that never had
  one is left alone.

## 0.2.2

- The Japanese messages a device shows call the gem "AI ホスト" (the stop and stopping messages; the device's own text says the same from Family mruby develop of 2026-11-20).
- `deploy/vps/update.sh`: the status it asks the running container for reads no input, so it does not wait on the terminal (seen once with `sudo-rs` on Ubuntu 26.04 over ssh; the cause is not pinned down).

## 0.2.1

- Ruby 3.4.13 in the image (`ruby:3.4.13-slim`), for the Regexp and String case conversion fixes of 2026-11-18 (heap overflows, a double free and out-of-bounds reads in 3.4.0-3.4.12).
  No change in the gem.

## 0.2.0

Runs as a container next to an Asterism console (docs/install.md).

- Every main setting can come from the environment (`ASTERISM_TUTOR_*`; options over the
  environment over the file over the defaults), so a `.env` is enough.
- The results a device has not fetched yet are kept on disk (`store.state_dir`, one file per
  request) and survive a restart; the day's counts and cost were already read back from the
  records.
- `asterism-tutor status`: whether the running gem is joined to its router with the helper
  exposed (for a healthcheck; it reads `status.json`, no port).
- SIGTERM: no new requests, the ones being worked on get `jobs.stop_grace_s` (8 s), the rest
  are failed as `stopped` (also at the next start, for a gem that was killed). A request
  during the stop gets the error `stopping`. A request failed as `stopped` is not counted in
  the device's requests of the day (the LLM cost it already made is).
- The container's day (the limits and the records' files) is Japan's by default
  (`TUTOR_TZ=Asia/Tokyo`).
- docs/install.md: the browser build's users, with the role `tutor` given per user (Asterism
  console 0.4.2 or later).
- `deploy/vps/`: the Dockerfile, the compose files, `env.example`, `update.sh`; the image
  `ghcr.io/ruby-asterism/asterism-tutor` built for each tag `v<version>` (amd64).
- `test/sender.rb --credentials` calls through an mTLS router with a console's certificate;
  its application is `ai_helper`, the device's.
- The repository is public: `LICENSE` (MIT), `README.md` in English with the Japanese one
  as `README.ja.md`.

## 0.1.0

The prototype: the helper object (`<node>/tutor/helper`), the fake and Anthropic LLMs, the
knowledge bundle for firmware 3.1.0, the checks (Prism and the table of pitfalls), the daily
limits, the JSONL log, options for the model and the limits.
