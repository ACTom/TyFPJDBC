# TyFPJDBC

[English](README_EN.md)

给 Free Pascal / Lazarus 用的通用 JDBC 桥：一套代码连 25 种数据库，写法不变；拖控件和纯代码两种用法都支持。

Java `Bridge` 是唯一状态机（池、连接、语句、游标全在它里面），Pascal 侧只拿 `Int64` 句柄，不直连 JNI。

## 特性

- 25 个驱动注册表（PostgreSQL/MySQL/MSSQL/Oracle/SQLite/H2 等），未知驱动直接报错，不静默兜底
- 通用方言：分页、标识符引用、主键回填按驱动描述配出，加新库不用改源码
- 连接池（HikariCP）与直连双模式，可开关
- LCL 设计时组件：`TJdbcConnection` + `TJdbcConnQuery`，拖上窗体设属性即用
- 类型真值表：整数/浮点/字符串（含 CJK）/日期/布尔/BLOB 按契约来，空与 NULL 分开
- mautool：驱动 jar 与 JRE运行时 的下载、校验、分发

## 快速开始（不用脚本）

1. **下载**：Releases 页下源码包解压（或 `git clone`）。
2. **安装设计包**：Lazarus → `Package` → `Open Package File` →
   选 `tyfpjdbc_design.lpk` → `Install`（重编一次 IDE）。
3. **新建项目**：拖 `TJdbcConnection` + `TJdbcConnQuery`
   （再加 `TDataSource` + `DBGrid` 照连）；`DriverId` 选 `sqlite`，
   `Database` 填 db 文件路径。
4. **下驱动**：右键 connection → `Connection setup...` → `Download` →
   `Test` → OK，全程点鼠标。
5. **下 JRE**：去 `runtime/*` Release 下对应平台的 zip，解压，
   把内层目录改名 `jre/` 放到 exe 输出目录旁。
6. **F9 运行**。想看完整可跑的例子直接打开 `examples/ex20_contacts/`。

## 自动化用法（CI/脚本）

上面全程手点嫌慢就走命令行：

```powershell
mkdir test-results/bin
fpc "-Fusrc/core" "-otest-results/bin/mautool.exe" "src/tools/mautool.lpr"
cd examples\ex20_contacts
lazbuild contacts.lpi
..\..\test-results\bin\mautool.exe --fetch-runtime --platform win64 --out runtime --config ..\..\configs\drivers.json
Expand-Archive runtime\jre-25-tyfpjdbc-win64.zip .
Rename-Item jre-25-tyfpjdbc-win64 jre
Move-Item jre\bridge .
Move-Item jre\drivers .
..\..\test-results\bin\mautool.exe --fetch-driver sqlite --out drivers --config ..\..\configs\drivers.json
.\contacts.exe --selftest   # TOTAL fails=0 即通
```

## 前置要求

Windows 64 位 + Lazarus（FPC 3.2.2）。JDK 不需要装：裁剪好的 JRE 跟着程序走（`mautool --fetch-runtime` 拉取，exe 旁 `jre/`）。

## 最小用法

```pascal
uses TyFPJDBC.JVM.Manager, TyFPJDBC.JNI.Bridge, TyFPJDBC.Engine,
  TyFPJDBC.Command, TyFPJDBC.Query;

TJVMManager.EnsureStarted(TJVMManager.FindLibJvm(''),
  TJVMManager.BuildDesktopArgs);
eng := TJdbcEngine.Create(TBridge.Create);
pool := eng.OpenPool(DefaultPoolCfg('jdbc:sqlite:' + DbPath, 'org.sqlite.JDBC'));
conn := eng.Borrow(pool);

q := TJdbcQuery.Create(nil);   // 读：窗口查询
q.OpenQuery(eng, conn, 't', 'SELECT id,name FROM t ORDER BY id', 200);

cmd := TJdbcCommand.Create(eng, conn);   // 写：命名参数
cmd.SetSQL('INSERT INTO t(name) VALUES(:n)');
SetLength(r, 1); r[0] := BStr('hi');     // r: TBoundRow
cmd.ExecUpdate(r);
```

字段读写一律 `AsUTF8String`。完整可跑的例子见 `examples/`。

## 示例

| 目录 | 说明 |
|---|---|
| `examples/ex20_contacts/` | 图形通讯录（LCL 拖控件完整应用，含自检） |
| `examples/ex11_code_first.lpr` | 纯代码：建池建表批量插入窗口查询 |
| `examples/ex12_dbgrid.lpr` | 网格绑定：浏览编辑新增落库重查 |
| `examples/ex10_json_config.lpr` | 读配置列出驱动与运行时 |
| `examples/ex01_connect_select.lpr` | Lazarus 自带 `sqlite3conn` 对照（非本库） |

## 文档地图

- 加新驱动/换库：`docs/DRIVER.md`
- 分页/引用/回填/绑定契约：`docs/DIALECT-MATRIX.md`
- 报错/SQLError/乱码/泄漏：`docs/TROUBLESHOOTING.md`
- 发版设计：`docs/superpowers/specs/`

## 发版

runtime（裁剪 JRE + bridge jars）随 GitHub Release 发版：`runtime/*` tag
（或 Actions 手动触发）自动构建 5 平台包并回填 `configs/runtimes.json`
（含各平台 sha256 与所属 tag）。`mautool --fetch-runtime` 按清单校验下载；
`mautool --verify-manifests` 校验清单自洽。

## 开发

```powershell
pwsh -NoProfile -File scripts/guard.ps1          # 门禁：无 UI 引用进 core、无源码旁产物
pwsh -NoProfile -File scripts/run-matrix.ps1     # 全矩阵（部分段需本地 PG/MySQL，无则 SKIP）
```

构建产物约定：`.o`/`.ppu` 只进 `test-results/work/units`，
`exe` 只进 `test-results/bin`；`zips/` 永不进 git。

## 许可

MPL-2.0
