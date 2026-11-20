#!/bin/sh
# Updates (or rolls back) the tutor on a server in one command, the way
# asterism-games' deploy/vps/update.sh does: by version, the published
# image ghcr.io/ruby-asterism/asterism-tutor:<version>. Plain sh, git and
# docker compose: nothing else on the host.
#
#   ./update.sh 0.2.0                  # the version (its tag v0.2.0 and its image)
#   ./update.sh --when-idle 0.2.0      # restart only once no request is being worked on
#   ./update.sh --build 0.2.0          # build the image here from the tag instead of pulling it
#   ./update.sh --dry-run 0.2.0        # print the steps, change nothing
#
# In order:
#   1. checks: the .env, the checkout has no local changes, the tag
#      v<version> (fetched when missing), docker compose answers, the
#      console's network is there (ASTERISM_PROJECT)
#   2. git checkout of the tag (detached: the compose file and the settings
#      of that version), and the image <TUTOR_IMAGE>:<version> pulled (or,
#      with --build, built from the tag with docker-compose.build.yml)
#      while the old tutor keeps running
#   3. (--when-idle) waits until the running tutor works on no request
#      (its status says "0 working"), at most --wait-max minutes; when the
#      time runs out nothing is restarted and the checkout is put back
#   4. TUTOR_VERSION=<version> in .env, docker compose up -d (a request
#      being worked on gets its grace, then fails as "stopped"; the results
#      not fetched, the records and the day's counts stay in the volume)
#   5. checks that the tutor runs on the new image and says it is healthy
#      (joined to the router with the helper exposed)
#   6. prints how to go back (this script with the old version)
# When something fails before the restart, the checkout is put back as it
# was and the running tutor is not touched.
#
# Options:
#   -C DIR          the deploy/vps directory (default: this script's directory)
#   --env-file F    the .env (default: DIR/.env)
#   --sudo          run docker (and git / sed when needed) with sudo
#   --build         build the image here (docker-compose.build.yml) instead of pulling it
#   --when-idle     restart only when no request is being worked on (see 3)
#   --wait-max MIN  minutes --when-idle waits at most (default 30)
#   --dry-run       print what it would do
#
# Paths must not contain spaces. Docs: docs/install.md, "Updating".

usage() {
  sed -n '2,/^# Paths must/p' "$SELF" | sed 's/^# \{0,1\}//'
  exit "${1:-2}"
}

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die() { printf '\nupdate.sh: %s\n' "$*" >&2; exit 1; }

act() {
  say "+ $*"
  [ "$DRY" = 1 ] || "$@" || die "failed: $*"
}

compose() {
  # shellcheck disable=SC2086
  $SUDO docker compose --env-file "$ENV_FILE" -f "$DIR/docker-compose.yml" "$@"
}

act_compose() {
  say "+ ${SUDO:+$SUDO }docker compose $*"
  [ "$DRY" = 1 ] || compose "$@" || die "failed: docker compose $*"
}

env_value() {
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1 | sed "s/^[\"']//; s/[\"']\$//"
}

set_env() {
  if grep -q "^$1=" "$ENV_FILE"; then
    act $ESUDO sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"
  else
    say "+ echo $1=$2 >> $ENV_FILE"
    [ "$DRY" = 1 ] || printf '%s=%s\n' "$1" "$2" | $ESUDO tee -a "$ENV_FILE" >/dev/null || die "could not write $ENV_FILE"
  fi
}

undo() {
  [ "$ARMED" = 1 ] || return 0
  ARMED=0
  printf '\nupdate.sh: stopped; putting the checkout back (%s); the running tutor was not restarted\n' "$OLD_REF" >&2
  $GIT -C "$TOP" -c advice.detachedHead=false checkout -q "$OLD_REF" || say "  could not check out $OLD_REF again: do it by hand" >&2
}

main() {
  ARMED=0
  DIR=""
  ENV_FILE=""
  SUDO=""
  DRY=0
  IDLE=0
  BUILD=0
  WAIT_MAX=30
  VERSION=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -C) DIR=$2; shift 2 ;;
      --env-file) ENV_FILE=$2; shift 2 ;;
      --sudo) SUDO=sudo; shift ;;
      --build) BUILD=1; shift ;;
      --when-idle) IDLE=1; shift ;;
      --wait-max) WAIT_MAX=$2; shift 2 ;;
      --dry-run|-n) DRY=1; shift ;;
      -h|--help) usage 0 ;;
      -*) say "update.sh: unknown option $1" >&2; usage 2 ;;
      *) [ -z "$VERSION" ] || die "one version only ($VERSION, $1)"; VERSION=$1; shift ;;
    esac
  done
  [ -n "$VERSION" ] || usage 2
  VERSION=${VERSION#v}
  printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' || die "not a version: $VERSION (e.g. 0.2.0)"
  printf '%s\n' "$WAIT_MAX" | grep -Eq '^[0-9]+$' || die "--wait-max takes minutes"

  [ -n "$DIR" ] || DIR=$(cd "$(dirname "$SELF")" && pwd)
  DIR=$(cd "$DIR" && pwd) || die "no directory $DIR"
  [ -f "$DIR/docker-compose.yml" ] || die "$DIR is not deploy/vps of asterism-tutor; give it with -C"
  cd "$DIR" || die "cannot enter $DIR"
  [ -n "$ENV_FILE" ] || ENV_FILE="$DIR/.env"
  [ -f "$ENV_FILE" ] || die "no $ENV_FILE (cp env.example .env; docs/install.md)"
  ESUDO=""
  [ -w "$ENV_FILE" ] || ESUDO=$SUDO

  step "Checks"
  TOP=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null) || die "$DIR is not in a git checkout of asterism-tutor"
  GIT=git
  [ -w "$TOP/.git" ] || GIT="$SUDO git"
  # credentials/ belongs to the container's user (docs/install.md, 700): git
  # cannot stat the file it tracks there and would call it changed. Its
  # contents are the tutor's own and never part of the check.
  CREDS="$($GIT -C "$DIR" rev-parse --show-prefix)credentials"
  $GIT -C "$TOP" diff --quiet HEAD -- . ":(exclude)$CREDS" ||
    die "the checkout $TOP has local changes (git status); commit or drop them first"
  OLD_REF=$($GIT -C "$TOP" symbolic-ref -q --short HEAD || $GIT -C "$TOP" rev-parse HEAD)
  TAG="v$VERSION"
  if ! $GIT -C "$TOP" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    depth=""
    [ "$($GIT -C "$TOP" rev-parse --is-shallow-repository)" = true ] && depth="--depth 1"
    # shellcheck disable=SC2086
    act $GIT -C "$TOP" fetch -q $depth origin "refs/tags/$TAG:refs/tags/$TAG" ||
      die "no tag $TAG (git fetch failed; is $VERSION released?)"
  fi
  $SUDO docker compose version >/dev/null 2>&1 || die "docker compose does not answer (try --sudo)"
  PROJECT=$(env_value ASTERISM_PROJECT)
  [ -n "$PROJECT" ] || PROJECT=asterism
  $SUDO docker network inspect "${PROJECT}_router" >/dev/null 2>&1 ||
    die "no network ${PROJECT}_router: start the console's stack first (ASTERISM_PROJECT in .env)"
  IMAGE=$(env_value TUTOR_IMAGE)
  [ -n "$IMAGE" ] || IMAGE=ghcr.io/ruby-asterism/asterism-tutor
  FROM=$(env_value TUTOR_VERSION)
  RUNNING=0
  [ -n "$(compose ps -q tutor 2>/dev/null)" ] && RUNNING=1
  if [ "$BUILD" = 1 ]; then how="built here from $TAG"; else how="pulled"; fi
  say "  $DIR (checkout $TOP at $OLD_REF), the console's project $PROJECT"
  say "  tutor ${FROM:-(none)} -> $VERSION ($IMAGE:$VERSION, $how)"
  [ "$IDLE" = 0 ] || say "  restart: when no request is being worked on (at most $WAIT_MAX minutes)"
  [ "$DRY" = 0 ] || say "  dry run: nothing below is run"

  ARMED=1
  trap undo EXIT
  step "The files and the image of $VERSION"
  act $GIT -C "$TOP" -c advice.detachedHead=false checkout -q "$TAG"
  if [ "$BUILD" = 1 ]; then
    say "+ ${SUDO:+$SUDO }env TUTOR_VERSION=$VERSION docker compose -f docker-compose.yml -f docker-compose.build.yml build tutor"
    if [ "$DRY" = 0 ]; then
      $SUDO env TUTOR_VERSION="$VERSION" docker compose --env-file "$ENV_FILE" -f "$DIR/docker-compose.yml" \
        -f "$DIR/docker-compose.build.yml" build tutor ||
        die "the image did not build (the tutor was not restarted)"
    fi
  else
    say "+ ${SUDO:+$SUDO }env TUTOR_VERSION=$VERSION docker compose pull tutor"
    if [ "$DRY" = 0 ]; then
      $SUDO env TUTOR_VERSION="$VERSION" docker compose --env-file "$ENV_FILE" -f "$DIR/docker-compose.yml" pull tutor ||
        die "could not pull $IMAGE:$VERSION (is $VERSION published? --build builds it here; the tutor was not restarted)"
    fi
  fi

  if [ "$IDLE" = 1 ] && [ "$RUNNING" = 1 ]; then
    step "Waiting until no request is being worked on"
    if [ "$DRY" = 1 ]; then
      say "(would ask the running tutor every 10 s: exe/asterism-tutor status)"
    else
      waited=0
      while :; do
        line=$(compose exec -T tutor bundle exec exe/asterism-tutor status </dev/null 2>&1)
        case "$line" in
          *" 0 working"*) break ;;
          *" working"*) ;;
          *) say "  (the tutor does not answer its status: going on)"; break ;;
        esac
        [ "$waited" -ge $((WAIT_MAX * 60)) ] && die "still working after $WAIT_MAX minutes: nothing restarted (run again later)"
        sleep 10
        waited=$((waited + 10))
      done
    fi
  fi

  ARMED=0
  step "Restart"
  set_env TUTOR_VERSION "$VERSION"
  act_compose up -d tutor

  step "Check"
  if [ "$DRY" = 1 ]; then
    say "(would wait until the tutor runs on $IMAGE:$VERSION and says it is up)"
  else
    tries=0
    until compose exec -T tutor bundle exec exe/asterism-tutor status </dev/null; do
      tries=$((tries + 1))
      [ "$tries" -ge 30 ] && die "the tutor is not up after 60 s (docker compose logs tutor)"
      sleep 2
    done
    img=$($SUDO docker inspect -f '{{.Config.Image}}' "$(compose ps -q tutor)")
    [ "$img" = "$IMAGE:$VERSION" ] || die "the tutor runs $img, not $IMAGE:$VERSION"
  fi
  trap - EXIT

  step "Done: tutor $VERSION"
  if [ -n "$FROM" ] && [ "$FROM" != "$VERSION" ]; then
    if printf '%s\n' "$FROM" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+'; then
      say "To go back: sh $DIR/update.sh -C $DIR $FROM (the image $IMAGE:$FROM is kept)"
    else
      say "Before: $FROM (an image built from a checkout; to go back, a version: sh $DIR/update.sh -C $DIR <version>)"
    fi
  fi
  say "Old images stay for going back; list them: ${SUDO:+$SUDO }docker image ls $IMAGE"
}

SELF=$0
# The whole script is read before it runs (main), so the checkout of
# another version may replace this file while it runs.
main "$@"; exit $?
