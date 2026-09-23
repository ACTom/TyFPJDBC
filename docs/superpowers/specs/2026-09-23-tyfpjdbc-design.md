# TyFPJDBC 设计文档（V1）

- 日期：2026-09-23
- 状态：待评审
- 目标读者：Lazarus / Free Pascal 开发者
- 范围：V1 四项全达成可发布

## 1. 目标与 V1 成功标准

### 1.1 目标

给 `Lazarus / Free Pascal 64bit` 提供一套 `JNI -> JDBC` 桥，复用 `JDBC` 生态和上游验证过的驱动矩阵，桌面和 `B/S` 服务端都能用。底层保留 `JDBC` 特性，上层兼容 `TDataset`。

### 1.2 V1 成功标准（四项全要）

1. `DBGrid` 能显示任意 `JDBC` 查询：`TJDBCQuery` 只读先行，`SQLite + H2` 零部署跑通，翻页正常。
2. 服务端跑稳连接池加并发：`HikariCP` 封装，多线程各用独立连接，`Pool` 全局共享，`JVM` 线程自动 `Attach / Detach`。
3. 完整可编辑 `Dataset`：`CachedUpdates + ApplyUpdates`，含新增主键回取 `getGeneratedKeys`，`BLOB` 读写正常。
4. 工具链先行：`drivers.json` 加命令行 `Maven` 下载器加裁剪 `JRE` 独立仓库可下载，`IDE` 向导复用同一份 `JSON`。

### 1.3 非目标

- 不支持 `Windows 32bit`，第一版只支持 `64bit` 应用。
- 不做 `LocalSQL`、跨库导数、离线包。
- 不碰 `Java` 虚拟线程，第一版用经典线程池加 `HikariCP`。

## 2. 总体架构与分包

### 2.1 链路

```text
FPC App -> TyFPJDBC.Core -> JNI -> tyfpjdbc-bridge.jar -> HikariCP / JDBC Driver -> DB
```

`Pascal` 侧不直调 `JDBC` 上千个 `JNI` 方法，只调门面 `jar` 的十几个扁平接口。批取、池化、`Array / JSON` 展开都在 `Java` 侧做。

### 2.2 分包（只按依赖拆）

- `TyFPJDBC.Core`：只 `uses SysUtils, Classes, syncobjs`。包含 `TJVMManager, TJDBCConnection, TJDBCStatement, TJDBCResultSet, TJDBCHikariPool, IJDBCConnectionPool`。禁止引用 `Forms, Dialogs, LCL`。桌面和服务端共用。
- `TyFPJDBC.DB`：允许 `uses DB, BufDataset`。包含 `TJDBCQuery: TBufDataset, TJDBCStoredProc, TJDBCScript`，以及 `Fetch / Format / Update Options`。`TDataset` 本身不是界面，服务端可用。
- `TyFPJDBC.LCL`：只放设计期包、连接串构建对话框、驱动下载向导界面。桌面专用。
- `TyFPJDBC.Tools`：命令行下载器加 `IDE` 向导共用的非界面逻辑，读同一份 `drivers.json / runtimes.json`，给 `CI / Docker` 用。

### 2.3 关键约束

1. `Core` 零界面依赖，`CI` 加 `grep Forms` 卡点。
2. `Pool` 全局共享，`Connection / Query` 按请求独占，`TDataset` 不跨线程。`HTTP` 工作线程首次自动 `AttachCurrentThread`，结束 `Detach`。
3. 驱动 `jar` 不进 `jlink` 镜像。镜像里只有 `JDK` 模块加 `bridge + HikariCP`，`drivers/` 目录运行时用 `URLClassLoader` 动态加载，多版本隔离。
4. 位数必须一致：`64bit FPC` 程序调 `64bit JVM`。

### 2.4 目录结构

```text
src/core/
src/db/
src/lcl/
src/tools/
java/bridge/
configs/drivers.json
configs/runtimes.json
tests/
docs/
scripts/
```

## 3. Java 门面加 JVM 加连接池

### 3.1 门面 jar

新建 `tyfpjdbc-bridge.jar`，约 `500` 行，把跨界次数压下来。只暴露扁平接口：

```text
GetBridgeVersion
CreatePool / DestroyPool
BorrowConnection / ReleaseConnection
ExecUpdate / ExecBatch
FetchBatch(batchSize)
GetResultMeta / GetDatabaseMeta
SetQueryTimeout / Cancel
GetPoolStats
GetLastErrorChain
```

约束：所有取数走 `FetchBatch` 列式批量，`String` 批量转 `UTF-8`。一个格子调一次 `JNI` 的写法第一版禁用。大 `BLOB` 走 `InputStream -> TStream` 流式，不进批量数组。

### 3.2 JVM 生命周期（TJVMManager 独管）

- `libjvm` 查找顺序：自带 `jre/` -> `JAVA_HOME` -> `Windows` 注册表 -> `PATH`，找不到直接报错。
- 启动参数分两档：
  - 桌面默认：`-Xmx512m -Dfile.encoding=UTF-8 -Djava.awt.headless=true`
  - 服务端：`MaxRAMPercentage=50~75 -Xrs -Dfile.encoding=UTF-8 -Djava.awt.headless=true`
- 调试开关：`-Xcheck:jni`、`hs_err_pid` 输出路径。
- 版本握手：连接时先对 `GetBridgeVersion`，`jar` 和 `Pascal` 单元对不上直接抛错。
- 线程：工作线程首次自动 `AttachCurrentThread`，结束 `Detach`。每次 `JNI` 调用后查 `ExceptionCheck`，每次批取后释放 `localref`。
- 日志：`jul + slf4j` 重定向到 `FPC` 日志回调，连接池警告看得见。

### 3.3 驱动加载

- `drivers/` 目录加 `URLClassLoader` 隔离，多版本共存。
- 先走 `ServiceLoader` 自动注册，失败兜底 `Class.forName(driverClass)`。
- 基座用 `Eclipse Temurin 25 LTS`，`CI` 拉官方包再 `jlink`，来源干净。

### 3.4 连接池

选用 `HikariCP`，`jar` 约 `150KB`，加 `slf4j-api` 即可运行。`Pascal` 属性一一映射：

```text
maximumPoolSize / minimumIdle
connectionTimeout / maxLifetime
keepaliveTime / leakDetectionThreshold
```

再包一层 `IJDBCConnectionPool` 接口：`GetConnection: IJDBCConnection`。以后原生库也能复用这个池语义。

`jlink` 模块起点用 `jdeps` 扫 `bridge + HikariCP + slf4j-api` 得出，必含：

```text
java.base, java.sql, java.naming, java.logging,
java.management, java.xml, java.security.sasl,
jdk.unsupported, java.transaction.xa
```

## 4. Options 加类型映射加 Macro / Param

借鉴 `FireDAC / UniDAC` 的思想，只留三组。

### 4.1 FetchOptions

- `RowsetSize`：默认 `1000`。
- `Mode`：`fmAll / fmOnDemand`。
  - `fmAll` 为 `Buffered` 模式，进 `TBufDataset` 给 `DBGrid` 用，限 `10` 万行内。
  - `fmOnDemand` 加 `Unidirectional=True` 为 `Forward-only` 流式，给导出和服务端分页用，内存恒定。
- `FetchSize`：直接透传给 `Statement.setFetchSize`。
- `Unidirectional`：流式必须开，`Bookmark`、翻页不可用。

### 4.2 FormatOptions

类型对照表加用户可覆盖。第一版写死，后面改即 breaking change。

| JDBC | FPC |
|---|---|
| `VARCHAR / NVARCHAR / CHAR` | `ftWideString` |
| `CLOB / NCLOB / SQLXML / JSON / JSONB / UUID` | `ftWideMemo`，按文本走 |
| `INTEGER / SMALLINT` | `ftInteger` |
| `BIGINT` | `ftLargeint` |
| `NUMERIC / DECIMAL` | `ftFmtBCD`，字符串中转保精度 |
| `FLOAT / DOUBLE / REAL` | `ftFloat` |
| `BOOLEAN / BIT` | `ftBoolean` |
| `DATE` | `ftDate` |
| `TIME` | `ftTime` |
| `TIMESTAMP` | `ftDateTime` |
| `TIMESTAMP WITH TIME ZONE` | 转本地 `TDateTime`，丢时区并记日志 |
| `BLOB / BINARY / VARBINARY / BYTEA` | `ftBlob`，大对象走流式 |
| `ARRAY / STRUCT` | 第一版转文本展示，不做结构化展开 |
| `NULL` | `wasNull() -> Field.Clear` |

编码：`jstring` 来回转统一 `UTF-8`，中文第一关在冒烟测试验证。

### 4.3 UpdateOptions

- `ReadOnly / KeyFields / UpdateMode / AutoIncField`。
- 可编辑走 `CachedUpdates + ApplyUpdates`，统一走当前连接事务提交，冲突进 `OnReconcile` 回调。
- 新增主键回取统一走 `getGeneratedKeys`，`DMLRefresh` 做 `RETURNING` 回查一行。
- 批量走 `Array DML`：`Execute(ATimes)` 一次绑 `1000` 行数组。

### 4.4 Param 与 Macro 双轨加防注入

原则：所有值一律走参数绑定，禁止字符串拼接拼值。`Macro` 只拼标识符，且走白名单。

- `Param` 走 `PreparedStatement` 的 `?` 绑定，防注入。
- `Macro(&table / &order)` 只做白名单替换，表名、排序字段动态拼用它。展开后重新生成 `SQL` 再进 `Param` 绑定。
- 存过单独 `TJDBCStoredProc` 包 `CallableStatement`，`IN / OUT / INOUT` 显式注册。

### 4.5 命名参数到占位符的转换

`FPC` 侧习惯 `:name` 命名参数，`JDBC` 标准是 `?` 按序绑定（`1` 起），两者必须转。转换器放在 `TyFPJDBC.DB` 层，`Core` 只认 `?`。

- 对外 API 保持 `ParamByName('id')` 兼容，内部维护 `name -> indices[]` 映射。同名出现两次即绑两个 `?` 位，如 `WHERE a=:id OR b=:id`。
- 执行流程固定三步：`Macro` 展开 -> 命名参数解析成 `?` -> 按序绑定。顺序不可调换。
- 解析器必须跳过：单引号、双引号、反引号字符串，`E'...'` 转义串，`PG` 的 `$$...$$` 函数体，行注释 `--...`，块注释 `/*...*/`。串里的 `:xx` 和 `?` 不解析。
- 必须保留：`PG` 的 `::int` 类型转换、`:=` 赋值、`://`、`12:30` 时间字面、`?`、`?|`、`?&` 等 `JSON` 操作符，不误判为参数。
- `TJDBCScript` 多语句模式默认关参数解析，按 `;` 分割时同样尊重字符串和注释，分隔后再对每条单独做上一步。
- 绑定按 `TParam` 类型选 `setter`：`ftString -> setString`，`ftInteger -> setInt`，`ftLargeint -> setLong`，`ftFloat -> setDouble`，`ftBCD / ftFmtBCD -> setBigDecimal`（字符串中转），`ftDate / ftTime / ftDateTime -> setDate / setTime / setTimestamp`，`ftBlob -> setBinaryStream`，`Null -> setNull`（类型取自 `ParameterMetaData`，取不到按 `VARCHAR` 兜底并记日志）。
- `LIKE` 不做拼接 helper，统一要求 `LIKE :kw ESCAPE '\'` 加绑定值里加 `%`，示例里只写这一种。
- `Macro` 白名单：只允许 `[A-Za-z0-9_.$]+`，出现 `; -- /* */ '` 等直接拒绝。表名、列名、排序方向（`ASC / DESC` 白名单枚举）走 `Macro`，值一律不走 `Macro`。
- 注入回归用例必含：`' OR '1'='1` 当值绑定原样存、`'--` 不截断语句、串内 `:id` 不替换、`::int` 保留、同名参数双绑、`Macro` 非法字符拒绝。

### 4.6 类清单

- `TJDBCConnection`：通用连接，通用属性放主类，特有选项放子类（如 `TJDBCPostgresOptions`），以后加新库不污染主类。
- `TJDBCQuery: TBufDataset`：统一查询。
- `TJDBCStoredProc`：存过。
- `TJDBCScript`：多语句 `DDL` 脚本执行。
- 第一版不做内存表、离线包。

## 5. 错误、事务、超时、监控

### 5.1 错误

整条链转，不只取第一条：`SQLException.getNextException + SQLState + vendorCode` 加 `SQLWarning` 链，全部进 `EJDBCError`。

```text
EJDBCError = class(EDatabaseError)
  SQLState: string;
  VendorCode: Integer;
  Chain: TStringList;
end
```

`Message` 拼第一条加 `caused by`，`EDatabaseError` 只做父类兼容。

### 5.2 事务

不硬套 `TSQLTransaction`，独立做：

```text
TJDBCConnection.AutoCommit: Boolean;
TJDBCConnection.Isolation: TJDBCIsolation; // 默认 ilReadCommitted
TJDBCConnection.ReadOnly: Boolean;
StartTransaction / Commit / Rollback
Savepoint(name) / RollbackToSavepoint / ReleaseSavepoint
```

`TJDBCQuery` 的 `CachedUpdates + ApplyUpdates` 走当前连接事务提交。

`catalog / schema` 只做属性透传，不做语义合并。

### 5.3 超时和取消

三个口必暴露：

- `loginTimeout / socketTimeout`：藏 `URL` 和 `Properties` 里，走 `SpecificOptions` 透传。
- `Statement.setQueryTimeout`：点取消按钮、服务端杀慢查询用。
- `Cancel()`：单独线程可调，`DBGrid` 换页、服务端超时直接杀。

### 5.4 监控

先有日志口，`IDE` 可视化以后再做：

- `OnPoolStats(active, idle, wait)`：连接池状态回调。
- `OnSlowQuery(SQL, ElapsedMs)`：按阈值回调。
- `Java` 侧 `JMX` 不直接暴露，转成 `Pascal` 回调。

## 6. 驱动清单加 Maven 加 JRE 分发

上游清单只做参考源，不直接打包，自己维护两份 `JSON`。

### 6.1 drivers.json

每库一条，字段固定：

```json
{
  "id": "postgresql",
  "displayName": "PostgreSQL",
  "maven": "org.postgresql:postgresql:42.7.4",
  "driverClass": "org.postgresql.Driver",
  "urlTemplate": "jdbc:postgresql://{host}:{port}/{database}",
  "defaultPort": 5432,
  "testQuery": "SELECT 1",
  "extraParams": {},
  "license": "BSD-2-Clause",
  "upstreamSyncVersion": "2026-09-01"
}
```

`urlTemplate / defaultPort / testQuery` 建议值照抄上游清单，写同步脚本定期对一次，自己不手维护版本。`SpecificOptions` 逃生口对应 `extraParams`。`GPL` 类驱动下载时弹 `license` 确认。

### 6.2 runtimes.json

跟 `Release` 一一对应：

```json
{
  "platform": "win64",
  "temurinVersion": "25",
  "modules": ["java.base", "java.sql"],
  "bridgeVersion": "1.0.0",
  "url": "以独立运行时仓库 Release 资产地址为准",
  "sha256": "以 Release 发布时生成的 SHA256 为准"
}
```

`platform` 共 `5` 个：`win64, linux-x64, linux-arm64, macos-x64, macos-arm64`。

### 6.3 分发两仓

- 主仓 `TyFPJDBC`：代码加 `configs/*.json` 加下载器。
- 独立仓 `TyFPJDBC-Runtimes`：只发 `Release`，命名 `jre-25-tyfpjdbc-win64.zip` 等 `5` 个包，全部为单档 `jlink-trimmed-9-modules`，不设第二档。
- `jlink` 做法（见 `scripts/build-jlink.ps1`，本机与跨机统一参数）：
  - 模块：`java.base, java.sql, java.naming, java.logging, java.management, java.xml, java.security.sasl, jdk.unsupported, java.transaction.xa`（`jdeps` 实测 floor 为 `java.base, java.management, java.naming, java.sql`，其余为 `HikariCP` 日志与驱动 `SASL / XA` 预留）。
  - 参数：`--disable-plugin generate-jli-classes --vm server --strip-debug --no-man-pages --no-header-files --compress=zip-9 --exclude-resources "**/classes*.jsa"`。其中 `generate-jli-classes` 在跨机模块集上必须禁用（否则报同名类已存在），`exclude-resources classes*.jsa` 去掉各平台自带的 `CDS` 归档（约 `45MB`）以满足预算。
  - `jmods` 来源：`win64` 用 `Temurin 25.0.4.1` 自带；其余 `4` 平台用 `Microsoft Build of OpenJDK 25.0.4.1` 的目标平台 `jmods`。上游 `Temurin` 归档不带 `jmods` 且 `java.base` 记录 `ModuleHashes`，异机 `jlink` 会被拒绝（已实测 `Unable to compute the hash / Hash ... differs to expected hash`），故跨机必须用带目标 `jmods` 的发行版，这是唯一改动点；模块清单与参数不变。
- 体积预算（下载器按此档强制执行）：解包不超 `80MB`，`zip` 不超 `50MB`。实测（`runtimes.json`）：`win64 38.9MB / 25.0MB`、`linux-x64 48.6MB / 27.2MB`、`linux-arm64 47.0MB / 26.5MB`、`macos-x64 41.3MB / 24.2MB`、`macos-arm64 39.1MB / 23.2MB`。
- 结构验证：`Linux` 启动器与 `libjvm.so` 为 `ELF`（`7F-45-4C-46`），`mac` 启动器与 `libjvm.dylib` 为 `Mach-O 64`（`CF-FA-ED-FE`），`win64` 为 `MZ`；每包零异平台二进制；`release` 的 `MODULES` 为 9 模块集。
- 镜像里只有 `JDK` 模块加 `bridge/ (Bridge.class, HikariCP, slf4j-api)`，驱动放 `drivers/` 运行时用 `URLClassLoader` 加载（`drivers/README.txt`）。
- 客户端缓存 `~/.tyfpjdbc/runtimes` 和 `~/.tyfpjdbc/drivers`，支持断点续传和离线复用。
- 服务端 `Docker` 直接用 `eclipse-temurin:25-jre` 基础镜像，不用这份 `zip`。

### 6.4 下载器

存坐标加校验加缓存，`IDE` 向导和命令行共用同一份 `JSON`，支持 `sha256` 校验、本地缓存、`CI` 缓存。

## 7. 测试与里程碑

### 7.1 测试分层

- `L0` 冒烟：`SQLite`，单 `jar` 自带各平台 `native` 库，零部署，跑 `connect + select 1 + 中文读写`，`CI` 常驻。
- `L0.5` 进阶：`H2`，纯 `Java` 单 `jar`，不用装 `server`。覆盖 `savepoint / batch / isolation / DatabaseMetaData / 存过别名`。
- `L1` 主力：`PostgreSQL` 原生装。`Windows` 上二选一：`winget install PostgreSQL.17`，或官方 `zip` 便携版 `initdb + pg_ctl start` 起测试实例，数据目录放仓库外，附 `ps1` 脚本。类型映射、事务、批量、流式、池化并发、慢查询取消全在这里验。
- `L2` 矩阵：`MySQL` 等放后期矩阵，第一版不测。

### 7.2 性能验收

三档：`10k / 100k / 1M` 行，`fetch 1000`，看耗时加 `Java` 堆峰值加 `FPC` 峰值。`Buffered` 限小结果集，`Forward-only` 跑导出和服务端分页。数字不达标不发布。

### 7.3 里程碑

- `M0 Spike`：本机起 `JVM`，`H2` 跑通 `connect + select`，验证中文和 `Attach / Detach`，产物标注 throwaway。
- `M1 Core`：`TJVMManager + TJDBCConnection + TJDBCPreparedStatement + TJDBCResultSet + HikariCP`，参数化加批量可用。
- `M2 DB 只读`：`TJDBCQuery: TBufDataset` 只读加 `DBGrid` 展示加三组 `Options`。
- `M3 可编辑加工具`：`CachedUpdates + ApplyUpdates + getGeneratedKeys + BLOB`，命令行下载器加裁剪 `JRE` 独立仓可下载。
- `M4 V1`：四项全过，`PG` 主力验证通过才发布。

### 7.4 CI 卡点

- `64bit` 独占。
- `Core` 零界面依赖：`grep Forms` 失败即红。
- `L0 + L0.5` 常驻，`L1` 需本地 `PG`，`L2` 后期矩阵。

## 8. 待决策与风险

1. `TIMESTAMP WITH TIME ZONE` 第一版丢时区转本地时间加日志，是否够用，待 `PG` 验证后确认。
2. `ARRAY / STRUCT` 第一版只转文本，结构化展开放第二版。
3. `Win32` 明确不支持，`32bit` 老项目以后走远程网关模式，不在本 `spec` 内。
4. `NUMERIC` 走 `ftFmtBCD` 字符串中转，超大精度性能待 `10k` 档实测。
