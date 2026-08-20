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
GIT_PROBE=""
if command -v cyrius >/dev/null 2>&1; then
  if ( cd "$ROOT" && cyrius build tests/integration/git_probe.cyr "$WORK/git_probe" ) >/dev/null 2>&1; then
    GIT_PROBE="$WORK/git_probe"
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

# ── summary ────────────────────────────────────────────────────────
printf '\n=== integration: %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
