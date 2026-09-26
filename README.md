# TyFPJDBC（0.9.0）

经由 JNI 的通用 JDBC 桥：Java `Bridge` 是唯一状态机，Pascal 只拿 `Int64`
句柄。25 驱动注册 + 通用方言（分页/引用/主键回填按驱动描述配出）+
类型真值表 + 四库绑定矩阵。版本握手恒为 `0.9.0`，`JniVersionUsed = $00010006`。

## 最快体验：通讯录 Demo（双击即跑）

```powershell
cd D:\Projects\ContactsDemo
.\contacts.exe                # 图形通讯录：搜索 / 新增 / 修改 / 删除
.\contacts.exe --selftest     # 无界面自检
Get-Content selftest.log      # 期望 TOTAL fails=0
```

`ContactsDemo/` 自带 `jre/` + `bridge/` + `drivers/`（exe 旁三件套），
不装 JDK、不配环境变量、不读系统 JRE。首次运行自动建 `contacts.db`。
详情见 `D:\Projects\ContactsDemo\README.md`。

## Howto（给使用者）

**前置要求**：Windows 64 位 + Lazarus 4.8（FPC 3.2.2）。JDK 不需要装，
跟着 exe 走。

**1. 拿 runtime（三件套进你的 exe 目录）**

```text
YourApp/
  YourApp.exe
  jre/        # 从 TyFPJDBC-Runtimes 取 jre-25-tyfpjdbc-win64.zip，解压后把内层目录改名为 jre/
  bridge/     # tyfpjdbc-bridge-0.9.0.jar + HikariCP-5.1.0.jar + slf4j-api-2.0.9.jar
  drivers/    # sqlite-jdbc-3.46.1.0.jar（换库就换 jar）
```

注意 zip 里是 `jre-25-tyfpjdbc-win64/...` 单层目录，解压后把内层改名为
`jre/`（程序找的是 `exe旁/jre/bin/server/jvm.dll`，不是 zip 名那层）。

**2. 代码里三行启动（抄 `ContactsDemo/contactsmain.pas` 的 `OpenDatabase`）**

```pascal
TJVMManager.EnsureStarted(TJVMManager.FindLibJvm(''),
  TJVMManager.BuildDesktopArgs);
FBridge := TBridge.Create;
FEng := TJdbcEngine.Create(FBridge);
cfg := DefaultPoolCfg('jdbc:sqlite:' + UTF8String(DbPath), 'org.sqlite.JDBC');
FPool := FEng.OpenPool(cfg);
FConn := FEng.Borrow(FPool);
```

读用 `TJdbcQuery.OpenQuery(eng, conn, '表名', 'SELECT ...', 窗口大小)` 绑
`TDataSource` 给 DBGrid；写用 `TJdbcCommand.SetSQL('... :name ...')` +
`BStr/BInt64/BBool/...` 命名参数。字段读写一律 `AsUTF8String`
（`AsString` 走 ANSI 会在 GBK 控制台下坏 CJK）。

**3. 换数据库**：`drivers/` 里换 JDBC jar，改 URL + DriverClass 即可
（PG：`jdbc:postgresql://host:5432/db` + `org.postgresql.Driver`；
MySQL：`jdbc:mysql://host:3306/db` + `com.mysql.cj.jdbc.Driver`）。
新库加驱动描述即可，不改库源码（`docs/DRIVER.md` 有 `Register` 示例）。

**4. 出问题先看**：`docs/TROUBLESHOOTING.md`（错误分类/JVM/乱码/泄漏），
`docs/DIALECT-MATRIX.md`（分页/引用/大小写折叠/绑定契约）。

## 性能与边界（先说清楚）

- 按行插入比 Lazarus 自带 `sqlite3conn` 慢约 3.4 倍（JNI 逐行开销）；
  扫描/分页相当或更快。插入密集型请用 `ExecBatch`。
- 批量上限 `Exec_BatchLimit=10000`（硬上限 `100000`）；窗口默认 1000。
- 0.9 含义：API 未冻结，升级可能 break；只验证过 Win64 + JDK 25.0.4.1。

## 开发者（本仓库）

```powershell
pwsh -NoProfile -File scripts/guard.ps1          # 门禁
pwsh -NoProfile -File scripts/run-matrix.ps1     # 完整矩阵（需 PG 5432 + MySQL 3306）
```

`.o`/`.ppu` 只进 `test-results/work/units`，`exe` 只进 `test-results/bin`。
`Bridge.java` 是状态机唯一真源，Pascal 侧不许旁路 JNI 直连。
