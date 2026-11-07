#!/usr/bin/env python3
# readcmd_diff.py — `blame`, `describe` and `merge-base` against git itself (1.13.2).
#
# usage: readcmd_diff.py <sit> <work dir> <seed> <rounds> <sha1|sha256>
#
# Each round builds a random DAG of commits with `git`: edits to a few files,
# branches, merges, tags of both kinds, then a `git gc` half the time. Each command
# then runs in that repository and answers against git's own.
#
#  - merge-base: sit's id must be one of `git merge-base --all`. A criss-cross has
#    several, and which one comes first is a tiebreak, not an answer.
#  - describe: against `git rev-list`, and no worse than `git describe --tags`.
#    The tag sit names must be an ancestor, its count must be the size of
#    `<tag>..<commit>`, and that count must not exceed git's. git's own answer is
#    not the oracle: it sorts candidates on depths it finishes only for the winner,
#    so it can print a farther tag (v8-11 with rel/v6 at 7, seen here), and its
#    ties go by commit date. The id is sit's fixed 12 hex, a prefix of the commit's.
#  - blame: against `git blame --first-parent --porcelain`, since sit walks the
#    first parent. Every line of every file holds a unique token, so the diff
#    algorithm has no ambiguous choice to make, and no file is renamed.
#
# Not part of the product; lives with the tests.
import os, random, shutil, subprocess, sys

sit, work, seed, rounds, fmt = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
rng = random.Random(seed)
fails = 0
checks = 0
token = 0
FILES = ['a.txt', 'dir/b.txt', 'dir/deep/c.txt', 'no-eol.txt']


def git(repo, *a, inp=None, check=True, date=None):
    e = dict(env)
    if date is not None:
        e.update(GIT_AUTHOR_DATE='%d +0000' % date, GIT_COMMITTER_DATE='%d +0000' % date,
                 GIT_AUTHOR_NAME='A', GIT_AUTHOR_EMAIL='a@a', GIT_COMMITTER_NAME='A', GIT_COMMITTER_EMAIL='a@a')
    r = subprocess.run(['git', '-C', repo] + list(a), input=inp, capture_output=True, env=e, check=check)
    return r.stdout.decode().strip()


def run_sit(repo, *a):
    r = subprocess.run([sit] + list(a), cwd=repo, capture_output=True, env=env)
    return r.returncode, r.stdout.decode(), r.stderr.decode()


def fresh():
    global token
    token += 1
    return 'line-%d-%d' % (seed, token)


def edit(repo, f):
    p = os.path.join(repo, f)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    lines = open(p).read().split('\n') if os.path.exists(p) else []
    lines = [l for l in lines if l]
    for _ in range(rng.randrange(1, 4)):
        op = rng.random()
        if op < 0.6 or not lines:
            lines.insert(rng.randrange(len(lines) + 1), fresh())
        elif op < 0.8:
            lines[rng.randrange(len(lines))] = fresh()
        else:
            del lines[rng.randrange(len(lines))]
    text = '\n'.join(lines)
    if f != 'no-eol.txt' and text:
        text += '\n'
    open(p, 'w').write(text)


def report(what, *detail):
    global fails
    fails += 1
    print('round %d (seed %d, %s) %s' % (r, seed, fmt, what))
    for d in detail:
        print('  ' + str(d)[:300])


for r in range(rounds):
    before = fails
    repo = os.path.join(work, 'r%d' % r)
    os.makedirs(repo)
    git(repo, 'init', '-q', '-b', 'main', '--object-format=' + fmt)
    date = 1700000000
    branches = ['main']
    edit(repo, FILES[0])
    git(repo, 'add', '-A')
    git(repo, 'commit', '-qm', 'root', date=date)
    commits = [git(repo, 'rev-parse', 'HEAD')]
    nextid = 0
    for step in range(rng.randrange(4, 18)):
        date += rng.randrange(1, 100)
        b = rng.choice(branches)
        git(repo, 'checkout', '-q', b)
        if commits and rng.random() < 0.2 and len(branches) < 4:
            nextid += 1
            nb = 'b%d' % nextid
            git(repo, 'checkout', '-q', '-b', nb, rng.choice(commits))
            branches.append(nb)
            b = nb
        merged = False
        if len(branches) > 1 and commits and rng.random() < 0.25:
            other = rng.choice([x for x in branches if x != b])
            res = subprocess.run(['git', '-C', repo, 'merge', '-q', '--no-ff', '--no-edit', '-s', 'ort', '-X', 'ours', other],
                                 capture_output=True, env=dict(env, GIT_AUTHOR_NAME='A', GIT_AUTHOR_EMAIL='a@a',
                                 GIT_COMMITTER_NAME='A', GIT_COMMITTER_EMAIL='a@a', GIT_AUTHOR_DATE='%d +0000' % date,
                                 GIT_COMMITTER_DATE='%d +0000' % date))
            merged = res.returncode == 0
            if not merged:
                subprocess.run(['git', '-C', repo, 'merge', '--abort'], capture_output=True, env=env)
        if not merged:
            for f in rng.sample(FILES, rng.randrange(1, 3)):
                edit(repo, f)
            git(repo, 'add', '-A')
            git(repo, 'commit', '-qm', 's%d' % step, '--allow-empty', date=date)
        h = git(repo, 'rev-parse', 'HEAD')
        commits.append(h)
        if rng.random() < 0.25:
            t = 'v%d' % step if rng.random() < 0.8 else 'rel/v%d' % step
            if rng.random() < 0.5:
                git(repo, 'tag', t, h, date=date)
            else:
                git(repo, 'tag', '-a', '-m', 'x', t, h, date=date)
    if rng.random() < 0.5:
        git(repo, 'gc', '-q')

    # merge-base
    for _ in range(4):
        a, b = rng.choice(commits), rng.choice(commits)
        want = git(repo, 'merge-base', '--all', a, b, check=False).split()
        rc, out, err = run_sit(repo, 'merge-base', a, b)
        checks += 1
        if want:
            if rc != 0 or out.strip() not in want:
                report('merge-base', a, b, want, (rc, out, err))
        elif rc == 0:
            report('merge-base found one', a, b, out)

    # describe
    for c in rng.sample(commits, min(4, len(commits))):
        res = subprocess.run(['git', '-C', repo, 'describe', '--tags', c], capture_output=True, env=env)
        rc, out, err = run_sit(repo, 'describe', c)
        checks += 1
        want = res.stdout.decode().strip()
        got = out.strip()
        if res.returncode != 0:
            if rc == 0:
                report('describe found a tag git did not', c, got)
        elif rc != 0:
            report('describe failed', c, want, err)
        else:
            parse = lambda s: s.rsplit('-', 2) if '-g' in s else [s, '0', '']
            wt, wn, _ = parse(want)
            gt, gn, gg = parse(got)
            true_n = git(repo, 'rev-list', '--count', '%s..%s' % (gt, c), check=False)
            anc = subprocess.run(['git', '-C', repo, 'merge-base', '--is-ancestor', gt, c], env=env).returncode
            if anc != 0:
                report('describe names no ancestor', c, want, got)
            elif true_n != gn:
                report('describe count is not rev-list', c, got, true_n)
            elif int(gn) > int(wn):
                report('describe farther than git', c, want, got)
            if gg and not c.startswith(gg[1:]):
                report('describe id', c, got)

    # blame
    for f in FILES:
        if git(repo, 'ls-tree', 'HEAD', '--', f, check=False):
            want = []
            out = git(repo, 'blame', '--first-parent', '--porcelain', '--', f)
            lines = out.split('\n')
            for line in lines:
                parts = line.split(' ')
                if len(parts) >= 3 and len(parts[0]) >= 40 and all(ch in '0123456789abcdef' for ch in parts[0]):
                    want.append(parts[0])
            rc, sout, err = run_sit(repo, 'blame', f)
            got = [l.split(' ')[0] for l in sout.splitlines()]
            gots = [l.split(') ', 1)[1] if ') ' in l else '' for l in sout.splitlines()]
            head = subprocess.run(['git', '-C', repo, 'show', 'HEAD:' + f], capture_output=True, env=env).stdout.decode()
            text = head.split('\n')
            if text and text[-1] == '':
                text.pop()
            checks += 1
            if rc != 0 or len(got) != len(want) or any(not w.startswith(g) for w, g in zip(want, got)):
                report('blame ' + f, want, got, (rc, err))
            elif gots != text:
                report('blame text ' + f, gots, text)
    if fails > 3:
        break
    if fails == before:
        shutil.rmtree(repo)

print('readcmd differential (%s): %d rounds, %d checks, %d mismatches' % (fmt, rounds, checks, fails))
sys.exit(1 if fails else 0)
