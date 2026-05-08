# cc5_aarch64 binary not rebuilt with v5.8.46 token-cap raise — aarch64 cross-build still capped at 262144

**Discovered:** 2026-05-04 during sit v0.7.2 release run.
**Severity:** Medium — aarch64 cross-build fails; x86_64 still ships. sit's CLAUDE.md flags aarch64 as "best-effort in CI" so this isn't a hard regression, but every aarch64 user runs unsupported until the cross compiler picks up the cap raise.
**Affects:** cyrius 5.8.46 through **5.8.52** verified. The token-array cap was raised 262144 → 1048576 in 5.8.46 and the cc5 (x86_64) binary grew accordingly (~700K → 741K), but `cc5_aarch64` stayed byte-identical at **438896 bytes** across 5.8.46, 5.8.48, 5.8.51, 5.8.52. The aarch64 cross compiler binary wasn't rebuilt with the new cap.

## Summary

```sh
cyrius build --aarch64 src/main.cyr build/sit-aarch64
# error: token limit exceeded (262144)
# compile src/main.cyr -> build/sit-aarch64 [aarch64] FAIL
```

The error string is the **pre-5.8.46 format** (`token limit exceeded (262144)`, no `needed M, cap is N` diagnostic), confirming the cross compiler is running pre-cap-raise codegen.

x86_64 against the same source builds clean under cc5 5.8.52: `cyrius build src/main.cyr build/sit` → 1.28 MB binary, 127/127 tests pass.

## Reproduction

```sh
cd /home/macro/Repos/sit            # at v0.7.2 + cyrius 5.8.51 pin
cyrius deps                          # 5/5 resolve clean
cyrius build src/main.cyr build/sit              # x86_64 OK
cyrius build --aarch64 src/main.cyr build/sit-aarch64
# → token limit exceeded (262144) — old format, old cap
```

Verifying the cross compiler binary is unchanged across the cap-raise window:

```sh
$ ls -la ~/.cyrius/versions/{5.8.46,5.8.48,5.8.51,5.8.52}/bin/cc5_aarch64
-rwxr-xr-x  438896 May  3 23:31  .../5.8.46/bin/cc5_aarch64
-rwxr-xr-x  438896 May  4 01:57  .../5.8.48/bin/cc5_aarch64
-rwxr-xr-x  438896 May  4 13:22  .../5.8.51/bin/cc5_aarch64
-rwxr-xr-x  438896 May  4 14:32  .../5.8.52/bin/cc5_aarch64

$ ls -la ~/.cyrius/bin/cc5  ~/.cyrius/bin/cc5_aarch64
-rwxr-xr-x  741040  cc5
-rwxr-xr-x  438896  cc5_aarch64
```

cc5 grew ~40K from the cap raise (token tables relocated to a new high block); cc5_aarch64 didn't.

## Root cause

Best guess from the byte-identical sizes: the cyrius release build pipeline doesn't rebuild `cc5_aarch64` from the updated source when the token-cap constants change in `src/frontend/lex.cyr` / memory layout in `src/main_aarch64.cyr` (or wherever the aarch64 peer of the cap lives). Could be:

1. The aarch64 cross compiler is built from a separate source path that wasn't touched by the v5.8.46 cap-raise patch.
2. The build pipeline caches `cc5_aarch64` artifacts and the cache key didn't bust.
3. The cap raise touched only `src/main.cyr` / `src/main_win.cyr` and missed `src/main_aarch64.cyr` / `src/main_aarch64_macho.cyr` / `src/main_aarch64_native.cyr`.

(3) is most likely — the original 2026-04-25 fixup-table-cap proposal listed `src/backend/aarch64/emit.cyr` as one of the cap-check sites; if those were updated for the original 32K → 262K bump but missed for the 262K → 1M bump, that matches the symptom.

## Proposed fix

1. **grep `262144` across `src/main_*aarch64*.cyr` and `src/backend/aarch64/emit.cyr`** in cyrius. Each remaining literal at a token-array cap-check site needs to move to `1048576` (or to the centralized `CYR_FIXUP_TBL_MAX` / `CYR_TOKEN_TBL_MAX` constant if one exists).
2. **Re-stat the aarch64 memory layout** — the v5.8.46 token-table relocation (to `0x368C000 / 0x3E8C000 / 0x468C000` per the archived issue's resolution notes) was applied to the x86_64 layout in `main.cyr`; the aarch64 peer needs the same shift, plus the `brk` extension to `S + 0x4E8C000`.
3. **Rebuild cc5_aarch64** as part of the next cyrius release. The byte-size delta should mirror cc5's (~40K growth) once the constants and layout match.

## Consumer-side workaround (now in place for sit)

`.github/workflows/release.yml` makes the aarch64 cross-build truly best-effort — failure no longer fails the release:

```yaml
if cyrius build --aarch64 src/main.cyr build/sit-aarch64; then
    echo "sit aarch64: $(wc -c < build/sit-aarch64) bytes"
else
    echo "::warning::aarch64 cross-build failed — see this issue; shipping x86_64 only"
    rm -f build/sit-aarch64
fi
```

x86_64 release artifacts ship unchanged; aarch64 is absent from the GitHub release until cyrius ships an updated cc5_aarch64.

## Cross-reference

- [`archived/2026-04-25-cyrius-fixup-table-cap.md`](archived/2026-04-25-cyrius-fixup-table-cap.md) — the original cap-raise issue. v5.8.46 resolution narrative names the x86_64 layout shift only; the aarch64 peer was not in scope of that ship.
- cyrius CHANGELOG `[5.8.46]` — token-cap raise + new `needed M, cap is N` diagnostic. The diagnostic message format change is the second smoking gun (cc5_aarch64 still emits the old format).
- sit release workflow: [`.github/workflows/release.yml`](../../.github/workflows/release.yml) — best-effort aarch64 swallowing now in place.
