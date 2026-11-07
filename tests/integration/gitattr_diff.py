#!/usr/bin/env python3
# gitattr_diff.py — `.gitattributes` against git itself (1.13.2).
#
# usage: gitattr_diff.py <sit> <work dir> <seed> <rounds>
#
# Each round builds a `.git/` repository whose blobs are written with
# `--no-filters`, so what is stored is chosen here and not by the attributes.
# The working copies are then written directly, and the index holds no stat data,
# so git has to clean and compare every file. git's `status --porcelain` is the
# expected answer; `sit status` has to name the same modified files.
#
# Left out on purpose: a working copy byte-identical to its blob, which sit calls
# clean without asking (git_attr.cyr; git's stat cache does too, after a checkout),
# and the conversions sit does not run, which it must report as not compared.
# Not part of the product; lives with the tests.
import os, random, shutil, subprocess, sys

sit, work, seed, rounds = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
           GIT_AUTHOR_NAME='x', GIT_AUTHOR_EMAIL='x@x', GIT_COMMITTER_NAME='x', GIT_COMMITTER_EMAIL='x@x')

PATHS = ['run.bat', 'a.txt', 'b.c', 'sub/x.bat', 'sub/y.txt', 'sub/deep/z.txt', 'sub/deep/w.c',
         'other/x.bat', 'Makefile', 'has space.txt', '!bang.txt', '#hash.txt', 'file[1].txt']

PATTERNS = ['*', '*.bat', '*.txt', '*.c', 'run.bat', 'a.txt', '/a.txt', '/run.bat', 'sub/*.bat',
            'sub/**', '**/deep/*', 'sub/deep/*.c', 'sub/', 'x.bat', '/x.bat', '*.[ch]', '[ab].*',
            '?.txt', '??n.bat', 'Makefile', '"has space.txt"', 'has[[:space:]]space.txt',
            '"!bang.txt"', '\\!bang.txt', '\\#hash.txt', 'file\\[1\\].txt', 'file[[]1].txt',
            '"sub/y.txt"', '**', '**/z.txt', 'other/**/x.bat', '[[:alpha:]].txt', '[^a].txt',
            '!*.bat', '*.BAT', 'sub', 'deep/z.txt']

STATES = ['text', '-text', '!text', 'text=auto', 'text=input', 'text=bogus', 'crlf', '-crlf', 'crlf=input',
          'eol=crlf', 'eol=lf', '!eol', 'text eol=crlf', 'text eol=lf', 'text=auto eol=crlf',
          'text=auto eol=lf', 'binary', '-binary', 'mine', '-mine', 'unrelated', 'text -text', '-text text',
          'bad!name', 'eol=bogus', '-text eol=crlf', 'text=auto -text']

MACROS = ['[attr]mine text eol=crlf', '[attr]mine -text', '[attr]mine binary',
          '[attr]mine text=auto', '[attr]yours mine', '[attr]mine yours']

CONTENT = [b'one\ntwo\nthree\n', b'one\r\ntwo\r\nthree\r\n', b'one\r\ntwo\nthree\r\n', b'one\rtwo\nthree\n',
           b'one\r\ntwo\r\nthree', b'one\ntwo\nthree', b'\x00one\r\ntwo\r\n', b'', b'\r\n', b'\r',
           b'caf\xc3\xa9\r\nlatte\r\n', b'\x01\x02\x03\r\n\x04\x05\r\n',
           b'x' * 200 + b'\x01\r\n']

# A blob and a working copy that differ only in their line endings: the case the
# whole conversion is for, which unrelated content would hit by chance alone.
EOL_PAIRS = [(b'one\ntwo\nthree\n', b'one\r\ntwo\r\nthree\r\n'), (b'one\ntwo\n', b'one\r\ntwo\n'),
             (b'one\r\ntwo\r\n', b'one\ntwo\n'), (b'one\ntwo', b'one\r\ntwo'),
             (b'one\ntwo\n', b'one\r\ntwo\r'), (b'caf\xc3\xa9\n', b'caf\xc3\xa9\r\n'),
             (b'one\r\ntwo\n', b'one\r\ntwo\r\n'), (b'\x00one\n', b'\x00one\r\n'),
             (b'a\rb\n', b'a\rb\r\n'), (b'\x01\x02\x03\n', b'\x01\x02\x03\r\n')]

rng = random.Random(seed)
fails = 0
checked = 0
cleaned = 0


def git(repo, *a, inp=None, check=True):
    return subprocess.run(['git', '-C', repo] + list(a), input=inp, capture_output=True, env=env, check=check).stdout


def rules(with_macros):
    out = []
    if with_macros and rng.random() < 0.4:
        out.append(rng.choice(MACROS))
    for _ in range(rng.randrange(1, 6)):
        out.append(rng.choice(PATTERNS) + ' ' + rng.choice(STATES))
    if rng.random() < 0.2:
        out.insert(0, '# a comment')
    if rng.random() < 0.2:
        out.append('   ')
    return '\n'.join(out) + '\n'


for r in range(rounds):
    repo = os.path.join(work, 'r%d' % r)
    os.makedirs(repo)
    git(repo, 'init', '-q', '-b', 'main')
    entries = {}
    for p in PATHS:
        if rng.random() < 0.7:
            if rng.random() < 0.6:
                entries[p] = rng.choice(EOL_PAIRS)
            else:
                entries[p] = (rng.choice(CONTENT), rng.choice(CONTENT))
    if not entries:
        entries['a.txt'] = (CONTENT[0], CONTENT[1])
    # Attribute files first, stored like any other file, so a fresh tree holds them.
    attr_files = {}
    if rng.random() < 0.9:
        attr_files['.gitattributes'] = rules(True)
    if rng.random() < 0.4:
        attr_files['sub/.gitattributes'] = rules(False)
    if rng.random() < 0.2:
        attr_files['sub/deep/.gitattributes'] = rules(False)
    for p, text in attr_files.items():
        os.makedirs(os.path.dirname(os.path.join(repo, p)) or repo, exist_ok=True)
        open(os.path.join(repo, p), 'w').write(text)
        blob = git(repo, 'hash-object', '-w', '--no-filters', '--stdin', inp=text.encode()).strip().decode()
        git(repo, 'update-index', '--add', '--cacheinfo', '100644,%s,%s' % (blob, p))
    for p, (stored, working) in entries.items():
        full = os.path.join(repo, p)
        os.makedirs(os.path.dirname(full) or repo, exist_ok=True)
        blob = git(repo, 'hash-object', '-w', '--no-filters', '--stdin', inp=stored).strip().decode()
        git(repo, 'update-index', '--add', '--cacheinfo', '100644,%s,%s' % (blob, p))
    git(repo, 'commit', '-qm', 'base')
    for p, (stored, working) in entries.items():
        open(os.path.join(repo, p), 'wb').write(working)
    if rng.random() < 0.25:
        os.makedirs(os.path.join(repo, '.git', 'info'), exist_ok=True)
        open(os.path.join(repo, '.git', 'info', 'attributes'), 'w').write(rules(True))
    # No stat data: git compares every file, cleaned.
    git(repo, 'read-tree', 'HEAD')
    porcelain = git(repo, '-c', 'core.quotepath=false', 'status', '--porcelain', '-z')
    want = set()
    for item in porcelain.split(b'\0'):
        if item[:2] == b' M':
            want.add(item[3:].decode())
    # A file whose bytes match its blob is sit's clean, whatever git's cleaning does.
    same = {p for p, (stored, working) in entries.items() if stored == working}
    want -= same
    out = subprocess.run([sit, 'status'], cwd=repo, capture_output=True, env=env)
    got = set()
    for line in out.stdout.decode().splitlines():
        if line.startswith('  modified:  '):
            got.add(line[len('  modified:  '):])
    checked += len(entries)
    # Files whose bytes differ and which git still calls clean: what this test is for.
    cleaned += len([p for p, (stored, working) in entries.items() if stored != working and p not in want])
    if want != got or out.returncode != 0:
        fails += 1
        print('round %d (seed %d): git %s, sit %s, rc %d' % (r, seed, sorted(want), sorted(got), out.returncode))
        for p, t in attr_files.items():
            print('  %s: %r' % (p, t))
        info = os.path.join(repo, '.git', 'info', 'attributes')
        if os.path.exists(info):
            print('  info: %r' % open(info).read())
        for p in sorted(want ^ got):
            print('  %s: stored %r working %r' % (p, entries[p][0], entries[p][1]))
            print('  ' + git(repo, 'check-attr', '-a', '--', p).decode().strip().replace('\n', ' | '))
        if fails > 3:
            break
    else:
        shutil.rmtree(repo)

print('gitattr differential: %d rounds, %d files, %d differed only after cleaning, %d mismatches'
      % (rounds, checked, cleaned, fails))
sys.exit(1 if fails else 0)
