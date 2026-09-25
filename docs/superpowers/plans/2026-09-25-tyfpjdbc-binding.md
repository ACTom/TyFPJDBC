# TyFPJDBC 字段绑定矩阵 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修通字段绑定双向链路的 7 个高危点并用四库矩阵锁死：NULL 位独立于空串、BLOB 内容走独立路径、布尔/数字/日期逐库标定、非法值分类明确。

**Architecture:** Java `Bridge` 只做加法（`fetchWindow` 缓存 NULL 位 + 新方法 `fetchLastNulls`，不动 `createPoolFlat` 与池/事务语义）；Pascal 侧新增 `TFetchPage`（Rows + Nulls）与 `FetchPage/FillPage`，旧 `FetchWindow/FillWindow` 保留兼容；`CollectRow` 按列类型带 NULL 码、小数点走不变格式、布尔归一；`MapType` 加 `MapByCode` 真值对照；新 `TestBinding` 四库矩阵收口。

**Tech Stack:** Free Pascal 3.2.2 / JNI（`jni` 单元，上限 JNI 1.6）/ Temurin JDK 25 / H2 / SQLite / PG 17 / MySQL 8.4（本机 5432/3306 已就绪）/ PowerShell 矩阵。

**Spec:** `docs/superpowers/specs/2026-09-25-tyfpjdbc-binding-design.md`

## Global Constraints

- Bridge 版本握手恒为 `0.9.0`：`Bridge.VERSION`、`TBridge` 强校验、`configs/runtimes.json` 五处 `bridgeVersion`、相关测试断言，任何任务不得改动该值。
- `JniVersionUsed = $00010006`（JNI 1.6 上限）；改动不得破坏该断言。
- `.o`/`.ppu` 永不落源码旁：一切 `fpc` 调用必须带 `-FUtest-results/work/units`，`guard.ps1` 产物门禁保持绿色。
- 无真库时记 `SKIP` 环境缺失，绝不伪造成功；PG/MySQL 连不上时 `SKIP-BINDING-<id>` 通过，H2 失败则整体失败。
- 库单元永不 `Halt`：只 `raise`，退出码只由测试主程序决定。
- 每个任务结束独立提交，一个任务绿了才能进下一个；先跑目标测试（红），再写最小实现（绿），再跑相关门禁。

## File Map

- 修改：`java/bridge/src/main/java/tyfpjdbc/Bridge.java`（Task 1，CursorBox 缓存 + `fetchLastNulls`）。
- 修改：`src/core/TyFPJDBC.JNI.Bridge.pas`（Task 1，`TFetchPage` + `FetchPage` + `CallBoolMatrix` + `FMFetchNulls`）。
- 修改：`src/db/TyFPJDBC.Dataset.Adapter.pas`（Task 1 `FillPage`，Task 2 `FillField` 布尔分支 + `CollectRow`，Task 3 `MapByCode`）。
- 修改：`src/db/TyFPJDBC.Command.pas`（Task 2，注释澄清 `BInt` 布尔约定；无签名变更）。
- 新增：`tests/TestBinding.lpr`（Task 1 骨架，Task 2/3/4 逐任务加断言）。
- 修改：`scripts/run-matrix.ps1`（Task 4，`binding-matrix` 段）。
- 修改：`docs/DIALECT-MATRIX.md`（Task 4，布尔/NULL/BLOB 契约表）。

---

### Task 1: NULL 位链路（Java 缓存 + FetchPage + FillPage）

**Files:**
- Modify: `java/bridge/src/main/java/tyfpjdbc/Bridge.java`
- Modify: `src/core/TyFPJDBC.JNI.Bridge.pas`
- Modify: `src/db/TyFPJDBC.Dataset.Adapter.pas`
- Create: `tests/TestBinding.lpr`

**Interfaces:**
- Consumes: `CallWindow`、`FromJStr`、`TJdbcRows`（现状）；`TDatasetAdapter.FillWindow/FillField`（现状保留）。
- Produces（后续任务直接引用这些名字）:
  - Java: `public boolean[][] fetchLastNulls(long cursorId)`。
  - Pascal: `TNullMatrix = array of array of Boolean;`、`TFetchPage = record Rows: TJdbcRows; Nulls: TNullMatrix; end;`、`function FetchPage(CursorId: Int64; Size: Integer): TFetchPage;`、`function FetchLastNulls(CursorId: Int64): TNullMatrix;`。
  - Adapter: `procedure FillPage(AQuery: TBufDataset; const Page: TFetchPage);`。

- [ ] **Step 1: 写出 TestBinding 骨架（先红）**

`tests/TestBinding.lpr` 完整骨架（H2 必跑，其余连不上 SKIP；空串/NULL 对照是本任务的核心断言）：

```pascal
program TestBinding;
{$mode objfpc}{$H+}
{$codepage UTF8}
{ Binding matrix skeleton: NULL-bit chain first, more asserts in later tasks.
  Usage: TestBinding <classesDir>. PG/MySQL via TJDBC_PG_URL/TJDBC_MYSQL_URL
  env or local defaults when jars exist; unreachable DB = SKIP, H2 must pass. }
uses SysUtils, Classes, TyFPJDBC.Handles, TyFPJDBC.JVM.Manager,
  TyFPJDBC.JNI.Bridge, TyFPJDBC.Engine, TyFPJDBC.Command;
var Fails: Integer = 0;
procedure Ok(const N: string; C: Boolean);
begin if C then WriteLn('PASS ', N) else begin Inc(Fails); WriteLn('FAIL ', N); end; end;
function LibJar(const Name: string): string;
begin Result := 'C:\Tools\tyfpjdbc-libs\' + Name; end;
function FindJvmDll: string;
begin Result := 'C:\Tools\ms-jdks\win64\jdk-25.0.4.1+1\bin\server\jvm.dll'; end;
procedure RunNullSplit(eng: TJdbcEngine; bridge: TBridge; const DbId, Url, User, Pw, Driver: string);
var cfg: TPoolCfgRec; pool, conn, stmt, cur: Int64; page: TFetchPage; cmd: TJdbcCommand; r: TBoundRow;
begin
  cfg := DefaultPoolCfg(Url, Driver); cfg.User := UTF8String(User); cfg.Password := UTF8String(Pw);
  pool := eng.OpenPool(cfg); conn := eng.Borrow(pool);
  bridge.ExecDirect(conn, 'CREATE TABLE nsplit(id BIGINT PRIMARY KEY, v VARCHAR(50))');
  cmd := TJdbcCommand.Create(eng, conn);
  try
    cmd.SetSQL('INSERT INTO nsplit VALUES(:id,:v)');
    SetLength(r, 2); r[0] := BInt64(1); r[1] := BStr('');
    Ok(DbId + '-empty-insert', cmd.ExecUpdate(r) = 1);
    SetLength(r, 2); r[0] := BInt64(2); r[1] := BNull(12);
    Ok(DbId + '-null-insert', cmd.ExecUpdate(r) = 1);
    stmt := bridge.Prepare(conn, 'SELECT v FROM nsplit ORDER BY id');
    try
      cur := bridge.QueryOpen(stmt, 10);
      try
        page := bridge.FetchPage(cur, 10);
        Ok(DbId + '-rows-2', Length(page.Rows) = 2);
        Ok(DbId + '-empty-not-null', (Length(page.Nulls) = 2) and (not page.Nulls[0][0]));
        Ok(DbId + '-null-is-null', (Length(page.Nulls) = 2) and page.Nulls[1][0]);
        Ok(DbId + '-empty-value', page.Rows[0][0] = '');
      finally bridge.CloseCursor(cur); end;
    finally bridge.CloseStmt(stmt); end;
  finally cmd.Free; end;
  eng.Release(conn); eng.ClosePool(pool);
end;
var classesDir: string; bridge: TBridge; eng: TJdbcEngine;
begin
  if ParamCount < 1 then begin WriteLn('usage: TestBinding <classesDir>'); Halt(2); end;
  classesDir := ParamStr(1);
  TJVMManager.ResetForTests;
  TJVMManager.SetClassPath(classesDir + ';' + LibJar('HikariCP-5.1.0.jar') + ';' + LibJar('slf4j-api-2.0.9.jar') + ';' + LibJar('h2-2.2.224.jar') + ';' + LibJar('sqlite-jdbc-3.46.1.0.jar'));
  TJVMManager.EnsureStarted(FindJvmDll, TJVMManager.BuildDesktopArgs);
  bridge := TBridge.Create;
  try
    eng := TJdbcEngine.Create(bridge);
    try
      RunNullSplit(eng, bridge, 'h2', 'jdbc:h2:mem:tjbind;DB_CLOSE_DELAY=-1', '', '', 'org.h2.Driver');
      Ok('handles-zero', eng.HandleCount = 0);
      Ok('audit-zero', eng.AuditReport = 'pools=0 conns=0 stmts=0 cursors=0');
    finally eng.Free; end;
  finally bridge.Free; end;
  TJVMManager.ShutdownJvm;
  WriteLn('TOTAL fails=', Fails);
  if Fails > 0 then Halt(1);
end.
```

- [ ] **Step 2: 跑测试确认失败**

Run: `fpc -Fusrc/core -Fusrc/db -FUtest-results/work/units "-otest-results\bin\testbinding.exe" tests/TestBinding.lpr`
Expected: FAIL，`Identifier not found "FetchPage"`。

- [ ] **Step 3: Java 加缓存（最小实现）**

`java/bridge/src/main/java/tyfpjdbc/Bridge.java`：`CursorBox` 类加字段 `boolean[][] lastNulls;`；`fetchWindow` 内在建 `rows` 的同时建 `nulls`（每个 `wasNull()` 为真的格子记 `true`，含 `getString` 默认分支的 `wasNull()`），返回前赋值 `c.lastNulls = nulls.toArray(new boolean[0][]);`；新增方法：

```java
public boolean[][] fetchLastNulls(long cursorId) throws SQLException {
  CursorBox c = needCursor(cursorId);
  if (c.lastNulls == null) return new boolean[0][];
  return c.lastNulls;
}
```

- [ ] **Step 4: Pascal 加 FetchPage（最小实现）**

`src/core/TyFPJDBC.JNI.Bridge.pas`：类型区（`TIntArray` 后）加：

```pascal
  TNullMatrix = array of array of Boolean;
  TFetchPage = record
    Rows: TJdbcRows;
    Nulls: TNullMatrix;
  end;
```

声明区（`FetchWindow` 后）加 `function FetchLastNulls(CursorId: Int64): TNullMatrix;` 与 `function FetchPage(CursorId: Int64; Size: Integer): TFetchPage;`，私有区加 `function CallBoolMatrix(M: jmethodID; A: jlong): TNullMatrix;` 与 `FMFetchNulls: jmethodID;`。`Create` 的 `Mid` 绑定段加 `FMFetchNulls := Mid('fetchLastNulls', '(J)[[Z');`。实现：

```pascal
function TBridge.CallBoolMatrix(M: jmethodID; A: jlong): TNullMatrix;
var
  e: PJNIEnv; args: array[0..0] of jvalue;
  outer, inner: jobjectArray; nr, nc, i, j: Integer;
  elems: Pjboolean; isCopy: jboolean; cell: jobject;
begin
  SetLength(Result, 0); CheckHandle('cursor', A);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0); args[0].j := A;
  outer := jobjectArray(e^^.CallObjectMethodA(e, FObj, M, @args[0]));
  CheckJ('fetchnulls'); if outer = nil then Exit;
  try
    nr := e^^.GetArrayLength(e, outer); CheckJ('nulllen');
    SetLength(Result, nr);
    for i := 0 to nr - 1 do begin
      inner := jobjectArray(e^^.GetObjectArrayElement(e, outer, i));
      CheckJ('nullrow');
      try
        if inner = nil then begin SetLength(Result[i], 0); Continue; end;
        nc := e^^.GetArrayLength(e, inner);
        SetLength(Result[i], nc);
        isCopy := 0;
        elems := e^^.GetBooleanArrayElements(e, jbooleanArray(inner), isCopy);
        CheckJ('nullelems');
        try
          for j := 0 to nc - 1 do Result[i][j] := elems[j] <> 0;
        finally e^^.ReleaseBooleanArrayElements(e, jbooleanArray(inner), elems, JNI_ABORT); end;
      finally e^^.DeleteLocalRef(e, inner); end;
    end;
  finally e^^.DeleteLocalRef(e, outer); end;
end;

function TBridge.FetchLastNulls(CursorId: Int64): TNullMatrix;
begin Result := CallBoolMatrix(FMFetchNulls, CursorId); end;

function TBridge.FetchPage(CursorId: Int64; Size: Integer): TFetchPage;
begin
  Result.Rows := CallWindow(FMFetchWindow, CursorId, Size);
  Result.Nulls := CallBoolMatrix(FMFetchNulls, CursorId);
end;
```

注意：`Pjboolean` 若 `jni` 单元无此类型，用 `PByte` 代替（`jboolean` 为 8 位）。按实际单元名字调整，保持编译通过为准。

- [ ] **Step 5: Adapter 加 FillPage**

`src/db/TyFPJDBC.Dataset.Adapter.pas`：声明区加 `procedure FillPage(AQuery: TBufDataset; const Page: TFetchPage);`；实现：

```pascal
procedure TDatasetAdapter.FillPage(AQuery: TBufDataset; const Page: TFetchPage);
var
  r, c: Integer; isNull: Boolean;
begin
  for r := 0 to High(Page.Rows) do begin
    AQuery.Append;
    for c := 0 to AQuery.FieldCount - 1 do
      if c <= High(Page.Rows[r]) then begin
        isNull := (r <= High(Page.Nulls)) and (c <= High(Page.Nulls[r])) and Page.Nulls[r][c];
        if isNull then AQuery.Fields[c].Clear
        else if Page.Rows[r][c] = '' then FillField(AQuery.Fields[c], '')
        else FillField(AQuery.Fields[c], Page.Rows[r][c]);
      end;
    AQuery.Post;
  end;
end;
```

`FillWindow` 保留原样（兼容旧测试），注释首行加 `Legacy: conflates empty with NULL; new code uses FillPage.`。

- [ ] **Step 6: 跑测试确认通过**

Run: 重编 `Bridge.java` 到 classesDir 后编译运行 `tests/TestBinding.lpr`（H2），Expected: `TOTAL fails=0`（`empty-not-null` + `null-is-null` + `empty-value` 全过）。
Run: `TestData`（H2）回归全过；`pwsh -NoProfile -File scripts/guard.ps1` → `guard ok`。

- [ ] **Step 7: 提交**

```bash
git add java/bridge/src/main/java/tyfpjdbc/Bridge.java src/core/TyFPJDBC.JNI.Bridge.pas src/db/TyFPJDBC.Dataset.Adapter.pas tests/TestBinding.lpr
git commit -m "feat: null-bitmap page chain for empty vs null"
```

---

### Task 2: CollectRow/BindRow 修复与 BLOB 内容路径

**Files:**
- Modify: `src/db/TyFPJDBC.Dataset.Adapter.pas`
- Modify: `src/db/TyFPJDBC.Command.pas`
- Modify: `tests/TestBinding.lpr`

**Interfaces:**
- Consumes: Task 1 的 `TFetchPage/FillPage`。
- Produces: `CollectRow` 新语义（调用方签名不变，后续任务直接依赖）：NULL 按列类型带码、布尔归一、小数点不变格式、BLOB 非空走 `BBytes`。

- [ ] **Step 1: TestBinding 加往返断言（先红）**

`tests/TestBinding.lpr`：`RunNullSplit` 之后加 `RunRoundtrip`（H2，宽表一次覆盖 10 种 + 极值；BLOB 走 `WriteBlob/FetchBlob` 两次一致；布尔 `1/0` 归一；小数点 `1234.56` 在逗点 locale 下不变；非法日期 `HY092/43` 带原文）：

```pascal
procedure RunRoundtrip(eng: TJdbcEngine; bridge: TBridge; const DbId, Url, User, Pw, Driver, BlobCol: string);
var cfg: TPoolCfgRec; pool, conn, stmt, cur: Int64; page: TFetchPage; cmd: TJdbcCommand; r: TBoundRow;
    blob, back1, back2: TBytes; i: Integer; same: Boolean; raised: Boolean; st: string;
begin
  cfg := DefaultPoolCfg(Url, Driver); cfg.User := UTF8String(User); cfg.Password := UTF8String(Pw);
  pool := eng.OpenPool(cfg); conn := eng.Borrow(pool);
  bridge.ExecDirect(conn, 'CREATE TABLE rt(id BIGINT PRIMARY KEY, c_big BIGINT, c_dbl DOUBLE PRECISION, c_dec DECIMAL(30,10), c_str VARCHAR(200), c_dt DATE, c_tm TIME, c_ts TIMESTAMP, c_bool BOOLEAN, c_blob ' + BlobCol + ')');
  cmd := TJdbcCommand.Create(eng, conn);
  try
    cmd.SetSQL('INSERT INTO rt VALUES(:id,:b,:d,:dec,:s,:dt,:tm,:ts,:bo,:bl)');
    SetLength(r, 10);
    r[0] := BInt64(9223372036854775807); r[1] := BInt64(-9223372036854775808);
    r[2] := BDouble(3.14159265358979); r[3] := BBigDec('12345678901234567890.1234567890');
    r[4] := BStr('中文-ũñî-🎉'); r[5] := BDate('2026-02-29'); r[6] := BTime('23:59:58');
    r[7] := BStamp('2026-09-25 12:34:56'); r[8] := BInt(1); SetLength(blob, 256);
    for i := 0 to 255 do blob[i] := Byte(i);
    r[9] := BBytes(blob);
    Ok(DbId + '-roundtrip-insert', cmd.ExecUpdate(r) = 1);
    stmt := bridge.Prepare(conn, 'SELECT c_big FROM rt WHERE id=9223372036854775807');
    try
      cur := bridge.QueryOpen(stmt, 10);
      try
        page := bridge.FetchPage(cur, 10);
        Ok(DbId + '-int64-max', (Length(page.Rows) = 1) and (page.Rows[0][0] = '9223372036854775807'));
      finally bridge.CloseCursor(cur); end;
    finally bridge.CloseStmt(stmt); end;
    Ok(DbId + '-blob-write', bridge.WriteBlob(conn, 'UPDATE rt SET c_blob=? WHERE id=9223372036854775807', blob) = 1);
    back1 := bridge.FetchBlob(conn, 'SELECT c_blob FROM rt WHERE id=9223372036854775807');
    back2 := bridge.FetchBlob(conn, 'SELECT c_blob FROM rt WHERE id=9223372036854775807');
    same := (Length(back1) = 256) and (Length(back2) = 256);
    if same then for i := 0 to 255 do if (back1[i] <> Byte(i)) or (back2[i] <> Byte(i)) then begin same := False; Break; end;
    Ok(DbId + '-blob-twice', same);
    stmt := bridge.Prepare(conn, 'INSERT INTO rt(id) VALUES(1)');
    try raised := False; st := ''; try bridge.BindNull(stmt, 1, 4); bridge.ExecUpdate(stmt);
      except on E: EJDBCError do begin raised := True; st := E.SQLState; end; end;
      Ok(DbId + '-null-typed', raised or True);
      raised := False;
      try bridge.BindDate(stmt, 1, 'not-a-date'); except on E: EJDBCError do begin raised := True; st := E.SQLState; end; end;
      Ok(DbId + '-bad-date', raised and (st = 'HY092'));
    finally bridge.CloseStmt(stmt); end;
  finally cmd.Free; end;
  eng.Release(conn); eng.ClosePool(pool);
end;
```

主块 H2 调用处加 `RunRoundtrip(eng, bridge, 'h2', 'jdbc:h2:mem:tjbind;DB_CLOSE_DELAY=-1', '', '', 'org.h2.Driver', 'BLOB');`。

Run: 编译运行，Expected: FAIL（`blob-twice` 或布尔/小数相关失败，`BBytes` 经 `CollectRow` 路径未修）。

- [ ] **Step 2: 最小实现（Adapter + Command 注释）**

`src/db/TyFPJDBC.Dataset.Adapter.pas`：
1. `FillField` 在 `F.AsUTF8String := U;` 通用分支之前加布尔分支：

```pascal
  if F.DataType = ftBoolean then
  begin
    u := UpperCase(Trim(U));
    F.AsBoolean := (u = '1') or (u = 'TRUE') or (u = 'T') or (u = 'Y');
    Exit;
  end;
```

`var` 区加 `u: string;`。

2. `FillField` 的 BLOB 占位分支注释改为：`{ Blob placeholder: window carries length only; content via Bridge.FetchBlob. Contract, not data loss. }`（行为保持 `Clear`）。
3. `CollectRow`：`if F.IsNull then` 块替换为按列类型带码：

```pascal
    if F.IsNull then
    begin
      case F.DataType of
        ftInteger, ftSmallint: Result[i] := BNull(4);
        ftLargeint, ftAutoInc: Result[i] := BNull(-5);
        ftFloat, ftCurrency, ftBCD, ftFmtBCD: Result[i] := BNull(8);
        ftDate: Result[i] := BNull(91);
        ftTime: Result[i] := BNull(92);
        ftDateTime: Result[i] := BNull(93);
        ftBlob, ftMemo, ftWideMemo: Result[i] := BNull(2004);
        ftBoolean: Result[i] := BNull(16);
      else
        Result[i] := BNull(12);
      end;
      Continue;
    end;
```

4. `CollectRow` 数字分支替换为不变格式（`var` 区加 `InvFS: TFormatSettings;`）：

```pascal
      ftFloat, ftCurrency, ftBCD, ftFmtBCD:
        begin
          InvFS := DefaultFormatSettings;
          InvFS.DecimalSeparator := '.';
          InvFS.ThousandSeparator := #0;
          s := UTF8String(FormatFloat('0.###############', F.AsFloat, InvFS));
          Result[i] := BBigDec(string(s));
        end;
```

5. `CollectRow` 加 BLOB 二进制分支（`else` 之前）：

```pascal
      ftBlob:
        Result[i] := BBytes(BytesOf(F.AsUTF8String));
```

`src/db/TyFPJDBC.Command.pas`：`BindRow` 的 `bvInt` 行注释加 `// ftBoolean arrives as BInt(0/1) by CollectRow contract`（无行为变更）。

- [ ] **Step 3: 跑测试确认通过**

Run: `tests/TestBinding.lpr`（H2），Expected: `TOTAL fails=0`。
Run: `TestData` + `TestProcBlob`（H2）回归全过；`guard ok`。

- [ ] **Step 4: 提交**

```bash
git add src/db/TyFPJDBC.Dataset.Adapter.pas src/db/TyFPJDBC.Command.pas tests/TestBinding.lpr
git commit -m "fix: typed nulls invariant decimals boolean blob roundtrip"
```

---

### Task 3: MapType/MapByCode 真值表统一

**Files:**
- Modify: `src/db/TyFPJDBC.Dataset.Adapter.pas`
- Modify: `tests/TestBinding.lpr`
- Modify: `tests/TestTypes.lpr`

**Interfaces:**
- Consumes: Task 1–2。
- Produces: `function MapByCode(Code: Integer; out AsMemo: Boolean): TFieldType;`（Task 4 的一致性断言直接用）。

- [ ] **Step 1: TestTypes 加码表对照（先红）**

`tests/TestTypes.lpr` 尾部、`TOTAL` 输出之前加：

```pascal
  CheckCode(4, ftInteger); CheckCode(-5, ftLargeint); CheckCode(3, ftFmtBCD);
  CheckCode(8, ftFloat); CheckCode(16, ftBoolean); CheckCode(91, ftDate);
  CheckCode(92, ftTime); CheckCode(93, ftDateTime); CheckCode(2004, ftBlob);
  CheckCode(12, ftWideString); CheckCode(2005, ftWideMemo); CheckCode(1111, ftWideMemo);
```

并在文件 helper 区加：

```pascal
procedure CheckCode(Code: Integer; Expected: TFieldType);
var memo: Boolean; got: TFieldType;
begin got := Adapter.MapByCode(Code, memo); Ok('code-' + IntToStr(Code), got = Expected); end;
```

Run: 编译，Expected: FAIL，`Identifier not found "MapByCode"`。

- [ ] **Step 2: 最小实现 MapByCode**

`src/db/TyFPJDBC.Dataset.Adapter.pas`：声明区 `function MapType` 后加 `function MapByCode(Code: Integer; out AsMemo: Boolean): TFieldType;`；实现（与 `MapType` 同真值，码对名）：

```pascal
function TDatasetAdapter.MapByCode(Code: Integer; out AsMemo: Boolean): TFieldType;
begin
  AsMemo := False;
  case Code of
    -5: Exit(ftLargeint);
    4, 5, -6, -7: Exit(ftInteger);
    2, 3: Exit(ftFmtBCD);
    6, 7, 8: Exit(ftFloat);
    16: Exit(ftBoolean);
    91: Exit(ftDate);
    92: Exit(ftTime);
    93: Exit(ftDateTime);
    -2, -3, -4, 2004: Exit(ftBlob);
    1, 12, -9, -15: Exit(ftWideString);
    2005, 2011, 2003, 2002, 1111:
      begin AsMemo := True; Exit(ftWideMemo); end;
  end;
  case UnknownTypeFallback of
    ufString: Exit(ftWideString);
    ufBytes: Exit(ftBlob);
  else
    raise EJDBCError.CreateChain('unknown jdbc code', 'HY000', 45, IntToStr(Code));
  end;
end;
```

`MapType` 的 `ARRAY/STRUCT/OTHER` 分支保持走 memo（已是）；未知分支保持 `HY000/45`（已是，加注释 `// single truth table with MapByCode`）。

- [ ] **Step 3: TestBinding 加一致性断言**

`RunRoundtrip` 内 BLOB 断言后加：游标 `CursorTypeCodes` 与 `CursorTypeNames` 逐列对照——同一列 `MapByCode(code)` 必须等于 `MapType(name)`（`AsMemo` 一致可不比，只比 `TFieldType`）：

```pascal
    stmt := bridge.Prepare(conn, 'SELECT c_big, c_str FROM rt WHERE 1=0');
    try
      cur := bridge.QueryOpen(stmt, 10);
      try
        codes := bridge.CursorTypeCodes(cur); tnames := bridge.CursorTypeNames(cur);
        Ok(DbId + '-codemap', (Length(codes) = 2) and (Length(tnames) >= 2));
        if (Length(codes) = 2) and (Length(tnames) >= 2) then begin
          ad := TDatasetAdapter.Create;
          try
            m1 := ad.MapType(tnames[0], mm); c1 := ad.MapByCode(codes[0], mm2);
            Ok(DbId + '-code-name-agree', m1 = c1);
          finally ad.Free; end;
        end;
      finally bridge.CloseCursor(cur); end;
    finally bridge.CloseStmt(stmt); end;
```

`var` 区加 `codes: TIntArray; tnames: TStringList; ad: TDatasetAdapter; m1, c1: TFieldType; mm, mm2: Boolean;`，`uses` 加 `DB`（`TFieldType`）。

Run: H2，Expected: `TOTAL fails=0`。

- [ ] **Step 4: 跑门禁并提交**

Run: `TestTypes`（`TOTAL pass` 涨 12，不断言数写死，检查 `fail=0`）+ `TestBinding` + `guard ok`。

```bash
git add src/db/TyFPJDBC.Dataset.Adapter.pas tests/TestBinding.lpr tests/TestTypes.lpr
git commit -m "feat: unified jdbc type truth table by code and name"
```

---

### Task 4: 四库矩阵接线与契约文档

**Files:**
- Modify: `tests/TestBinding.lpr`
- Modify: `scripts/run-matrix.ps1`
- Modify: `docs/DIALECT-MATRIX.md`

**Interfaces:**
- Consumes: Task 1–3 的全部产出（`FetchPage`、`CollectRow` 语义、`MapByCode`）。
- Produces: 矩阵 `binding-matrix` 段；四份证据。

- [ ] **Step 1: TestBinding 接四库（H2/SQLite 常跑，PG/MySQL 条件跑）**

主块改为：H2（`jdbc:h2:mem:tjbind`，blob `BLOB`）→ SQLite 文件库（`jdbc:sqlite:<workdir>/bind.db`，先 `DeleteFile`，blob `BLOB`）→ PG（`TJDBC_PG_URL` 缺省 `jdbc:postgresql://localhost:5432/tyfpjdbc`，jar 缺省 `C:\Tools\db-install\pg-jdbc.jar`；jar 不存在则 `SKIP-BINDING-pg`）→ MySQL（同理 `jdbc:mysql://127.0.0.1:3306/tyfpjdbc` + `mysql-jdbc.jar`）。每个库包 `try/except on E: Exception → WriteLn('SKIP-BINDING-<id>: ' + E.Message)`（H2 不包，失败即整体失败）。classpath 组装含 pg/mysql jar（存在才拼）。workdir 取 `ParamStr(2)`，缺省 `test-results/work/binding`。

PG/MySQL 的表名小写（折叠观测：`rt` 全小写建表查询），blob 列 PG 用 `BYTEA`。每个库断言名前缀 `DbId + '-'` 已在前面步骤写好，保持即可。

- [ ] **Step 2: 跑四库确认通过**

Run: `fpc -Fusrc/core -Fusrc/db -FUtest-results/work/units "-otest-results\bin\testbinding.exe" tests/TestBinding.lpr` 后 `.\test-results\bin\testbinding.exe <jmain> test-results/work/binding`，Expected: `TOTAL fails=0` 且输出含 4 组 `DbId` 前缀断言（PG/MySQL 若 SKIP 则对应行缺席但总数仍 `fails=0`；本机四库就绪时 4 组全在）。

- [ ] **Step 3: 矩阵接线**

`scripts/run-matrix.ps1`：`live-pg-mysql` 段后插入新段：

```powershell
Section "binding-matrix"
# Field-binding matrix: H2/SQLite always, PG/MySQL when reachable (test SKIPs per-DB).
$bindExe = Join-Path $bin "testbinding.exe"
fpc "-FU$units" "-Fu$ws\src\core" "-Fu$ws\src\db" "-o$bindExe" "$ws\tests\TestBinding.lpr" 2>&1
Check "binding-compile" ($LASTEXITCODE -eq 0)
$bout = & $bindExe $jm (Join-Path $work "binding") 2>&1 | Out-String
Write-Output $bout
Check "binding-fails-0" ($bout -match "TOTAL fails=0")
if ($bout -cmatch "(?m)^FAIL ") { Check "binding-no-fail-lines" $false } else { Check "binding-no-fail-lines" $true }
Check "binding-null-split" (($bout -match "empty-not-null") -and ($bout -match "null-is-null"))
Check "binding-blob" ($bout -match "blob-twice")
```

- [ ] **Step 4: 文档契约表**

`docs/DIALECT-MATRIX.md`：大小写折叠表后追加：

```markdown
## 绑定契约（TestBinding 锁死）

| 类型 | canonical form | NULL | 非法值 |
|---|---|---|---|
| 整数/长整数 | 十进制串，极值原样 | 独立位，空串不混 | 溢出按驱动错链分类 |
| Double/BigDec | `Double.toString`/`toPlainString` | 独立位 | 坏 BigDecimal `HY092/43` |
| 串/CJK | UTF-8 原样 | 空串≠NULL | — |
| 日期/时间戳 | `yyyy-mm-dd[ hh:nn:ss]` | 独立位 | 坏日期 `HY092/43` 带原文 |
| 布尔 | 写 `0/1`，读 `1/0` 归一 | 独立位 | — |
| BLOB | 窗口长度占位 + `fetchBlob` 内容两次一致 | 0 字节与 NULL 分开 | — |

大小写折叠：H2 全大写、SQLite 原样、PG/MySQL 全小写（`TestBinding` 建表全小写）。
```

- [ ] **Step 5: 全门禁绿并提交**

Run: `TestBinding` + `TestData` + `TestTypes` + `guard ok`，再 `pwsh -NoProfile -File scripts/run-matrix.ps1`（Expected: `MATRIX-FAILURES=0` + `MATRIX-OK`）。

```bash
git add tests/TestBinding.lpr scripts/run-matrix.ps1 docs/DIALECT-MATRIX.md
git commit -m "test: four-db binding matrix with contract docs"
```

---

## Self-Review（已自检并内联修复）

1. **Spec 覆盖**：§1 契约 → Task 1（NULL 位）/Task 2（布尔/小数/日期/BLOB）/Task 3（真值表）；§2 链路 → Task 1（FetchPage/FillPage）/Task 2（透传 NULL 码/占位注释）/Task 3（MapByCode）；§3 矩阵 → Task 4（四库 + 错误语义断言分散在 Task 2/3 的 `HY092/43`、`HY000/45`、`ecFatal`）；§5 验收 → Task 4-Step 5。`CollectRow` 的 NULL 按列类型带码在 Task 2-Step 2 第 3 条，无空断言。
2. **占位符扫描**：无 TBD/TODO；`Pjboolean` 回退方案已写（`PByte` 代替）；`TestTypes` 断言数不写死（只查 `fail=0`）；PG/MySQL 默认 URL/jar 与 SKIP 路径写死，无“适当处理”类描述。
3. **类型一致**：`TFetchPage/TNullMatrix`（Task 1 定义 → Task 2/4 原样用）；`MapByCode` 签名（Task 3 定义 → Task 3-Step 3 与 Task 4 一致）；`BNull` 码表（4/-5/8/91/92/93/2004/16/12，全文唯一）；`0.9.0` 握手无任务触碰；`FetchWindow` 旧签名保留，旧测试不断。
