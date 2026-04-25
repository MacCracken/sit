#!/bin/sh
# benchmark.sh — head-to-head git vs sit wall-clock benchmarks.
#
# Produces a markdown table on stdout suitable for pasting into
# docs/development/benchmarks-git-v-sit.md. Each operation runs in a
# freshly-created scratch directory; no warm-cache advantages either way.
#
# Usage: SIT=/path/to/build/sit ./scripts/benchmark.sh
#
# RUNS can be overridden (default 10 for heavy ops, 20 for light).

set -eu

SIT="${SIT:-$(pwd)/build/sit}"
GIT="${GIT:-git}"
RUNS_LIGHT="${RUNS_LIGHT:-20}"
RUNS_HEAVY="${RUNS_HEAVY:-10}"

[ -x "$SIT" ] || { echo "error: sit binary not found at $SIT"; exit 1; }

# ── timing helpers ────────────────────────────────────────────────

now_ns() { date +%s%N; }

stats() {
    awk '
        { a[NR]=$1 }
        END {
            n = NR
            asort(a)
            med = a[int((n+1)/2)]
            printf "%d %d\n", a[1], med
        }
    '
}

fmt_ms() {
    awk -v ns="$1" 'BEGIN { printf "%.2f", ns/1000000 }'
}

# ── scratch / fixture helpers ─────────────────────────────────────

export HOME="$(mktemp -d)"
export GIT_AUTHOR_NAME="Bench"
export GIT_AUTHOR_EMAIL="b@e"
export GIT_COMMITTER_NAME="Bench"
export GIT_COMMITTER_EMAIL="b@e"
export SIT_AUTHOR_NAME="Bench"
export SIT_AUTHOR_EMAIL="b@e"

$GIT config --global user.name  "Bench"
$GIT config --global user.email "b@e"
$GIT config --global init.defaultBranch main

fixture_history_git() {
    dir=$(mktemp -d)
    (
        cd "$dir" && $GIT init -q
        i=0
        while [ $i -lt 100 ]; do
            echo "file $i content" > "f$i.txt"
            $GIT add "f$i.txt"
            $GIT commit -q -m "c$i"
            i=$((i+1))
        done
    ) > /dev/null 2>&1
    echo "$dir"
}
fixture_history_sit() {
    dir=$(mktemp -d)
    (
        cd "$dir" && $SIT init > /dev/null
        i=0
        while [ $i -lt 100 ]; do
            echo "file $i content" > "f$i.txt"
            $SIT add "f$i.txt" > /dev/null
            $SIT commit -m "c$i" > /dev/null
            i=$((i+1))
        done
    )
    echo "$dir"
}

make_blob() {
    size="$1"; path="$2"
    head -c "$size" /dev/urandom > "$path"
}

bench_init() {
    name="init"
    runs=$RUNS_LIGHT
    git_times=""; sit_times=""
    i=0
    while [ $i -lt $runs ]; do
        d=$(mktemp -d)
        t0=$(now_ns); (cd "$d" && $GIT init -q) ; t1=$(now_ns)
        git_times="$git_times
$((t1-t0))"
        rm -rf "$d"
        d=$(mktemp -d)
        t0=$(now_ns); (cd "$d" && $SIT init > /dev/null) ; t1=$(now_ns)
        sit_times="$sit_times
$((t1-t0))"
        rm -rf "$d"
        i=$((i+1))
    done
    g=$(printf "%s" "$git_times" | sed '/^$/d' | stats)
    s=$(printf "%s" "$sit_times" | sed '/^$/d' | stats)
    echo "$name $g $s"
}

bench_add() {
    size="$1"; label="$2"
    name="add-$label"
    runs=$RUNS_HEAVY
    git_times=""; sit_times=""
    i=0
    while [ $i -lt $runs ]; do
        d=$(mktemp -d); (cd "$d" && $GIT init -q)
        make_blob "$size" "$d/big.bin"
        t0=$(now_ns); (cd "$d" && $GIT add big.bin) ; t1=$(now_ns)
        git_times="$git_times
$((t1-t0))"
        rm -rf "$d"
        d=$(mktemp -d); (cd "$d" && $SIT init > /dev/null)
        make_blob "$size" "$d/big.bin"
        t0=$(now_ns); (cd "$d" && $SIT add big.bin > /dev/null) ; t1=$(now_ns)
        sit_times="$sit_times
$((t1-t0))"
        rm -rf "$d"
        i=$((i+1))
    done
    g=$(printf "%s" "$git_times" | sed '/^$/d' | stats)
    s=$(printf "%s" "$sit_times" | sed '/^$/d' | stats)
    echo "$name $g $s"
}

bench_commit() {
    name="commit"
    runs=$RUNS_LIGHT
    git_times=""; sit_times=""
    i=0
    while [ $i -lt $runs ]; do
        d=$(mktemp -d); (cd "$d" && $GIT init -q && echo x > f && $GIT add f)
        t0=$(now_ns); (cd "$d" && $GIT commit -q -m c) ; t1=$(now_ns)
        git_times="$git_times
$((t1-t0))"
        rm -rf "$d"
        d=$(mktemp -d); (cd "$d" && $SIT init > /dev/null && echo x > f && $SIT add f > /dev/null)
        t0=$(now_ns); (cd "$d" && $SIT commit -m c > /dev/null) ; t1=$(now_ns)
        sit_times="$sit_times
$((t1-t0))"
        rm -rf "$d"
        i=$((i+1))
    done
    g=$(printf "%s" "$git_times" | sed '/^$/d' | stats)
    s=$(printf "%s" "$sit_times" | sed '/^$/d' | stats)
    echo "$name $g $s"
}

bench_log() {
    name="log-100commits"
    runs=$RUNS_LIGHT
    gd=$(fixture_history_git)
    sd=$(fixture_history_sit)
    git_times=""; sit_times=""
    i=0
    while [ $i -lt $runs ]; do
        t0=$(now_ns); (cd "$gd" && $GIT log > /dev/null) ; t1=$(now_ns)
        git_times="$git_times
$((t1-t0))"
        t0=$(now_ns); (cd "$sd" && $SIT log > /dev/null) ; t1=$(now_ns)
        sit_times="$sit_times
$((t1-t0))"
        i=$((i+1))
    done
    g=$(printf "%s" "$git_times" | sed '/^$/d' | stats)
    s=$(printf "%s" "$sit_times" | sed '/^$/d' | stats)
    rm -rf "$gd" "$sd"
    echo "$name $g $s"
}

bench_status() {
    name="status-100files"
    runs=$RUNS_LIGHT
    gd=$(fixture_history_git)
    sd=$(fixture_history_sit)
    git_times=""; sit_times=""
    i=0
    while [ $i -lt $runs ]; do
        t0=$(now_ns); (cd "$gd" && $GIT status > /dev/null) ; t1=$(now_ns)
        git_times="$git_times
$((t1-t0))"
        t0=$(now_ns); (cd "$sd" && $SIT status > /dev/null) ; t1=$(now_ns)
        sit_times="$sit_times
$((t1-t0))"
        i=$((i+1))
    done
    g=$(printf "%s" "$git_times" | sed '/^$/d' | stats)
    s=$(printf "%s" "$sit_times" | sed '/^$/d' | stats)
    rm -rf "$gd" "$sd"
    echo "$name $g $s"
}

bench_diff() {
    name="diff-edit"
    runs=$RUNS_LIGHT
    git_times=""; sit_times=""
    i=0
    while [ $i -lt $runs ]; do
        d=$(mktemp -d); (cd "$d" && $GIT init -q && yes hello | head -500 > a.txt && $GIT add a.txt && $GIT commit -q -m r) > /dev/null 2>&1
        (cd "$d" && sed -i '250s/hello/changed/' a.txt)
        t0=$(now_ns); (cd "$d" && $GIT diff > /dev/null) ; t1=$(now_ns)
        git_times="$git_times
$((t1-t0))"
        rm -rf "$d"
        d=$(mktemp -d); (cd "$d" && $SIT init > /dev/null && yes hello | head -500 > a.txt && $SIT add a.txt > /dev/null && $SIT commit -m r > /dev/null)
        (cd "$d" && sed -i '250s/hello/changed/' a.txt)
        t0=$(now_ns); (cd "$d" && $SIT diff > /dev/null) ; t1=$(now_ns)
        sit_times="$sit_times
$((t1-t0))"
        rm -rf "$d"
        i=$((i+1))
    done
    g=$(printf "%s" "$git_times" | sed '/^$/d' | stats)
    s=$(printf "%s" "$sit_times" | sed '/^$/d' | stats)
    echo "$name $g $s"
}

bench_clone() {
    name="clone-100commits"
    runs=$RUNS_HEAVY
    gsrc=$(fixture_history_git)
    ssrc=$(fixture_history_sit)
    git_times=""; sit_times=""
    i=0
    while [ $i -lt $runs ]; do
        dst=$(mktemp -d)/repo
        t0=$(now_ns); $GIT clone -q "$gsrc" "$dst" 2>/dev/null ; t1=$(now_ns)
        git_times="$git_times
$((t1-t0))"
        rm -rf "$(dirname "$dst")"
        dst=$(mktemp -d)/repo
        t0=$(now_ns); $SIT clone "$ssrc" "$dst" > /dev/null 2>&1 ; t1=$(now_ns)
        sit_times="$sit_times
$((t1-t0))"
        rm -rf "$(dirname "$dst")"
        i=$((i+1))
    done
    g=$(printf "%s" "$git_times" | sed '/^$/d' | stats)
    s=$(printf "%s" "$sit_times" | sed '/^$/d' | stats)
    rm -rf "$gsrc" "$ssrc"
    echo "$name $g $s"
}

bench_fetch() {
    name="fetch-1commit"
    runs=$RUNS_HEAVY
    git_times=""; sit_times=""
    i=0
    while [ $i -lt $runs ]; do
        up=$(mktemp -d); $GIT init -q --bare "$up" > /dev/null
        seed=$(mktemp -d); (cd "$seed" && $GIT init -q && echo a > f && $GIT add f && $GIT commit -q -m r && $GIT remote add o "$up" && $GIT push -q o main) > /dev/null 2>&1
        local_c=$(mktemp -d)/r; $GIT clone -q "$up" "$local_c" 2>/dev/null
        (cd "$seed" && echo b > g && $GIT add g && $GIT commit -q -m next && $GIT push -q o main) > /dev/null 2>&1
        t0=$(now_ns); (cd "$local_c" && $GIT fetch -q origin main) > /dev/null 2>&1 ; t1=$(now_ns)
        git_times="$git_times
$((t1-t0))"
        rm -rf "$up" "$seed" "$(dirname "$local_c")"

        up=$(mktemp -d); (cd "$up" && $SIT init > /dev/null && echo a > f && $SIT add f > /dev/null && $SIT commit -m r > /dev/null)
        local_c=$(mktemp -d)/r; $SIT clone "$up" "$local_c" > /dev/null 2>&1
        (cd "$up" && echo b > g && $SIT add g > /dev/null && $SIT commit -m next > /dev/null)
        t0=$(now_ns); (cd "$local_c" && $SIT fetch origin main > /dev/null) ; t1=$(now_ns)
        sit_times="$sit_times
$((t1-t0))"
        rm -rf "$up" "$(dirname "$local_c")"
        i=$((i+1))
    done
    g=$(printf "%s" "$git_times" | sed '/^$/d' | stats)
    s=$(printf "%s" "$sit_times" | sed '/^$/d' | stats)
    echo "$name $g $s"
}

emit_row() {
    row="$1"
    if [ -z "$row" ]; then
        echo "| (bench failed to produce a result) | — | — | — |"
        return
    fi
    op=$(echo "$row" | awk '{print $1}')
    gmin=$(echo "$row" | awk '{print $2}')
    gmed=$(echo "$row" | awk '{print $3}')
    smin=$(echo "$row" | awk '{print $4}')
    smed=$(echo "$row" | awk '{print $5}')
    gmin_ms=$(fmt_ms "$gmin")
    gmed_ms=$(fmt_ms "$gmed")
    smin_ms=$(fmt_ms "$smin")
    smed_ms=$(fmt_ms "$smed")
    ratio=$(awk -v s="$smin" -v g="$gmin" 'BEGIN{ if (g > 0) printf "%.2fx", s/g; else printf "—" }')
    echo "| \`$op\` | $gmin_ms / $gmed_ms ms | $smin_ms / $smed_ms ms | $ratio |"
}

echo "# Benchmark results"
echo ""
echo "| operation | git (min / med) | sit (min / med) | sit/git ratio (min) |"
echo "|---|---:|---:|---:|"

emit_row "$(bench_init)"
emit_row "$(bench_add 1024 1KB)"
emit_row "$(bench_add 65536 64KB)"
emit_row "$(bench_add 1048576 1MB)"
emit_row "$(bench_commit)"
emit_row "$(bench_log)"
emit_row "$(bench_status)"
emit_row "$(bench_diff)"
emit_row "$(bench_clone)"
emit_row "$(bench_fetch)"

echo ""
echo "_Generated by \`scripts/benchmark.sh\` at $(date -u +%Y-%m-%dT%H:%M:%SZ)._"
echo "_Host: $(uname -srm); git $($GIT --version | awk '{print $3}'); sit from $SIT._"
