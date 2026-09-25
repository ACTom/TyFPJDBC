# TyFPJDBC 驱动接入（DRIVER）

规则：Java `Bridge` 是唯一状态机，Pascal 只拿 `Int64` 句柄。
任何 JDBC 驱动都走同一注册表接入，未知驱动直接报错（`08000`），不静默兜底。
版本握手恒为 `0.9.0`（`Bridge.VERSION` = `TBridge` 强校验 =
`configs/runtimes.json` 五处 `bridgeVersion`）。

## 内置驱动

`src/core/TyFPJDBC.Driver.Registry.pas`（`RegisterBuiltinDrivers`）与
`configs/drivers.json` 同增同减（25 条），`mautool --list` 应输出 25 行：

| id | driverClass | urlTemplate | 默认端口 | 许可 |
|---|---|---|---|---|
| postgresql | org.postgresql.Driver | jdbc:postgresql://{host}:{port}/{database} | 5432 | BSD-2 |
| mysql | com.mysql.cj.jdbc.Driver | jdbc:mysql://{host}:{port}/{database} | 3306 | GPL-2 |
| mariadb | org.mariadb.jdbc.Driver | jdbc:mariadb://{host}:{port}/{database} | 3306 | LGPL-2.1 |
| mssql | com.microsoft.sqlserver.jdbc.SQLServerDriver | jdbc:sqlserver://{host}:{port};databaseName={database} | 1433 | MIT |
| oracle | oracle.jdbc.OracleDriver | jdbc:oracle:thin:@{host}:{port}:{database} | 1521 | OTN |
| sqlite | org.sqlite.JDBC | jdbc:sqlite:{database} | 0 | Apache-2.0 |
| h2 | org.h2.Driver | jdbc:h2:mem:{database} | 0 | MPL-2.0 |
| duckdb | org.duckdb.DuckDBDriver | jdbc:duckdb:{database} | 0 | MIT |
| derby | org.apache.derby.jdbc.EmbeddedDriver | jdbc:derby:{database};create=true | 0 | Apache-2.0 |
| hsqldb | org.hsqldb.jdbc.JDBCDriver | jdbc:hsqldb:file:{database} | 0 | BSD-3-Clause |
| firebird | org.firebirdsql.jdbc.FBDriver | jdbc:firebirdsql://{host}:{port}/{database} | 3050 | IPL-1.0 |
| db2 | com.ibm.db2.jcc.DB2Driver | jdbc:db2://{host}:{port}/{database} | 50000 | Proprietary |
| informix | com.informix.jdbc.IfxDriver | jdbc:informix-sqli://{host}:{port}/{database} | 9088 | Proprietary |
| sybase | net.sourceforge.jtds.jdbc.Driver | jdbc:jtds:sybase://{host}:{port}/{database} | 5000 | LGPL-2.1 |
| teradata | com.teradata.jdbc.TeraDriver | jdbc:teradata://{host}/{database} | 1025 | Proprietary |
| vertica | com.vertica.jdbc.Driver | jdbc:vertica://{host}:{port}/{database} | 5433 | Proprietary |
| clickhouse | com.clickhouse.jdbc.ClickHouseDriver | jdbc:clickhouse://{host}:{port}/{database} | 8123 | Apache-2.0 |
| trino | io.trino.jdbc.TrinoDriver | jdbc:trino://{host}:{port}/{database} | 8080 | Apache-2.0 |
| presto | com.facebook.presto.jdbc.PrestoDriver | jdbc:presto://{host}:{port}/{database} | 8080 | Apache-2.0 |
| hive | org.apache.hive.jdbc.HiveDriver | jdbc:hive2://{host}:{port}/{database} | 10000 | Apache-2.0 |
| snowflake | net.snowflake.client.jdbc.SnowflakeDriver | jdbc:snowflake://{host}.snowflakecomputing.com/{database} | 443 | Apache-2.0 |
| redshift | com.amazon.redshift.jdbc42.Driver | jdbc:redshift://{host}:{port}/{database} | 5439 | Apache-2.0 |
| exasol | com.exasol.jdbc.EXADriver | jdbc:exa:{host}:{port};schema={database} | 8563 | MIT |
| monetdb | nl.cwi.monetdb.jdbc.MonetDriver | jdbc:monetdb://{host}:{port}/{database} | 50000 | Apache-2.0 |
| hana | com.sap.db.jdbc.Driver | jdbc:sap://{host}:{port}/?databaseName={database} | 30015 | Proprietary |

maven 版本为尽力值（以中央仓库为准；改 `drivers.json` 即生效，无需改代码；
无 `sha1` 的条目下载时走上游 `.sha1` 实时取）。

wire 协议兼容别名（不用新条目，走已有条目即可）：
CockroachDB/Yugabyte/Timescale/QuestDB/CrateDB → `postgresql` 条目；
StarRocks/OceanBase/TiDB → `mysql` 条目；Spark SQL → `hive` 条目。
25 条 + 8 别名 = 33 个可连名。

不收录：BigQuery/Athena（REST 式 URL 不合 `host/port/database` 模板）、
Cassandra/Couchbase（非 SQL wire 语义不同）、Netezza/Greenplum/Phoenix
（无公开 maven 构件或已停更）。要加走 `TDriverRegistry.Register` 自定义，
`TestDialect` 的 `custom-driver` 即该路径断言。

`TestDialect` 断言：未知驱动抛 `08000`；嵌入式（sqlite/h2/duckdb/derby/hsqldb）
只替换 `{database}`；`mssql` 的 `Extra` 用 `;` 连接，其余用 `?k=v&...`；
`BuiltinIds` 数量 `>= 25`。

## 配置（TJDBCConfig，唯一入口）

所有可调项集中在 `src/core/TyFPJDBC.Config.pas` 的 `TJdbcConfig`：

| 分组 | 字段 | 默认值 | 范围/影响 |
|---|---|---|---|
| JVM | `JVM_Xmx` | `512m` | 传 `-Xmx`；为空则 `Validate` 拒绝 |
| JVM | `JVM_MaxRAMPercentage` | `60.0` | server 模式 `-XX:MaxRAMPercentage`，`Validate` 要求 `>= 50` |
| JVM | `JVM_Headless` | `True` | `False` 直接拒绝（库只跑 headless） |
| JVM | `JVM_FileEncoding` | `UTF-8` | 非 `UTF-8` 直接拒绝（CJK 纪律） |
| 池 | `Pool_MaxPool` / `Pool_MinIdle` | `10` / `2` | `Validate` 要求 `MaxPool >= 1`、`MinIdle <= MaxPool`；经 `ApplyToPoolCfg` 生效 |
| 池 | `Pool_ConnTimeoutMs` | `30000` | 借连接等待上限；`TestTx` 池打满用 `2000` 验证超时分类 |
| 池 | `Pool_MaxLifetimeMs` / `Pool_KeepaliveMs` | `1800000` / `30000` | Hikari 生命周期/保活 |
| 池 | `Pool_LeakMs` | `0` | `0` 关闭泄漏检测；`> 0` 透传 Hikari |
| 池 | `Pool_TestQuery` / `Pool_ValidTimeoutMs` | `SELECT 1` / `5000` | 校验查询与超时 |
| 执行 | `Exec_WindowSize` | `1000` | `TJdbcQuery` 默认窗口与 `QueryOpen` 大小 |
| 执行 | `Exec_BatchLimit` | `10000` | `ExecBatch` 单次上限，上限 `100000` |
| 执行 | `Exec_TimeoutSecs` | `0` | `0` 不设超时；`TJdbcCommand.SetTimeout` 覆盖 |
| 字段 | `Field_WideWidth` | `255` | 宽串建表宽度 |
| 写约束 | `Savepoint_MaxLen` | `64` | savepoint 名白名单长度上限 |
| 观测 | `Obs_SlowWarnMs` / `Obs_SlowErrorMs` | `1000` / `5000` | `Timed` 分级：`>= warn` 为 slow（1 级），`>= error` 为 2 级 |
| 观测 | `Obs_SampleEvery` | `1` | `1` 全采样；`N` 每 N 条记一条 |

LCL 设计时组件（`TJdbcConnection` 池数、`TJdbcConnQuery` 窗口）默认值
同样从 `TJdbcConfig.Default` 取，`TestLcl` 按 Config 断言而非硬编码。

## 注册自定义驱动

```pascal
uses TyFPJDBC.Driver.Registry;
var
  e: TDriverEntry;
begin
  e.Id := 'mydb';
  e.DriverClass := 'com.example.JdbcDriver';
  e.UrlTemplate := 'jdbc:mydb://{host}:{port}/{database}';
  e.DefaultPort := 1234;
  e.TestQuery := 'SELECT 1';
  e.License := 'Commercial';
  e.Maven := 'com.example:mydb-jdbc:1.0.0';
  e.Sha := '';
  TDriverRegistry.Register(e);
end;
```

同名 `Id`（大小写不敏感）覆盖旧条目。`BuildUrl` 在 `Port<=0` 时回填
`DefaultPort`；`sqlite`/`h2` 不要求 `Host`/`Database`，其余缺 `Host` 抛
`08000/41`、缺 `Database` 抛 `08000/42`。`BuildProperties` 透传
`loginTimeout/socketTimeout/readOnly`。

## 驱动 jar 分发（mautool）

```powershell
mautool.exe --driver h2 --out C:\Tools\tyfpjdbc-libs
mautool.exe --fetch-driver mysql --accept-license   # GPL 需显式接受并落 marker
mautool.exe --verify-file --driver h2 --sha1 <hex> --out <dir>
mautool.exe --verify-manifests --config configs/drivers.json
```

行为（`src/tools/mautool.lpr`，`TestDistrib` 全断言）：
缓存命中先验 `sha1`；缺失则下载到临时文件、验 `sha1` 后原子改名；
`sha1` 不一致删除下载件并报 `MISMATCH`；未知驱动报 `unknown driver`。
缓存目录：`%TYFPJDBC_CACHE%`，缺省 `%USERPROFILE%\.tyfpjdbc\cache`。

## 运行时分发

```powershell
mautool.exe --resolve-runtime --platform win64 --sha256 <hex> --out <dir>
mautool.exe --verify-runtime --platform win64 --sha256 <hex> --out <dir>
mautool.exe --verify-runtime --platform win64 --sha256 000... --out <dir>  # 必 MISMATCH
```

`configs/runtimes.json` 固定 5 平台、`bridgeVersion 0.9.0`、`sha256` 64 位 hex。
