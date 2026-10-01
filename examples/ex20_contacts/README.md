# 通讯录 Demo（TyFPJDBC 开箱验证）

LCL 图形通讯录：DBGrid 浏览 + 搜索 + 新增/修改/删除，SQLite 落 `contacts.db`。

本目录只进源码（二进制与数据库不进 git，见下）。在一台干净机器上：

```powershell
cd examples\ex20_contacts
lazbuild contacts.lpi
..\..\test-results\bin\mautool.exe --fetch-runtime --platform win64 --out runtime
..\..\test-results\bin\mautool.exe --fetch-driver sqlite --out drivers
.\contacts.exe                # 图形界面：搜索 / 新增 / 修改 / 删除
.\contacts.exe --selftest     # 无界面自检，结果写 selftest.log
Get-Content selftest.log      # 期望 TOTAL fails=0
.\contacts.exe --verifyform   # 窗体装配校验，结果写 verifyform.log
Get-Content verifyform.log    # 期望 TOTAL fails=0
```

> mautool 本体先编出来：`fpc -Fusrc/core -otest-results/bin/mautool.exe src/tools/mautool.lpr`
> （在仓库根执行）。GPL 许可的驱动（如 MySQL）下载时需另行确认，见输出提示。

`mautool` 会把运行时摆成程序要的样子（`jre/` + `bridge/` + `drivers/` 全在
exe 旁边）：不装 JDK、不配环境变量、不读系统 JRE。首次运行自动建
`contacts.db`。首跑空表会自动写入 3 条示例（张三/李四/王五），打开就能
看到数据。

## 查找规则

`TJVMManager.FindLibJvm` / 默认 classpath：只认 exe 旁 `jre/`，classpath
由程序枚举 `bridge/*.jar` + `drivers/*.jar` 拼出，不展开 `*` 通配符
（JNI 的 `-Djava.class.path` 不展开通配符，已实测）。

自检内容：JVM 启动、classpath 形状、SQLite 插入 1 行、重查行数、
中文 `张三-中文` 原样往返、句柄 `HandleCount=0` + 审计全零。

窗体校验内容：主窗体实例化（走完整 `FormCreate`/建库/种子链路），
lfm 控件全部装上、`TDataSource` 已绑数据集且种子行不少于 3 行、
状态栏含记录数、`DBGrid.DataSource` 指向正确。

## 自己改着玩

1. 用 Lazarus 打开 `contacts.lpi`，直接编译（`OtherUnitFiles` 是相对路径
   `../../src/...`，指向主仓源码，无需装包）。
2. 换库：把对应 JDBC jar 丢进 `drivers/`（或 `mautool --fetch-driver`），改
   `contactsmain.pas` 里连接信息的 URL + DriverClass（PG/MySQL 需要真库在跑）。
3. 改窗体（`.lfm`）后必须重建资源再编译，否则界面不更新：
   `lazres.exe contactsmain.lrs contactsmain.lfm`，
   然后 `lazbuild contacts.lpi`（`.lrs` 按类名 `TMainForm` 注册，
   手工 `lazres xx.res xx.lfm` 会按文件名注册导致窗体空白，切勿这样做）。
4. 字段读写一律 `AsUTF8String`，不要用 `AsString`（GBK 控制台会坏 CJK）。

## 已知现象（不是 bug）

- 控制台出现 `SLF4J: No SLF4J providers` 和 sqlite 的 `System::load`
  native-access 警告：上游 jar 的常规输出，不影响功能。
- IDE 里 F9 调试启动时，调试器可能报一次
  `External: ACCESS VIOLATION ... reading from address $0`：
  这是 HotSpot 在 JIT 代码里的一次隐式空指针陷阱（内部抛接、
  触发一次后即 deopt），已被 JVM 自己处理，点 Continue 照常运行。
  双击 exe / `Run Without Debugging` 从不出现。
- exe 约 8MB，`jre/` 约 38MB：裁剪 JRE 的正常体积。
