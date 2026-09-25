# TyFPJDBC 方言矩阵（DIALECT-MATRIX）

接口 `src/core/TyFPJDBC.Dialect.Api.pas`：`IJdbcDialect`（`PagedSQL` /
`QuoteIdent` / `KeyReturn` / `DialectId`），`DialectFor(DriverId)` 未知抛
`08000`。形状断言在 `tests/TestDialect.lpr`（19 项）；语义基线在
`tests/TestSemantic.lpr`（H2/SQLite 常跑，PG/MySQL 有容器才跑，
基线落 `test-results/work/semantic/baseline-<dbid>.txt`，不入库）。

## 分页

| 方言 | PagedSQL('SELECT * FROM t ORDER BY id', 10, 20) | 真库执行 |
|---|---|---|
| postgresql（base） | `... ORDER BY id LIMIT 10 OFFSET 20` | PG 容器：`LIMIT 2 OFFSET 1` 取回 `2,3` |
| mysql / mariadb（base） | `... ORDER BY id LIMIT 10 OFFSET 20` | 待容器（MySQL 无 manifest，当前 SKIP，PG 覆盖服务端语义） |
| sqlite（base） | `... ORDER BY id LIMIT 10 OFFSET 20` | SQLite：`LIMIT 2 OFFSET 1` 取回 `2,3` |
| h2（base） | `... ORDER BY id LIMIT 10 OFFSET 20` | H2：`LIMIT 2 OFFSET 1` 取回 `2,3` |
| mssql | `... ORDER BY id OFFSET 20 ROWS FETCH NEXT 10 ROWS ONLY`（需 ORDER BY） | 形状断言，无真库 |
| oracle（12c+） | `... ORDER BY id OFFSET 20 ROWS FETCH FIRST 10 ROWS ONLY` | 形状断言，无真库 |

## 标识符引用

| 方言 | 规则 | 例 |
|---|---|---|
| postgresql / oracle / sqlite / h2（base） | `"` 包裹，内嵌 `"` 双写 | `weird"name` → `"weird""name"` |
| mysql / mariadb | 反引号包裹，内嵌反引号双写 | ``weird`name`` → `` `weird``name` `` |
| mssql | `[`...`]`，内嵌 `]` 双写 | `a]b` → `[a]]b]` |

大小写折叠观测（`TestSemantic` 的 `fold-observed`，JDBC 不统一、各库自有语义）：
H2 建 `SemFold` 读回 `SEMFOLD`；SQLite 读回 `SemFold`。创表与查询大小写必须一致，
不要跨库假设折叠规则。

## 主键回填

只有 `postgresql` 实现 `KeyReturn(Table, Key) = ' RETURNING "key"'`；
其余方言返回空串，走 `getGeneratedKeys` 路径。
`TJdbcQuery.ApplyUpdates2` 当前对无 `KeyField` 表直接抛 `HY092/47`，
拒绝无键写（`TestData` 的 `unkeyed-refused` 断言）。

语义基线（`genkeys` 行）：H2 `1,2`；SQLite `1,2`；插入后回填键逐一重查一致，
PG/MySQL 待容器补行。

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

## 错误与超时采样

`TestSemantic` 的 `error-state` 行记录坏语句的 `SQLState`（H2/SQLite 当前为
`HY000`，属驱动原生分类，见 TROUBLESHOOTING 速查）；`timeout-attr` 行记录
`SetTimeout(5)` 后 trivial 查询正常（`accepted`）。取消/超时的真假按库记录，
不强求一致。

## 已验证组合

- `TestDialect`：六方言分页/引用/`RETURNING`、未知方言 `08000`、
  URL 拼装（pg 默认端口、sqlite/h2、pg extra）、`BuildProperties`、
  自定义 `mydb` 注册。
- 真库回环：H2（`TestEngine/Data/ProcBlob/Soak/Lcl/Tx/Injection` + `TestSemantic`）、
  SQLite（文件库 `TestSemantic` + tiers 性能）。
  PG/MySQL 无本地真库时矩阵记 `SKIP` 环境缺失，见矩阵日志。
