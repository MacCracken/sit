# sit — Upstream Issue Writeups

Findings surfaced during sit work that belong **upstream** (cyrius,
sankoch, sigil, patra, sakshi, sandhi) get written up here. The user
carries them across to the target repo — do not edit upstream repos
directly.

## Filename convention

`YYYY-MM-DD-{dep}-{short-slug}.md`, kebab-case.

Examples:
- `2026-04-24-cyrius-stdlib-alloc-grow-undersize.md`
- `2026-05-11-patra-wal-recovery-race.md`

Date = discovery date. Stable — keep the date even when the issue is
later resolved / archived.

## Body template

Mirror of the cyrius issues template:

```markdown
# {title}

**Discovered:** YYYY-MM-DD during {context}
**Severity:** Low / Medium / High / Critical
**Affects:** {dep} {version range}

## Summary
## Reproduction
## Root cause (if known)
## Proposed fix
## Consumer-side workaround (if any)
```

## Severity

- **Critical** — silent data corruption, security, bootstrap, SIGSEGV
  on first-party usage.
- **High** — hard failure on a shipping consumer with no workaround.
- **Medium** — hard failure with a workaround, or silent perf > 2×.
- **Low** — misleading error messages, doc drift, ergonomic
  papercuts.

## Lifecycle

When the upstream fix lands and sit picks it up:
- Add `— RESOLVED` suffix to the top heading.
- Drop a pointer to the fix version + sit CHANGELOG entry that closed
  the consumer workaround.
- Move to `archived/`. Filename stays stable.
