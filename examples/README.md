# Examples

每个用法至少一个可运行示例。FPC 示例用 `fpc -Fu src/core -Fu src/db` 编译；
`ex01` 需要 `sqlite3.dll` 在 exe 旁边（`C:\Tools\sqlite3.dll` 有一份）。
Java 示例用 `javac -cp <bridge jars>` 编译。

| 用法 | 示例 | 说明 |
|---|---|---|
| 连接 + `SELECT 1` + 中文读写 | `ex01_connect_select.lpr` | Lazarus 自带 `sqlite3conn` 直连 `:memory:` |
| 命名参数 `:name` → `?` + 防注入 | `ex02_named_params.lpr` | `TSqlParser` 转换、`Macro` 白名单 |
| 批量分页取数 20k/1000 | `ex03_batch_fetch.lpr` | `RowsetSize` 分页 |
| 可编辑 + 主键回取 + 注入当值存 | `ex04_edit_apply.lpr` | `CachedUpdates/ApplyUpdates/getGeneratedKeys` |
| 事务 + savepoint + 池借还 | `ex05_transaction.lpr` | `TJDBCConnection` + `TJDBCHikariPool` |
| BLOB 流式 | `ex06_blob_stream.lpr` | `NeedStream` + `TMemoryStream` |
| 多语句迁移脚本切分 | `ex07_script_migrate.lpr` | `TJDBCScript.Split` |
| 池监控 + 慢查询回调 | `ex08_pool_stats.lpr` | `OnPoolStats/OnSlowQuery` |
| 图形化 DBGrid/DBEdit/DBNavigator | `ex09_dbgrid/` | `lazbuild` 工程，界面全画在 `unit1.lfm`，`TJDBCQuery` 直绑 `TDataSource` |
| Java 桥端到端 | `BridgeDemo.java` | `Bridge` 经 H2 跑通读写 |

```powershell
# 单个示例
fpc -Fusrc/core -Fusrc/db -oex01.exe examples/ex01_connect_select.lpr
Copy-Item C:\Tools\sqlite3.dll . -Force  # 仅 ex01 需要
.\ex01.exe
# 图形化示例（LCL 工程）
lazbuild examples/ex09_dbgrid/ex09_dbgrid.lpi
.\test-results\bin\ex09\ex09_dbgrid.exe
# Java
$cp="C:\Tools\tyfpjdbc-libs\HikariCP-5.1.0.jar;C:\Tools\tyfpjdbc-libs\slf4j-api-2.0.9.jar;C:\Tools\tyfpjdbc-libs\h2-2.2.224.jar"
& "$jh\bin\javac.exe" -cp $cp -d out examples/BridgeDemo.java java/bridge/src/main/java/tyfpjdbc/Bridge.java
```
