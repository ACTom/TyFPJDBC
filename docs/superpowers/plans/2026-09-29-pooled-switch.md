# Pooled Switch + Direct Connect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `Pooled` switch to `TJdbcConnection` backed by a new pool-bypassing `directConnect` path from Java to component, default behavior byte-identical.

**Architecture:** One vertical slice per layer: Java (`Bridge.directConnect`) → JNI (`TBridge.DirectConnect`) → engine (`TJdbcEngine.OpenDirect`) → component (`Pooled` branch) → shipped-jar refresh. Each task is independently testable and committable.

**Tech Stack:** Java 25 (HotSpot, `DriverManager`), FreePascal 3.2.2/Lazarus 4.8 (objfpc), PowerShell 7, H2 2.2.224 + SQLite 3.46.1.0 loopback jars.

**Spec:** `docs/superpowers/specs/2026-09-29-tyfpjdbc-pooled-switch-design.md` — executors read both; on any conflict the spec wins except the explicit deviation noted in Task 3.

## Global Constraints

- `Bridge.VERSION` stays `0.9.0`; version handshake behavior unchanged.
- `JniVersionUsed = $00010006`; JNI 1.6 only.
- Error taxonomy per `docs/TROUBLESHOOTING.md`: bad url `HY092/40`, unknown class `08000/33`, unknown driver `08000/40`, bad handle `HY000/99`.
- `.o`/`.ppu` only to `test-results/work/units`, exe only to `test-results/bin`; never beside sources, never root `lib/` (enforced by `scripts/guard.ps1`).
- JDK: `C:\Tools\ms-jdks\win64\jdk-25.0.4.1+1` with fallback `C:\Tools\jdk25\jdk-25.0.4.1+1`; driver jars from `C:\Tools\tyfpjdbc-libs`.
- `Pooled=True` behavior must remain byte-identical (existing tests lock it).

## Review Focus

- Old shipped jar without `directConnect` + new Pascal `Mid` lookup = `bridge.method missing` at `TBridge.Create`, breaking even the pooled path. Pinned by Task 4 (jar refresh + handshake test).
- `DriverClassOverride` (Cycle 1) combined with `Pooled=False` must use the override class on the direct path. Pinned by a Task 3 test asserting the override flows into `OpenDirect`.
- `Disconnect` on a direct connection must not touch pool handles (`FPool` stays 0; existing `Shutdown` guard covers it — pinned by Task 3 audit-zero test, no double-release).
- GPL-licensed or custom drivers over direct connect behave identically to pooled (transport-only change; entry supplies URL/class/dialect). Pinned by Task 2 using the standard H2 entry, no special-casing.
- Spec deviation: spec §4's `08000/53` is dropped — `TJdbcConnection` exposes no pool-stat accessors, and `TJdbcEngine` pool methods already reject handle 0 with `HY000/99` via `CheckHandle`, pinned by TestEngine's existing `bad-handle-local` test. No new code.

## File Structure

- `java/bridge/src/main/java/tyfpjdbc/Bridge.java` — add `directConnect` beside `createPool`; single state machine unchanged.
- `java/bridge/src/main/java/tyfpjdbc/BridgeSmoke.java` — add 5 direct cases (total 17 → 22 PASS lines; recount from file).
- `scripts/run-matrix.ps1` — update `smoke-17` count assertion 17 → 22 (line ~43, name and value).
- `src/core/TyFPJDBC.JNI.Bridge.pas` — add `FMDirectConnect` method id + `DirectConnect` wrapper (manual 4×`JStr` pattern, follow `CreatePool` at ~lines 793-803).
- `src/core/TyFPJDBC.Engine.pas` — add `OpenDirect`, tracked in `FConns`.
- `src/lcl/TyFPJDBC.LCL.Conn.pas` — add `Pooled` (default True), branch `Connect`.
- `tests/TestEngine.lpr` — add direct-* asserts in the live H2 section.
- `tests/TestLcl.lpr` — add `pooled-default` assert in the config section.
- `D:\Projects\ContactsDemo\bridge\tyfpjdbc-bridge-0.9.0.jar` — refresh `Bridge*.class` entries (backup first).

---

### Task 1: Java `directConnect` + smoke

**Files:**
- Modify: `java/bridge/src/main/java/tyfpjdbc/Bridge.java`
- Modify: `java/bridge/src/main/java/tyfpjdbc/BridgeSmoke.java`
- Modify: `scripts/run-matrix.ps1` (count line only)
- Test: BridgeSmoke output (`TOTAL fails=0`, exact PASS count recounted)

**Interfaces:**
- Consumes: existing `ConnBox`/`ids`/`recordChain`/`getErrorChain` in `Bridge.java`.
- Produces: `public long directConnect(String jdbcUrl, String user, String pw, String driverClass) throws SQLException` — used by Task 2's JNI wrapper with signature `(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)J`.

- [ ] **Step 1: Write the failing smoke cases**

Append to `BridgeSmoke.main` after `b.destroyPool(pool);` (line ~115), before `TOTAL`:
```java
long d = b.directConnect("jdbc:h2:mem:direct;DB_CLOSE_DELAY=-1", "", "", "org.h2.Driver");
ok("direct-open", d > 0);
ok("direct-ddl", b.execDirect(d, "CREATE TABLE dt(id BIGINT PRIMARY KEY, v VARCHAR(20))") == 0);
long di = b.prepare(d, "INSERT INTO dt VALUES(?, ?)");
b.bindLong(di, 1, 7L); b.bindString(di, 2, "seven");
ok("direct-roundtrip", b.execUpdate(di) == 1);
b.closeStmt(di);
long dq = b.prepare(d, "SELECT v FROM dt WHERE id=7");
long dc = b.queryOpen(dq, 10);
String[][] dw = b.fetchWindow(dc, 10);
ok("direct-read", dw.length == 1 && "seven".equals(dw[0][0]));
b.closeCursor(dc); b.closeStmt(dq);
b.closeConn(d);
boolean badCls = false;
try { b.directConnect("jdbc:h2:mem:x", "", "", "no.such.Driver"); }
catch (java.sql.SQLException e) { badCls = "08000".equals(e.getSQLState()); }
ok("direct-badclass", badCls);
```
(Count check: existing 17 `ok(` + new 5 = 22 PASS lines — recount from the file when implementing and set the exact number.)

- [ ] **Step 2: Compile to verify it fails**

Run (PowerShell, from `D:\Projects\TyFPJDBC`):
```powershell
$jh="C:\Tools\ms-jdks\win64\jdk-25.0.4.1+1"; $libs="C:\Tools\tyfpjdbc-libs"
$cp="$libs\HikariCP-5.1.0.jar;$libs\slf4j-api-2.0.9.jar;$libs\h2-2.2.224.jar;$libs\sqlite-jdbc-3.46.1.0.jar"
& "$jh\bin\javac.exe" -encoding UTF-8 -cp $cp -d test-results/work/jmain java/bridge/src/main/java/tyfpjdbc/PoolCfg.java java/bridge/src/main/java/tyfpjdbc/Bridge.java java/bridge/src/main/java/tyfpjdbc/BridgeSmoke.java
```
Expected: FAIL — `cannot find symbol: directConnect`.

- [ ] **Step 3: Implement `directConnect` in `Bridge.java`** (place beside `createPool`)

Body: empty/null url → `throw new SQLException("bad url", "HY092", 40)`; `Class.forName(driverClass)` catching `ClassNotFoundException` → `recordChain` + `throw new SQLException("no driver class " + driverClass, "08000", 33)`; else `DriverManager.getConnection(jdbcUrl, user, pw)` into a `ConnBox`, `ids.incrementAndGet()`, `conns.put`, return id; `SQLException` → `recordChain`, rethrow. `VERSION` untouched.

- [ ] **Step 4: Recompile + run smoke, verify green**

Same javac command as Step 2 (must exit 0), then:
```powershell
& "$jh\bin\java.exe" "-Dfile.encoding=UTF-8" -cp "test-results/work/jmain;$cp" tyfpjdbc.BridgeSmoke
```
Expected: `TOTAL fails=0` and PASS-line count equals the exact number counted in Step 1; update the `smoke-17` assertion name and value in `scripts/run-matrix.ps1` to match.

- [ ] **Step 5: Commit**

```bash
git add java/bridge/src/main/java/tyfpjdbc/Bridge.java java/bridge/src/main/java/tyfpjdbc/BridgeSmoke.java scripts/run-matrix.ps1
git commit -m "feat: Bridge.directConnect + smoke"
```

---

### Task 2: JNI wrapper + engine `OpenDirect` + TestEngine direct tests

**Files:**
- Modify: `src/core/TyFPJDBC.JNI.Bridge.pas`
- Modify: `src/core/TyFPJDBC.Engine.pas`
- Modify: `tests/TestEngine.lpr`
- Test: `tests/TestEngine.lpr` live run (`TOTAL fails=0`, zero `FAIL ` lines)

**Interfaces:**
- Consumes: Task 1's `directConnect(url, user, pw, driverClass): long`.
- Produces: `TBridge.DirectConnect(const Url, User, Password, DriverClass: UTF8String): Int64` and `TJdbcEngine.OpenDirect(const Cfg: TPoolCfgRec): Int64` (uses only `Cfg.Url/User/Password/DriverClass`; tracked in `FConns`) — used by Task 3.

- [ ] **Step 1: Write the failing TestEngine asserts**

In `tests/TestEngine.lpr`, declare two locals beside the existing ones (`dconn: Int64; cfgBad: TPoolCfgRec;`), and insert the block below right after the pool section's `eng.ClosePool(pool);` (line ~171, when handles are zero). Raw bridge calls mirror the file's existing style; keep pool-based tests untouched:
```pascal
dconn := eng.OpenDirect(cfg);
Ok('direct-open', (dconn > 0) and (eng.PoolCount = 0) and (eng.ConnCount = 1));
Ok('direct-ddl', bridge.ExecDirect(dconn,
  'CREATE TABLE dt(id BIGINT PRIMARY KEY, v VARCHAR(20))') = 0);
stmt := bridge.Prepare(dconn, 'INSERT INTO dt VALUES(?,?)');
try
  bridge.BindLong(stmt, 1, 7);
  bridge.BindString(stmt, 2, 'seven');
  Ok('direct-exec', bridge.ExecUpdate(stmt) = 1);
finally
  bridge.CloseStmt(stmt);
end;
stmt := bridge.Prepare(dconn, 'SELECT v FROM dt WHERE id=7');
try
  cur := bridge.QueryOpen(stmt, 10);
  try
    rows := bridge.FetchWindow(cur, 10);
    Ok('direct-read', (Length(rows) = 1) and (rows[0][0] = 'seven'));
  finally
    bridge.CloseCursor(cur);
  end;
finally
  bridge.CloseStmt(stmt);
end;
eng.Release(dconn);
Ok('direct-release-zero', (eng.HandleCount = 0) and
  (eng.AuditReport = 'pools=0 conns=0 stmts=0 cursors=0'));
cfgBad := DefaultPoolCfg('jdbc:h2:mem:bad;DB_CLOSE_DELAY=-1', 'no.such.Driver');
raised := False;
try
  eng.OpenDirect(cfgBad);
except
  on E: EJDBCError do
    raised := E.SQLState = '08000';
end;
Ok('direct-badclass', raised);
```
(`raised` already exists in the file's var block; `dconn`/`cfgBad` are the only new locals.)

- [ ] **Step 2: Compile to verify it fails**

Run: `fpc -FUD:\Projects\TyFPJDBC\test-results\work\units -FuD:\Projects\TyFPJDBC\src\core -FuD:\Projects\TyFPJDBC\src\db -oD:\Projects\TyFPJDBC\test-results\bin\testengine.exe D:\Projects\TyFPJDBC\tests\TestEngine.lpr` (absolute `-o…​.exe` — relative `-o` makes fpc emit an extensionless binary next to the stale `.exe`; verified 2026-09-29)
Expected: FAIL — `identifier idents no member "OpenDirect"`.

- [ ] **Step 3: Implement `TBridge.DirectConnect`**

Add `FMDirectConnect: jmethodID` to the private id block; register with `Mid('directConnect', '(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)J')` beside the other `Mid` calls; implement the wrapper following `CreatePool`'s manual four-`JStr` + `CallLongMethodA` + `CheckJ('directconnect')` shape (do NOT extend `CallLongStr`).

- [ ] **Step 4: Implement `TJdbcEngine.OpenDirect`**

```pascal
function TJdbcEngine.OpenDirect(const Cfg: TPoolCfgRec): Int64;
begin
  Result := FBridge.DirectConnect(Cfg.Url, Cfg.User, Cfg.Password, Cfg.DriverClass);
  CheckHandle('conn', Result);
  Track(FConns, Result);
end;
```
(`Release`/`ForceReset`/counts need no changes.)

- [ ] **Step 5: Recompile + run TestEngine live, verify green**

Recompile with the Step 2 command (exit 0), then run with the freshly compiled classes dir from Task 1 as the argument (same convention as `run-matrix.ps1`): `D:\Projects\TyFPJDBC\test-results\bin\testengine.exe D:\Projects\TyFPJDBC\test-results\work\jmain`.
Expected: `TOTAL fails=0`, no `^FAIL ` lines, new `direct-*` PASS lines present.

- [ ] **Step 6: Commit**

```bash
git add src/core/TyFPJDBC.JNI.Bridge.pas src/core/TyFPJDBC.Engine.pas tests/TestEngine.lpr
git commit -m "feat: engine OpenDirect + direct tests"
```

---

### Task 3: Component `Pooled` switch + regression

**Files:**
- Modify: `src/lcl/TyFPJDBC.LCL.Conn.pas`
- Modify: `tests/TestLcl.lpr` (`pooled-default` assert in the JVM-free config section)
- Test: TestLcl config run + full live suites + `guard.ps1` + Demo board

**Interfaces:**
- Consumes: Task 2's `OpenDirect`.
- Produces: `property Pooled: Boolean ... default True` and `function EffectiveDriverClass: string` on `TJdbcConnection`; `Connect` branches (pool path unchanged; direct path builds cfg with `cfg.DriverClass := UTF8String(EffectiveDriverClass)`, sets `FPool := 0`, `FConn := OpenDirect(cfg)`, same `TestQuery` probe). No new engine/JNI API.

- [ ] **Step 1: Write the failing tests**

In `tests/TestLcl.lpr` config section beside `conn-override-default`, add:
```pascal
Ok('pooled-default', c.Pooled);
Ok('conn-effective-default', c.EffectiveDriverClass = 'org.postgresql.Driver');
c.DriverClassOverride := 'com.example.Wrapper';
Ok('conn-effective-override', c.EffectiveDriverClass = 'com.example.Wrapper');
```
(`c.DriverId` is `'sqlite'` at that point in the existing test; `EffectiveDriverClass` is a new public pure function on `TJdbcConnection` returning the override when non-blank else the entry class — headless-testable, no JVM.)
Compile with `fpc -Mobjfpc -Sh -FuD:\Projects\TyFPJDBC\src\core -FuD:\Projects\TyFPJDBC\src\db -FuD:\Projects\TyFPJDBC\src\lcl -FUD:\Projects\TyFPJDBC\test-results\work\units -oD:\Projects\TyFPJDBC\test-results\bin\testlcl.exe D:\Projects\TyFPJDBC\tests\TestLcl.lpr` (absolute `-o…​.exe`, see Task 2 note).
Expected: FAIL — `identifier idents no member "Pooled"`.

- [ ] **Step 2: Implement `Pooled` + `EffectiveDriverClass`**

New public function `function EffectiveDriverClass: string;` returning `Trim(FDriverClassOverride)` when non-blank else `TDriverRegistry.Find(FDriverId).DriverClass`. Field `FPooled: Boolean`, constructor init `True`, published `property Pooled: Boolean read FPooled write FPooled default True`. In `Connect`: `if FPooled then <existing pool block incl. probe> else begin <build cfg as today but with `cfg.DriverClass := UTF8String(EffectiveDriverClass)>` FPool := 0; FConn := TJdbcEngine(FEngine).OpenDirect(cfg)` then the identical probe block on `FConn`. `Shutdown`/`Disconnect`/`TestConnection` need no changes (existing `FPool > 0` guard skips pool teardown). `MaxPool/MinIdle` ignored when not pooled (document in the property comment).

- [ ] **Step 3: Verify green + full regression**

Recompile TestLcl (Step 1 command, exit 0); run config-only (no args): `TOTAL fails=0`. Then run live suites with fresh classes: TestEngine, TestLcl (with classes dir arg), TestDialect, TestTx per `run-matrix.ps1` conventions — each `TOTAL fails=0` and no `^FAIL ` lines. Run `pwsh -NoProfile -File scripts/guard.ps1` → `guard ok`. Demo board (`lazbuild` + `--selftest`/`--verifyform`) is Task 4's gate, not this task's: the shipped Demo jar lacks `directConnect` until Task 4 refreshes it, so any Demo run before that fails at `TBridge.Create` with `bridge.method directConnect` (verified 2026-09-29).

- [ ] **Step 4: Commit**

```bash
git add src/lcl/TyFPJDBC.LCL.Conn.pas tests/TestLcl.lpr
git commit -m "feat: TJdbcConnection.Pooled switch"
```

---

### Task 4: Refresh shipped Demo bridge jar (+ spec-deviation record)

**Files:**
- Modify (binary): `D:\Projects\ContactsDemo\bridge\tyfpjdbc-bridge-0.9.0.jar` (only `tyfpjdbc/Bridge*.class` entries; backup first, restore on any failure)
- Test: Demo `--selftest` (handshake) + `--verifyform`

**Interfaces:**
- Consumes: Task 1's compiled `Bridge*.class` (rebuild from source with the matrix javac command if stale).
- Produces: Demo jar containing `directConnect`; nothing else in the jar changes (`VERSION` still `0.9.0`).

- [ ] **Step 1: Backup + refresh jar entries**

```powershell
Copy-Item D:\Projects\ContactsDemo\bridge\tyfpjdbc-bridge-0.9.0.jar C:\Users\Tom\AppData\Local\Temp\opencode\bridge-pre-direct.jar -Force
& "$jh\bin\jar.exe" uf D:\Projects\ContactsDemo\bridge\tyfpjdbc-bridge-0.9.0.jar -C test-results/work/jmain tyfpjdbc/Bridge.class
```
(Inner classes `Bridge$*.class` unchanged by Task 1 — verify with `jar tf` before/after that only `tyfpjdbc/Bridge.class` differs; if Task 1 touched them, include the changed ones too. `PoolCfg` untouched — do not include it.)

- [ ] **Step 2: Verify handshake + board with refreshed jar**

Run Demo `--selftest` → `TOTAL fails=0` (proves version handshake + JNI method table incl. `directConnect` resolve at `TBridge.Create`); run `--verifyform` → `TOTAL fails=0`. Confirm `git status` in `D:\Projects\TyFPJDBC` shows no source changes from this task (jar lives outside the repo; record its SHA256 in the commit message body of the previous task? No — do not amend; just report it).

- [ ] **Step 3: Record the release-hygiene follow-up**

Same bytes-version/different content (`0.9.0` jar with a new method) is intentional here but the Runtimes release pipeline owns the canonical rebuild — file it as a follow-up note in the final report, not code. No commit in this task (binary outside git); if anything fails, restore from `bridge-pre-direct.jar` and report.
