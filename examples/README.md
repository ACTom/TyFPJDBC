# Examples

每个用法至少一个可运行示例。FPC 示例用 `fpc -Fu src/core -Fu src/db -FUtest-results/work/units` 编译
（`.o`/`.ppu` 单元产物进 `test-results/work/units`，不落源码旁；`exe` 进 `test-results/bin`）；
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
| 图形化 DBGrid/DBEdit/DBNavigator | `ex09_dbgrid/` | `lazbuild` 工程，界面全画在 `unit1.lfm`，`TJDBCQuery` 直绑 `TDataSource`；`GridData.TryLoadLive` 走真实 JNI+sqlite 文件库取数（`TestLiveGrid` 无头覆盖），JVM 不可用时回退内置行 |
| 配置复用只读演示 | `ex10_json_config.lpr` | 读同一份 `configs/drivers.json` + `configs/runtimes.json`，列出驱动/运行时并解析 sqlite 条目到本地 jar |
| V2 代码优先（建池建表批量插入窗口查询） | `ex11_code_first.lpr` | `TJVMManager` + `TBridgeV2` + `TJdbcEngine` + `TJdbcCommand` + `TJV2Query`，H2 回环 `inserted=3 rows=3 handles=0` |
| V2 网格绑定（浏览编辑新增落库重查） | `ex12_dbgrid.lpr` | `TJV2Query` 绑 `TDataSource` 按网格方式浏览，编辑一行直写，新增两行经 `ApplyUpdates2` 落库，重查 `requery-rows=4 handles=0` |
| Java 桥端到端 | `BridgeDemo.java` | `Bridge` 经 H2 跑通读写 |

```powershell
# 单个示例
fpc -Fusrc/core -Fusrc/db -FUtest-results/work/units -otest-results/bin/ex01.exe examples/ex01_connect_select.lpr
Copy-Item C:\Tools\sqlite3.dll test-results/bin -Force  # 仅 ex01 需要
.\test-results\bin\ex01.exe
# 图形化示例（LCL 工程）
lazbuild examples/ex09_dbgrid/ex09_dbgrid.lpi
.\test-results\bin\ex09\ex09_dbgrid.exe
# V2 示例（需 H2/JVM，classesDir 指向已编译 BridgeV2）
fpc -Fusrc/core -Fusrc/db -FUtest-results/work/units -otest-results/bin/ex11.exe examples/ex11_code_first.lpr
fpc -Fusrc/core -Fusrc/db -FUtest-results/work/units -otest-results/bin/ex12.exe examples/ex12_dbgrid.lpr
# Java
$cp="C:\Tools\tyfpjdbc-libs\HikariCP-5.1.0.jar;C:\Tools\tyfpjdbc-libs\slf4j-api-2.0.9.jar;C:\Tools\tyfpjdbc-libs\h2-2.2.224.jar"
& "$jh\bin\javac.exe" -cp $cp -d out examples/BridgeDemo.java java/bridge/src/main/java/tyfpjdbc/Bridge.java
```
