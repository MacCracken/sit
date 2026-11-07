#!/usr/bin/env python3
# owl 1.5.3 audit (2026-10-31), INFO-004 — a small git repository whose HEAD
# tree is cheap to store and expensive for sit_diff_path to flatten.
# Written by the audit's VCS reviewer; see ../2026-10-31-sit-diff-path-flattens-whole-head-tree.md
# usage: treebomb.py <repo_dir> <depth> <fanout_N> <leaf_M> <namelen>
# Builds a git repo whose HEAD tree = { README (blob), zzz.../ -> chain(depth) -> fan(N x leaf) }
# leaf = M blob entries (all the same empty blob). Worktree has README only (clean).
import os, sys, subprocess
repo, depth, N, M, L = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
           GIT_AUTHOR_NAME='x', GIT_AUTHOR_EMAIL='x@x', GIT_COMMITTER_NAME='x', GIT_COMMITTER_EMAIL='x@x')
def git(*a, inp=None):
    return subprocess.run(['git', '-C', repo] + list(a), input=inp, capture_output=True, env=env, check=True).stdout
os.makedirs(repo)
git('init', '-q', '-b', 'main')
def nm(i, prefix='n'):
    s = f'{prefix}{i:08d}'
    return (s + 'x' * L)[:L]
empty = git('hash-object', '-w', '--stdin', inp=b'').strip().decode()
readme = b'hello\nworld\n'
rb = git('hash-object', '-w', '--stdin', inp=readme).strip().decode()
def mktree(lines):
    return git('mktree', inp=('\n'.join(lines) + '\n').encode()).strip().decode()
leaf = mktree([f'100644 blob {empty}\t{nm(i)}' for i in range(M)])
fan = mktree([f'040000 tree {leaf}\t{nm(i)}' for i in range(N)])
t = fan
for k in range(depth):
    t = mktree([f'040000 tree {t}\t{nm(k, "c")}'])
root = mktree([f'100644 blob {rb}\tREADME', f'040000 tree {t}\t{nm(0, "z")}'])
c = git('commit-tree', root, '-m', 'bomb').strip().decode()
git('update-ref', 'refs/heads/main', c)
open(os.path.join(repo, 'README'), 'wb').write(readme)
print('nodes~', N + N * M, 'depth', depth, 'namelen', L)
