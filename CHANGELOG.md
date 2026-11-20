# Changelog

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
