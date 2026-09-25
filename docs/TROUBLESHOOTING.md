# TyFPJDBC 排障（TROUBLESHOOTING）

## 错误分类速查（TJdbcErrors）

| 分类 | 含义 | SQLState | 恢复建议（`ErrAdvice`） |
|---|---|---|---|
| `ecRetryable` | 可重试 | `HYT00` 超时、`HY008` 取消、`08001/08006` 连接断、`40001` 死锁 | 退避后重连验证再试 |
| `ecConfig` | 先修配置/SQL | `HY000` 坏句柄/版本 mismatch、`HY092` 非法选项/写约束、`08000` 缺驱动/缺参 | 修配置或 SQL 再试 |
| `ecFatal` | 不盲重试 | `23xxx` 约束违反 | 查约束或数据 |
| `ecDriver` | 驱动原生 | 其余 | `Bridge.ErrorChain` 取全链 |

`TJDBCScript.ExecScript` 的 `stmt N failed` 错误透出原 `SQLState` 并追加分类建议；
`TestTx` 的池打满超时当前为 `HY000`（Hikari 抛 `SQLTransientConnectionException`
经 `08000` 族归一，属驱动原生分类，按 `ecDriver` 处理）。

## SQLState 明细

| SQLState | VendorCode | 含义 | 常见触发 |
|---|---|---|---|
| HY000 | 99 | 坏句柄/版本 | `pool/conn/stmt/cursor <= 0`；`CheckHandle` 本地先抛，不进 JNI；版本 mismatch（期望 `0.9.0`） |
| 08000 | 31/32/40/41/42 | 连接/驱动/参数缺失 | 未知驱动（40）、缺 host（41）、缺 database（42）、坏 URL（HY092/40 见下） |
| HY092 | 41/44/46/47 | 非法选项或写约束 | 坏 savepoint 名（41，`Savepoint_MaxLen=64` 白名单）、坏批量（44）、缺表名（46）、无键写（47） |
| HY008 | — | 取消 | `TJdbcCommand.Cancel` 后执行 |
| HYT00 | — | 超时 | `setQueryTimeout` 到期 |
|（驱动原生） | 驱动码 | 驱动错误链 | `Bridge.getErrorChain()` ThreadLocal 取全链 |

未知方言同样 `08000`（`DialectFor('nosuch')`）。

## 可观测（TJdbcObserve）

- 分级：`Obs_SlowWarnMs=1000`（1 级 slow）、`Obs_SlowErrorMs=5000`（2 级 error），
  `Timed` 返回是否 slow，2 级计入 `ErrorCount`。
- `P95Ms`：已记录样本的 95 分位（空为 0）；`TestTiers` 每 tier 输出
  `p95-page-ms` 与 `obs-p95-ms`。
- 采样：`Obs_SampleEvery=1` 全记；`N` 则每 N 条记一条（`Timed` 返回值仍按阈值算）。
- 池快照：`TJdbcEngine.PoolSnapshot(pool)` 输出
  `active=1 idle=1 waiting=0 leak=0`（`TestTiers` 每 tier 打一行 `snap=`）。
- 句柄审计：`eng.AuditReport` 输出 `pools=0 conns=0 stmts=0 cursors=0`，
  泄漏时直接打印该串定位哪一类没归零。

## JVM 起不来

1. `FindLibJvm` 顺序：显式路径 → 自带 `jre/` → `JAVA_HOME` →
   Windows 注册表 → `PATH` → macOS dylib。`TestJvm` 断言缺失路径报错含
   `libjvm`。
2. 含空格路径必须走数组传参（`BuildArgArray`/`JoinArgs` 引号配对），
   不要按空格切分。
3. 配置变化视为不同运行时：已启动且配置不同会抛错，先 `ShutdownJvm`。
4. `JniVersionUsed = $00010006`（`jni` 单元只到 JNI 1.6），JDK 25 实测可用。

## 中文乱码

`AsString` 走 ANSI 会在 GBK 控制台下损坏 CJK。
纪律：双向一律 `AsUTF8String`（`TestData` 的 `cjk-verbatim` 断言
`'中文测试'` 长度 12 原样往返）。控制台显示损坏不等于数据损坏，
以测试断言为准。

## H2 42103 / 表找不到

H2 对未引用标识符折叠为大写（`TestSemantic` 观测为 `SEMFOLD`，
SQLite 为 `SemFold`）。`TJdbcQuery.Quoted` 当前是未引用直通
（建表 `T` 则查 `T`），对方言引用只在 DML 生成器里经
`Dialect.QuoteIdent` 处理。创表与查询大小写必须一致。

## H2 ALIAS 冲突（90076）

H2 的 ALIAS 注册在同一 JVM 内全局存活，`mem` 库关闭也不消失。
测试用 `bitcount<PID>` + `tjproc<PID>` 按进程隔离（`TestProcBlob`）。

## mautool MISMATCH

- `checksum MISMATCH`：文件与期望 `sha1`/`sha256` 不一致，下载件已删除，
  用正确哈希重跑（`TestDistrib` 同时覆盖 accept 与全零 reject）。
- `unknown driver`：驱动 id 不在 `configs/drivers.json`。
- GPL 驱动（`mysql`）无 `--accept-license` 且无 marker 时会交互要求输入
  `ACCEPT`，自动化脚本必须传 flag。

## 句柄泄漏

每次测试结尾断言 `eng.HandleCount = 0` + `AuditReport` 全零；soak 另断言
线程引擎归零与 `AttachedCount` 回基线。释放顺序：游标 → 语句 → 连接 → 池 → JVM。
`TJdbcQuery.CloseQuery` 逆序释放，可重复调用。
