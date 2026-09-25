# TyFPJDBC 方言矩阵（DIALECT-MATRIX）

接口 `src/core/TyFPJDBC.Dialect.Api.pas`：`IJdbcDialect`（`PagedSQL` /
`QuoteIdent` / `KeyReturn` / `DialectId`），`DialectFor(DriverId)` 未知抛
`08000`。全部行为由 `tests/TestDialect.lpr`（19 项）断言。

## 分页

| 方言 | PagedSQL('SELECT * FROM t ORDER BY id', 10, 20) |
|---|---|
| postgresql（base） | `... ORDER BY id LIMIT 10 OFFSET 20` |
| mysql / mariadb（base） | `... ORDER BY id LIMIT 10 OFFSET 20` |
| sqlite（base） | `... ORDER BY id LIMIT 10 OFFSET 20` |
| h2（base） | `... ORDER BY id LIMIT 10 OFFSET 20` |
| mssql | `... ORDER BY id OFFSET 20 ROWS FETCH NEXT 10 ROWS ONLY`（需 ORDER BY） |
| oracle（12c+） | `... ORDER BY id OFFSET 20 ROWS FETCH FIRST 10 ROWS ONLY` |

## 标识符引用

| 方言 | 规则 | 例 |
|---|---|---|
| postgresql / oracle / sqlite / h2（base） | `"` 包裹，内嵌 `"` 双写 | `weird"name` → `"weird""name"` |
| mysql / mariadb | 反引号包裹，内嵌反引号双写 | ``weird`name`` → `` `weird``name` `` |
| mssql | `[`...`]`，内嵌 `]` 双写 | `a]b` → `[a]]b]` |

## 主键回填

只有 `postgresql` 实现 `KeyReturn(Table, Key) = ' RETURNING "key"'`；
其余方言返回空串，走 `getGeneratedKeys` 路径。
`TJdbcQuery.ApplyUpdates2` 当前对无 `KeyField` 表直接抛 `HY092/47`，
拒绝无键写（`TestData` 的 `unkeyed-refused` 断言）。

## 已验证组合

- `TestDialect`：六方言分页/引用/`RETURNING`、未知方言 `08000`、
  URL 拼装（pg 默认端口、sqlite/h2、pg extra）、`BuildProperties`、
  自定义 `mydb` 注册。
- 真库回环：H2（`TestEngine/Data/ProcBlob/Soak/Lcl`）、SQLite 驱动 jar
  就绪（`sqlite-jdbc-3.46.1.0.jar`）。PG/MySQL/MSSQL/Oracle 无本地真库，
  本轮以方言纯逻辑断言 + URL 拼装覆盖，见矩阵日志环境缺失记录。
