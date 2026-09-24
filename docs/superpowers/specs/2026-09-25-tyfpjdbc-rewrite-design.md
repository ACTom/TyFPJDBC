# TyFPJDBC 重写规格：通用 JDBC 句柄架构（V2）

- 日期：2026-09-25
- 状态：设计已确认，待评审后进入实现计划
- 前提：允许推倒重写，不兼容任何现有设计；现有 `src/core`、`src/db`、`java/bridge` 实现仅作为经验复用，不保留 API
- 目标：把 TyFPJDBC 打造成有价值、有竞争力的通用 JDBC 控件——任意 JDBC 驱动可接入，代码优先 API 与 DB 感知控件同时生产可用

## 1. 背景与取舍

### 1.1 为什么重写

现有实现是功能打通的作品：Pascal 侧内存模拟池与 Java 侧真 HikariCP 双状态机并存，
事务在 Pascal 侧是布尔值、在 Java 侧是真实 Connection 状态，主键回填是本地发号，
取数全走 `getString`、写数全走 `setString`，错误链是全局变量，语句取消是单槽 Map。
这些形状能让当前 SQLite/H2 测试变绿，但换库、换并发、换长连接就会碎。

### 1.2 可复用的经验（不复用代码形态）

- 命名参数 `:name` 到 `?` 的转换与参数顺序记录
- `CustomMap` 覆盖 + 未知类型显式策略（新设计不再静默兜底）
- `FieldToUTF8/FieldFromUTF8` 的 UTF-8 精确传输
- 批量事务提交后恢复 `autoCommit` 的模式
- 确定性 runtime zip 打包、mautool 清单校验、性能三档 harness 的思路

### 1.3 路线结论

采用路线 A：通用句柄重写。Java 侧为唯一状态机，Pascal 侧只拿句柄。
不选原生优先混合（违背“所有 JDBC 数据库”初衷），不选去 JVM 纯 Pascal（按库实现 wire 协议工作量不可控）。

## 2. 总体架构

### 2.1 一句话架构

```
Lazarus App
  ├─ 代码优先 API（TJdbcEngine / TJdbcQuery / TJdbcCommand）
  └─ DB 感知控件（TJdbcConnection / TJdbcQuery + DBGrid/DBEdit，lpk 设计时包）
        │
        │  Pascal 侧：只存 Int64 句柄 + 配置，不存连接状态
        ▼
TJNI + Bridge v2（Java 侧唯一状态机）
  ├─ Pool（HikariCP 全量参数）
  ├─ Conn（setAutoCommit/isolation/readOnly/catalog/schema/isValid）
  ├─ Stmt（PreparedStatement 类型化绑定 + 超时 + 取消）
  └─ Cursor（前向窗口游标 + 服务端分页）
        │
        ▼
Dialect 层（分页/引用/类型/元数据）
        │
        ▼
任意 JDBC 驱动（driverClass + urlTemplate + Properties + ClassLoader 隔离）
```

### 2.2 已确认（第一节通过）

- Java 侧拥有池、连接、事务、游标；Pascal 侧只拿 Int64 句柄
- 执行与展示分离：执行引擎不管 Dataset 展示，Dataset 适配器只做窗口映射
- 方言可插拔：分页、引用、类型、元数据按方言实现
- 类型化绑定：不再全走 setString/getString
- 流式窗口取数：不做全量缓冲假装流式
- 设计时包独立：运行时零 LCL 依赖，设计时包单独提供组件编辑器

## 3. 组件划分

### 3.1 已确认（第二节通过）

| 组件 | 职责 | 不做什么 |
|---|---|---|
| `TJdbcEngine`（Pascal） | 句柄管理、配置校验、生命周期编排、错误转换 | 不存事务状态、不模拟池、不模拟语句 |
| `Bridge v2`（Java） | 池/连接/语句/游标的创建、执行、关闭、统计 | 不做 SQL 改写、不做 Pascal 侧类型映射 |
| `Dialect`（两侧各一薄层） | 分页改写、标识符引用、类型映射、元数据查询 | 不碰传输、不碰池 |
| `DatasetAdapter`（Pascal） | 游标窗口到 TBufDataset/TField 的映射、编辑增量收集 | 不拼 SQL 字符串、不直接调 JDBC |
| `Runtime`（工具链） | JRE 发现/下载/校验、驱动 jar 解析/下载/隔离加载 | 不参与查询执行 |
| `LCL` 设计时包 | 组件注册、连接对话框、属性编辑器、测试按钮 | 不进运行时包 |

### 3.2 取数流程

1. `TJdbcQuery.Open` 经 Engine 拿连接句柄，经 Dialect 改写分页 SQL
2. Bridge v2 创建 Stmt + Cursor，返回 cursorId + 首窗口行 + 列元数据
3. DatasetAdapter 按元数据建 FieldDefs，按窗口填充，不一次拉全表
4. `Next/Eof` 触发 `fetchWindow(cursorId, offset, size)`，窗口大小可配
5. `Close` 按游标→语句→连接的逆序释放

### 3.3 写数流程

1. DatasetAdapter 收集插入/编辑增量，不拼 SQL 字符串
2. Engine 经 Dialect 生成带占位符的 DML（表名列名按方言引用）
3. Bridge v2 用 PreparedStatement 类型化绑定执行批量，单事务提交
4. 主键经 `getGeneratedKeys` 或方言 `RETURNING` 回填，不做本地发号
5. 无主键表拒绝生成定位 UPDATE（显式报错，不退到首列）

## 4. 模块详细设计

### 4.1 连接与池

- 唯一状态机在 Java 侧 HikariCP；Pascal 侧 `TJdbcConnection` 只有配置 + poolId 句柄
- 全量池参可配：`maximumPoolSize/minimumIdle/connectionTimeout/maxLifetime/keepaliveTime/leakDetectionThreshold/connectionTestQuery/validationTimeout`
- 连接属性下发：`setAutoCommit/setTransactionIsolation/setReadOnly/setCatalog/setSchema/setNetworkTimeout`
- 借用按 `connectionTimeout` 等待，不再立即抛；`TestOnBorrow/TestWhileIdle` 走 `isValid/testQuery`
- 池统计用结构化接口（active/idle/waiting/leak count），不用字符串解析

### 4.2 驱动注册表

- 任意驱动可注册：`driverId/driverClass/urlTemplate/defaultPort/testQuery/extraParams/license/maven坐标/sha`
- `BuildUrl + BuildProperties` 由注册表生成，Properties 透传超时/字符集/只读等
- 驱动 jar 经 URLClassLoader 隔离加载，多驱动共存不冲突
- 未知类型/未知驱动显式报错并记日志，不静默兜底

### 4.3 方言层

- 首批方言：PostgreSQL、MySQL/MariaDB、MSSQL、Oracle、SQLite、H2；新方言以接口实现接入
- 方言职责：分页改写（LIMIT/OFFSET、TOP、FETCH FIRST、ROWNUM 封装）、标识符引用（双引号/反引号/方括号）、类型映射表、主键回填策略、元数据查询
- 方言选择：按 driverId 显式选择 + 按 DatabaseMetaData 产品名校验，不一致即报错

### 4.4 JVM 生命周期

- 支持多配置：classpath/args 变化即视为不同运行时，需要显式 `Shutdown` 后重建；单进程单 VM 的 HotSpot 约束向调用方显式报错
- `FindLibJvm` 顺序：显式路径 → 自带 `jre/` → `JAVA_HOME` → 注册表（Windows）→ `PATH` → macOS 动态库路径；找不到即报可操作错误
- 参数构造器处理含空格路径（引用或数组传参，不按空格切分）
- JNI 版本按运行 JDK 协商，不写死 1.6；线程 Attach 计数与 Detach 配对，泄漏可断言

### 4.5 执行、超时、取消

- 语句是 Java 侧一等对象：每个执行拿 stmtId，不再是按 connId 单槽
- 超时经 `setQueryTimeout` 下发；取消经 `Statement.cancel(stmtId)` 精确取消
- Pascal 侧不再有模拟 Statement；超时/取消错误单独分类，可重试判定
- 批量按类型化 `addBatch/executeBatch` 执行，大批量按 `BatchSize` 分片

### 4.6 类型系统

- 绑定按列类型走 `setInt/setLong/setBigDecimal/setString/setDate/setTime/setTimestamp/setBytes/setNull`，不用全字符串
- 读取按 `ResultSetMetaData` 列类型走对应 getter，NUMERIC/时间类型不经字符串中转
- BLOB/CLOB 按阈值选择一次传输或流式（`setBinaryStream/getBinaryStream` 分片），阈值可配
- 未知类型：默认报错；可选 `UnknownTypeFallback`（报错/按字符串/按字节），必须显式配置

### 4.7 事务与存储过程

- 事务 API 直接映射 JDBC：`setAutoCommit/commit/rollback/setSavepoint/rollbackTo/releaseSavepoint`，Pascal 侧不做二次状态机
- Savepoint 名走白名单校验，不拼字符串
- 存储过程走 `CallableStatement`，支持入参/出参/结果集返回，不做 `OUT:` 字符串模拟
- 脚本执行按方言分隔 + 事务边界执行，失败定位到语句序号

### 4.8 元数据

- Bridge v2 新增：`getTables/getColumns/getPrimaryKeys/getResultMeta/getDatabaseMeta`
- Dataset 建表、主键定位、设计时字段列表都走元数据，不猜测

## 5. 错误、日志、可观测

### 5.1 已确认（第三节通过）

- 句柄错用（未知 poolId/connId/stmtId/cursorId）在本地直接抛，不进 JDBC
- 驱动错误携带完整链：SQLState/vendorCode/message/cause 链 + ThreadLocal 隔离，不用全局 lastError
- 取消/超时单独分类（`HY008/HYT00` 语义保留并文档化），调用方可判定重试
- 资源按游标→语句→连接→池→JVM 逆序关闭，泄漏计数可查

### 5.2 日志与指标

- 日志回调可注册（级别：debug/info/warn/error），JVM 侧 JUL 转发到 Pascal
- 慢查询自动计时上报（阈值可配），不再靠手动 ReportSlow
- 指标：池状态、执行耗时直方图、取数窗口/lows、JVM 堆水位；全部走结构化接口

## 6. LCL 与开发者体验

- 提供 `.lpk` 设计时包：`TJdbcConnection/TJdbcQuery` 可拖放，属性编辑器支持驱动下拉、URL 模板展开、Properties 编辑、Test 按钮
- 连接对话框：驱动选择、host/port/database、用户密码（掩码）、超时/只读/模式、连接测试，成功才可确认
- 代码优先 API 示例与 DB 感知控件示例各一套，覆盖连接→查询→取数→编辑→批量→事务→BLOB→存储过程→脚本迁移
- 文档：快速开始、驱动接入指南、方言矩阵、故障排查（常见 SQLState 对照）

## 7. 分发与安装

- 应用启动时 Runtime 解析器：按平台选 jre 包、校验 sha256、解包复用、缺失即下载
- 驱动解析器：按 maven 坐标下载、sha 校验、本地缓存（`~/.tyfpjdbc` 目录可配）、支持代理与断点续传
- License 确认：GPL 类驱动在下载前显式确认并记录
- 不写死 curl；按平台选传输实现，失败可重试并给出可操作信息

## 8. 测试与合入门槛

- 真库矩阵：PostgreSQL/MySQL/MSSQL/Oracle/SQLite/H2，覆盖分页/类型/事务/回填/元数据/BLOB/存储过程
- 并发 soak：多线程借用/执行/取消/超时混合压测，无错位、无泄漏
- 资源断言：游标/语句/连接/JVM 句柄计数归零；Attach 计数配对
- 性能门：三档数据量 + 窗口取数内存恒定断言 + 批量吞吐记录（不设虚假数值目标）
- LCL 门：设计时包编译、对话框可用、DBGrid 真数据展示与编辑回写
- 版本矩阵：FPC/Lazarus 多版本、JDK 17/21/25、Win/Linux/macOS 真机或 CI 等价环境

## 9. 验收标准

1. 任意受支持 JDBC 驱动只需注册表条目即可跑通代码优先与控件两条路径，无需改核心代码
2. 换库不改业务代码：分页、引用、类型、回填、元数据行为由方言层承担并被矩阵测试覆盖
3. 长连接多线程下无状态错位：取消杀对语句、错误链不串扰、资源可回收
4. 新测试全部驱动 shipped 代码，不含模拟池/模拟语句/本地发号/全局错误等测试形状

## 10. 自检记录

- 占位扫描：无 TBD/TODO；所有“可配”均有默认值与生效路径说明
- 一致性：单状态机贯穿连接/池/事务/游标四节；类型化绑定贯穿执行/批量/BLOB 三节
- 范围：单规格覆盖重写全量；实现计划阶段再拆子包
- 歧义：方言选择以显式 driverId + 元数据校验为准；未知类型默认报错，均已显式
