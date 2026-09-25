# TyFPJDBC 通用方言规格（generic dialect）

版本：0.1（brainstorming 方案 A 三节已确认，待评审后转 implementation plan）
日期：2026-09-25
基线：master（version 0.9.0，无 v2 后缀命名）
目标：消灭 `pas` 产品代码与 `Bridge.java` 中的 `if db == xxx` 分支，新库只加驱动描述文件，不改 `pas` / `java` 源码。

## 0. 约束（已确认）

- `pas` 源码与 `Bridge.java` 中没有针对 H2 / SQLite / PG / MySQL 的 `if` 分支，这个结论是盘点结论，不是假设。
- 达标线是纯零代码：新库允许加一段驱动描述文件，不允许改任何 `pas` / `java` 源码文件。
- `Bridge.java` 零改动：它只认 JDBC 标准 `Types` 码与 typed `getter/setter`，差异由各库 JDBC 驱动消化。
- `0.9.0` 版本握手、`JniVersionUsed = $00010006`、`.o` / `.ppu` 永不落源码旁、`guard.ps1` 门禁保持不变。
- `IJdbcDialect` 签名不变：`DialectId` / `PagedSQL` / `QuoteIdent` / `KeyReturn`。
- 未知驱动仍抛 `08000`，未知类型仍按 `UnknownTypeFallback` 抛 `HY000/45`，不加静默回退。

## 1. 目标与总体结构（已确认）

- 读写热路径本来就是通用的，保持不动：`Bridge.java` 的 `fetchWindow` / `bindLong` / `bindBigDecimal` / `bindBoolean` / `bindBytes` / `bindNull`，Pascal 侧的 `BindRow` / `CollectRow` / `FillField` / `FillPage` / `FetchPage`。
- 真正的分库差异只收敛到三个边缘点，全部数据化：
  1. SQL 文本风格：分页写法、标识符引用、主键回填，现状散在 `TyFPJDBC.Dialect.Pg` / `Mysql` / `Mssql` / `Oracle` 四个小子类里。
  2. 类型名拼写：`BYTEA` / `IMAGE` / `LONGBLOB` 等，现状硬编码在 `MapType` 的 `or` 串里。
  3. 连接描述：URL 模板、默认端口、`TestQuery`、内嵌与否、参数分隔符，现状硬编码在 `RegisterBuiltinDrivers`，外加 `BuildUrl` 里一个 `mssql` 特判。
- 新结构：删除按库分的方言单元，只留一个由驱动描述配置出来的 `TGenericDialect`；`TDriverEntry` 扩展风格字段；描述文件是唯一新增入口；`MapType` 变成别名表查表。
- 测试里的 `BlobCol` / `DdlAuto` / URL / 大小写 / `SKIP` 接线差异保留，那是测试在喂各库真实语法，不是产品分支。

## 2. 驱动描述字段与方言风格枚举（已确认）

每个驱动用一个描述项表达全部差异，示例：

```json
{
  "id": "mydb",
  "driverClass": "com.example.jdbc.Driver",
  "urlTemplate": "jdbc:mydb://{host}:{port}/{database}",
  "defaultPort": 1234,
  "testQuery": "SELECT 1",
  "embedded": false,
  "paging": "limit-offset",
  "quote": "double",
  "keyReturn": "none",
  "paramSep": "&",
  "typeAliases": { "MYBLOB": "blob", "MYTEXT": "widememo" }
}
```

字段语义：

- `paging`：`limit-offset` 对应 base 的 `LIMIT … OFFSET …`；`offset-fetch-next` 对应 mssql 的 `OFFSET … ROWS FETCH NEXT … ROWS ONLY`；`offset-fetch-first` 对应 oracle 的 `OFFSET … ROWS FETCH FIRST … ROWS ONLY`。
- `quote`：`double` 是 `"` 包裹内嵌双写；`backtick` 是反引号包裹；`bracket` 是 `[` … `]` 内嵌 `]` 双写。
- `keyReturn`：`returning` 只用于 postgresql 的 `RETURNING "key"`；其余为 `none`，走 `getGeneratedKeys` 路径。
- `paramSep`：`&` 对应 `?a=1&b=2`，`;` 对应 mssql 的 `;a=1;b=2`，收掉 `BuildUrl` 里唯一的 `LowerCase(e.Id) = 'mssql'` 特判。
- `embedded`：为真只替换 `{database}`；为假替换 `host` / `port` / `database` 并校验 `host` / `database` 非空，替代 `IsEmbedded` 的 `sqlite/h2/duckdb/derby/hsqldb` 硬编码名单。
- `typeAliases`：把 `MapType` 里 `BLOB/BYTEA/IMAGE/LONGBLOB` 这类并集硬编码搬成数据；键为规范化后的类型名（大写、去括号参数），值为规范分类名，仅允许 `widestring` / `widememo` / `integer` / `largeint` / `fmtbcd` / `float` / `boolean` / `date` / `time` / `datetime` / `blob`；查不到时走全局别名表，再查不到走现有 `UnknownTypeFallback`，`HY000/45` 不变。
- `MapByCode` 不动，它认的是 JDBC 标准整型码，本来就是通用的。
- `DialectFor(DriverId)` 签名不变，内部不再查分库注册表，改为查驱动描述并现场配出 `TGenericDialect`；描述文件缺失时回退到内置表，保证老行为。
- 描述文件校验失败报 `HY000/45` 并带文件名与字段名，不静默。未知枚举值、缺 `driverClass`、缺 `urlTemplate` 都属于校验失败。

现有 `configs/drivers.json` 已有 `id` / `driverClass` / `urlTemplate` / `defaultPort` / `testQuery` / `license` / `maven` / `sha1` 字段，本 spec 只新增 `embedded` / `paging` / `quote` / `keyReturn` / `paramSep` / `typeAliases` 六个风格字段，不改现有字段语义。

## 3. 查表流程与删文件清单（已确认）

流程只有一条：`DriverId → 驱动描述 → 配出通用方言`，中间无 `if db == xxx`。

- `DialectFor('mydb')`：先查 `configs/drivers.json` 里的自定义项，再查内置表，取到描述后按 `paging` / `quote` / `keyReturn` 配出一个 `TGenericDialect` 实例并返回 `IJdbcDialect`。
- `BuildUrl`：`embedded` 为真只替换 `{database}`；否则替换 `{host}` / `{port}` / `{database}`，`port <= 0` 时用 `defaultPort`，`Extra` 参数按 `paramSep` 拼接，`?` 已存在时用对应分隔符追加。
- `MapType`：先规范化类型名（去括号参数、去空格后缀、转大写），先查该库 `typeAliases`，再查全局别名表（即现状 `MapType` 的 `or` 串整体下沉），再走 `UnknownTypeFallback`。行为与现在一致，只是硬编码串变成数据。
- 删文件：删除 `TyFPJDBC.Dialect.Pg` / `Mysql` / `Mssql` / `Oracle` / `H2` / `Sqlite` 六个单元；保留 `Dialect.Api`（接口不变）与 `Dialect.Base`（改造成由风格枚举配置的 `TGenericDialect`）；删除 `initialization` 里逐个 `RegisterDialect` 的写法，改为查表配出。
- 读写热路径一行不改：`Bridge.java` 的 `fetchWindow` / `bindX`、`TyFPJDBC.Command.BindRow`、`TyFPJDBC.Dataset.Adapter.CollectRow` / `FillField` / `FillPage` 保持通用。
- 测试只加一个纯逻辑回归：构造一个假想新库描述（如 `mydb`），断言分页、引用、建 URL、类型别名都按描述走，不连真库；现有 `TestDialect` / `TestBinding` / `TestSemantic` 行为不变，矩阵 expectations（`TestTypes 62`、`binding-*`）不动。

## 4. 非目标

- 不改池、事务、句柄、JNI 形状、`createPoolFlat` 参数表、错误分类（`ecRetryable` / `ecFatal` / `ecConfig` / `ecDriver`）。
- 不改 `Bridge` 版本握手与 JNI 上限；不做性能优化；不统一各库的折叠、错误码、超时语义，只收敛本库的分支形状。
- 不把测试接线差异当产品分支改：`TestBinding` 的 `BlobCol`、表名小写、`SKIP-BINDING-*` 保留。

## 5. 验收

- `src` 下无按库名的 `if` / `case` 分支：`grep` `postgres|mysql|mssql|oracle|sqlite|h2` 只命中驱动描述、别名表、测试与文档。
- 新增一个假想库描述文件即可通过纯逻辑回归，无需改 `pas` / `java` 源码。
- `TestDialect` / `TestTypes` / `TestBinding`（H2/SQLite/PG/MySQL）全绿；`guard.ps1` 全绿；完整矩阵 `MATRIX-OK`。
