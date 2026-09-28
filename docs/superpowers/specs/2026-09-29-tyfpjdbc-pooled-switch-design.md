# TyFPJDBC 连接池开关规格（pooled switch + direct connect）

版本：0.1（brainstorming 已确认，待评审后转 implementation plan）
日期：2026-09-29
基线：Cycle 1 未提交改动之上（`DriverClassOverride`、向导/编辑器增强已在本机验证通过，未合入）
目标：`TJdbcConnection` 加 `Pooled` 开关；关 = 直连 `DriverManager`，全程 bypass Hikari；开 = 现状零变化。

## 0. 约束（已确认）

- 默认行为零变化：`Pooled` 默认 `True`，池路径一字不动。
- `Bridge.java` 仍是唯一状态机：直连的连接同样进 `conns` 表、拿 `Int64` 句柄、走 `closeConn` 释放、`ThreadLocal` 错误链不变。
- 错误分类沿用 `TROUBLESHOOTING.md`：驱动原生归 `ecDriver`，配置问题归 `ecConfig`。
- `TJdbcConnQuery`、向导窗、属性编辑器一律不动（它们只认 `LiveConn`）。
- `Bridge.jar` 版本号与握手（`0.9.0`）不变：新增方法不改变 `VERSION`。

## 1. Java：`Bridge.directConnect`（已确认）

- 签名：`public long directConnect(String jdbcUrl, String user, String pw,
  String driverClass) throws SQLException`。
- 语义：空 URL 抛 `HY092/40`（与 `createPool` 的 `bad url` 同形）；
  `Class.forName(driverClass)` 失败抛 `08000/33`（`no driver class ...`，
  两边均无撞号，已查）；否则 `DriverManager.getConnection(url, user, pw)`，
  装入 `ConnBox`，`ids` 发新句柄返回；`SQLException` 一律 `recordChain` 后重抛。
- 不碰：`createPool`/`borrowConn`/`closeConn`/池统计；新连接不进 `pools` 表。

## 2. Pascal JNI：`TBridge.DirectConnect`（已确认）

- 签名：`function DirectConnect(const Url, User, Password,
  DriverClass: UTF8String): Int64;`（`TyFPJDBC.JNI.Bridge`）。
- 方法号注册沿现有模式：`FM directConnect :=
  Mid('directConnect',
  '(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)J')`；
  传参沿 `CreatePool` 的手工 `JStr` 四串模式（现有 `CallLongStr` 只支持
  一长一串，不够用，不扩展它）。
- 句柄校验与错误链沿用（`HY000/99` 本地先验 + `getErrorChain`）。

## 3. 引擎：`TJdbcEngine.OpenDirect`（已确认）

- 签名：`function OpenDirect(const Cfg: TPoolCfgRec): Int64;`
- 只取 `Cfg.Url/User/Password/DriverClass` 四字段（池字段忽略，文档写死）；
  `Result := FBridge.DirectConnect(...)` 后 `CheckHandle('conn', ...)`，
  记入 `FConns`（`HandleCount`/`AuditReport` 形状不变：直连体现为
  `pools=0 conns=1`）。
- `Release` 不变（`CloseConn` 本就只认 conn 句柄，直连/池连接同路释放）；
  `ClosePool` 永不对直连调用（`FPool` 保持 0）。

## 4. 组件：`TJdbcConnection.Pooled`（已确认）

- `property Pooled: Boolean ... default True`，构造默认 `True`。
- `Connect` 分支：池路现状不动；直连路跳过建池——解析 `DriverId`（含
  `DriverClassOverride`，复用 Cycle 1 逻辑）→ `cfg.DriverClass` 填最终类 →
  `FPool := 0; FConn := engine.OpenDirect(cfg)` → 同跑 `TestQuery` 探针
 （与池路对称，配错早暴露）。
- `Shutdown` 无需改（已是 `if FPool > 0` 才关池，直连 `FPool=0` 天然跳过；
  连接释放走同一条）。
- `PoolActive/PoolIdle/PoolWaiting/PoolSnapshot` 在 `FPool = 0` 时抛
  `EJDBCError('not pooled', '08000', 53, ...)`（53 已查两边无撞号；
  误用早暴露，不静默给零）。
- `Pooled=False` 时 `MaxPool/MinIdle` 被忽略（文档写死；OI 不藏属性，做不到）。
- `TestConnection` 经 `Connect`，两路通用，不变。

## 5. 数据流（已确认）

- 池模式：`EnsureStarted → Create → OpenPool → Borrow → (probe) → 用 → Release → ClosePool`（不变）。
- 直连模式：`EnsureStarted → Create → OpenDirect → (probe) → 用 → Release`
  （无池创建/销毁；多放几个 conn 即多条独立直连，满足“一 conn 一连接”）。
- 查询/命令/脚本层只见 conn 句柄，两路无感。

## 6. 测试（已确认）

- `TestEngine` 新增直连段（H2 mem）：`OpenDirect → ExecDirect 建表 →
  query 回环 → Release → HandleCount=0 + AuditReport 全零 +
  PoolCount=0`；坏类名断言 `SQLState=08000`；`--selftest` 式全绿才算过。
- `TestLcl` 加 `pooled-default`（默认 True）与 `not-pooled-raises`
  （`PoolSnapshot` 在直连 conn 上抛 `08000/53`——需活连接，走已有 JVM 段）。
- 回归：`TestDialect/TestTx` 不动但必跑；`guard.ps1`；Demo `--verifyform`
  （`LCL.Conn` 动了，必须重验）。

## 7. 非目标（已确认）

- 向导窗/属性编辑器不加池开关 UI（OI 布尔属性即开关）。
- 不做连接字符串直填（URL 仍由条目拼装；自定义走 Cycle 1 的注册代码）。
- 不做池参数运行时热调；不断开空闲直连的保活（无池即无保活，文档写死）。

## 8. 验收（已确认）

- 新测试全绿 + 全量既有测试全绿 + `guard ok` + Demo 双自检归零。
- `Pooled=True` 的行为与本 spec 之前逐字节一致（默认零变化，用既有测试锁死）。
