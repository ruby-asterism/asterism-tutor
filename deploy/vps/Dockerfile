# The AI helper's image (asterism-tutor): CRuby, the gems of Gemfile.lock
# and the gem itself with its knowledge bundles (bundles/) and rules
# (data/). Published for each version by .github/workflows/image.yml as
# ghcr.io/ruby-asterism/asterism-tutor (docs/install.md); built here
# instead with docker-compose.build.yml, or by hand from the repository's
# root:
#   docker build -f deploy/vps/Dockerfile -t asterism-tutor:dev .
#
# asterism-zenoh compiles its C extension against the zenoh-c release it
# pins, downloaded while the image is built; prism and msgpack compile
# theirs. The runtime stage has no compiler.
#
# No key is in the image: the LLM key is ANTHROPIC_API_KEY in the
# container's environment (deploy/vps/.env), the router's certificate is
# mounted read-only at /credentials.
ARG RUBY_VERSION=3.4.13
FROM ruby:${RUBY_VERSION}-slim AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential curl git pkg-config unzip ca-certificates && \
    rm -rf /var/lib/apt/lists/*

ENV BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_DEPLOYMENT=1

WORKDIR /app
COPY Gemfile Gemfile.lock asterism-tutor.gemspec ./
COPY lib/tutor/version.rb lib/tutor/version.rb
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

COPY . .

FROM ruby:${RUBY_VERSION}-slim

ARG TUTOR_VERSION=dev
LABEL org.opencontainers.image.title="asterism-tutor" \
      org.opencontainers.image.source="https://github.com/ruby-asterism/asterism-tutor" \
      org.opencontainers.image.description="The parent's side of Family mruby's AI helper: answers the devices over Asterism" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${TUTOR_VERSION}"

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# The records and the tickets go to the state volume (docker-compose.yml);
# the router's certificate is the console's .tar in /credentials.
ENV BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_DEPLOYMENT=1 \
    ASTERISM_TUTOR_LOG_DIR=/state/log \
    ASTERISM_TUTOR_STATE_DIR=/state/store \
    ASTERISM_TUTOR_IMAGE_VERSION=${TUTOR_VERSION}

WORKDIR /app
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /app /app

# Runs as 1000, the owner of credentials/ on the server (docs/install.md).
RUN groupadd --system --gid 1000 tutor && useradd --uid 1000 --gid 1000 --no-create-home tutor && \
    mkdir -p /state && chown tutor:tutor /state
USER 1000:1000

CMD ["bundle", "exec", "exe/asterism-tutor"]
