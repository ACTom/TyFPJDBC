# Examples

每个用法至少一个可运行示例。FPC 示例用 `fpc -Fu src/core -Fu src/db -FUtest-results/work/units` 编译
（`.o`/`.ppu` 单元产物进 `test-results/work/units`，不落源码旁；`exe` 进 `test-results/bin`）；
`ex01` 需要 `sqlite3.dll` 在 exe 旁边（`C:\Tools\sqlite3.dll` 有一份）。
Java 示例用 `javac -cp <bridge jars>` 编译。

| 用法 | 示例 | 说明 |
|---|---|---|
| 连接 + `SELECT 1` + 中文读写 | `ex01_connect_select.lpr` | Lazarus 自带 `sqlite3conn` 直连 `:memory:` |
| 代码优先（建池建表批量插入窗口查询） | `ex11_code_first.lpr` | `TJVMManager` + `TBridge` + `TJdbcEngine` + `TJdbcCommand` + `TJdbcQuery`，H2 回环 `inserted=3 rows=3 handles=0` |
| 网格绑定（浏览编辑新增落库重查） | `ex12_dbgrid.lpr` | `TJdbcQuery` 绑 `TDataSource` 按网格方式浏览，编辑一行直写，新增两行经 `ApplyUpdates2` 落库，重查 `requery-rows=4 handles=0` |
| 配置复用只读演示 | `ex10_json_config.lpr` | 读同一份 `configs/drivers.json` + `configs/runtimes.json`，列出驱动/运行时并解析 sqlite 条目到本地 jar |

```powershell
# 单个示例
fpc -Fusrc/core -Fusrc/db -FUtest-results/work/units -otest-results/bin/ex01.exe examples/ex01_connect_select.lpr
Copy-Item C:\Tools\sqlite3.dll test-results/bin -Force  # 仅 ex01 需要
.\test-results\bin\ex01.exe
# 查询示例（需 H2/JVM，classesDir 指向已编译 Bridge）
fpc -Fusrc/core -Fusrc/db -FUtest-results/work/units -otest-results/bin/ex11.exe examples/ex11_code_first.lpr
fpc -Fusrc/core -Fusrc/db -FUtest-results/work/units -otest-results/bin/ex12.exe examples/ex12_dbgrid.lpr
```
