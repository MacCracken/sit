#!/bin/sh
# gen-version.sh — regenerate src/version.cyr from the VERSION file.
#
# The `/sit/v1/capabilities` banner has to report sit's version from *source*,
# but cyrius.cyml's ${file:VERSION} is build metadata and does not reach source,
# and `cyrius build` has no value-injection flag (--features is conditional
# compilation, not a define). So the constant is generated here instead of
# hand-copied.
#
# It was hand-copied from v0.8.2 to v1.4.7: it silently drifted to 0.8.10
# through v1.0.3, and was missed again at 1.4.6 — caught only by the CI gate
# that exists solely to catch it. Recorded as a known footgun in the v0.8.2
# CHANGELOG and finally closed in 1.4.8.
#
# Run from the repo root. CI regenerates and diffs, the same shape as the
# `dist/` sync gate, so a stale version.cyr fails the build rather than
# shipping a wrong banner.
set -e
cd "$(dirname "$0")/.."
VERSION=$(tr -d '[:space:]' < VERSION)

case "$VERSION" in
    *[!0-9.]*|"") echo "gen-version: VERSION is not a bare semver: '$VERSION'" >&2; exit 1 ;;
esac

cat > src/version.cyr <<CYR
# version.cyr — GENERATED FILE, DO NOT EDIT.
#
# Regenerate with \`scripts/gen-version.sh\` after changing VERSION; CI fails if
# this file disagrees with VERSION. See that script for why the version is
# generated rather than hand-copied.
#
# Kept as a function rather than a top-level \`var\` on purpose: a top-level
# \`var NAME = <non-literal>\` consumes one of the 4,096 initialized-globals
# slots, and a bare string literal in a function body does not.

fn sit_version_string() { return "$VERSION"; }
CYR
echo "src/version.cyr: $VERSION"
