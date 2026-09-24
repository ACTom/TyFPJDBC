# TyFPJDBC V2 排障（TROUBLESHOOTING）

## SQLState 速查

| SQLState | VendorCode | 含义 | 常见触发 |
|---|---|---|---|
| HY000 | 99 | 坏句柄 | `pool/conn/stmt/cursor <= 0`；`CheckHandle` 本地先抛，不进 JNI |
| 08000 | 31/32/40/41/42 | 连接/驱动/参数缺失 | 未知驱动（40）、缺 host（41）、缺 database（42）、坏 URL（HY092/40 见下） |
| HY092 | 41/46/47 | 非法选项或写约束 | 坏 savepoint 名、坏超时、缺表名（46）、无键写（47） |
| HY008 | — | 取消 | `TJdbcCommand.Cancel` 后执行 |
| HYT00 | — | 超时 | `setQueryTimeout` 到期 |
|（驱动原生） | 驱动码 | 驱动错误链 | `BridgeV2.getErrorChain()` ThreadLocal 取全链 |

未知方言同样 `08000`（`DialectFor('nosuch')`）。

## JVM 起不来

1. `FindLibJvmV2` 顺序：显式路径 → 自带 `jre/` → `JAVA_HOME` →
   Windows 注册表 → `PATH` → macOS dylib。`TestV2Jvm` 断言缺失路径报错含
   `libjvm`。
2. 含空格路径必须走数组传参（`BuildArgArray`/`JoinArgs` 引号配对），
   不要按空格切分。
3. 配置变化视为不同运行时：已启动且配置不同会抛错，先 `ShutdownJvm`。
4. `JniVersionUsed = $00010006`（`jni` 单元只到 JNI 1.6），JDK 25 实测可用。

## 中文乱码

旧 `AsString` 走 ANSI 会在 GBK 控制台下损坏 CJK。
V2 纪律：双向一律 `AsUTF8String`（`TestV2Data` 的 `cjk-verbatim` 断言
`'中文测试'` 长度 12 原样往返）。控制台显示损坏不等于数据损坏，
以测试断言为准。

## H2 42103 / 表找不到

H2 对未引用标识符折叠为大写。`TJV2Query.Quoted` 当前是未引用直通
（建表 `T` 则查 `T`），对方言引用只在 DML 生成器里经
`Dialect.QuoteIdent` 处理。创表与查询大小写必须一致。

## H2 ALIAS 冲突（90076）

H2 的 ALIAS 注册在同一 JVM 内全局存活，`mem` 库关闭也不消失。
测试用 `bitcount<PID>` + `v2proc<PID>` 按进程隔离（`TestV2ProcBlob`）。

## mautool MISMATCH

- `checksum MISMATCH`：文件与期望 `sha1`/`sha256` 不一致，下载件已删除，
  用正确哈希重跑（`TestV2Distrib` 同时覆盖 accept 与全零 reject）。
- `unknown driver`：驱动 id 不在 `configs/drivers.json`。
- GPL 驱动（`mysql`）无 `--accept-license` 且无 marker 时会交互要求输入
  `ACCEPT`，自动化脚本必须传 flag。

## 句柄泄漏

每次测试结尾断言 `eng.HandleCount = 0`；soak 另断言线程引擎归零与
`AttachedCount` 回基线。释放顺序：游标 → 语句 → 连接 → 池 → JVM。
`TJV2Query.CloseQuery` 逆序释放，可重复调用。
