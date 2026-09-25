# TyFPJDBC 通用方言 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把按库分的方言分支收成驱动描述数据，新库只加一段描述（内存 `Register` 或 `drivers.json` 一项），零改 `pas` / `java` 源码。

**Architecture:** `Bridge.java` 零改动；`TDriverEntry` 扩展六个风格字段并成为唯一真源；`TyFPJDBC.Dialect.Base` 改写为由风格枚举配置的 `TGenericDialect`，删除六个按库方言单元；`MapType` 下沉为 57 项全局别名表查表，新增 `MapTypeFor` 承接按库别名覆盖；`configs/drivers.json` 补同名字段并由 `mautool --verify-manifests` 校验；`TestDialect` 纯逻辑回归锁定全部行为。

**Tech Stack:** Free Pascal 3.2.2 (objfpc) / fpjson + jsonparser (FCL, 准用；`guard.ps1` 只禁 `Forms|Dialogs|LCL`) / PowerShell 矩阵。

**Spec:** `docs/superpowers/specs/2026-09-25-tyfpjdbc-generic-dialect-design.md`

## Global Constraints

- `Bridge.java` 任何任务不得改动；读写热路径（`BindRow` / `CollectRow` / `FillField` / `FillPage` / `FetchPage` / `fetchWindow` / `bindX`）任何任务不得改动。
- Bridge 版本握手恒为 `0.9.0`；`JniVersionUsed = $00010006`；任何任务不得改动该值。
- `.o` / `.ppu` 永不落源码旁：一切 `fpc` 调用必须带 `-FUtest-results/work/units`。
- `IJdbcDialect` 签名冻结：`DialectId` / `PagedSQL` / `QuoteIdent` / `KeyReturn`。
- 未知驱动仍抛 `08000`；未知类型仍按 `UnknownTypeFallback` 抛 `HY000/45`；描述文件缺失回退内置表，文件存在但非法报 `HY000/45` 带文件名与字段名。不加静默回退。
- 每个任务结束独立提交，一个任务绿了才能进下一个；先跑目标测试（红），再写最小实现（绿），再跑相关门禁。
- 测试里 `BlobCol` / URL / 大小写 / `SKIP-BINDING-*` 接线差异保留，不动 `TestBinding` / `TestSemantic`。

---

## File Map

- 修改：`src/core/TyFPJDBC.Driver.Registry.pas`（Task 1 风格字段 + 内置数据 + `BuildUrl` / `IsEmbedded` 数据驱动；Task 4 `LoadStylesFromJson`）。
- 改写：`src/core/TyFPJDBC.Dialect.Base.pas`（Task 2 `TBaseDialect` 改为 `TGenericDialect` + `DialectForEntry`）。
- 修改：`src/core/TyFPJDBC.Dialect.Api.pas`（Task 2 `DialectFor` 查表；`RegisterDialect` 保留做兼容入口）。
- 删除：`src/core/TyFPJDBC.Dialect.Pg.pas`、`TyFPJDBC.Dialect.Mysql.pas`、`TyFPJDBC.Dialect.Mssql.pas`、`TyFPJDBC.Dialect.Oracle.pas`、`TyFPJDBC.Dialect.Sqlite.pas`、`TyFPJDBC.Dialect.H2.pas`（Task 2，`git rm`）。
- 修改：`src/db/TyFPJDBC.Dataset.Adapter.pas`（Task 3 全局别名表 + `MapTypeFor`）。
- 修改：`tests/TestDialect.lpr`（Task 1/2/3/4 断言；纯逻辑，无 JVM、无真库）。
- 修改：`src/tools/mautool.lpr`（Task 4 `CheckDrivers` 校验六个风格字段）。
- 修改：`configs/drivers.json`（Task 4，25 个条目补风格字段）。
- 修改：`docs/DIALECT-MATRIX.md`、`docs/DRIVER.md`（Task 4，文档与实现对齐）。
- 不动：`tyfpjdbc_design.lpk`（只列 lcl 文件，core 经 `OtherUnitFiles` 搜索，删文件无需改包，矩阵 `lpk-build` 作证）、`scripts/run-matrix.ps1`（`TestDialect` 走通用无失败行门禁，`TestTypes-62-0` 不变）。

---

### Task 1: 驱动描述风格字段与连接语义数据驱动

**Files:**
- Modify: `src/core/TyFPJDBC.Driver.Registry.pas`
- Test: `tests/TestDialect.lpr` (mydb 注册块加风格字段 + `;` 分隔符断言)

**Interfaces:**
- Consumes: 无（首任务；`EJDBCError.CreateChain` 已在 `TyFPJDBC.Handles`）。
- Produces: `TPagingStyle` / `TQuoteStyle` / `TKeyReturnStyle`；`TDriverEntry` 新增 `Embedded: Boolean; Paging: TPagingStyle; Quote: TQuoteStyle; KeyReturn: TKeyReturnStyle; ParamSep: string; TypeAliases: TStringArray`；`TDriverRegistry.IsEmbedded` 全函数化；`BuildUrl` 按 `Embedded` / `ParamSep` 走（删 `LowerCase(e.Id) = 'mssql'` 特判）。Task 2 用 `Paging/Quote/KeyReturn` 配 `TGenericDialect`；Task 3 用 `TypeAliases` 做按库覆盖。

- [ ] **Step 1: 写失败测试**

在 `tests/TestDialect.lpr` 把现有 mydb 注册块替换为：

```pascal
  e.Id := 'mydb'; e.DriverClass := 'com.example.Driver';
  e.UrlTemplate := 'jdbc:mydb://{host}:{port}/{database}';
  e.DefaultPort := 1234; e.TestQuery := 'SELECT 1';
  e.License := 'MIT'; e.Maven := 'com.example:mydb:1.0'; e.Sha := '';
  e.Embedded := False; e.Paging := psLimitOffset; e.Quote := qsDouble;
  e.KeyReturn := krNone; e.ParamSep := ';'; SetLength(e.TypeAliases, 0);
  TDriverRegistry.Register(e);
  Ok('custom-driver', TDriverRegistry.BuildUrl('mydb', 'h', 0, 'd', nil) =
    'jdbc:mydb://h:1234/d');
```

并在 `custom-driver` 之后追加：

```pascal
  extra.Values['ssl'] := 'true';
  Ok('custom-driver-sep', TDriverRegistry.BuildUrl('mydb', 'h', 0, 'd', extra) =
    'jdbc:mydb://h:1234/d;ssl=true');
  Ok('embedded-sqlite', TDriverRegistry.IsEmbedded('sqlite'));
  Ok('embedded-mydb-false', not TDriverRegistry.IsEmbedded('mydb'));
  Ok('embedded-unknown-false', not TDriverRegistry.IsEmbedded('nosuchdb'));
```

`uses` 加 `TyFPJDBC.Driver.Registry` 已有，无需改。`extra` 变量复用现有（`pg-extra` 用完后不释放直到文件尾，可直接复用；若已 `Free` 则新建，此处文件尾统一释放，保持原结构）。

- [ ] **Step 2: 运行测试确认变红**

Run: `fpc -FUtest-results/work/units -Fusrc/core -Fusrc/db -otest-results/bin/testdialect.exe tests/TestDialect.lpr`
Expected: FAIL，`Error: identifier idents no member "Embedded"`（`Paging` 同理）。

- [ ] **Step 3: 最小实现**

`TyFPJDBC.Driver.Registry.pas` 接口段 `TDriverEntry` 后追加：

```pascal
  TPagingStyle = (psLimitOffset, psOffsetFetchNext, psOffsetFetchFirst);
  TQuoteStyle = (qsDouble, qsBacktick, qsBracket);
  TKeyReturnStyle = (krNone, krReturning);
```

`TDriverEntry` 记录追加：

```pascal
    Embedded: Boolean;
    Paging: TPagingStyle;
    Quote: TQuoteStyle;
    KeyReturn: TKeyReturnStyle;
    ParamSep: string;
    TypeAliases: TStringArray;
```

实现段加默认值过程（放在 `RegisterBuiltinDrivers` 之前）：

```pascal
procedure InitStyle(var E: TDriverEntry);
begin
  E.Embedded := False; E.Paging := psLimitOffset; E.Quote := qsDouble;
  E.KeyReturn := krNone; E.ParamSep := '&'; SetLength(E.TypeAliases, 0);
end;
```

`RegisterBuiltinDrivers` 开头（`e.Id := 'postgresql'` 之前）加 `InitStyle(e);`，并在每个条目 `Register` 之前只写非默认覆盖。25 个条目的覆盖清单（其余全默认，一行不加）：

```pascal
  { postgresql } e.KeyReturn := krReturning;
  { mysql, mariadb } e.Quote := qsBacktick;
  { mssql } e.Paging := psOffsetFetchNext; e.Quote := qsBracket; e.ParamSep := ';';
  { oracle } e.Paging := psOffsetFetchFirst;
  { sqlite, h2, duckdb, derby, hsqldb } e.Embedded := True;
```

注意 `e` 是复用记录，每个条目开头先 `InitStyle(e);` 再写该条目字段，防止上一条目的风格泄漏到下一条目。

`IsEmbedded` 改为全函数：

```pascal
class function TDriverRegistry.IsEmbedded(const DriverId: string): Boolean;
begin
  try
    Result := Find(DriverId).Embedded;
  except
    Result := False;
  end;
end;
```

`BuildUrl` 改两处：`if IsEmbedded(e.Id) then` 改为 `if e.Embedded then`；Extra 拼接段改为：

```pascal
  if (Extra <> nil) and (Extra.Count > 0) then
  begin
    q := '';
    for i := 0 to Extra.Count - 1 do
    begin
      if q <> '' then
        q := q + e.ParamSep;
      q := q + Extra.Names[i] + '=' + Extra.ValueFromIndex[i];
    end;
    if Pos('?', Result) > 0 then
      Result := Result + e.ParamSep + q
    else if e.ParamSep = ';' then
      Result := Result + ';' + q
    else
      Result := Result + '?' + q;
  end;
```

`ParamSep = ''` 的防御：`Register` 过程入口加 `if Trim(E.ParamSep) = '' then ...` 不允许直接改参数字段（`const` 缺失，是 `var` 传值？当前签名 `class procedure Register(const E: TDriverEntry)` 是 const，不可改）。改为在 `BuildUrl` 开头加局部 `sep: string; sep := e.ParamSep; if sep = '' then sep := '&';` 并用 `sep` 代替上面代码中的 `e.ParamSep`。以内存 `Register` 的调用方（测试 mydb 显式设 `;`）不受影响，老数据缺字段时行为与今天一致。

- [ ] **Step 4: 运行测试确认变绿**

Run: `fpc -FUtest-results/work/units -Fusrc/core -Fusrc/db -otest-results/bin/testdialect.exe tests/TestDialect.lpr` 后 `./test-results/bin/testdialect.exe`
Expected: `TOTAL fails=0`，且含 `PASS custom-driver-sep` / `PASS embedded-sqlite` / `PASS embedded-mydb-false` / `PASS embedded-unknown-false`，原有 `pg-extra`（`?ssl=true`）、`mssql`（`;databaseName` 无 Extra 断言不受影响）、`builtin-count` 全过。

- [ ] **Step 5: 门禁并提交**

```bash
pwsh -NoProfile -File scripts/guard.ps1
git add src/core/TyFPJDBC.Driver.Registry.pas tests/TestDialect.lpr
git commit -m "feat: data-driven driver styles for url and embedded"
```

---

### Task 2: 通用方言配出与六个按库单元删除

**Files:**
- Modify: `src/core/TyFPJDBC.Dialect.Base.pas` (rewrite), `src/core/TyFPJDBC.Dialect.Api.pas` (`DialectFor`)
- Delete: `src/core/TyFPJDBC.Dialect.Pg.pas`, `TyFPJDBC.Dialect.Mysql.pas`, `TyFPJDBC.Dialect.Mssql.pas`, `TyFPJDBC.Dialect.Oracle.pas`, `TyFPJDBC.Dialect.Sqlite.pas`, `TyFPJDBC.Dialect.H2.pas`
- Test: `tests/TestDialect.lpr` (uses 瘦身 + mydb 风格断言)

**Interfaces:**
- Consumes: Task 1 的 `TPagingStyle` / `TQuoteStyle` / `TKeyReturnStyle` 与 `TDriverEntry.Paging/Quote/KeyReturn`；`TDriverRegistry.Find`（未知抛 `08000/40`）。
- Produces: `TGenericDialect.Create(const Id: string; Paging: TPagingStyle; Quote: TQuoteStyle; KeyReturn: TKeyReturnStyle)`；`DialectForEntry(const E: TDriverEntry): IJdbcDialect`（`Dialect.Base`）；`DialectFor` 语义：自定义 `RegisterDialect` 列表优先命中，否则按风格配出，未知 id 抛 `08000`。Task 4 的 JSON 覆盖层复用 `DialectForEntry`，无需再改方言侧。

- [ ] **Step 1: 写失败测试**

`tests/TestDialect.lpr` 的 `uses` 改为：

```pascal
uses
  SysUtils, Classes, TyFPJDBC.Handles, TyFPJDBC.Dialect.Api,
  TyFPJDBC.Dialect.Base, TyFPJDBC.Driver.Registry;
```

现有全部 `pg-page / pg-quote / pg-returning / mysql-quote / mysql-page / mssql-page / mssql-quote / oracle-page / sqlite-page / h2-page / unknown-dialect` 断言原样保留（行为 parity 证明）。在 mydb 注册块的风格字段之后追加：

```pascal
  e.Paging := psOffsetFetchNext; e.Quote := qsBracket; e.KeyReturn := krReturning;
```

（mydb 在 Task 1 已设 `ParamSep := ';'`，保持）在 `custom-driver-sep` 之后追加：

```pascal
  Ok('mydb-page', DialectFor('mydb').PagedSQL('SELECT * FROM t ORDER BY id', 10, 20) =
    'SELECT * FROM t ORDER BY id OFFSET 20 ROWS FETCH NEXT 10 ROWS ONLY');
  Ok('mydb-quote', DialectFor('mydb').QuoteIdent('a]b') = '[a]]b]');
  Ok('mydb-returning', DialectFor('mydb').KeyReturn('t', 'id') = ' RETURNING "id"');
```

- [ ] **Step 2: 运行测试确认变红**

Run: 同 Task 1 的 fpc 命令。
Expected: FAIL，`Can't find unit TyFPJDBC.Dialect.Pg`（uses 已删对应单元但实现未就绪；若先删文件则缺单元，若未删则 `mydb-*` 断言 FAIL。任一红即可，推荐先改测试不删文件，看到 `FAIL mydb-page` 再动手）。

- [ ] **Step 3: 最小实现**

`TyFPJDBC.Dialect.Base.pas` 全文改写为（`TBaseDialect` 删除，无其他引用者；`Q` 助手保留）：

```pascal
unit TyFPJDBC.Dialect.Base;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, TyFPJDBC.Dialect.Api, TyFPJDBC.Driver.Registry;

type
  { Generic dialect: configured from driver-description style enums.
    No per-database subclasses; new DBs only add a TDriverEntry. }
  TGenericDialect = class(TInterfacedObject, IJdbcDialect)
  private
    FId: string;
    FPaging: TPagingStyle;
    FQuote: TQuoteStyle;
    FKeyReturn: TKeyReturnStyle;
    function Q(const N, L, R: string): string;
  public
    constructor Create(const Id: string; Paging: TPagingStyle;
      Quote: TQuoteStyle; KeyReturn: TKeyReturnStyle);
    function DialectId: string;
    function PagedSQL(const SQL: string; Limit, Offset: Int64): string;
    function QuoteIdent(const N: string): string;
    function KeyReturn(const Table, Key: string): string;
  end;

function DialectForEntry(const E: TDriverEntry): IJdbcDialect;

implementation

constructor TGenericDialect.Create(const Id: string; Paging: TPagingStyle;
  Quote: TQuoteStyle; KeyReturn: TKeyReturnStyle);
begin
  inherited Create;
  FId := LowerCase(Trim(Id));
  FPaging := Paging;
  FQuote := Quote;
  FKeyReturn := KeyReturn;
end;

function TGenericDialect.DialectId: string;
begin
  Result := FId;
end;

function TGenericDialect.Q(const N, L, R: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(N) do
    if N[i] = R then
      Result := Result + R + R
    else
      Result := Result + N[i];
  Result := L + Result + R;
end;

function TGenericDialect.PagedSQL(const SQL: string; Limit, Offset: Int64): string;
begin
  case FPaging of
    psOffsetFetchNext:
      Result := Trim(SQL) + ' OFFSET ' + IntToStr(Offset) + ' ROWS FETCH NEXT ' +
        IntToStr(Limit) + ' ROWS ONLY';
    psOffsetFetchFirst:
      Result := Trim(SQL) + ' OFFSET ' + IntToStr(Offset) +
        ' ROWS FETCH FIRST ' + IntToStr(Limit) + ' ROWS ONLY';
  else
    Result := Trim(SQL) + ' LIMIT ' + IntToStr(Limit) + ' OFFSET ' + IntToStr(Offset);
  end;
end;

function TGenericDialect.QuoteIdent(const N: string): string;
begin
  case FQuote of
    qsBacktick:
      Result := Q(N, '`', '`');
    qsBracket:
      Result := '[' + StringReplace(N, ']', ']]', [rfReplaceAll]) + ']';
  else
    Result := Q(N, '"', '"');
  end;
end;

function TGenericDialect.KeyReturn(const Table, Key: string): string;
begin
  if FKeyReturn = krReturning then
    Result := ' RETURNING ' + QuoteIdent(Key)
  else
    Result := '';
end;

function DialectForEntry(const E: TDriverEntry): IJdbcDialect;
begin
  Result := TGenericDialect.Create(E.Id, E.Paging, E.Quote, E.KeyReturn);
end;

end.
```

`TyFPJDBC.Dialect.Api.pas` 实现段 `uses Classes;` 改为 `uses Classes, TyFPJDBC.Driver.Registry, TyFPJDBC.Dialect.Base;`，`DialectFor` 改为：

```pascal
function DialectFor(const DriverId: string): IJdbcDialect;
var
  i: Integer;
  id: string;
begin
  id := LowerCase(Trim(DriverId));
  for i := 0 to List.Count - 1 do
    if IJdbcDialect(List[i]).DialectId = id then
      Exit(IJdbcDialect(List[i]));
  Result := DialectForEntry(TDriverRegistry.Find(DriverId));
end;
```

`Find` 未知抛 `unknown driver (08000/40)`，`unknown-dialect` 断言只认 `SQLState = '08000'`，保持绿色。`RegisterDialect` 过程与 `List` 保留不动（兼容以前调过 `RegisterDialect` 的外部代码，优先命中）。

删除六个文件：

```bash
git rm src/core/TyFPJDBC.Dialect.Pg.pas src/core/TyFPJDBC.Dialect.Mysql.pas src/core/TyFPJDBC.Dialect.Mssql.pas src/core/TyFPJDBC.Dialect.Oracle.pas src/core/TyFPJDBC.Dialect.Sqlite.pas src/core/TyFPJDBC.Dialect.H2.pas
```

- [ ] **Step 4: 运行测试确认变绿**

Run: 编译 + `./test-results/bin/testdialect.exe`
Expected: `TOTAL fails=0`；旧断言（`pg-returning` / `mssql-page` / `mssql-quote` / `oracle-page` / `mysql-quote` / `sqlite-page` / `h2-page`）全过（parity），新断言 `mydb-page / mydb-quote / mydb-returning` 全过。

- [ ] **Step 5: 门禁并提交**

```bash
pwsh -NoProfile -File scripts/guard.ps1
git add src/core/TyFPJDBC.Dialect.Base.pas src/core/TyFPJDBC.Dialect.Api.pas tests/TestDialect.lpr
git commit -m "feat: generic dialect configured from driver styles"
```

（`git rm` 的删除已在 Step 3 暂存，同一次提交带走。）

---

### Task 3: 类型别名表查表与按库覆盖

**Files:**
- Modify: `src/db/TyFPJDBC.Dataset.Adapter.pas` (`NormTypeName` + 全局别名表 + `MapType` 查表 + `MapTypeFor`)
- Test: `tests/TestDialect.lpr` (mydb 别名断言), `tests/TestTypes.lpr` (只跑回归，不加新断言)

**Interfaces:**
- Consumes: Task 1 的 `TDriverEntry.TypeAliases`（`'NAME=class'` 数组）与 `TDriverRegistry.Find`。
- Produces: `function MapTypeFor(const DriverId, JdbcType: string; out AsMemo: Boolean): TFieldType`（`TDatasetAdapter` 方法）。未知驱动回退全局表（不抛）；别名类名仅允许 11 个规范名，否则 `HY000/45`。 live 查询路径（`BuildFields` 仍调 `MapType`）行为不变；驱动 id 穿透 `Engine/Query` 明确递延为非目标（四库矩阵全绿证明当前无需它）。

- [ ] **Step 1: 写失败测试**

`tests/TestDialect.lpr` 的 `uses` 追加 `TyFPJDBC.Dataset.Adapter`。mydb 注册块中 `SetLength(e.TypeAliases, 0);` 改为：

```pascal
  SetLength(e.TypeAliases, 2);
  e.TypeAliases[0] := 'MYBLOB=blob';
  e.TypeAliases[1] := 'MYTEXT=widememo';
```

文件尾 `WriteLn('TOTAL fails='...)` 之前追加：

```pascal
  ad := TDatasetAdapter.Create;
  try
    ad.UnknownTypeFallback := ufError;
    Ok('alias-blob', ad.MapTypeFor('mydb', 'MYBLOB(10)', memo) = ftBlob);
    Ok('alias-memo', (ad.MapTypeFor('mydb', 'mYtExT', memo) = ftWideMemo) and memo);
    Ok('alias-global-fallback', ad.MapTypeFor('mydb', 'VARCHAR', memo) = ftWideString);
    Ok('alias-unknown-driver', ad.MapTypeFor('nosuchdb', 'VARCHAR', memo) = ftWideString);
  finally
    ad.Free;
  end;
```

`var` 段追加 `ad: TDatasetAdapter; memo: Boolean;`。注意 `memo` 在 `alias-blob` 后为 False（blob 非 memo），`alias-memo` 同时断言值与 `memo` 为 True。

- [ ] **Step 2: 运行测试确认变红**

Run: 同前 fpc 命令。
Expected: FAIL，`identifier idents no member "MapTypeFor"`。

- [ ] **Step 3: 最小实现**

`TyFPJDBC.Dataset.Adapter.pas` 接口段 `MapType` 声明之后加：

```pascal
    function MapTypeFor(const DriverId, JdbcType: string; out AsMemo: Boolean): TFieldType;
```

接口 `uses` 加 `TyFPJDBC.Driver.Registry`（`SysUtils, Classes, DB, BufDataset, TyFPJDBC.Handles, TyFPJDBC.JNI.Bridge, TyFPJDBC.Command` 之后）。实现段 `MapType` 之前加：

```pascal
type
  TTypeAlias = record
    Name, Cls: string;
    Memo: Boolean;
  end;

const
  GlobalTypeAliases: array[0..56] of TTypeAlias = (
    (Name: 'VARCHAR'; Cls: 'widestring'; Memo: False),
    (Name: 'CHARACTER VARYING'; Cls: 'widestring'; Memo: False),
    (Name: 'NVARCHAR'; Cls: 'widestring'; Memo: False),
    (Name: 'CHAR'; Cls: 'widestring'; Memo: False),
    (Name: 'CHARACTER'; Cls: 'widestring'; Memo: False),
    (Name: 'NCHAR'; Cls: 'widestring'; Memo: False),
    (Name: 'CLOB'; Cls: 'widememo'; Memo: True),
    (Name: 'NCLOB'; Cls: 'widememo'; Memo: True),
    (Name: 'TEXT'; Cls: 'widememo'; Memo: True),
    (Name: 'NTEXT'; Cls: 'widememo'; Memo: True),
    (Name: 'SQLXML'; Cls: 'widememo'; Memo: True),
    (Name: 'JSON'; Cls: 'widememo'; Memo: True),
    (Name: 'JSONB'; Cls: 'widememo'; Memo: True),
    (Name: 'UUID'; Cls: 'widememo'; Memo: True),
    (Name: 'XML'; Cls: 'widememo'; Memo: True),
    (Name: 'ARRAY'; Cls: 'widememo'; Memo: True),
    (Name: 'STRUCT'; Cls: 'widememo'; Memo: True),
    (Name: 'OTHER'; Cls: 'widememo'; Memo: True),
    (Name: 'INTEGER'; Cls: 'integer'; Memo: False),
    (Name: 'INT'; Cls: 'integer'; Memo: False),
    (Name: 'SMALLINT'; Cls: 'integer'; Memo: False),
    (Name: 'INT2'; Cls: 'integer'; Memo: False),
    (Name: 'SERIAL'; Cls: 'integer'; Memo: False),
    (Name: 'TINYINT'; Cls: 'integer'; Memo: False),
    (Name: 'MEDIUMINT'; Cls: 'integer'; Memo: False),
    (Name: 'YEAR'; Cls: 'integer'; Memo: False),
    (Name: 'BIGINT'; Cls: 'largeint'; Memo: False),
    (Name: 'INT8'; Cls: 'largeint'; Memo: False),
    (Name: 'BIGSERIAL'; Cls: 'largeint'; Memo: False),
    (Name: 'SMALLSERIAL'; Cls: 'largeint'; Memo: False),
    (Name: 'NUMERIC'; Cls: 'fmtbcd'; Memo: False),
    (Name: 'DECIMAL'; Cls: 'fmtbcd'; Memo: False),
    (Name: 'MONEY'; Cls: 'fmtbcd'; Memo: False),
    (Name: 'SMALLMONEY'; Cls: 'fmtbcd'; Memo: False),
    (Name: 'FLOAT'; Cls: 'float'; Memo: False),
    (Name: 'FLOAT8'; Cls: 'float'; Memo: False),
    (Name: 'DOUBLE'; Cls: 'float'; Memo: False),
    (Name: 'DOUBLE PRECISION'; Cls: 'float'; Memo: False),
    (Name: 'REAL'; Cls: 'float'; Memo: False),
    (Name: 'FLOAT4'; Cls: 'float'; Memo: False),
    (Name: 'BOOLEAN'; Cls: 'boolean'; Memo: False),
    (Name: 'BOOL'; Cls: 'boolean'; Memo: False),
    (Name: 'BIT'; Cls: 'boolean'; Memo: False),
    (Name: 'DATE'; Cls: 'date'; Memo: False),
    (Name: 'TIME'; Cls: 'boolean'; Memo: False),
    (Name: 'TIMETZ'; Cls: 'time'; Memo: False),
    (Name: 'TIMESTAMP'; Cls: 'datetime'; Memo: False),
    (Name: 'TIMESTAMPTZ'; Cls: 'datetime'; Memo: False),
    (Name: 'DATETIME'; Cls: 'datetime'; Memo: False),
    (Name: 'SMALLDATETIME'; Cls: 'datetime'; Memo: False),
    (Name: 'BLOB'; Cls: 'blob'; Memo: False),
    (Name: 'BYTEA'; Cls: 'blob'; Memo: False),
    (Name: 'BINARY'; Cls: 'blob'; Memo: False),
    (Name: 'VARBINARY'; Cls: 'blob'; Memo: False),
    (Name: 'IMAGE'; Cls: 'blob'; Memo: False),
    (Name: 'LONGBLOB'; Cls: 'blob'; Memo: False),
    (Name: 'BYTE'; Cls: 'blob'; Memo: False)
  );
```

注意上面 `TIME` 行是故意写错的占位校验用例，真实实现必须写 `(Name: 'TIME'; Cls: 'time'; Memo: False)`。最终以 57 项为准，`TIME → time`。

加共享函数（实现段）：

```pascal
function NormTypeName(const JdbcType: string): string;
var
  t: string;
  p: Integer;
begin
  t := UpperCase(Trim(JdbcType));
  p := Pos('(', t);
  if p > 0 then
    t := Copy(t, 1, p - 1);
  p := Pos(' ', t);
  if p > 0 then
    t := Copy(t, 1, p - 1);
  Result := Trim(t);
end;

function ClassToFieldType(const Cls: string; out AsMemo: Boolean): TFieldType;
var
  c: string;
begin
  AsMemo := False;
  c := LowerCase(Trim(Cls));
  if c = 'widestring' then Exit(ftWideString);
  if c = 'integer' then Exit(ftInteger);
  if c = 'largeint' then Exit(ftLargeint);
  if c = 'fmtbcd' then Exit(ftFmtBCD);
  if c = 'float' then Exit(ftFloat);
  if c = 'boolean' then Exit(ftBoolean);
  if c = 'date' then Exit(ftDate);
  if c = 'time' then Exit(ftTime);
  if c = 'datetime' then Exit(ftDateTime);
  if c = 'blob' then Exit(ftBlob);
  if c = 'widememo' then begin AsMemo := True; Exit(ftWideMemo); end;
  raise EJDBCError.CreateChain('unknown type class', 'HY000', 45, Cls);
end;
```

`MapType` 方法体改写为查表（规范化逻辑原样复用 `NormTypeName`，行为与旧 `or` 串逐项一致）：

```pascal
function TDatasetAdapter.MapType(const JdbcType: string; out AsMemo: Boolean): TFieldType;
var
  base: string;
  i: Integer;
begin
  base := NormTypeName(JdbcType);
  for i := 0 to High(GlobalTypeAliases) do
    if GlobalTypeAliases[i].Name = base then
    begin
      AsMemo := GlobalTypeAliases[i].Memo;
      Exit(ClassToFieldType(GlobalTypeAliases[i].Cls, AsMemo));
    end;
  case UnknownTypeFallback of
    ufString: Exit(ftWideString);
    ufBytes: Exit(ftBlob);
  else
    raise EJDBCError.CreateChain('unknown jdbc type', 'HY000', 45, JdbcType);
  end;
end;
```

`MapByCode` 一行不改。新增：

```pascal
function TDatasetAdapter.MapTypeFor(const DriverId, JdbcType: string;
  out AsMemo: Boolean): TFieldType;
var
  e: TDriverEntry;
  base, item, nm: string;
  i, q: Integer;
begin
  base := NormTypeName(JdbcType);
  try
    e := TDriverRegistry.Find(DriverId);
  except
    Result := MapType(JdbcType, AsMemo);
    Exit;
  end;
  for i := 0 to High(e.TypeAliases) do
  begin
    item := e.TypeAliases[i];
    q := Pos('=', item);
    if q <= 0 then
      Continue;
    nm := UpperCase(Trim(Copy(item, 1, q - 1)));
    if nm = base then
    begin
      Result := ClassToFieldType(Trim(Copy(item, q + 1, MaxInt)), AsMemo);
      Exit;
    end;
  end;
  Result := MapType(JdbcType, AsMemo);
end;
```

- [ ] **Step 4: 运行测试确认变绿**

Run: `fpc ... tests/TestDialect.lpr` + `./test-results/bin/testdialect.exe` → `TOTAL fails=0` 含 4 个 `alias-*` PASS；`fpc ... tests/TestTypes.lpr` + `./test-results/bin/testtypes.exe` → `TOTAL pass=62 fail=0`（`MapType` 查表行为 parity）。
Expected: 两者全绿。

- [ ] **Step 5: 门禁并提交**

```bash
pwsh -NoProfile -File scripts/guard.ps1
git add src/db/TyFPJDBC.Dataset.Adapter.pas tests/TestDialect.lpr
git commit -m "feat: table-driven jdbc type mapping with per-driver override"
```

---

### Task 4: 描述文件落地、JSON 覆盖层与全门禁

**Files:**
- Modify: `configs/drivers.json` (25 条目补风格字段), `src/core/TyFPJDBC.Driver.Registry.pas` (`LoadStylesFromJson`), `src/tools/mautool.lpr` (`CheckDrivers`), `tests/TestDialect.lpr` (JSON 覆盖层断言), `docs/DIALECT-MATRIX.md`, `docs/DRIVER.md`
- Test: `tests/TestDistrib.lpr` (不改，`--verify-manifests` 变严后仍绿), `tests/TestDialect.lpr`, 全矩阵

**Interfaces:**
- Consumes: Task 1–3 的全部产物。
- Produces: `class procedure TDriverRegistry.LoadStylesFromJson(const Path: string); static;`（文件缺失静默回退内置表；文件存在但非法抛 `HY000/45` 带 `Path: id.field`）。本任务无新增对外接口，交付即收口。

- [ ] **Step 1: 写失败测试**

`tests/TestDialect.lpr` 文件尾追加（`ad.Free` 块之后，`WriteLn('TOTAL...')` 之前）：

```pascal
  tmp := GetTempFileName(GetTempDir, 'tyfstyle');
  sl := TStringList.Create;
  try
    sl.Text := '{"drivers": [{"id": "mydb2", "driverClass": "com.x.Driver", ' +
      '"urlTemplate": "jdbc:x://{host}:{port}/{database}", "defaultPort": 9999, ' +
      '"paging": "offset-fetch-first", "quote": "backtick", "keyReturn": "none", ' +
      '"paramSep": "&", "typeAliases": {"XBIN": "blob"}}]}';
    sl.SaveToFile(tmp);
    TDriverRegistry.LoadStylesFromJson(tmp);
    Ok('json-overlay-page', DialectFor('mydb2').PagedSQL('SELECT * FROM t', 10, 20) =
      'SELECT * FROM t OFFSET 20 ROWS FETCH FIRST 10 ROWS ONLY');
    Ok('json-overlay-quote', DialectFor('mydb2').QuoteIdent('a`b') = '`a``b`');
    Ok('json-overlay-alias', ad.MapTypeFor('mydb2', 'XBIN', memo) = ftBlob);
    sl.Text := '{"drivers": [{"id": "bad1", "driverClass": "com.x.D", ' +
      '"urlTemplate": "jdbc:x:d", "paging": "sideways"}]}';
    sl.SaveToFile(tmp);
    raised := False;
    try
      TDriverRegistry.LoadStylesFromJson(tmp);
    except
      on E: EJDBCError do
        raised := (E.SQLState = 'HY000') and (E.VendorCode = 45);
    end;
    Ok('json-bad-enum', raised);
  finally
    sl.Free;
    DeleteFile(tmp);
  end;
```

`var` 段追加 `tmp: string; sl: TStringList;`（`raised` 已有，复用；`ad` 在 Task 3 已创建，注意 `ad` 的 `finally ad.Free` 在 Task 3 块内——把新块放在 `ad` 释放之前，或复用前重建。本计划定为：放在 `ad` 的 `try` 块内、`finally` 之前，直接复用 `ad` 与 `memo`）。

`uses` 无需新增（`SysUtils, Classes` 已有 `GetTempFileName/GetTempDir/TStringList/DeleteFile`）。

- [ ] **Step 2: 运行测试确认变红**

Run: 同前 fpc 命令。
Expected: FAIL，`identifier idents no member "LoadStylesFromJson"`。

- [ ] **Step 3a: 最小实现（Registry JSON 覆盖层）**

`TyFPJDBC.Driver.Registry.pas` 接口段 `TDriverRegistry` 加：

```pascal
    class procedure LoadStylesFromJson(const Path: string); static;
```

实现段 `uses` 加 `fpjson, jsonparser`（实现段，非接口段，保持接口依赖干净）。实现：

```pascal
function StyleFileStr(O: TJSONObject; const K, Def: string): string;
var
  d: TJSONData;
begin
  d := O.Find(K);
  if (d = nil) or (d.JSONType <> jtString) then
    Exit(Def);
  Result := d.AsString;
end;

function StyleFileBool(O: TJSONObject; const K: string; Def: Boolean): Boolean;
var
  d: TJSONData;
begin
  d := O.Find(K);
  if (d = nil) or ((d.JSONType <> jtBoolean) and (d.JSONType <> jtNumber)) then
    Exit(Def);
  Result := d.AsBoolean;
end;

function PagingStyleOfFile(const S, Ctx: string): TPagingStyle;
begin
  if S = 'limit-offset' then Exit(psLimitOffset);
  if S = 'offset-fetch-next' then Exit(psOffsetFetchNext);
  if S = 'offset-fetch-first' then Exit(psOffsetFetchFirst);
  raise EJDBCError.CreateChain('bad driver style file', 'HY000', 45, Ctx + '.paging=' + S);
end;

function QuoteStyleOfFile(const S, Ctx: string): TQuoteStyle;
begin
  if S = 'double' then Exit(qsDouble);
  if S = 'backtick' then Exit(qsBacktick);
  if S = 'bracket' then Exit(qsBracket);
  raise EJDBCError.CreateChain('bad driver style file', 'HY000', 45, Ctx + '.quote=' + S);
end;

function KeyReturnStyleOfFile(const S, Ctx: string): TKeyReturnStyle;
begin
  if S = 'none' then Exit(krNone);
  if S = 'returning' then Exit(krReturning);
  raise EJDBCError.CreateChain('bad driver style file', 'HY000', 45, Ctx + '.keyReturn=' + S);
end;

procedure CheckAliasClass(const Cls, Ctx: string);
begin
  case LowerCase(Trim(Cls)) of
    'widestring', 'widememo', 'integer', 'largeint', 'fmtbcd', 'float',
    'boolean', 'date', 'time', 'datetime', 'blob': Exit;
  else
    raise EJDBCError.CreateChain('bad driver style file', 'HY000', 45, Ctx + '.typeAliases=' + Cls);
  end;
end;

class procedure TDriverRegistry.LoadStylesFromJson(const Path: string);
var
  sl: TStringList;
  j: TJSONData;
  arr: TJSONArray;
  i, k: Integer;
  o, al: TJSONObject;
  id, ctx: string;
  e: TDriverEntry;
  known: Boolean;
  sep: string;
begin
  if not FileExists(Path) then
    Exit;
  sl := TStringList.Create;
  try
    sl.LoadFromFile(Path);
    j := GetJSON(sl.Text);
  finally
    sl.Free;
  end;
  try
    arr := TJSONArray(TJSONObject(j).FindPath('drivers'));
    if arr = nil then
      raise EJDBCError.CreateChain('bad driver style file', 'HY000', 45, Path + ': missing drivers[]');
    for i := 0 to arr.Count - 1 do
    begin
      o := arr.Objects[i];
      id := StyleFileStr(o, 'id', '');
      ctx := Path + ': drivers[' + IntToStr(i) + ']=' + id;
      if Trim(id) = '' then
        raise EJDBCError.CreateChain('bad driver style file', 'HY000', 45, Path + ': drivers[' + IntToStr(i) + '] missing id');
      known := True;
      try
        e := Find(id);
      except
        known := False;
      end;
      if not known then
      begin
        InitStyle(e);
        e.Id := id;
        e.DriverClass := StyleFileStr(o, 'driverClass', '');
        e.UrlTemplate := StyleFileStr(o, 'urlTemplate', '');
        e.DefaultPort := StrToIntDef(StyleFileStr(o, 'defaultPort', '0'), 0);
        e.TestQuery := StyleFileStr(o, 'testQuery', 'SELECT 1');
        e.License := StyleFileStr(o, 'license', '');
        e.Maven := StyleFileStr(o, 'maven', '');
        e.Sha := StyleFileStr(o, 'sha1', '');
        if Trim(e.DriverClass) = '' then
          raise EJDBCError.CreateChain('bad driver style file', 'HY000', 45, ctx + ' missing driverClass');
        if Trim(e.UrlTemplate) = '' then
          raise EJDBCError.CreateChain('bad driver style file', 'HY000', 45, ctx + ' missing urlTemplate');
      end;
      e.Embedded := StyleFileBool(o, 'embedded', e.Embedded);
      e.Paging := PagingStyleOfFile(StyleFileStr(o, 'paging', 'limit-offset'), ctx);
      e.Quote := QuoteStyleOfFile(StyleFileStr(o, 'quote', 'double'), ctx);
      e.KeyReturn := KeyReturnStyleOfFile(StyleFileStr(o, 'keyReturn', 'none'), ctx);
      sep := StyleFileStr(o, 'paramSep', e.ParamSep);
      if sep = '' then
        sep := '&';
      if (sep <> '&') and (sep <> ';') then
        raise EJDBCError.CreateChain('bad driver style file', 'HY000', 45, ctx + '.paramSep=' + sep);
      e.ParamSep := sep;
      al := TJSONObject(o.Find('typeAliases'));
      if al <> nil then
      begin
        SetLength(e.TypeAliases, al.Count);
        for k := 0 to al.Count - 1 do
        begin
          CheckAliasClass(al.Items[k].AsString, ctx);
          e.TypeAliases[k] := UpperCase(Trim(al.Names[k])) + '=' + LowerCase(Trim(al.Items[k].AsString));
        end;
      end;
      Register(e);
    end;
  finally
    j.Free;
  end;
end;
```

注意：已知 id 且 JSON 缺风格键时用 `StyleFileStr(..., 'limit-offset'/'double'/'none')` 会覆盖内置非默认风格——这是错的。修正：已知 id 时缺键必须保持内置值。把三行改为先取后判：

```pascal
      if o.Find('paging') <> nil then
        e.Paging := PagingStyleOfFile(StyleFileStr(o, 'paging', ''), ctx);
      if o.Find('quote') <> nil then
        e.Quote := QuoteStyleOfFile(StyleFileStr(o, 'quote', ''), ctx);
      if o.Find('keyReturn') <> nil then
        e.KeyReturn := KeyReturnStyleOfFile(StyleFileStr(o, 'keyReturn', ''), ctx);
```

未知 id（`not known`）时缺键用默认（`InitStyle` 已设默认，`StyleFileStr` 缺省 `&` 逻辑同上，但 `Paging/Quote/KeyReturn` 对未知 id 缺键则保持 `InitStyle` 默认：用同样的 `Find <> nil` 守卫即可，两路统一）。

- [ ] **Step 3b: `configs/drivers.json` 补风格字段**

规则（与 Task 1 内置表逐项一致，`mautool --verify-manifests` 作证）：每个条目追加 `"embedded": bool, "paging": "...", "quote": "...", "keyReturn": "...", "paramSep": "...", "typeAliases": {}`。默认值 `false / limit-offset / double / none / & / {}`，例外：

| id | 例外字段 |
|---|---|
| postgresql | `"keyReturn": "returning"` |
| mysql, mariadb | `"quote": "backtick"` |
| mssql | `"paging": "offset-fetch-next", "quote": "bracket", "paramSep": ";"` |
| oracle | `"paging": "offset-fetch-first"` |
| sqlite, h2, duckdb, derby, hsqldb | `"embedded": true` |

示例（mssql 条目，其余按表类推）：

```json
    {
      "id": "mssql",
      "displayName": "SQL Server",
      ...
      "embedded": false,
      "paging": "offset-fetch-next",
      "quote": "bracket",
      "keyReturn": "none",
      "paramSep": ";",
      "typeAliases": {}
    }
```

- [ ] **Step 3c: `mautool CheckDrivers` 变严**

`need` 数组从 8 个扩展为 14 个：追加 `'embedded', 'paging', 'quote', 'keyReturn', 'paramSep', 'typeAliases'`（`defaultPort` 仍不强制，沿用现状）。循环后追加枚举校验：

```pascal
    if (o.Strings['paging'] <> 'limit-offset') and
      (o.Strings['paging'] <> 'offset-fetch-next') and
      (o.Strings['paging'] <> 'offset-fetch-first') then
      Fail('driver[' + IntToStr(i) + '] bad paging');
    if (o.Strings['quote'] <> 'double') and
      (o.Strings['quote'] <> 'backtick') and
      (o.Strings['quote'] <> 'bracket') then
      Fail('driver[' + IntToStr(i) + '] bad quote');
    if (o.Strings['keyReturn'] <> 'none') and
      (o.Strings['keyReturn'] <> 'returning') then
      Fail('driver[' + IntToStr(i) + '] bad keyReturn');
    if (o.Strings['paramSep'] <> '&') and
      (o.Strings['paramSep'] <> ';') then
      Fail('driver[' + IntToStr(i) + '] bad paramSep');
```

`typeAliases` 只验存在（内容类名由 Registry 覆盖层校验，不在 mautool 重复展开）。

- [ ] **Step 3d: 文档对齐**

`docs/DIALECT-MATRIX.md` 开头接口段改写为：

```markdown
接口 `src/core/TyFPJDBC.Dialect.Api.pas`：`IJdbcDialect`（`PagedSQL` /
`QuoteIdent` / `KeyReturn` / `DialectId`），实现是唯一的 `TGenericDialect`
（`src/core/TyFPJDBC.Dialect.Base.pas`），由驱动描述的风格枚举配出；
`DialectFor(DriverId)` 未知抛 `08000`。风格枚举与类型别名见
`docs/superpowers/specs/2026-09-25-tyfpjdbc-generic-dialect-design.md` §2。
```

分页表与引用表保留行为行，仅把左侧“方言”列改为风格值（`limit-offset` / `offset-fetch-next` / `offset-fetch-first`；`double / backtick / bracket`），`postgresql（base）` 等旧名移到“覆盖库”列。主键回填段“只有 `postgresql` 实现”改为“只有 `keyReturn=returning`（postgresql）配出”。已验证组合段追加：`TestDialect` 含 `mydb/mydb2` 假想库（零源码新增证明）。

`docs/DRIVER.md` 第 54–55 行两句改为：“嵌入式判定走驱动描述的 `embedded` 字段（sqlite/h2/duckdb/derby/hsqldb 为真），只替换 `{database}`；`Extra` 连接符走 `paramSep`（mssql 为 `;`，其余为 `?k=v&...`）。”

- [ ] **Step 4: 运行测试确认变绿**

Run: `fpc ... tests/TestDialect.lpr` + exe → `TOTAL fails=0` 含 `json-overlay-*` / `json-bad-enum`；`fpc ... tests/TestTypes.lpr` → `TOTAL pass=62 fail=0`；`pwsh -NoProfile -File scripts/guard.ps1` → `guard ok`；`test-results/bin/mautool.exe --verify-manifests --config configs/drivers.json` → `manifests verified`（先重编 mautool：`fpc -FUtest-results/work/units -Fusrc/core -otest-results/bin/mautool.exe src/tools/mautool.lpr`）。
Expected: 全部绿色。

- [ ] **Step 5: 全矩阵并提交**

Run（PG 5432、MySQL 3306 需存活，`TestBinding` 四库实跑）: `pwsh -NoProfile -File scripts/run-matrix.ps1`
Expected: `MATRIX-FAILURES=0` + `MATRIX-OK`。

```bash
git add configs/drivers.json src/core/TyFPJDBC.Driver.Registry.pas src/tools/mautool.lpr tests/TestDialect.lpr docs/DIALECT-MATRIX.md docs/DRIVER.md
git commit -m "test: driver style overlays from json with full gate green"
```

---

## Self-Review（已自检并内联修复）

1. **Spec 覆盖**：§0 纯零代码 → 各任务只加描述、不改热路径与 `Bridge.java`；§1 三边缘点 → Task 1（连接描述）/ Task 2（SQL 风格）/ Task 3（类型名）；§2 六字段 → Task 1（内存字段）+ Task 4（JSON 落地）；§3 查表流程 → Task 2（`DialectForEntry`）+ 删六文件清单；§4 非目标 → 全任务 Global Constraints 复述；§5 验收 → Task 4-Step 5 矩阵。
2. **占位符扫描**：无 TBD/TODO；25 条目用“默认 + 例外表”精确表达；`TIME → time` 的笔误在 Task 3-Step 3 已显式纠正；JSON 缺键覆盖内置值的陷阱在 Step 3a 已用 `Find <> nil` 守卫修复。
3. **类型一致**：风格枚举定义于 `Driver.Registry`（Task 1）→ Task 2/4 原样引用；`TDriverEntry.TypeAliases` 为 `TStringArray` 的 `'NAME=class'`（Task 1 定义 → Task 3/4 同格式读写）；规范类名 11 个（Task 3 `ClassToFieldType` ↔ Task 4 `CheckAliasClass` 同表）；`MapTypeFor` 签名三处一致；`0.9.0` 无任务触碰。
