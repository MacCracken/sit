#!/bin/sh
# End-to-end sit walkthrough: init → add → branch → signed-commit → merge → verify.
# See README.md in this directory for context.
set -eu

SIT="${SIT:-$PWD/build/sit}"
[ -x "$SIT" ] || { echo "sit binary not found at $SIT — build with 'cyrius build src/main.cyr build/sit' or set SIT=/path/to/sit"; exit 1; }

# Isolate HOME so the example can't clobber a real ~/.sit/
EXAMPLE_HOME=$(mktemp -d -t sit-example-home.XXXXXX)
DEMO=$(mktemp -d -t sit-example-repo.XXXXXX)
trap 'rm -rf "$EXAMPLE_HOME" "$DEMO"' EXIT

export HOME="$EXAMPLE_HOME"
export SIT_AUTHOR_NAME="Example Author"
export SIT_AUTHOR_EMAIL="example@sit.local"

hr() { printf '\n=== %s ===\n' "$*"; }

hr "generate a signing key (~/.sit/signing_key)"
"$SIT" key generate

hr "init a fresh repo"
cd "$DEMO"
"$SIT" init

hr "first commit on main (signed)"
cat > readme.md <<'EOF'
# demo repo
initial readme
EOF
cat > fruits.txt <<'EOF'
alpha
bravo
charlie
EOF
"$SIT" add readme.md
"$SIT" add fruits.txt
"$SIT" commit -S -m "initial commit"

hr "checkout a feature branch"
"$SIT" checkout -b extra-fruit

hr "edit + commit on the feature branch"
cat > fruits.txt <<'EOF'
alpha
bravo
charlie
delta
EOF
"$SIT" add fruits.txt
"$SIT" commit -S -m "add delta"

hr "switch back to main, make a divergent edit"
"$SIT" checkout main
cat > readme.md <<'EOF'
# demo repo
initial readme

with a second paragraph
EOF
"$SIT" add readme.md
"$SIT" commit -S -m "expand readme"

hr "status (clean, one commit ahead of feature branch)"
"$SIT" status

hr "merge extra-fruit into main, signed (3-way, non-overlapping changes)"
"$SIT" merge -S extra-fruit

hr "final log"
"$SIT" log

hr "show --stat for the merge commit"
"$SIT" show --stat

hr "verify-commit on HEAD (the signed merge commit)"
"$SIT" verify-commit

hr "fsck — confirm every stored object re-hashes to its key"
"$SIT" fsck

hr "done"
echo "sit binary: $SIT"
echo "temp repo:  $DEMO (cleaned up on exit)"
echo "temp HOME:  $EXAMPLE_HOME (cleaned up on exit)"
