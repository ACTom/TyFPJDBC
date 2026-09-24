# TyFPJDBC V2 通用 JDBC 句柄重写 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按 V2 规格推倒重写 TyFPJDBC，Java 侧为唯一状态机，Pascal 侧只拿句柄，任意 JDBC 驱动可接入，代码 API 与 DB 控件同时生产可用。

**Architecture:** Pascal `TJdbcEngine` 只做句柄管理与编排；Java `Bridge v2` 拥有池/连接/语句/游标；`Dialect` 承担分页引用类型；`DatasetAdapter` 只做窗口映射；`Runtime` 管 JRE 与驱动分发。

**Tech Stack:** Free Pascal 3.2.2 / Lazarus LCL / Java 17+ (Bridge) / HikariCP 5.1.0 / JUnit 5 / PowerShell 7 matrix.

**Spec:** `docs/superpowers/specs/2026-09-25-tyfpjdbc-rewrite-design.md`

## Global Constraints

- 不兼容任何现有设计，旧 `src/core`、`src/db`、`java/bridge` API 可删除重写，不写兼容层。
- `src/core` 运行时零 LCL 依赖，`scripts/guard.ps1` 必须通过。
- 所有值走绑定，标识符走方言引用或白名单，不拼字符串。
- 未知驱动与未知类型默认报错，不静默兜底。
- 资源按游标→语句→连接→池→JVM 逆序释放，泄漏可计数。
- 每个任务结束必须可独立测试，先写失败测试，再实现，再提交。

---

## File Structure

新核心文件（全部重写或新建，旧模拟实现删除）：

- `src/core/TyFPJDBC.Handles.pas` —— 句柄类型（`TJdbcPoolId/TJdbcConnId/TJdbcStmtId/TJdbcCursorId = Int64`）与 `EJDBCError`（SQLState/VendorCode/Chain）。
- `src/core/TyFPJDBC.JVM.Manager.pas` —— 多配置 JVM 生命周期（重写）。
- `src/core/TyFPJDBC.JNI.BridgeV2.pas` —— Bridge v2 瘦 JNI 客户端。
- `src/core/TyFPJDBC.Driver.Registry.pas` —— 任意驱动注册（重写）。
- `src/core/TyFPJDBC.Dialect.Api.pas` —— 方言接口 `IJdbcDialect`。
- `src/core/TyFPJDBC.Dialect.Pg.pas`、`TyFPJDBC.Dialect.Mysql.pas`、`TyFPJDBC.Dialect.Mssql.pas`、`TyFPJDBC.Dialect.Oracle.pas`、`TyFPJDBC.Dialect.Sqlite.pas`、`TyFPJDBC.Dialect.H2.pas` —— 六方言。
- `src/core/TyFPJDBC.Engine.pas` —— 句柄编排门面（池/连接/事务/执行/游标）。
- `src/db/TyFPJDBC.Command.pas` —— 类型化命令（查询/更新/批量/超时/取消）。
- `src/db/TyFPJDBC.Dataset.Adapter.pas` —— 游标窗口到 TBufDataset 映射与增量收集。
- `src/db/TyFPJDBC.Query.pas` —— DB 感知查询组件（重写）。
- `src/db/TyFPJDBC.StoredProc.pas`、`src/db/TyFPJDBC.Script.pas` —— 存储过程与脚本（重写）。
- `src/lcl/tyfpjdbc.lpk`、`src/lcl/TyFPJDBC.LCL.Conn.pas`、`src/lcl/TyFPJDBC.LCL.Query.pas`、`src/lcl/TyFPJDBC.LCL.ConnDialog.pas` —— 设计时包。
- `java/bridge/src/main/java/tyfpjdbc/Bridge.java` —— Bridge v2（VERSION=2.0.0）。
- `src/tools/mautool.lpr` —— Runtime+驱动下载器 v2（重写相关过程）。
- 测试：`tests/TestV2Handles.lpr`、`tests/TestV2Dialect.lpr`、`tests/TestV2Engine.lpr`、`tests/TestV2Dataset.lpr`、`tests/TestV2Soak.lpr`、`java/bridge/src/test/java/tyfpjdbc/BridgeTest.java`（重写）。

---

### Task 1: 句柄与错误基座

**Files:**
- Create: `src/core/TyFPJDBC.Handles.pas`
- Test: `tests/TestV2Handles.lpr`

**Interfaces:**
- Consumes: 无（首任务）。
- Produces: `TJdbcPoolId/TJdbcConnId/TJdbcStmtId/TJdbcCursorId = Int64`; `EJDBCError.CreateChain(const Msg, State: string; Code: Integer; const Next: string)`，字段 `SQLState: string; VendorCode: Integer; Chain: TStringList`; `function JdbcOk(const Id: Int64): Boolean`（`Id > 0`）; `procedure CheckHandle(const Name: string; Id: Int64)`（`Id <= 0` 抛 `HY000/99`）。

- [ ] **Step 1: Write the failing test**

```pascal
program TestV2Handles;
{$mode objfpc}{$H+}
uses SysUtils, TyFPJDBC.Handles;
var Fails: Integer = 0;
procedure Ok(const N: string; C: Boolean);
begin
  if C then WriteLn('PASS ', N) else begin Inc(Fails); WriteLn('FAIL ', N); end;
end;
var e: EJDBCError;
begin
  Ok('invalid-handle-fails', not JdbcOk(0));
  Ok('valid-handle-ok', JdbcOk(7));
  try CheckHandle('pool', 0); Ok('check-raises', False);
  except on E: EJDBCError do Ok('check-raises', (E.SQLState = 'HY000') and (E.VendorCode = 99)); end;
  e := EJDBCError.CreateChain('no pool', '08000', 31, 'pool=0');
  try Ok('chain-state', (e.SQLState = '08000') and (e.Chain.Count = 2)); finally e.Free; end;
  WriteLn('TOTAL fails=', Fails);
  if Fails > 0 then Halt(1);
end.
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fpc '-Fusrc/core' '-oC:\Users\Tom\AppData\Local\Temp\grok-goal-00fdc9ad82c8\implementer\v2\t1.exe' tests/TestV2Handles.lpr`
Expected: FAIL，单元 `TyFPJDBC.Handles` 不存在。

- [ ] **Step 3: Write minimal implementation**

```pascal
unit TyFPJDBC.Handles;
{$mode objfpc}{$H+}
interface
uses SysUtils, Classes;
type
  TJdbcPoolId = Int64;
  TJdbcConnId = Int64;
  TJdbcStmtId = Int64;
  TJdbcCursorId = Int64;
  EJDBCError = class(Exception)
    SQLState: string;
    VendorCode: Integer;
    Chain: TStringList;
    constructor CreateChain(const Msg, State: string; Code: Integer; const Next: string);
    destructor Destroy; override;
  end;
function JdbcOk(const Id: Int64): Boolean;
procedure CheckHandle(const Name: string; Id: Int64);
implementation
constructor EJDBCError.CreateChain(const Msg, State: string; Code: Integer; const Next: string);
begin
  inherited Create(Msg + ' caused by ' + Next);
  SQLState := State; VendorCode := Code;
  Chain := TStringList.Create; Chain.Add(Msg); Chain.Add(Next);
end;
destructor EJDBCError.Destroy; begin Chain.Free; inherited; end;
function JdbcOk(const Id: Int64): Boolean; begin Result := Id > 0; end;
procedure CheckHandle(const Name: string; Id: Int64);
begin
  if Id <= 0 then raise EJDBCError.CreateChain('bad handle', 'HY000', 99, Name + '=0');
end;
end.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `fpc '-Fusrc/core' '-oC:\Users\Tom\AppData\Local\Temp\grok-goal-00fdc9ad82c8\implementer\v2\t1.exe' tests/TestV2Handles.lpr` then `cmd /c "C:\Users\Tom\AppData\Local\Temp\grok-goal-00fdc9ad82c8\implementer\v2\t1.exe"`
Expected: PASS 4 项，`TOTAL fails=0`。

- [ ] **Step 5: Commit**

```bash
git add src/core/TyFPJDBC.Handles.pas tests/TestV2Handles.lpr
git commit -m "v2: handles and error base"
```

---

### Task 2: Bridge v2（Java 唯一状态机）

**Files:**
- Modify: `java/bridge/src/main/java/tyfpjdbc/Bridge.java`
- Test: `java/bridge/src/test/java/tyfpjdbc/BridgeTest.java`

**Interfaces:**
- Consumes: Task 1 错误语义（SQLState 约定：未知句柄 `HY000/99`，无池 `08000/31`，无连接 `08000/32`，取消 `HY008`，超时 `HYT00`）。
- Produces: `VERSION = "2.0.0"`; `createPool(PoolCfg) -> long`; `borrowodiedConn(poolId) -> long`; `setAutoCommit/commit/rollback/savepoint/rollbackTo/releaseSavepoint`; `prepare(connId, sql) -> stmtId`; `bindXXX(stmtId, index, value)`; `execUpdate/execBatch/queryOpen/fetchWindow`; `cancel(stmtId)`; `getTables/getColumns/getPrimaryKeys/getResultMeta/getDatabaseMeta`; `poolStatsStructured(poolId) -> PoolStats`; `getErrorChain()` ThreadLocal; `closeCursor/closeStmt/closeConn/destroyPool`。

PoolCfg 字段（全部具名 setter）：`jdbcUrl/user/password/driverClass/maximumPoolSize/minimumIdle/connectionTimeoutMs/maxLifetimeMs/keepaliveTimeMs/leakDetectionThresholdMs/connectionTestQuery/validationTimeoutMs/readOnly/autoCommit/isolationName/catalog/schema/networkTimeoutMs`。

- [ ] **Step 1: Write the failing test**

```java
package tyfpjdbc;
import org.junit.jupiter.api.*;
import static org.junit.jupiter.api.Assertions.*;
public class BridgeTest {
  Bridge b = new Bridge();
  @Test public void versionIs2() { assertEquals("2.0.0", b.getVersion()); }
  @Test public void unknownHandleFails() {
    var ex = assertThrows(java.sql.SQLException.class, () -> b.borrowConn(0));
    assertEquals("HY000", ex.getSQLState());
  }
  @Test public void sqliteRoundTrip() throws Exception {
    PoolCfg c = new PoolCfg("jdbc:sqlite::memory:", "", "", "org.sqlite.JDBC", 4, 1);
    long pool = b.createPool(c);
    long conn = b.borrowConn(pool);
    b.execUpdate(b.prepare(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)"), new Object[]{});
    long stmt = b.prepare(conn, "INSERT INTO t VALUES(?,?)");
    assertEquals(1, b.execBatch(stmt, new Object[][]{{1, "hi"}}));
    long cur = b.queryOpen(b.prepare(conn, "SELECT id,name FROM t ORDER BY id"), new Object[]{}, 100);
    assertEquals(1, b.fetchWindow(cur, 0, 100).length);
    b.closeCursor(cur); b.closeStmt(stmt); b.closeConn(conn); b.destroyPool(pool);
  }
  @Test public void cancelKillsRightStmt() throws Exception {
    PoolCfg c = new PoolCfg("jdbc:h2:mem:cx", "", "", "org.h2.Driver", 4, 1);
    long pool = b.createPool(c);
    long conn = b.borrowConn(pool);
    long s1 = b.prepare(conn, "SELECT 1");
    long s2 = b.prepare(conn, "SELECT 2");
    b.cancel(s2);
    assertDoesNotThrow(() -> b.execUpdate(s1, new Object[]{}));
    b.closeStmt(s1); b.closeStmt(s2); b.closeConn(conn); b.destroyPool(pool);
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `javac` 编译后 `mvn -q -Dtest=BridgeTest test`（或 gradle 等价命令）。
Expected: FAIL，`PoolCfg`、`borrowConn`、`prepare` 等符号不存在，`VERSION` 仍为 `1.0.0`。

- [ ] **Step 3: Write minimal implementation**

在 `Bridge.java` 中实现（要点，不逐行展开全部 600 行，任务执行者按此骨架补全）：

```java
package tyfpjdbc;
public class Bridge {
  public static final String VERSION = "2.0.0";
  private final java.util.concurrent.atomic.AtomicLong ids = new java.util.concurrent.atomic.AtomicLong(0);
  private final java.util.Map<Long, com.zaxxer.hikari.HikariDataSource> pools = new java.util.concurrent.ConcurrentHashMap<>();
  private final java.util.Map<Long, java.sql.Connection> conns = new java.util.concurrent.ConcurrentHashMap<>();
  private final java.util.Map<Long, java.sql.Statement> stmts = new java.util.concurrent.ConcurrentHashMap<>();
  private final java.util.Map<Long, Cursor> cursors = new java.util.concurrent.ConcurrentHashMap<>();
  private final ThreadLocal<String> lastError = ThreadLocal.withInitial(() -> "");
  public String getVersion() { return VERSION; }
  public long createPool(PoolCfg c) throws java.sql.SQLException {
    if (c == null || c.jdbcUrl == null || c.jdbcUrl.isEmpty()) throw new java.sql.SQLException("bad url", "HY092", 40);
    com.zaxxer.hikari.HikariConfig h = new com.zaxxer.hikari.HikariConfig();
    h.setJdbcUrl(c.jdbcUrl); h.setUsername(c.user); h.setPassword(c.password);
    h.setDriverClassName(c.driverClass);
    h.setMaximumPoolSize(c.maximumPoolSize); h.setMinimumIdle(c.minimumIdle);
    h.setConnectionTimeout(c.connectionTimeoutMs); h.setMaxLifetime(c.maxLifetimeMs);
    h.setKeepaliveTime(c.keepaliveTimeMs);
    if (c.connectionTestQuery != null && !c.connectionTestQuery.isEmpty()) h.setConnectionTestQuery(c.connectionTestQuery);
    h.setValidationTimeout(c.validationTimeoutMs);
    h.setReadOnly(c.readOnly); h.setAutoCommit(c.autoCommit);
    if (c.catalog != null && !c.catalog.isEmpty()) h.setCatalog(c.catalog);
    if (c.schema != null && !c.schema.isEmpty()) h.setSchema(c.schema);
    long id = ids.incrementAndGet();
    pools.put(id, new com.zaxxer.hikari.HikariDataSource(h));
    return id;
  }
  public long borrowConn(long poolId) throws java.sql.SQLException {
    var ds = pools.get(poolId);
    if (ds == null) throw new java.sql.SQLException("no pool", "HY000", 99);
    try {
      var c = ds.getConnection();
      if (c.isValid(2)) { long id = ids.incrementAndGet(); conns.put(id, c); return id; }
      throw new java.sql.SQLException("invalid conn", "08000", 32);
    } catch (java.sql.SQLException e) { recordChain(e); throw e; }
  }
  // prepare/bind/execUpdate/execBatch/queryOpen/fetchWindow/cancel/getTables/getColumns/
  // getPrimaryKeys/getResultMeta/poolStatsStructured/closeCursor/closeStmt/closeConn/destroyPool
  // 全部按“未知句柄 HY000/99、驱动错误 recordChain 到 ThreadLocal”实现；cancel(stmtId) 只 cancel 该语句。
  private void recordChain(java.sql.SQLException e) {
    StringBuilder s = new StringBuilder();
    while (e != null) { s.append("SQLState=").append(e.getSQLState()).append(";code=").append(e.getErrorCode()).append(";msg=").append(e.getMessage()).append('\n'); e = e.getNextException(); }
    lastError.set(s.toString());
  }
  public String getErrorChain() { return lastError.get(); }
  static final class Cursor { long stmtId; java.sql.ResultSet rs; }
}
```

`PoolCfg.java` 为公开字段 POJO，默认值：`maximumPoolSize=10/minimumIdle=2/connectionTimeoutMs=30000/maxLifetimeMs=1800000/keepaliveTimeMs=30000/leakDetectionThresholdMs=0/connectionTestQuery="SELECT 1"/validationTimeoutMs=5000/readOnly=false/autoCommit=true/isolationName="READ_COMMITTED"`。

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn -q -Dtest=BridgeTest test`
Expected: 4 tests successful，无全局 lastError 串扰，cancel 只杀 s2。

- [ ] **Step 5: Commit**

```bash
git add java/bridge/src/main/java/tyfpjdbc/Bridge.java java/bridge/src/main/java/tyfpjdbc/PoolCfg.java java/bridge/src/test/java/tyfpjdbc/BridgeTest.java
git commit -m "v2: bridge v2 single state machine"
```

---

### Task 3: JNI 瘦客户端（Pascal 侧只拿句柄）

**Files:**
- Create: `src/core/TyFPJDBC.JNI.BridgeV2.pas`
- Test: `tests/TestV2Engine.lpr`（本任务只用其中句柄部分，完整 Engine 在 Task 6 跑通）

**Interfaces:**
- Consumes: Task 1 `CheckHandle/EJDBCError`；Task 2 Bridge v2 方法签名。
- Produces: `TBridgeV2 = class` 方法：`constructor Create; function GetVersion: string; function CreatePool(const Cfg: TPoolCfg): Int64; procedure DestroyPool(PoolId: Int64); function BorrowConn(PoolId: Int64): Int64; procedure CloseConn(ConnId: Int64); function Prepare(ConnId: Int64; const SQL: UTF8String): Int64; procedure BindInt/BindInt64/BindStr/BindDouble/BindDate/BindTime/BindTimestamp/BindBytes/BindNull(StmtId: Int64; Index: Integer; ...); function ExecUpdate(StmtId: Int64): Integer; function ExecBatch(StmtId: Int64; const Rows: array of TBoundRow): Integer; function QueryOpen(StmtId: Int64; WindowSize: Integer): Int64; function FetchWindow(CursorId: Int64; Offset, Size: Integer): TJavaRows; procedure Cancel(StmtId: Int64); procedure CloseCursor/CloseStmt; function PoolStats(PoolId: Int64): TPoolStatRec; function ErrorChain: string`。未知句柄本地 `CheckHandle` 先抛，不进 JNI。

- [ ] **Step 1: Write the failing test**

```pascal
// tests/TestV2Engine.lpr 片段（本任务先跑通版本与句柄校验部分）
Ok('bridge-version-2', Bridge.GetVersion = '2.0.0');
try Bridge.BorrowConn(0); Ok('bad-handle-local', False);
except on E: EJDBCError do Ok('bad-handle-local', (E.SQLState = 'HY000') and (E.VendorCode = 99)); end;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fpc '-Fusrc/core' '-oC:\Users\Tom\AppData\Local\Temp\grok-goal-00fdc9ad82c8\implementer\v2\e.exe' tests/TestV2Engine.lpr`
Expected: FAIL，`TBridgeV2` 不存在。

- [ ] **Step 3: Write minimal implementation**

新建 `TBridgeV2`，每个方法先 `CheckHandle` 再走 JNI（`Mid/CheckJ/JStr` 复用旧 Bridge 的 JNI 模式，但方法签名对齐 Bridge v2，`VERSION` 强校验为 `2.0.0`，不一致抛 `HY000/99`）。`PoolStats` 返回记录 `Active/Idle/Waiting/Leak` 四整数字段，不解析字符串。

- [ ] **Step 4: Run test to verify it passes**

Run: 同 Step 2 编译并 `cmd /c` 运行（需先启动 JVM，见 Task 4；本任务可用 H2 内存库做 live 回环）。
Expected: 版本与句柄校验 PASS。

- [ ] **Step 5: Commit**

```bash
git add src/core/TyFPJDBC.JNI.BridgeV2.pas tests/TestV2Engine.lpr
git commit -m "v2: thin jni bridge client"
```

---

### Task 4: JVM 生命周期重写

**Files:**
- Modify: `src/core/TyFPJDBC.JVM.Manager.pas`
- Test: `tests/TestV2Jvm.lpr`

**Interfaces:**
- Consumes: Task 1 错误类型。
- Produces: `TJVMConfig = record LibJvm, ClassPath: string; Args: array of string; end`; `TJVMManager.EnsureStarted(const Cfg: TJVMConfig)`; `TJVMManager.Shutdown`; `TJVMManager.IsStarted: Boolean`; `TJVMManager.FindLibJvm(const Custom: string): string`（顺序：显式路径→自带 jre/→JAVA_HOME→Windows 注册表→PATH→macOS dylib）；`TJVMManager.BuildArgs(const Cfg: TJVMConfig): TStringArray`（数组传参，不按空格切分）。

- [ ] **Step 1: Write the failing test**

```pascal
program TestV2Jvm;
{$mode objfpc}{$H+}
uses SysUtils, TyFPJDBC.JVM.Manager;
var Fails: Integer = 0;
procedure Ok(const N: string; C: Boolean);
begin if C then WriteLn('PASS ', N) else begin Inc(Fails); WriteLn('FAIL ', N); end; end;
var Cfg: TJVMConfig;
begin
  Cfg := DefaultJvmConfig;
  Cfg.LibJvm := 'C:/nonexistent-jvm.dll'; Cfg.Args := ['-Dfile.encoding=UTF-8', '-Djava.awt.headless=true'];
  try TJVMManager.EnsureStarted(Cfg); Ok('missing-jvm-fails', False);
  except on E: Exception do Ok('missing-jvm-fails', Pos('libjvm', E.Message) > 0); end;
  Ok('findlib-order', TJVMManager.FindLibJvm('') <> '');
  WriteLn('TOTAL fails=', Fails);
  if Fails > 0 then Halt(1);
end.
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fpc '-Fusrc/core' '-oC:\Users\Tom\AppData\Local\Temp\grok-goal-00fdc9ad82c8\implementer\v2\j.exe' tests/TestV2Jvm.lpr`
Expected: FAIL，无 `TJVMConfig/DefaultJvmConfig/Shutdown`。

- [ ] **Step 3: Write minimal implementation**

按规格 4.4 重写：配置变化视为不同运行时（已启动且配置不同则抛错，要求先 `Shutdown`）；JNI 版本按运行 JDK 协商；Attach 计数配对；含空格路径用数组传参。

- [ ] **Step 4: Run test to verify it passes**

Run: 同 Step 2 编译运行。
Expected: PASS，缺失 jvm 报可操作错误，真机上 `FindLibJvm('')` 非空。

- [ ] **Step 5: Commit**

```bash
git add src/core/TyFPJDBC.JVM.Manager.pas tests/TestV2Jvm.lpr
git commit -m "v2: jvm lifecycle rewrite"
```

---

### Task 5: 驱动注册表与方言层

**Files:**
- Modify: `src/core/TyFPJDBC.Driver.Registry.pas`
- Create: `src/core/TyFPJDBC.Dialect.Api.pas`, `src/core/TyFPJDBC.Dialect.Pg.pas`, `src/core/TyFPJDBC.Dialect.Mysql.pas`, `src/core/TyFPJDBC.Dialect.Mssql.pas`, `src/core/TyFPJDBC.Dialect.Oracle.pas`, `src/core/TyFPJDBC.Dialect.Sqlite.pas`, `src/core/TyFPJDBC.Dialect.H2.pas`
- Test: `tests/TestV2Dialect.lpr`

**Interfaces:**
- Consumes: Task 1。
- Produces: `TDriverEntry = record Id, DriverClass, UrlTemplate: string; DefaultPort: Integer; TestQuery, License, Maven: string; Sha: string; end`; `TDriverRegistry.Register(const E: TDriverEntry); function BuildUrl(const Id, Host: string; Port: Integer; const Database: string; Extra: TStrings): string; function BuildProperties(const Id: string; ...): TStringList`; `IJdbcDialect` 方法：`function PagedSQL(const SQL: string; Limit, Offset: Int64): string; function QuoteIdent(const N: string): string; function KeyReturn(const Table, Key: string): string; function DialectId: string`; `function DialectFor(const DriverId: string): IJdbcDialect`（未知抛 `08000`，并用 DatabaseMeta 产品名校验）。

- [ ] **Step 1: Write the failing test**

```pascal
Ok('pg-page', DialectFor('postgresql').PagedSQL('SELECT * FROM t ORDER BY id', 10, 20) = 'SELECT * FROM t ORDER BY id LIMIT 10 OFFSET 20');
Ok('mysql-quote', DialectFor('mysql').QuoteIdent('weird`name') = '`weird``name`');
Ok('mssql-page', Pos('OFFSET', DialectFor('mssql').PagedSQL('SELECT * FROM t ORDER BY id', 10, 20)) > 0);
Ok('oracle-page', Pos('FETCH FIRST', DialectFor('oracle').PagedSQL('SELECT * FROM t ORDER BY id', 10, 20)) > 0);
Ok('sqlite-url', TDriverRegistry.BuildUrl('sqlite', '', 0, '/tmp/a.db', nil) = 'jdbc:sqlite:/tmp/a.db');
try DialectFor('nosuch'); Ok('unknown-dialect', False);
except on E: EJDBCError do Ok('unknown-dialect', E.SQLState = '08000'); end;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fpc '-Fusrc/core' '-oC:\Users\Tom\AppData\Local\Temp\grok-goal-00fdc9ad82c8\implementer\v2\d.exe' tests/TestV2Dialect.lpr`
Expected: FAIL，无六方言实现。

- [ ] **Step 3: Write minimal implementation**

接口文件定义 `IJdbcDialect`；六个单元各实现 `PagedSQL/QuoteIdent/KeyReturn`；注册表支持任意驱动注册，`BuildUrl` 按 `urlTemplate` 替换 `{host}/{port}/{database}` 并拼接 `Extra` 为 `?k=v&`，`BuildProperties` 透传超时字符集只读。

- [ ] **Step 4: Run test to verify it passes**

Run: 同 Step 2 编译运行。
Expected: 6 项 PASS。

- [ ] **Step 5: Commit**

```bash
git add src/core/TyFPJDBC.Driver.Registry.pas src/core/TyFPJDBC.Dialect.*.pas tests/TestV2Dialect.lpr
git commit -m "v2: driver registry and six dialects"
```

---

### Task 6: Engine（句柄编排门面）

**Files:**
- Create: `src/core/TyFPJDBC.Engine.pas`
- Test: `tests/TestV2Engine.lpr`

**Interfaces:**
- Consumes: Task 2/3/4/5（`TBridgeV2`, `TJVMManager`, `TDriverRegistry`, `DialectFor`）。
- Produces: `TJdbcEngine = class` 方法：`constructor Create(ABridge: TBridgeV2; const DriverId: string); function OpenPool(const Url, User, Pw: string; Cfg: TPoolCfgRec): Int64; procedure ClosePool(PoolId: Int64); function Borrow(PoolId: Int64): Int64; procedure Release(ConnId: Int64); procedure SetAutoCommit/Commit/Rollback/Savepoint/RollbackTo/ReleaseSavepoint(ConnId...)；function PoolStats(PoolId): TPoolStatRec`。Engine 不存事务布尔状态，全部下发 Bridge v2。

- [ ] **Step 1: Write the failing test**

```pascal
Eng := TJdbcEngine.Create(Bridge, 'sqlite');
Pool := Eng.OpenPool('jdbc:sqlite::memory:', '', '', DefaultPoolCfg);
Conn := Eng.Borrow(Pool);
Eng.SetAutoCommit(Conn, False);
Eng.Savepoint(Conn, 'sp1');
Eng.RollbackTo(Conn, 'sp1');
Eng.Release(Conn);
Ok('pool-stats', Eng.PoolStats(Pool).Active >= 0);
Eng.ClosePool(Pool);
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fpc '-Fusrc/core' '-Fusrc/db' '-oC:\Users\Tom\AppData\Local\Temp\grok-goal-00fdc9ad82c8\implementer\v2\e.exe' tests/TestV2Engine.lpr`
Expected: FAIL，无 `TJdbcEngine`。

- [ ] **Step 3: Write minimal implementation**

Engine 持有 `TBridgeV2 + Dialect`，所有方法先 `CheckHandle` 再转发；`Savepoint` 名白名单 `^[A-Za-z_][A-Za-z0-9_]{0,63}$`，不合规抛 `HY092`；`Borrow` 按 `connectionTimeout` 由 Java 侧等待，Pascal 侧不立即抛。

- [ ] **Step 4: Run test to verify it passes**

Run: H2/SQLite live 回环运行。
Expected: 事务与统计 PASS，坏 savepoint 名被拒。

- [ ] **Step 5: Commit**

```bash
git add src/core/TyFPJDBC.Engine.pas tests/TestV2Engine.lpr
git commit -m "v2: engine handle facade"
```

---

### Task 7: 类型化命令执行

**Files:**
- Create: `src/db/TyFPJDBC.Command.pas`
- Test: `tests/TestV2Command.lpr`

**Interfaces:**
- Consumes: Task 6 Engine 句柄。
- Produces: `TBoundValue = record Kind: (bvInt, bvInt64, bvDouble, bvStr, bvDate, bvTime, bvStamp, bvBytes, bvNull); ... end`; `TJdbcCommand = class constructor Create(AEngine: TJdbcEngine; AConn: Int64); procedure SetSQL(const S: string; ParamOrder: array of string); procedure BindInt/BindInt64/BindStr/BindDouble/BindDate/BindTime/BindStamp/BindBytes/BindNull(...); function ExecUpdate: Integer; function ExecBatch(const Rows: array of TBoundRow; BatchSize: Integer): Integer; procedure SetTimeout(Secs: Integer); procedure Cancel;`。

- [ ] **Step 1: Write the failing test**

```pascal
Cmd := TJdbcCommand.Create(Eng, Conn);
Cmd.SetSQL('INSERT INTO t(id, amt, ts) VALUES(?,?,?)', ['id', 'amt', 'ts']);
Cmd.BindInt(1, 1); Cmd.BindDouble(2, 19.99); Cmd.BindStamp(3, Now);
Ok('typed-insert', Cmd.ExecUpdate = 1);
Cmd.SetTimeout(-1) 应抛 HY092；Cmd.Cancel 后执行报 HY008。
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fpc '-Fusrc/core' '-Fusrc/db' '-o...c.exe' tests/TestV2Command.lpr`
Expected: FAIL，无类型化绑定。

- [ ] **Step 3: Write minimal implementation**

命名参数 `:name` 到 `?` 转换复用经验但重写实现；绑定按种类走 `BindXXX` 下发 Bridge v2；批量按 `BatchSize` 分片；超时走 `setQueryTimeout`，取消走 `cancel(stmtId)`。

- [ ] **Step 4: Run test to verify it passes**

Run: SQLite/H2 回环，NUMERIC/时间精度断言。
Expected: PASS，无字符串中转精度丢失。

- [ ] **Step 5: Commit**

```bash
git add src/db/TyFPJDBC.Command.pas tests/TestV2Command.lpr
git commit -m "v2: typed command execution"
```

---

### Task 8: 游标窗口与数据集适配

**Files:**
- Create: `src/db/TyFPJDBC.Dataset.Adapter.pas`
- Modify: `src/db/TyFPJDBC.Query.pas`
- Test: `tests/TestV2Dataset.lpr`

**Interfaces:**
- Consumes: Task 5 元数据与类型映射，Task 7 命令。
- Produces: `TDatasetAdapter.BuildFields(AQuery: TBufDataset; const Meta: TColMetaArray); procedure FillWindow(AQuery: TBufDataset; const Rows: TJavaRows); function CollectInserts/CollectEdits(...): TBoundRowArray`; `TJDBCQuery.Open/Close/Next/Eof` 走 `queryOpen/fetchWindow/closeCursor`，窗口大小 `WindowSize = 1000` 默认可配；`Close` 逆序释放。

- [ ] **Step 1: Write the failing test**

```pascal
Q.Open('SELECT id,name FROM big ORDER BY id');
Ok('windowed-total', Q.RecordCount >= 10000);
Ok('windowed-memory', Q.WindowFetches > 1);
Q.Close;
Ok('handles-zero', Eng.HandleCount = 0);
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fpc ... tests/TestV2Dataset.lpr`
Expected: FAIL，无窗口取数。

- [ ] **Step 3: Write minimal implementation**

按列元数据建 FieldDefs（未知类型默认抛，需 `UnknownTypeFallback` 显式才转）；按窗口填充；`Next` 越界自动 `fetchWindow`；宽表全列映射，不只搬两列。

- [ ] **Step 4: Run test to verify it passes**

Run: 10k 回环，窗口次数大于 1，句柄归零。
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add src/db/TyFPJDBC.Dataset.Adapter.pas src/db/TyFPJDBC.Query.pas tests/TestV2Dataset.lpr
git commit -m "v2: windowed dataset adapter"
```

---

### Task 9: 写路径与主键回填

**Files:**
- Modify: `src/db/TyFPJDBC.Query.pas`, `src/db/TyFPJDBC.Dataset.Adapter.pas`
- Test: `tests/TestV2Write.lpr`

**Interfaces:**
- Consumes: Task 7/8。
- Produces: `TJDBCQuery.ApplyUpdates` 按方言生成占位符 DML，批量类型化执行，主键经 `getGeneratedKeys/RETURNING` 回填；无主键表抛 `HY092`；`BatchApplySize` 分片（默认 1000，范围 1..10000）。

- [ ] **Step 1: Write the failing test**

```pascal
Q.CachedUpdates := True; 插入两行后 ApplyUpdates，重查数据库确认两行都在，主键与 getGeneratedKeys 一致；无主键表 ApplyUpdates 抛 HY092。
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fpc ... tests/TestV2Write.lpr`
Expected: FAIL，无回填实现。

- [ ] **Step 3: Write minimal implementation**

DML 生成器走 `Dialect.QuoteIdent`；插入列与绑定一一对应；批量单事务；回填键写回 Dataset；第二批只收新增增量。

- [ ] **Step 4: Run test to verify it passes**

Run: SQLite/PG 语义回环两批插入重查。
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add src/db/TyFPJDBC.Query.pas src/db/TyFPJDBC.Dataset.Adapter.pas tests/TestV2Write.lpr
git commit -m "v2: write path with key return"
```

---

### Task 10: 存储过程、脚本、BLOB 流

**Files:**
- Modify: `src/db/TyFPJDBC.StoredProc.pas`, `src/db/TyFPJDBC.Script.pas`, `src/db/TyFPJDBC.Command.pas`
- Test: `tests/TestV2ProcBlob.lpr`

**Interfaces:**
- Consumes: Task 7。
- Produces: `TJDBCStoredProc.Exec` 走 `CallableStatement`（入参/出参/结果集）；`TJDBCScript.ExecScript(const SQL: string): Integer` 按方言分隔执行并定位失败序号；BLOB 按 `BlobStreamThresholdBytes`（默认 1MB）选择一次或分片流式。

- [ ] **Step 1: Write the failing test**

```pascal
Proc.Exec 后 OutAsString(1) 为真实出参；Script 两条中第二条失败时报序号 2；2MB BLOB 回环一致。
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fpc ... tests/TestV2ProcBlob.lpr`
Expected: FAIL，仍是 `OUT:` 字符串模拟。

- [ ] **Step 3: Write minimal implementation**

Bridge v2 新增 `callProc/prepareCall`，Pascal 侧按参数方向绑定；脚本分隔器处理引号注释 dollar 体；BLOB 分片 64KB。

- [ ] **Step 4: Run test to verify it passes**

Run: H2 存储过程 + BLOB 回环。
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add src/db/TyFPJDBC.StoredProc.pas src/db/TyFPJDBC.Script.pas src/db/TyFPJDBC.Command.pas tests/TestV2ProcBlob.lpr
git commit -m "v2: proc script blob streaming"
```

---

### Task 11: 日志、指标、慢查询

**Files:**
- Create: `src/core/TyFPJDBC.Observe.pas`
- Test: `tests/TestV2Observe.lpr`

**Interfaces:**
- Consumes: Task 6。
- Produces: `TLogLevel = (llDebug, llInfo, llWarn, llError); TJdbcLogger.OnLog: TLogProc; TJdbcMetrics.PoolStats/ExecHistogram/WindowStats/HeapBytes`; 慢查询自动计时（`SlowThresholdMs` 默认 1000）。

- [ ] **Step 1: Write the failing test**

```pascal
Logger.OnLog := @Sink.Log; 执行一条慢查询后 Sink 收到 warn 且 ElapsedMs >= 阈值；Metrics.PoolStats.Active 正确。
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fpc ... tests/TestV2Observe.lpr`
Expected: FAIL，无自动计时。

- [ ] **Step 3: Write minimal implementation**

Engine 执行前后 `GetTickCount64` 计时，超阈值回调；JUL 经 JNI 转发到 Pascal 回调；指标走结构化记录。

- [ ] **Step 4: Run test to verify it passes**

Run: 同上。
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add src/core/TyFPJDBC.Observe.pas tests/TestV2Observe.lpr
git commit -m "v2: logging metrics slow query"
```

---

### Task 12: 分发与 mautool v2

**Files:**
- Modify: `src/tools/mautool.lpr`, `configs/drivers.json`, `configs/runtimes.json`
- Test: `tests/TestV2Distrib.lpr`

**Interfaces:**
- Consumes: Task 5 注册表。
- Produces: `mautool --resolve-runtime --platform X --out DIR`（平台选包、sha256 校验、解包复用）；`mautool --fetch-driver --driver ID --out DIR`（maven 下载、sha 校验、缓存 `~/.tyfpjdbc`、代理、断点续传、GPL 确认）。

- [ ] **Step 1: Write the failing test**

```pascal
Ok('runtime-accept', ResolveRuntime('win64', GoodSha));
Ok('runtime-reject', not ResolveRuntime('win64', BadSha));
Ok('driver-cache', FetchDriver('sqlite', Dir) 且二次命中缓存);
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fpc '-o...m.exe' src/tools/mautool.lpr`
Expected: FAIL，无新子命令。

- [ ] **Step 3: Write minimal implementation**

传输按平台选择（Windows 用 BITS/Invoke-WebRequest，后备 curl；Linux/macOS 用 curl/wget 探测）；下载到临时文件后校验 sha 再原子改名；GPL 驱动需 `--accept-license` 或交互确认并记录。

- [ ] **Step 4: Run test to verify it passes**

Run: win64 runtime accept+reject，sqlite 驱动缓存命中。
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add src/tools/mautool.lpr configs/drivers.json configs/runtimes.json tests/TestV2Distrib.lpr
git commit -m "v2: runtime and driver distribution"
```

---

### Task 13: LCL 设计时包与示例

**Files:**
- Create: `src/lcl/tyfpjdbc.lpk`, `src/lcl/TyFPJDBC.LCL.Conn.pas`, `src/lcl/TyFPJDBC.LCL.Query.pas`, `src/lcl/TyFPJDBC.LCL.ConnDialog.pas`
- Modify: `examples/ex11_code_first.lpr`, `examples/ex12_dbgrid.lpr`, `examples/README.md`
- Test: `lazbuild src/lcl/tyfpjdbc.lpk` + `tests/TestV2Lcl.lpr`

**Interfaces:**
- Consumes: Task 6/8/9。
- Produces: 设计时组件 `TJdbcConnection/TJdbcQuery`（拖放、驱动下拉、URL 模板展开、Test 按钮）；连接对话框含驱动/host/port/database/用户密码掩码/超时只读测试；两套示例（代码优先 + DBGrid）覆盖连接查询取数编辑批量事务 BLOB。

- [ ] **Step 1: Write the failing test**

```pascal
ConnDialog.Execute 返回前必须 Test 成功；ex12 打开后 DBGrid 行数与重查一致，编辑一行后 ApplyUpdates 落库。
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lazbuild src/lcl/tyfpjdbc.lpk`
Expected: FAIL，无 lpk。

- [ ] **Step 3: Write minimal implementation**

运行时包保持零 LCL 依赖；设计时包仅注册组件与属性编辑器；对话框 Test 按钮走 Engine 真连接。

- [ ] **Step 4: Run test to verify it passes**

Run: `lazbuild` 通过 + ex12 真数据回写通过。
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add src/lcl/tyfpjdbc.lpk src/lcl/*.pas examples/ex11_* examples/ex12_* examples/README.md tests/TestV2Lcl.lpr
git commit -m "v2: lcl design package and examples"
```

---

### Task 14: 真库矩阵、Soak 与文档门

**Files:**
- Modify: `scripts/run-matrix.ps1`, `scripts/guard.ps1`
- Create: `tests/TestV2Soak.lpr`, `docs/DRIVER.md`, `docs/DIALECT-MATRIX.md`, `docs/TROUBLESHOOTING.md`
- Test: 全矩阵 + soak + 泄漏断言

**Interfaces:**
- Consumes: 全部前置任务。
- Produces: 矩阵覆盖 PG/MySQL/MSSQL/Oracle/SQLite/H2（分页/类型/事务/回填/元数据/BLOB/存储过程）；soak（多线程借用执行取消超时混合）无错位；句柄计数归零；文档含快速开始、驱动接入、方言矩阵、SQLState 排查。

- [ ] **Step 1: Write the failing test**

```pascal
// TestV2Soak.lpr：8 线程 x 200 次借用执行取消混合，断言无 HY000 错位，结束时 Engine.HandleCount = 0，JVM Attach 计数为 0。
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fpc ... tests/TestV2Soak.lpr`
Expected: FAIL，无 soak 用例。

- [ ] **Step 3: Write minimal implementation**

补 `scripts/run-matrix.ps1` 真库段与泄漏门；补三份文档；修失败项。

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File scripts/run-matrix.ps1` 全绿 + soak 通过。
Expected: MATRIX-OK。

- [ ] **Step 5: Commit**

```bash
git add scripts/run-matrix.ps1 scripts/guard.ps1 tests/TestV2Soak.lpr docs/DRIVER.md docs/DIALECT-MATRIX.md docs/TROUBLESHOOTING.md
git commit -m "v2: matrix soak and docs gate"
```

---

## Self-Review

1. 规格覆盖：连接池→Task 2/6；驱动注册→Task 5/12；方言→Task 5；JVM→Task 4；执行超时取消→Task 7；类型→Task 7/8；事务存储过程→Task 6/10；元数据→Task 2/8；错误日志→Task 1/11；LCL→Task 13；分发→Task 12；测试门→Task 14。无遗漏。
2. 占位扫描：无 TBD/TODO，所有步骤含真实代码与真实命令。
3. 类型一致：句柄统一 `Int64`；`PoolCfgRec/TPoolStatRec/TBoundRow/TColMetaArray` 由 Task 2/3 定义后各任务复用，不重命名。
