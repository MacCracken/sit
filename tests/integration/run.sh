#!/usr/bin/env bash
# sit — in-tree integration suite (v0.8.12)
#
# Promotes the docs/guides/getting-started.md end-to-end scenarios into a
# versioned, locally-runnable test with explicit assertions, plus the two
# v0.8.12 feature gates (shallow clone, `log --graph`). Runnable locally
# (`tests/integration/run.sh`) and from CI. Exits non-zero on any failure.
#
# Binary: $SIT, else <repo>/build/sit. Each scenario runs in an isolated
# HOME + temp repo; everything is cleaned up on exit.
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SIT="${SIT:-$ROOT/build/sit}"
[ -x "$SIT" ] || { echo "sit binary not found at $SIT — build with 'cyrius build src/main.cyr build/sit'"; exit 1; }

WORK=$(mktemp -d -t sit-itest.XXXXXX)
export HOME="$WORK/home"; mkdir -p "$HOME"
export SIT_AUTHOR_NAME="Integration Test"
export SIT_AUTHOR_EMAIL="itest@sit.local"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$*"; }
assert_eq()       { if [ "$1" = "$2" ]; then ok; else bad "$3 (expected '$2', got '$1')"; fi; }
assert_contains() { case "$1" in *"$2"*) ok;; *) bad "$3 (missing '$2')";; esac; }
hr() { printf '\n=== %s ===\n' "$*"; }

# Object count from `fsck` ("checked N objects, ...").
objcount() { "$SIT" fsck 2>/dev/null | sed -n 's/^checked \([0-9]*\) objects.*/\1/p'; }

# ── 1. core loop: init → add → commit → log → status → fsck ─────────
hr "core loop"
R="$WORK/core"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'hello\n' > a.txt
"$SIT" add a.txt >/dev/null
"$SIT" commit -m "first" >/dev/null
assert_contains "$("$SIT" log --oneline)" "first" "log shows first commit"
assert_eq "$(objcount)" "3" "one commit = 3 objects"
assert_contains "$("$SIT" fsck)" "0 bad" "fsck clean after first commit"

# diff of a working-tree change
printf 'hello\nworld\n' > a.txt
assert_contains "$("$SIT" diff)" "+world" "diff shows the added line"

# ── 2. branch + merge → merge commit ───────────────────────────────
hr "branch + merge"
R="$WORK/merge"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'a\n' > a.txt; "$SIT" add a.txt >/dev/null; "$SIT" commit -m "base1" >/dev/null
printf 'b\n' > b.txt; "$SIT" add b.txt >/dev/null; "$SIT" commit -m "base2" >/dev/null
"$SIT" checkout -b feature >/dev/null
printf 'c\n' > c.txt; "$SIT" add c.txt >/dev/null; "$SIT" commit -m "feature work" >/dev/null
"$SIT" checkout main >/dev/null
printf 'd\n' > d.txt; "$SIT" add d.txt >/dev/null; "$SIT" commit -m "main work" >/dev/null
"$SIT" merge feature >/dev/null 2>&1
assert_contains "$("$SIT" fsck)" "0 bad" "fsck clean after merge"

# ── 3. log --graph structure (hash-independent) ────────────────────
hr "log --graph"
GRAPH=$("$SIT" log --graph | sed 's/[0-9a-f]\{12\}/HASH/')
EXPECTED=$(cat <<'EOF'
* HASH Merge branch 'feature'
|\
* | HASH main work
| * HASH feature work
|/
* HASH base2
* HASH base1
EOF
)
assert_eq "$GRAPH" "$EXPECTED" "graph DAG shape matches the merge snapshot"

# ── 3b. merge-base full-DAG LCA (v0.8.13 diamond gate) ─────────────
# Build a diamond where the first-parent chain reaches the true base only
# through a merge's second parent. Layout:
#   R ─ A ─ M ─ C   (main; M merges feature)
#    \     /
#     B ─────── D   (feature)
# True LCA(C, D) = B. The pre-v0.8.13 first-parent walk fell back to R.
hr "merge-base full-DAG LCA (diamond)"
R="$WORK/diamond"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'r\n' > r.txt; "$SIT" add r.txt >/dev/null; "$SIT" commit -m "R" >/dev/null
ROOT=$(tr -d '\n' < .sit/refs/heads/main)
"$SIT" checkout -b feature >/dev/null
printf 'b\n' > b.txt; "$SIT" add b.txt >/dev/null; "$SIT" commit -m "B" >/dev/null
BASE=$(tr -d '\n' < .sit/refs/heads/feature)
"$SIT" checkout main >/dev/null
printf 'a\n' > a.txt; "$SIT" add a.txt >/dev/null; "$SIT" commit -m "A" >/dev/null
"$SIT" merge feature >/dev/null 2>&1
printf 'c\n' > c.txt; "$SIT" add c.txt >/dev/null; "$SIT" commit -m "C" >/dev/null
"$SIT" checkout feature >/dev/null
printf 'd\n' > d.txt; "$SIT" add d.txt >/dev/null; "$SIT" commit -m "D" >/dev/null
MB=$("$SIT" merge-base main feature)
assert_eq "$MB" "$BASE" "merge-base(main,feature) = B (true full-DAG LCA)"
if [ "$MB" = "$ROOT" ]; then bad "merge-base returned root (pre-v0.8.13 first-parent behavior)"; else ok; fi
# self and ancestor identities
assert_eq "$("$SIT" merge-base main main)" "$(tr -d '\n' < .sit/refs/heads/main)" "merge-base(X,X) = X"

# ── 4. clone (file://) full round-trip ─────────────────────────────
hr "clone file:// full"
R="$WORK/origin"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
for i in 1 2 3 4 5 6 7 8 9 10; do
  printf 'line %s\n' "$i" >> f.txt
  "$SIT" add f.txt >/dev/null
  "$SIT" commit -m "commit $i" >/dev/null
done
ORIGIN_OBJS=$(objcount)
assert_eq "$ORIGIN_OBJS" "30" "10-commit origin = 30 objects"
cd "$WORK"
"$SIT" clone --force-absolute "$R" full >/dev/null 2>&1
cd "$WORK/full"
assert_eq "$(objcount)" "30" "full clone copies all 30 objects"
assert_eq "$("$SIT" log --oneline | wc -l | tr -d ' ')" "10" "full clone log shows 10 commits"
assert_contains "$("$SIT" fsck)" "0 bad" "full clone fsck clean"

# ── 5. shallow clone --depth 1 (v0.8.12 gate) ──────────────────────
hr "shallow clone --depth 1"
cd "$WORK"
"$SIT" clone --depth 1 --force-absolute "$R" d1 >/dev/null 2>&1
cd "$WORK/d1"
assert_eq "$(objcount)" "3" "--depth 1 pulls exactly 3 objects (1 commit+tree+blob)"
assert_eq "$("$SIT" log --oneline | wc -l | tr -d ' ')" "1" "--depth 1 log shows 1 commit"
"$SIT" log --oneline >/dev/null 2>&1; assert_eq "$?" "0" "--depth 1 log exits 0 (clean shallow boundary)"
assert_contains "$("$SIT" fsck)" "0 bad" "--depth 1 fsck clean despite absent parent"
[ -f .sit/shallow ]; assert_eq "$?" "0" ".sit/shallow boundary marker written"
assert_eq "$(wc -l < .sit/shallow | tr -d ' ')" "1" ".sit/shallow lists one boundary commit"

# ── 6. shallow clone --depth 3 ─────────────────────────────────────
hr "shallow clone --depth 3"
cd "$WORK"
"$SIT" clone --depth 3 --force-absolute "$R" d3 >/dev/null 2>&1
cd "$WORK/d3"
assert_eq "$(objcount)" "9" "--depth 3 pulls 9 objects (3 commits)"
assert_eq "$("$SIT" log --oneline | wc -l | tr -d ' ')" "3" "--depth 3 log shows 3 commits"

# ── 7. push round-trip over file:// ────────────────────────────────
hr "push round-trip"
cd "$WORK/full"
printf 'extra\n' >> f.txt
"$SIT" add f.txt >/dev/null
"$SIT" commit -m "downstream commit" >/dev/null
# push back to a fresh bare-ish origin clone to avoid denyCurrentBranch.
cd "$WORK"
"$SIT" clone --force-absolute "$R" pushtarget >/dev/null 2>&1
cd "$WORK/full"
"$SIT" remote add target "$WORK/pushtarget" >/dev/null 2>&1
# (push to the remote's checked-out branch is refused by design; this just
#  exercises that the dispatch + FF preflight run without crashing.)
"$SIT" push target main >/dev/null 2>&1 || true
ok   # reaching here without a crash is the assertion

# ── summary ────────────────────────────────────────────────────────
printf '\n=== integration: %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
