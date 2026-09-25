# TyFPJDBC 易用性加固规格（usability hardening）

版本：0.1（brainstorming 三节已确认，待评审后转 implementation plan）
日期：2026-09-25
基线：master `646f080`（1.0 生产级加固已合入，version 0.9.0）
目标：用户装上即用——运行时自包含、驱动向导内下载、包一层即达。

## 0. 约束（已确认）

- 不支持系统 JRE：版本兼容性不可控。查找顺序只剩三档——
  显式路径（用户显式传入才用，报错信息劝退）→ exe 旁 `jre/`（默认）
  → 可配置根（`TJdbcConfig`，见 §1）。`JAVA_HOME`、注册表、`PATH`、
  macOS 固定路径探测全部删除。
- 默认 exe 旁自包含：`jre/`（裁剪运行时）+ `drivers/`（驱动 jar），
  开箱即用；用户可在初始化时改根目录以符合自家程序规范。
- 驱动注册表预置 DBeaver 级别条目（约 30 个，只含元数据不带 jar，
  按需下载）；真库验证仍只有 H2/SQLite/PG/MySQL，其余只做形状断言。
- 对话框下载不依赖外部 exe：下载逻辑抽成库内单元，
  `mautool` 反过来成为该单元的薄壳。

## 1. 运行时目录与 JRE 策略（已确认）

- 默认布局（exe 旁）：
  `<exe>/jre/`（`bin/server/jvm.dll` 或 `lib/server/libjvm.so`）、
  `<exe>/drivers/`（`<artifact>-<ver>.jar`）、
  `<exe>/bridge/`（`Bridge.class` + HikariCP + slf4j）。
- `TJdbcConfig` 新增 `Runtime_Root: string`（默认空 = exe 旁）、
  `Runtime_JvmPath: string`（默认空 = 按布局推导，显式传入才用系统 JRE）。
- `FindLibJvm` 删除 JAVA_HOME/注册表/PATH/macOS 固定路径分支；
  显式路径命中时 `DoLog` 写警告（非确认版本，随时可能不兼容）。
- `SetClassPath` 默认按布局拼接 `bridge/*` + `drivers/*.jar`，
  用户仍可整体覆盖。
- 测试：`TestJvm` 重写——默认布局推导、显式路径放行、
  系统 JRE 不再被自动发现（`JAVA_HOME` 指向假 jvm 时必须报 `libjvm` 错）。

## 2. 驱动选择对话框（已确认，修法一）

- 注册表预置 DBeaver 主流驱动条目（约 30 个，见约束），
  每个条目：`id、driverClass、urlTemplate、默认端口、testQuery、
  maven 坐标、许可`。
- 新增 `src/db/TyFPJDBC.Driver.Fetch.pas`（纯 Pascal，`fphttpclient`）：
  下载 → 验 `sha1` → 原子改名；`mautool` 的下载分支改为调它
  （行为不变，`TestDistrib` 全过）。
- `TJdbcConnDialog` 完整向导：驱动列表（含许可提示，GPL 标黄）→
  jar 状态（存在/mismatch/缺失）→ 一键下载（进度，GPL 先勾接受）→
  Test 真连通（`testQuery`，成功才启用 OK，延续 `TestedOk` 门控）→
  OK 写回 `TJdbcConnection`（驱动、连接参数、池、超时，IDE 持久化）。
- 测试：`TestLcl` 扩展——缺 jar 时 OK 禁用（回归空壳行为）→
  下载（mock fetch）→ Test（H2 真库）→ 写回断言。

## 3. 包目录上浮（已确认）

- `src/lcl/tyfpjdbc.lpk` 上浮为仓库根 `tyfpjdbc_design.lpk`（包名同步改为
  `tyfpjdbc_design`：原包名 `tyfpjdbc` 与单元命名空间 `TyFPJDBC.*`
  大小写不敏感撞名，Lazarus 生成的包装单元 `unit tyfpjdbc` 非法，
  根目录构建必败；改名后单元名保持 `TyFPJDBC.*` 不动），
  `Files` 直引 `src/lcl/...、src/core/...、src/db/...`，
  `OtherUnitFiles` 为 `src/core;src/db;src/lcl`；包版本（0.9.0）不动。
- `src/lcl/` 只留源码；矩阵、文档中的 `lazbuild` 路径同步改。
- 测试：`lazbuild tyfpjdbc_design.lpk` 根目录一次通过 + `TestLcl` 全过。

## 4. 非目标

- 不做系统 JRE 版本探测与兼容矩阵（已决定不支持）。
- 不预装全部驱动 jar（只预置元数据，按需下载）。
- 不改 `Bridge` JNI 签名与 `0.9.0` 握手。

## 5. 验收

- `guard.ps1` 全绿（含产物门禁）。
- `TestJvm/TestLcl/TestDistrib` 全过；`lazbuild tyfpjdbc.lpk` 根一次通过。
- 完整矩阵 `MATRIX-OK`；四份证据（tests/launch/guard/matrix）归档。
