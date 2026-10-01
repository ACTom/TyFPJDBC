# Mono-Repo Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish TyFPJDBC runtimes from the main repo: tag or dispatch builds 5 JREs, updates one manifest, attaches zips to the same GitHub Release, and lets mautool fetch them back verified.

**Architecture:** Merge Runtimes content into the main repo (scripts + manifest, zips never in git); one `runtime-release.yml` (dispatch + tag triggers, native per-platform jlink matrix, manifest commit-back, Release publish); mautool gains `--fetch-runtime` against Release assets. No new secrets beyond `GITHUB_TOKEN`.

**Tech Stack:** GitHub Actions (windows/ubuntu/macos runners, pwsh everywhere), Microsoft Build of OpenJDK 25 (via actions/setup-java), javac, PowerShell 7 zip script (reused unchanged), FreePascal mautool, H2 loopback for smoke.

**Spec:** `docs/superpowers/specs/2026-10-01-tyfpjdbc-release-design.md` — executors read both; on conflict the spec wins.

## Global Constraints

- JRE module set (exact, all platforms): `java.base,java.sql,java.naming,java.logging,java.management,java.xml,java.security.sasl,jdk.unsupported,java.transaction.xa`.
- jlink flags (exact): `--disable-plugin generate-jli-classes --vm server --strip-debug --no-man-pages --no-header-files --compress=zip-9 --exclude-resources "**/classes*.jsa"`.
- Zip determinism via existing `build-runtime-zip.ps1` (entries sorted, timestamp fixed `2026-01-01T00:00:00Z`, Optimal); bytes may differ across runner images over time — manifest always records fresh values, never asserts equality with old ones.
- Budgets enforced everywhere: unpacked ≤ 80MB (83886080), zip ≤ 50MB (52428800).
- Tag format: `runtime/jre<jdkVersion>-bridge<bridgeVersion>`, e.g. `runtime/jre25.0.4.1-bridge0.9.0`; asset names `jre-25-tyfpjdbc-<platform>.zip` (platforms: win64, linux-x64, linux-arm64, macos-x64, macos-arm64).
- Bridge deps pinned: HikariCP 5.1.0 + slf4j-api 2.0.9 from Maven Central (same versions as `java/bridge/build.gradle`).
- `Bridge.VERSION` stays `0.9.0`; version handshake behavior unchanged.
- `.o`/`.ppu` only to `test-results/work/units`; `zips/` never in git (`.gitignore`).
- No secret beyond auto `GITHUB_TOKEN`; no proprietary inputs anywhere.

## Review Focus

- Tag says `bridge0.9.0` but `Bridge.VERSION` differs → workflow must fail before building anything. Pinned by Task 2 (fail-fast step plus a recorded negative simulation: mismatched fake tag → fail; every real run re-executes it).
- Manifest回填 writes malformed JSON (reordered keys, wrong indent, broken types) → consumer drift. Pinned by Task 2 (update-manifest fixture: round-trip with no changes → `git diff` empty; plus CI gate below).
- Zip layout wrong (jvm binary missing, bridge jars missing) → broken runtime shipped. Pinned by Task 2 (per-platform layout/budget/sha asserts in the workflow + local win64 dry run reproducing the same checks).
- mautool fetches a 404 HTML page saved as zip → must MISMATCH-delete, never cache poison. Pinned by Task 3 Step 2 (pure URL-builder test) reusing the already-tested `FetchJar` MISMATCH-delete path (existing `driver-reject` coverage).
- Manifest-commit push retriggers the workflow forever → infinite release loop. Pinned by Task 2 (review gate: triggers are dispatch + `runtime/*` tags only; manifest commits land on master untagged — assert by inspection in review, no code).

## File Structure

- `scripts/runtime/build-jlink.ps1` (moved from Runtimes, cross-host logic replaced by native per-platform invocation), `scripts/runtime/build-runtime-zip.ps1` (moved unchanged), new `scripts/runtime/update-manifest.ps1` (manifest backfill; single responsibility: JSON in, JSON out).
- `.github/workflows/runtime-release.yml` (new; triggers, matrix, verify, release).
- `configs/runtimes.json` (merged manifest + `releaseTag` per entry; `''` means predates releases, `--fetch-runtime` then requires explicit `--tag`).
- `src/tools/mautool.lpr` (new `--fetch-runtime` mode; `--verify-manifests` tolerates empty `releaseTag`, requires `runtime/`-prefixed non-empty values), `scripts/run-matrix.ps1` + `tests/TestDistrib.lpr` (zips-dir references become env-overridable, default `%USERPROFILE%\.tyfpjdbc\runtimes`, bootstrap documented).
- `.gitignore` (zip guard line).

---

### Task 1: Merge migration

**Files:**
- Move (git mv): `D:\Projects\TyFPJDBC-Runtimes\scripts\*.ps1` → `scripts/runtime/`; merge `manifests/runtimes.json` entries into `configs/runtimes.json` (add `"releaseTag": ""` to each of the 5 entries; all other fields byte-identical).
- Modify: `.gitignore` (add `*.zip` guard line).
- Test: `scripts/guard.ps1` + JSON parse + existing `mautool --verify-manifests`.

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `scripts/runtime/build-jlink.ps1`, `scripts/runtime/build-runtime-zip.ps1`, merged `configs/runtimes.json` with `releaseTag` — used by Tasks 2–3.

- [ ] **Step 1: Move scripts and merge manifest**

`git mv` the two ps1 files; copy the 5 entries (add `"releaseTag": ""` each); append `.gitignore` line. Do NOT touch `scripts/run-matrix.ps1`, `TestDistrib.lpr`, or the local Runtimes dir yet (they keep working against local zips until Task 4).

- [ ] **Step 2: Verify merge is inert**

Run: `pwsh -NoProfile -File scripts/guard.ps1` → `guard ok`; parse both manifests (`ConvertFrom-Json`, 5 entries each); run `mautool --verify-manifests` (existing binary semantics) → `manifests verified`. If the old checker rejects the extra `releaseTag` field, allowlist it additively in `CheckRuntimes` (no behavior change) and note it in the commit message.
Expected: all green, zero behavior change.

- [ ] **Step 3: Commit**

```bash
git add scripts/runtime configs/runtimes.json .gitignore
git commit -m "chore: merge runtimes content into mono-repo"
```

---

### Task 2: Release workflow

**Files:**
- Create: `.github/workflows/runtime-release.yml`
- Create: `scripts/runtime/update-manifest.ps1`
- Test: local win64 dry run + fixture round-trip + `mautool --verify-manifests` + plan review of trigger set.

**Interfaces:**
- Consumes: Task 1's scripts + manifest shape.
- Produces: green workflow definition + tested `update-manifest.ps1` (exact params below) — used by Task 4's live run.

- [ ] **Step 1: Write `scripts/runtime/update-manifest.ps1` with fixture test**

Params: `-ManifestPath, -Platform, -PackedBytes, -UnpackedBytes, -Sha256, -JdkVersion, -BridgeVersion, -ReleaseTag, -AssetUrl`. Behavior: update exactly that platform's entry, preserve all other bytes of the file. Test (no framework; script asserts on fixture copies in `$env:TEMP`): (a) round-trip current `configs/runtimes.json` with no changes → `git diff` empty; (b) fixture update of one platform → only that entry's 6 fields change. Run both locally, both must pass.

- [ ] **Step 2: Write `.github/workflows/runtime-release.yml`**

Triggers: `workflow_dispatch` (inputs `jdk_version` default `25.0.4.1`, `bridge_ref` default triggering SHA, `platforms` default all five) + `push: tags: ['runtime/*']`. Concurrency group `runtime-release` (one at a time). Permissions `contents: write` only.
Fail-fast job/step first: parse versions from tag (or inputs); grep `VERSION = "<bv>"` from `java/bridge/src/main/java/tyfpjdbc/Bridge.java`; mismatch → fail with message.
Build matrix (5 platforms; runner labels pinned with a comment to re-check at implementation: `windows-latest`, `ubuntu-latest`, `ubuntu-24.04-arm`, macOS x64/arm64 runners; if macOS-Intel has no runner, that single platform falls back to the old cross-jlink invocation as an explicit exception step).
Per platform: checkout main repo at `bridge_ref`; `actions/setup-java@v4` (distribution `microsoft`, version `25`); curl HikariCP 5.1.0 + slf4j-api 2.0.9 + h2 2.2.224 from Maven Central (fail on empty); `javac` Bridge classes; run `BridgeSmoke` (needs h2 on cp) → `TOTAL fails=0`; assemble BridgeDir; run `scripts/runtime/build-jlink.ps1` natively for that platform; verify layout (jvm binary exists), budgets, record sha.
Release job: download all zips; run `update-manifest.ps1` per platform; build mautool (`apt-get install fpc`, compile `src/tools/mautool.lpr`) and run `mautool --verify-manifests` on the updated manifest (fail stops the release before commit); commit manifest to master; create Release for the tag with 5 zips + log; notes embed per-platform sha256.
Negative check (manual, recorded): run the tag-parse/fail-fast snippet locally against a mismatched fake tag → expect fail before any build step.

- [ ] **Step 3: Local single-platform dry run**

On this Windows machine (JDK present at `C:\Tools\ms-jdks\win64\jdk-25.0.4.1+1`): run the win64-equivalent steps by hand (javac → smoke → build-jlink win64 → layout/budget/sha asserts). Expected: all asserts pass; produced zip boots `java -version`. Do NOT commit the zip; delete it after.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/runtime-release.yml scripts/runtime/update-manifest.ps1
git commit -m "ci: mono-repo runtime release workflow"
```

---

### Task 3: mautool fetch-runtime + reference updates

**Files:**
- Modify: `src/tools/mautool.lpr` (new `--fetch-runtime` mode; `--verify-manifests` tolerates empty `releaseTag`, requires `runtime/` prefix when non-empty; usage text).
- Modify: `scripts/run-matrix.ps1` (`$rtZips` env-overridable, default `%USERPROFILE%\.tyfpjdbc\runtimes`), `tests/TestDistrib.lpr` (same default for its zips path).
- Test: `tests/TestDistrib.lpr` (pure URL test, no network) + full suite + guard.

**Interfaces:**
- Consumes: Task 1's manifest shape (`releaseTag`, `asset`).
- Produces: `mautool --fetch-runtime --platform <p> --out <dir> [--tag]` — used by Task 4 bootstrap.

- [ ] **Step 1: Write the failing URL test**

In `tests/TestDistrib.lpr` beside the `maven-path` assert, add (exact expected strings computed from manifest entry + tag `runtime/jre25.0.4.1-bridge0.9.0`):
```pascal
Ok('fetch-url', TDriverFetch.RuntimeAssetUrl('win64', 'runtime/jre25.0.4.1-bridge0.9.0') = 'https://github.com/ACTom/TyFPJDBC/releases/download/runtime/jre25.0.4.1-bridge0.9.0/jre-25-tyfpjdbc-win64.zip');
```
where `TDriverFetch.RuntimeAssetUrl(const Platform, Tag: string): string` is the new pure class function beside `MavenURL` (same pattern TestDistrib already uses for `MavenPath`; mautool itself calls it to build the download URL). Compile → FAIL (identifier missing).

- [ ] **Step 2: Implement `--fetch-runtime`**

New mode in the arg parser + `CmdFetchRuntime`: resolve tag (flag or manifest `releaseTag`; empty manifest tag without flag → Fail with message); build URL via the Step 1 helper; download with existing `RunDownload` plumbing; verify sha256 against the manifest entry; MISMATCH → delete + Fail (mirror `FetchJar` semantics). Update usage text. `--verify-manifests`: allow empty `releaseTag`; non-empty must start with `runtime/`.

- [ ] **Step 3: Update zips references + verify green**

`run-matrix.ps1` `$rtZips` and `TestDistrib.lpr` zips path become env-overridable (`TYFPJDBC_ZIPS`, default `%USERPROFILE%\.tyfpjdbc\runtimes`); document one-time bootstrap (`--fetch-runtime` ×5). Run: TestDistrib (`TOTAL fails=0`), guard (`guard ok`), package build (`lazbuild tyfpjdbc_design.lpk`, exit 0).

- [ ] **Step 4: Commit**

```bash
git add src/tools/mautool.lpr scripts/run-matrix.ps1 tests/TestDistrib.lpr
git commit -m "feat: mautool fetch-runtime from Release"
```

---

### Task 4: Push + first live release

**Files:**
- None in repo (operations + verification); fix commits only if the live run exposes workflow bugs.
- Test: the live dispatch run itself + Demo board.

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: published Release + verified local bootstrap (nothing code).

- [ ] **Step 1: Push (requires user-created empty `ACTom/TyFPJDBC`)**

```bash
git remote add origin <url-the-user-supplies>
git push -u origin master
```
(Implementer does not create the repo; waits for the URL.)

- [ ] **Step 2: Dispatch first build**

`gh workflow run runtime-release.yml -f jdk_version=25.0.4.1 -f platforms=all` (or UI Run). Watch to green; on red, fix minimally (workflow or scripts only, one fix + rerun), commit fixes.

- [ ] **Step 3: Verify acceptance (spec §5)**

Release shows 5 zips; manifest回填 commit exists; fresh `mautool --fetch-runtime` ×5 into clean dir + `--verify-runtime` all `VERIFIED`; `mautool --verify-manifests` green; local matrix key sections (guard/smoke/TestEngine/TestLcl) green. Then retire local `D:\Projects\TyFPJDBC-Runtimes` (rename, do not delete yet) and re-run matrix zips sections against the fetched cache.

- [ ] **Step 4: Report, no code commit**

Record release tag + SHAs in the final report. No commit in this task unless Step 2 required fixes (then they were already committed there).
