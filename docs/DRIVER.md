# TyFPJDBC 驱动接入（DRIVER）

规则：Java `Bridge` 是唯一状态机，Pascal 只拿 `Int64` 句柄。
任何 JDBC 驱动都走同一注册表接入，未知驱动直接报错（`08000`），不静默兜底。

## 内置驱动

`src/core/TyFPJDBC.Driver.Registry.pas`（`RegisterBuiltinDrivers`）：

| id | driverClass | urlTemplate | 默认端口 | 许可 |
|---|---|---|---|---|
| postgresql | org.postgresql.Driver | jdbc:postgresql://{host}:{port}/{database} | 5432 | BSD-2 |
| mysql | com.mysql.cj.jdbc.Driver | jdbc:mysql://{host}:{port}/{database} | 3306 | GPL-2 |
| mariadb | org.mariadb.jdbc.Driver | jdbc:mariadb://{host}:{port}/{database} | 3306 | LGPL-2.1 |
| mssql | com.microsoft.sqlserver.jdbc.SQLServerDriver | jdbc:sqlserver://{host}:{port};databaseName={database} | 1433 | MIT |
| oracle | oracle.jdbc.OracleDriver | jdbc:oracle:thin:@{host}:{port}:{database} | 1521 | OTN |
| sqlite | org.sqlite.JDBC | jdbc:sqlite:{database} | 0 | Apache-2.0 |
| h2 | org.h2.Driver | jdbc:h2:mem:{database} | 0 | MPL-2.0 |

`TestDialect` 断言：未知驱动抛 `08000`；`sqlite`/`h2` 只替换 `{database}`；
`mssql` 的 `Extra` 用 `;` 连接，其余用 `?k=v&...`。

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

`configs/runtimes.json` 固定 5 平台、`bridgeVersion 2.0.0`、`sha256` 64 位 hex。
