# TyFPJDBC 易用性加固 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用户装上即用：exe 旁自包含运行时，三档 JRE 查找（不支持系统 JRE），驱动注册表扩到 DBeaver 级（25 条 + wire 别名），下载逻辑入库共用，驱动向导对话框完整可用，包上浮到仓库根。

**Architecture:** Java `Bridge` 与扁平 `createPoolFlat` 签名不动；Pascal 侧加 `Runtime_Root/Runtime_JvmPath` 配置、`TyFPJDBC.Driver.Fetch` 下载单元（mautool 变薄壳）、`TDriverRegistry.BuiltinIds` 统一驱动源、非可视 `TJdbcDriverWizard` 逻辑类 + 瘦 LCL 窗体；`tyfpjdbc.lpk` 上浮到根。

**Tech Stack:** Free Pascal 3.2.2 / Lazarus LCL / JNI（`jni` 单元，上限 JNI 1.6）/ Temurin JDK 25 / 下载走 curl/PowerShell 子进程（与现 mautool 策略一致，https 无需 openssl）/ PowerShell 矩阵。

**Spec:** `docs/superpowers/specs/2026-09-25-tyfpjdbc-usability-design.md`

## Global Constraints

- Bridge 版本握手恒为 `0.9.0`：`Bridge.VERSION`、`TBridge` 强校验、`configs/runtimes.json` 五处 `bridgeVersion`、相关测试断言，任何任务不得改动该值。
- `JniVersionUsed = $00010006`（JNI 1.6 上限）；改动 JVM 参数不得破坏该断言。
- `.o`/`.ppu` 永不落源码旁：一切 `fpc` 调用必须带 `-FUtest-results/work/units`，`guard.ps1` 产物门禁保持绿色。
- PG/MySQL 无本地库时记 `SKIP` 环境缺失，绝不伪造成功；新增驱动只做形状断言（URL 拼装），不建真库。
- 库单元永不 `Halt`：`TyFPJDBC.Driver.Fetch` 内只 `raise`，退出码只由 `mautool.lpr` 决定。
- 每个任务结束独立提交，一个任务绿了才能进下一个；先跑目标测试（红），再写最小实现（绿），再跑相关门禁。

## File Map

- 修改：`src/core/TyFPJDBC.Config.pas`（Task 1，`Runtime_Root/Runtime_JvmPath`）。
- 修改：`src/core/TyFPJDBC.JVM.Manager.pas`（Task 1，三档查找 + 默认 classpath）。
- 修改：`tests/TestJvm.lpr`（Task 1，重写查找断言）。
- 修改：`.gitignore`（Task 1，补 `jre/` + `bridge/`）。
- 新增：`src/core/TyFPJDBC.Driver.Fetch.pas`（Task 2，下载单元）。
- 修改：`src/tools/mautool.lpr`（Task 2，变薄壳）。
- 修改：`tests/TestDistrib.lpr`（Task 2，纯逻辑断言）。
- 修改：`src/core/TyFPJDBC.Driver.Registry.pas`（Task 3，18 新条目 + `IsEmbedded` + `BuiltinIds`）。
- 修改：`configs/drivers.json`（Task 3，22 新条目）。
- 修改：`tests/TestDialect.lpr`（Task 3，URL 形状表）。
- 修改：`docs/DRIVER.md`（Task 3，驱动表更新）。
- 新增：`src/lcl/TyFPJDBC.LCL.Wizard.pas`（Task 4，向导逻辑）。
- 修改：`src/lcl/TyFPJDBC.LCL.ConnDialog.pas`（Task 4，完整窗体）。
- 修改：`src/lcl/tyfpjdbc.lpk`（Task 4 加 Wizard 单元；Task 5 整体搬走）。
- 修改：`tests/TestLcl.lpr`（Task 4，向导断言）。
- 移动：`src/lcl/tyfpjdbc.lpk` → `tyfpjdbc.lpk`（Task 5）。
- 修改：`scripts/run-matrix.ps1`（Task 2 加 `-Fu src/core`；Task 5 改 lpk 路径）。
- 修改：`scripts/guard.ps1`（Task 5，根 `lib/` 门禁）。

---

### Task 1: 运行时布局与三档 JRE 查找

**Files:**
- Modify: `src/core/TyFPJDBC.Config.pas`
- Modify: `src/core/TyFPJDBC.JVM.Manager.pas`
- Modify: `tests/TestJvm.lpr`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `TJVMOptions`、`EnsureStarted`、`SplitArgs/JoinArgs`（现状不动）。
- Produces（后续任务直接引用这些名字）:
  - `TJdbcConfig.Runtime_Root: string`（默认 `''` = exe 旁）、`TJdbcConfig.Runtime_JvmPath: string`（默认 `''`）。
  - `TJVMManager.SetRuntimeConfig(const Root, JvmPath: string)`、`TJVMManager.DefaultClassPath: string`（`<root>/bridge/*` + 分隔符 + `<root>/drivers/*`）。

- [ ] **Step 1: 给 TestJvm 加新断言（先红）**

`tests/TestJvm.lpr`：`uses` 的 `SysUtils` 后加 `Classes`；`var Cfg` 那一行附近加 `tmpJvm: string;`；把最后的 `findlib-probe` 块（`try TJVMManager.FindLibJvm('')` 那 6 行，含 `Ok('findlib-probe'...)` 两处）整个替换为：

```pascal
  tmpJvm := IncludeTrailingPathDelimiter(GetTempDir) + 'fake-jvm.dll';
  with TFileStream.Create(tmpJvm, fmCreate) do Free;
  try
    Ok('explicit-path', TJVMManager.FindLibJvm(tmpJvm) = tmpJvm);
  finally
    DeleteFile(tmpJvm);
  end;
  { Root 钉死到不存在的目录后，JAVA_HOME 必须被无视：系统 JRE 不再是来源。 }
  TJVMManager.SetRuntimeConfig('C:\nonexistent-root-xyz', '');
  SetEnvironmentVariable('JAVA_HOME', 'C:\nonexistent-java-home-xyz');
  try
    TJVMManager.FindLibJvm('');
    Ok('no-system-jre', False);
  except
    on E: Exception do
      Ok('no-system-jre', Pos('libjvm', E.Message) > 0);
  end;
  TJVMManager.SetRuntimeConfig('', '');
  Ok('default-cp-shape', (Pos('bridge', TJVMManager.DefaultClassPath) > 0) and
    (Pos('drivers', TJVMManager.DefaultClassPath) > 0));
```

Run: `fpc -Fusrc/core -FUtest-results/work/units "-otest-results\bin\testjvm.exe" tests/TestJvm.lpr`
Expected: FAIL，`Identifier not found "SetRuntimeConfig"`。

- [ ] **Step 2: Config 加两个字段**

`src/core/TyFPJDBC.Config.pas`：public 区 `Obs_SampleEvery: Integer;` 后加：

```pascal
    Runtime_Root: string;
    Runtime_JvmPath: string;
```

构造函数 `Obs_SampleEvery := 1;` 后加：

```pascal
  Runtime_Root := '';
  Runtime_JvmPath := '';
```

`Validate` 末尾（`JVM_FileEncoding` 检查后）加：

```pascal
  if (Runtime_JvmPath <> '') and not FileExists(Runtime_JvmPath) then
    raise Exception.Create('Runtime_JvmPath not found: ' + Runtime_JvmPath);
```

- [ ] **Step 3: JVM Manager 改查找**

声明区删除 `class function FindLibJvmLegacy(const CustomPath: string): string; static;` 这一行，改为：

```pascal
    class procedure SetRuntimeConfig(const Root, JvmPath: string); static;
    class function DefaultClassPath: string; static;
```

`class var` 区（`FOnLog` 那一行附近）加：

```pascal
    class var FRuntimeRoot: string;
    class var FRuntimeJvmPath: string;
```

删除 `FindLibJvmLegacy` 整个实现（从 `class function TJVMManager.FindLibJvmLegacy` 起到它 `end;` 之前含 `raise Exception.Create('libjvm not found...')` 的一段），把 `FindLibJvm` 实现替换为：

```pascal
class function TJVMManager.FindLibJvm(const CustomPath: string): string;
var
  root, cand: string;

  function TryPath(const P: string): Boolean;
  begin
    Result := (P <> '') and FileExists(P);
    if Result then
      FindLibJvm := P;
  end;

begin
  { Only three sources: explicit path, configured root, exe-side jre/.
    System JRE (JAVA_HOME/registry/PATH) is deliberately unsupported. }
  if TryPath(CustomPath) then
  begin
    DoLog('WARNING: explicit libjvm used, version not verified: ' + CustomPath);
    Exit;
  end;
  if TryPath(FRuntimeJvmPath) then
  begin
    DoLog('WARNING: configured libjvm used, version not verified: ' + FRuntimeJvmPath);
    Exit;
  end;
  root := FRuntimeRoot;
  if root = '' then
    root := ExtractFilePath(ParamStr(0));
  cand := IncludeTrailingPathDelimiter(root) + 'jre' + PathDelim + 'bin' +
    PathDelim + 'server' + PathDelim + 'jvm.dll';
  if TryPath(cand) then
    Exit;
  cand := IncludeTrailingPathDelimiter(root) + 'jre' + PathDelim + 'lib' +
    PathDelim + 'server' + PathDelim + 'libjvm.so';
  if TryPath(cand) then
    Exit;
  cand := IncludeTrailingPathDelimiter(root) + 'jre' + PathDelim + 'lib' +
    PathDelim + 'server' + PathDelim + 'libjvm.dylib';
  if TryPath(cand) then
    Exit;
  raise Exception.Create('libjvm not found: bundle jre/ next to the exe or set ' +
    'Runtime_Root/Runtime_JvmPath (system JRE is not supported)');
end;

class procedure TJVMManager.SetRuntimeConfig(const Root, JvmPath: string);
begin
  FLock.Enter;
  try
    FRuntimeRoot := Root;
    FRuntimeJvmPath := JvmPath;
  finally
    FLock.Leave;
  end;
end;

class function TJVMManager.DefaultClassPath: string;
var
  root: string;
begin
  root := FRuntimeRoot;
  if root = '' then
    root := ExtractFilePath(ParamStr(0));
  Result := IncludeTrailingPathDelimiter(root) + 'bridge' + PathDelim + '*' +
    PathSeparator + IncludeTrailingPathDelimiter(root) + 'drivers' + PathDelim + '*';
end;
```

`ResetForTests` 里 `FAttachCount := 0;` 后加（锚定含下面 `Keep a live VM` 注释的那一处，`ShutdownJvm` 里的另一处不要动）：

```pascal
    FRuntimeRoot := '';
    FRuntimeJvmPath := '';
```

`EnsureStarted` 里 `argList := SplitArgs(ExtraArgs);` 到 `cpOpt := ...FClassPath` 那一段改为用有效 classpath（`var` 区加 `effCP: string;`）：

```pascal
    argList := SplitArgs(ExtraArgs);
    effCP := FClassPath;
    if effCP = '' then
      effCP := DefaultClassPath;
    nopt := Length(argList);
    if effCP <> '' then
      Inc(nopt);
```

以及 `cpOpt := AnsiString('-Djava.class.path=' + FClassPath);` 改为 `cpOpt := AnsiString('-Djava.class.path=' + effCP);`。

`GetClassPath` 改为未设置时回退默认布局：

```pascal
class function TJVMManager.GetClassPath: string;
begin
  FLock.Enter;
  try
    Result := FClassPath;
    if Result = '' then
      Result := DefaultClassPath;
  finally
    FLock.Leave;
  end;
end;
```

- [ ] **Step 4: 跑测试确认通过**

Run: 编译并运行 `tests/TestJvm.lpr`，Expected: `TOTAL fails=0`（含新增 4 项）。
再跑 `TestEngine`（H2 真库，显式 `SetClassPath` 路径不受影响）确认 `TOTAL fails=0`。
Run: `pwsh -NoProfile -File scripts/guard.ps1`，Expected: `guard ok`。

- [ ] **Step 5: `.gitignore` 补布局目录**

`drivers/` 那一节：`jre-*/` 行后加 `jre/`（精确名，现有 `jre-*/` 盖不住），`runtimes/` 行后加 `bridge/`（放 class 和 jar，永不入库）。

- [ ] **Step 6: 提交**

```bash
git add src/core/TyFPJDBC.Config.pas src/core/TyFPJDBC.JVM.Manager.pas tests/TestJvm.lpr .gitignore
git commit -m "feat: exe-side runtime layout with three-source libjvm lookup"
```

---

### Task 2: 下载逻辑入库，mautool 变薄壳

**Files:**
- Create: `src/core/TyFPJDBC.Driver.Fetch.pas`
- Modify: `src/tools/mautool.lpr`
- Modify: `tests/TestDistrib.lpr`
- Modify: `scripts/run-matrix.ps1`（mautool-build 段 fpc 追加 `-Fu src/core`）

**Interfaces:**
- Consumes: Task 1 的缓存目录规则（照搬：`%TYFPJDBC_CACHE%` 否则 `%USERPROFILE%\.tyfpjdbc\cache`）。
- Produces（Task 4 直接用）:
  - `TDriverFetch.IsGplLicense(const L: string): Boolean`（含 `GPL` 但不含 `LGPL` 才算；`AGPL` 照样拦截）。
  - `TDriverFetch.SetMarkerDir/CacheDir/LicenseMarkerFile/LicenseAccepted/MarkLicenseAccepted`（marker 默认真实缓存，测试可重定向）。
  - `TDriverFetch.MavenPath(const Maven: string; out Group, Artifact, Ver: string): string`（坏坐标返回 `''`，永不 `Halt`）。
  - `TDriverFetch.MavenURL/FetchText/Sha1OfFile`。
  - `TDriverFetch.FetchJar(const URL, ExpectSha, Target: string): TFetchResult`（`frCacheHit`/`frDownloaded`；mismatch/下载失败 `raise`，消息分别含 `checksum MISMATCH` / `download failed`）。

- [ ] **Step 1: TestDistrib 加纯逻辑断言（先红）**

`tests/TestDistrib.lpr`：`uses` 加 `TyFPJDBC.Driver.Fetch`；`var` 区加 `g, a, v: string;`；在 `begin` 后、`Run('--verify-manifests...` 之前插入：

```pascal
  Ok('gpl-gate', TDriverFetch.IsGplLicense('GPL-2'));
  Ok('lgpl-open', not TDriverFetch.IsGplLicense('LGPL-2.1'));
  Ok('bsd-open', not TDriverFetch.IsGplLicense('BSD-2-Clause'));
  Ok('maven-path', TDriverFetch.MavenPath('com.h2database:h2:2.2.224', g, a, v) =
    'com/h2database/h2/2.2.224/h2-2.2.224.jar');
```

Run: `fpc -Fusrc/core -Fusrc/db -FUtest-results/work/units "-otest-results\bin\testdistrib.exe" tests/TestDistrib.lpr`
Expected: FAIL，`Can't find unit TyFPJDBC.Driver.Fetch`。

- [ ] **Step 2: 新建 Fetch 单元（最小实现）**

`src/core/TyFPJDBC.Driver.Fetch.pas` 完整内容（下载经 curl/PowerShell 子进程，与现 mautool 策略一致；本单元只 `raise` 不 `Halt`）：

```pascal
unit TyFPJDBC.Driver.Fetch;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes;
type
  TFetchResult = (frCacheHit, frDownloaded);
  { In-library driver fetch: download, verify sha1, atomic store.
    mautool is a thin shell over this; the LCL wizard calls it directly. }
  TDriverFetch = class
    class function IsGplLicense(const L: string): Boolean; static;
    class procedure SetMarkerDir(const D: string); static;
    class function CacheDir: string; static;
    class function LicenseMarkerFile(const DriverId: string): string; static;
    class function LicenseAccepted(const DriverId: string): Boolean; static;
    class procedure MarkLicenseAccepted(const DriverId: string); static;
    class function MavenPath(const Maven: string; out Group, Artifact, Ver: string): string; static;
    class function MavenURL(const Rel: string): string; static;
    class function Sha1OfFile(const P: string): string; static;
    class function FetchText(const URL: string): string; static;
    class function FetchJar(const URL, ExpectSha, Target: string): TFetchResult; static;
  end;

implementation
uses
  sha1, process;

var
  GMarkerDir: string;

class function TDriverFetch.IsGplLicense(const L: string): Boolean;
var
  u: string;
begin
  { LGPL is explicitly open; plain GPL and AGPL need the accept gate. }
  u := UpperCase(L);
  Result := (Pos('GPL', u) > 0) and (Pos('LGPL', u) = 0);
end;

class procedure TDriverFetch.SetMarkerDir(const D: string);
begin
  GMarkerDir := D;
end;

class function TDriverFetch.CacheDir: string;
begin
  Result := GetEnvironmentVariable('TYFPJDBC_CACHE');
  if Trim(Result) = '' then
    Result := IncludeTrailingPathDelimiter(GetEnvironmentVariable('USERPROFILE')) +
      '.tyfpjdbc' + PathDelim + 'cache';
  if not DirectoryExists(Result) then
    ForceDirectories(Result);
end;

class function TDriverFetch.LicenseMarkerFile(const DriverId: string): string;
var
  dir: string;
begin
  dir := GMarkerDir;
  if dir = '' then
    dir := CacheDir;
  Result := IncludeTrailingPathDelimiter(dir) + 'license-' +
    LowerCase(Trim(DriverId)) + '.accepted';
end;

class function TDriverFetch.LicenseAccepted(const DriverId: string): Boolean;
begin
  Result := FileExists(LicenseMarkerFile(DriverId));
end;

class procedure TDriverFetch.MarkLicenseAccepted(const DriverId: string);
var
  f: string;
  sl: TStringList;
begin
  f := LicenseMarkerFile(DriverId);
  ForceDirectories(ExtractFilePath(f));
  sl := TStringList.Create;
  try
    sl.Text := 'accepted ' + DateTimeToStr(Now);
    sl.SaveToFile(f);
  finally
    sl.Free;
  end;
end;

class function TDriverFetch.MavenPath(const Maven: string; out Group, Artifact, Ver: string): string;
var
  p1, p2: Integer;
begin
  Result := '';
  Group := '';
  Artifact := '';
  Ver := '';
  p1 := Pos(':', Maven);
  p2 := LastDelimiter(':', Maven);
  if (p1 = 0) or (p2 <= p1) then
    Exit;
  Group := Copy(Maven, 1, p1 - 1);
  Artifact := Copy(Maven, p1 + 1, p2 - p1 - 1);
  Ver := Copy(Maven, p2 + 1, MaxInt);
  if (Group = '') or (Artifact = '') or (Ver = '') then
  begin
    Group := '';
    Artifact := '';
    Ver := '';
    Exit;
  end;
  Result := StringReplace(Group, '.', '/', [rfReplaceAll]) + '/' + Artifact +
    '/' + Ver + '/' + Artifact + '-' + Ver + '.jar';
end;

class function TDriverFetch.MavenURL(const Rel: string): string;
begin
  Result := 'https://repo1.maven.org/maven2/' + Rel;
end;

class function TDriverFetch.Sha1OfFile(const P: string): string;
begin
  Result := LowerCase(SHA1Print(SHA1File(P)));
end;

function Downloader: string;
begin
  { Prefer curl where present; fall back to PowerShell Invoke-WebRequest so
    stock Windows without curl still works. No hard curl dependency. }
  if FileExists(GetEnvironmentVariable('SystemRoot') + '\System32\curl.exe') then
    Exit('curl');
  Result := 'powershell';
end;

function RunToFile(const Exe, Args, OutFile: string): Boolean;
var
  P: TProcess;
  fs: TFileStream;
  buf: array[0..8191] of Byte;
  n: Integer;
begin
  Result := False;
  P := TProcess.Create(nil);
  try
    P.Executable := Exe;
    P.Parameters.DelimitedText := Args;
    P.Options := [poWaitOnExit, poUsePipes];
    P.Execute;
    fs := TFileStream.Create(OutFile, fmCreate);
    try
      repeat
        n := P.Output.Read(buf, SizeOf(buf));
        if n > 0 then
          fs.WriteBuffer(buf, n);
      until n <= 0;
    finally
      fs.Free;
    end;
    Result := P.ExitStatus = 0;
  finally
    P.Free;
  end;
end;

function RunGet(const Exe, Args, OutFile: string): Boolean;
var
  dlArgs, final_: string;
begin
  if OutFile = '' then
    Exit(RunToFile(Exe, Args, GetTempFileName('', 'mauout')));
  { curl -o vs powershell -OutFile: normalize here so callers pass URLs only. }
  if (Exe = 'powershell') and (Pos('http', Args) > 0) then
  begin
    dlArgs := '-NoProfile -Command Invoke-WebRequest ' + Trim(Args) + ' ' +
      OutFile + '.tmp';
    Result := RunToFile(Exe, dlArgs, OutFile + '.tmp');
  end
  else
    Result := RunToFile(Exe, Args + ' -o "' + OutFile + '"', OutFile + '.tmp');
  if not Result then
    Exit(False);
  { Atomic rename after successful download (no partial cache poison). }
  final_ := OutFile;
  if FileExists(final_) then
    DeleteFile(final_);
  Result := RenameFile(OutFile + '.tmp', final_);
end;

class function TDriverFetch.FetchText(const URL: string): string;
var
  tmp: string;
  sl: TStringList;
  dl: string;
begin
  Result := '';
  tmp := GetTempFileName('', 'mau');
  try
    dl := Downloader;
    if dl = 'powershell' then
    begin
      if not RunGet(dl, URL, tmp) then
        raise Exception.Create('download failed: ' + URL);
    end
    else if not RunGet(dl, '-sL "' + URL + '"', tmp) then
      raise Exception.Create('download failed: ' + URL);
    sl := TStringList.Create;
    try
      sl.LoadFromFile(tmp);
      Result := Trim(sl.Text);
    finally
      sl.Free;
    end;
  finally
    DeleteFile(tmp);
  end;
end;

class function TDriverFetch.FetchJar(const URL, ExpectSha, Target: string): TFetchResult;
var
  gotSha: string;
  dl: string;
begin
  if Trim(ExpectSha) = '' then
    raise Exception.Create('sha1 required for ' + Target);
  if FileExists(Target) then
  begin
    gotSha := Sha1OfFile(Target);
    if gotSha = LowerCase(Trim(ExpectSha)) then
      Exit(frCacheHit);
    raise Exception.Create('checksum MISMATCH for ' + Target);
  end;
  { Cache miss: download, verify, atomically store. Proxy comes from
    environment (https_proxy) via curl/powershell defaults. }
  dl := Downloader;
  if dl = 'powershell' then
  begin
    if not RunGet('powershell', URL, Target) then
      raise Exception.Create('download failed: ' + URL);
  end
  else if not RunGet(dl, '-sL "' + URL + '"', Target) then
    raise Exception.Create('download failed: ' + URL);
  gotSha := Sha1OfFile(Target);
  if gotSha <> LowerCase(Trim(ExpectSha)) then
  begin
    DeleteFile(Target);
    raise Exception.Create('checksum MISMATCH for ' + Target);
  end;
  Result := frDownloaded;
end;

end.
```

- [ ] **Step 3: mautool 改调 Fetch（行为不变）**

`src/tools/mautool.lpr`：
1. `uses` 加 `TyFPJDBC.Driver.Fetch`，去掉 `sha1`（直接引用已全部搬走；`process` 保留，`RunCapture` 还在用）。
2. 删除以下函数整段（已搬进 Fetch 单元）：`MavenPath`、`MavenURL`、`CacheDir`、`IsGplLicense`、`Downloader`、`RunToFile`、`RunGet`、`FetchText`。保留 `NeedLicense`（按第 3 条重写）与 `RunCapture`（runtime 验签用）。
3. `NeedLicense` 改为：

```pascal
procedure NeedLicense(const DriverId, License: string; var AcceptFlag: Boolean);
var
  ans: string;
begin
  if not TDriverFetch.IsGplLicense(License) then
    Exit;
  if AcceptFlag then
    Exit;
  if TDriverFetch.LicenseAccepted(DriverId) then
    Exit;
  Write('Driver ', DriverId, ' is ', License,
    '. Type ACCEPT to download: ');
  ReadLn(ans);
  if UpperCase(Trim(ans)) <> 'ACCEPT' then
    Fail('license not accepted for ' + DriverId);
  TDriverFetch.MarkLicenseAccepted(DriverId);
end;
```

4. `CmdDriver` 内替换：`CacheDir + ...` → `TDriverFetch.CacheDir + ...`；`FetchText(url + '.sha1')` → `TDriverFetch.FetchText(url + '.sha1')`；两处 `LowerCase(SHA1Print(SHA1File(target)))` → `TDriverFetch.Sha1OfFile(target)`；`rel := MavenPath(maven, grp, art, ver)` → `rel := TDriverFetch.MavenPath(maven, grp, art, ver)` 并在其后加 `if rel = '' then Fail('bad maven coordinate ' + maven)`；`url := MavenURL(rel)` → `url := TDriverFetch.MavenURL(rel)`。
5. `CmdVerifyFile` 内同样替换 `MavenPath` 和 sha 计算。
6. 矩阵 mautool-build 段 fpc 调用追加 `-Fu src/core`。

- [ ] **Step 4: 跑测试确认行为一致**

Run: 按既有电池方式重编 mautool（带 `-Fu src/core`）后跑 `tests/TestDistrib.lpr`（`MAUTOOL_EXE` 指向刚编好的），Expected: `TOTAL fails=0`（含新增 4 项纯逻辑断言和原有 manifests/runtime/driver accept-reject）。
Run: `pwsh -NoProfile -File scripts/guard.ps1`，Expected: `guard ok`。

- [ ] **Step 5: 提交**

```bash
git add src/core/TyFPJDBC.Driver.Fetch.pas src/tools/mautool.lpr tests/TestDistrib.lpr scripts/run-matrix.ps1
git commit -m "refactor: driver download into library unit, mautool as thin shell"
```

---

### Task 3: DBeaver 级驱动表（25 条 + wire 别名）

**Files:**
- Modify: `src/core/TyFPJDBC.Driver.Registry.pas`
- Modify: `configs/drivers.json`
- Modify: `tests/TestDialect.lpr`
- Modify: `docs/DRIVER.md`

**Interfaces:**
- Consumes: Task 2 的 `TDriverFetch.MavenPath`（向导用，本任务不用）。
- Produces（Task 4 直接用）: `TDriverRegistry.BuiltinIds: TDriverIdArray`（`TDriverIdArray = array of string`，注册表单元内定义）；`TDriverRegistry.IsEmbedded(const DriverId: string): Boolean`。

- [ ] **Step 1: TestDialect 加 URL 形状表（先红）**

`tests/TestDialect.lpr`：在靠近其他 helper 的位置加：

```pascal
procedure CheckUrl(const Id, Host: string; Port: Integer; const Db, Want: string);
begin
  try
    Ok('url-' + Id, TDriverRegistry.BuildUrl(Id, Host, Port, Db, nil) = Want);
  except
    Ok('url-' + Id, False);
  end;
end;
```

在 `WriteLn('TOTAL fails='` 之前插入：

```pascal
  CheckUrl('duckdb', '', 0, 'mem.db', 'jdbc:duckdb:mem.db');
  CheckUrl('derby', '', 0, 'appdb', 'jdbc:derby:appdb;create=true');
  CheckUrl('hsqldb', '', 0, 'appdb', 'jdbc:hsqldb:file:appdb');
  CheckUrl('firebird', 'db', 0, 'app', 'jdbc:firebirdsql://db:3050/app');
  CheckUrl('db2', 'db', 0, 'app', 'jdbc:db2://db:50000/app');
  CheckUrl('informix', 'db', 0, 'app', 'jdbc:informix-sqli://db:9088/app');
  CheckUrl('sybase', 'db', 0, 'app', 'jdbc:jtds:sybase://db:5000/app');
  CheckUrl('teradata', 'db', 0, 'app', 'jdbc:teradata://db/app');
  CheckUrl('vertica', 'db', 0, 'app', 'jdbc:vertica://db:5433/app');
  CheckUrl('clickhouse', 'db', 0, 'app', 'jdbc:clickhouse://db:8123/app');
  CheckUrl('trino', 'db', 0, 'app', 'jdbc:trino://db:8080/app');
  CheckUrl('presto', 'db', 0, 'app', 'jdbc:presto://db:8080/app');
  CheckUrl('hive', 'db', 0, 'app', 'jdbc:hive2://db:10000/app');
  CheckUrl('snowflake', 'myacct', 0, 'app', 'jdbc:snowflake://myacct.snowflakecomputing.com/app');
  CheckUrl('redshift', 'db', 0, 'app', 'jdbc:redshift://db:5439/app');
  CheckUrl('exasol', 'db', 0, 'app', 'jdbc:exa:db:8563;schema=app');
  CheckUrl('monetdb', 'db', 0, 'app', 'jdbc:monetdb://db:50000/app');
  CheckUrl('hana', 'db', 0, 'app', 'jdbc:sap://db:30015/?databaseName=app');
  CheckUrl('mysql', 'db', 0, 'app', 'jdbc:mysql://db:3306/app');
  CheckUrl('mariadb', 'db', 0, 'app', 'jdbc:mariadb://db:3306/app');
  CheckUrl('mssql', 'db', 0, 'app', 'jdbc:sqlserver://db:1433;databaseName=app');
  CheckUrl('oracle', 'db', 0, 'app', 'jdbc:oracle:thin:@db:1521:app');
  Ok('builtin-count', Length(TDriverRegistry.BuiltinIds) >= 25);
```

Run: 编译 `tests/TestDialect.lpr`，Expected: FAIL（`unknown driver`，`duckdb` 不存在）。

- [ ] **Step 2: 注册表加 18 条目 + IsEmbedded + BuiltinIds**

`src/core/TyFPJDBC.Driver.Registry.pas`：
1. `TDriverEntry` 记录之前加 `TDriverIdArray = array of string;`；`TDriverRegistry` 声明加：

```pascal
    class function IsEmbedded(const DriverId: string): Boolean; static;
    class function BuiltinIds: TDriverIdArray; static;
```

2. `RegisterBuiltinDrivers` 的 `h2` 条目之后追加（id 与 Step 1 断言名一一对应）：

```pascal
  e.Id := 'duckdb'; e.DriverClass := 'org.duckdb.DuckDBDriver';
  e.UrlTemplate := 'jdbc:duckdb:{database}';
  e.DefaultPort := 0; e.TestQuery := 'SELECT 1';
  e.License := 'MIT'; e.Maven := 'org.duckdb:duckdb_jdbc:1.0.0'; e.Sha := '';
  TDriverRegistry.Register(e);
  e.Id := 'derby'; e.DriverClass := 'org.apache.derby.jdbc.EmbeddedDriver';
  e.UrlTemplate := 'jdbc:derby:{database};create=true';
  e.DefaultPort := 0; e.TestQuery := 'SELECT 1';
  e.License := 'Apache-2.0'; e.Maven := 'org.apache.derby:derby:10.17.1.0'; e.Sha := '';
  TDriverRegistry.Register(e);
  e.Id := 'hsqldb'; e.DriverClass := 'org.hsqldb.jdbc.JDBCDriver';
  e.UrlTemplate := 'jdbc:hsqldb:file:{database}';
  e.DefaultPort := 0; e.TestQuery := 'SELECT 1';
  e.License := 'BSD-3-Clause'; e.Maven := 'org.hsqldb:hsqldb:2.7.2'; e.Sha := '';
  TDriverRegistry.Register(e);
  e.Id := 'firebird'; e.DriverClass := 'org.firebirdsql.jdbc.FBDriver';
  e.UrlTemplate := 'jdbc:firebirdsql://{host}:{port}/{database}';
  e.DefaultPort := 3050; e.TestQuery := 'SELECT 1 FROM RDB$DATABASE';
  e.License := 'IPL-1.0'; e.Maven := 'org.firebirdsql.jdbc:jaybird:4.0.9.java11'; e.Sha := '';
  TDriverRegistry.Register(e);
  e.Id := 'db2'; e.DriverClass := 'com.ibm.db2.jcc.DB2Driver';
  e.UrlTemplate := 'jdbc:db2://{host}:{port}/{database}';
  e.DefaultPort := 50000; e.TestQuery := 'SELECT 1 FROM SYSIBM.SYSDUMMY1';
  e.License := 'Proprietary'; e.Maven := 'com.ibm.db2:jcc:11.5.9.0'; e.Sha := '';
  TDriverRegistry.Register(e);
  e.Id := 'informix'; e.DriverClass := 'com.informix.jdbc.IfxDriver';
  e.UrlTemplate := 'jdbc:informix-sqli://{host}:{port}/{database}';
  e.DefaultPort := 9088; e.TestQuery := 'SELECT 1 FROM SYSTABLES';
  e.License := 'Proprietary'; e.Maven := 'com.ibm.informix:jdbc:4.50.10'; e.Sha := '';
  TDriverRegistry.Register(e);
  e.Id := 'sybase'; e.DriverClass := 'net.sourceforge.jtds.jdbc.Driver';
  e.UrlTemplate := 'jdbc:jtds:sybase://{host}:{port}/{database}';
  e.DefaultPort := 5000; e.TestQuery := 'SELECT 1';
  e.License := 'LGPL-2.1'; e.Maven := 'net.sourceforge.jtds:jtds:1.3.1'; e.Sha := '';
  TDriverRegistry.Register(e);
  e.Id := 'teradata'; e.DriverClass := 'com.teradata.jdbc.TeraDriver';
  e.UrlTemplate := 'jdbc:teradata://{host}/{database}';
  e.DefaultPort := 1025; e.TestQuery := 'SELECT 1';
  e.License := 'Proprietary'; e.Maven := 'com.teradata.jdbc:terajdbc4:17.20.00.12'; e.Sha := '';
  TDriverRegistry.Register(e);
  e.Id := 'vertica'; e.DriverClass := 'com.vertica.jdbc.Driver';
  e.UrlTemplate := 'jdbc:vertica://{host}:{port}/{database}';
  e.DefaultPort := 5433; e.TestQuery := 'SELECT 1';
  e.License := 'Proprietary'; e.Maven := 'com.vertica.jdbc:vertica-jdbc:23.4.0-0'; e.Sha := '';
  TDriverRegistry.Register(e);
  e.Id := 'clickhouse'; e.DriverClass := 'com.clickhouse.jdbc.ClickHouseDriver';
  e.UrlTemplate := 'jdbc:clickhouse://{host}:{port}/{database}';
  e.DefaultPort := 8123; e.TestQuery := 'SELECT 1';
  e.License := 'Apache-2.0'; e.Maven := 'com.clickhouse:clickhouse-jdbc:0.6.0'; e.Sha := '';
  TDriverRegistry.Register(e);
  e.Id := 'trino'; e.DriverClass := 'io.trino.jdbc.TrinoDriver';
  e.UrlTemplate := 'jdbc:trino://{host}:{port}/{database}';
  e.DefaultPort := 8080; e.TestQuery := 'SELECT 1';
  e.License := 'Apache-2.0'; e.Maven := 'io.trino:trino-jdbc:435'; e.Sha := '';
  TDriverRegistry.Register(e);
  e.Id := 'presto'; e.DriverClass := 'com.facebook.presto.jdbc.PrestoDriver';
  e.UrlTemplate := 'jdbc:presto://{host}:{port}/{database}';
  e.DefaultPort := 8080; e.TestQuery := 'SELECT 1';
  e.License := 'Apache-2.0'; e.Maven := 'com.facebook.presto:presto-jdbc:0.288'; e.Sha := '';
  TDriverRegistry.Register(e);
  e.Id := 'hive'; e.DriverClass := 'org.apache.hive.jdbc.HiveDriver';
  e.UrlTemplate := 'jdbc:hive2://{host}:{port}/{database}';
  e.DefaultPort := 10000; e.TestQuery := 'SELECT 1';
  e.License := 'Apache-2.0'; e.Maven := 'org.apache.hive:hive-jdbc:3.1.3'; e.Sha := '';
  TDriverRegistry.Register(e);
  e.Id := 'snowflake'; e.DriverClass := 'net.snowflake.client.jdbc.SnowflakeDriver';
  e.UrlTemplate := 'jdbc:snowflake://{host}.snowflakecomputing.com/{database}';
  e.DefaultPort := 443; e.TestQuery := 'SELECT 1';
  e.License := 'Apache-2.0'; e.Maven := 'net.snowflake:snowflake-jdbc:3.16.1'; e.Sha := '';
  TDriverRegistry.Register(e);
  e.Id := 'redshift'; e.DriverClass := 'com.amazon.redshift.jdbc42.Driver';
  e.UrlTemplate := 'jdbc:redshift://{host}:{port}/{database}';
  e.DefaultPort := 5439; e.TestQuery := 'SELECT 1';
  e.License := 'Apache-2.0'; e.Maven := 'software.amazon.redshift:redshift-jdbc42:2.1.0.9'; e.Sha := '';
  TDriverRegistry.Register(e);
  e.Id := 'exasol'; e.DriverClass := 'com.exasol.jdbc.EXADriver';
  e.UrlTemplate := 'jdbc:exa:{host}:{port};schema={database}';
  e.DefaultPort := 8563; e.TestQuery := 'SELECT 1';
  e.License := 'MIT'; e.Maven := 'com.exasol:exasol-jdbc:24.1.0'; e.Sha := '';
  TDriverRegistry.Register(e);
  e.Id := 'monetdb'; e.DriverClass := 'nl.cwi.monetdb.jdbc.MonetDriver';
  e.UrlTemplate := 'jdbc:monetdb://{host}:{port}/{database}';
  e.DefaultPort := 50000; e.TestQuery := 'SELECT 1';
  e.License := 'MPL-2.0'; e.Maven := 'org.monetdb:monetdb-jdbc:3.2'; e.Sha := '';
  TDriverRegistry.Register(e);
  e.Id := 'hana'; e.DriverClass := 'com.sap.db.jdbc.Driver';
  e.UrlTemplate := 'jdbc:sap://{host}:{port}/?databaseName={database}';
  e.DefaultPort := 30015; e.TestQuery := 'SELECT 1 FROM DUMMY';
  e.License := 'Proprietary'; e.Maven := 'com.sap.cloud.db.jdbc:ngdbc:2.18.16'; e.Sha := '';
  TDriverRegistry.Register(e);
```

3. `BuildUrl` 里 `if (LowerCase(e.Id) = 'sqlite') or (LowerCase(e.Id) = 'h2') then` 改为 `if IsEmbedded(e.Id) then`，并新增：

```pascal
class function TDriverRegistry.IsEmbedded(const DriverId: string): Boolean;
var
  id: string;
begin
  id := LowerCase(Trim(DriverId));
  Result := (id = 'sqlite') or (id = 'h2') or (id = 'duckdb') or
    (id = 'derby') or (id = 'hsqldb');
end;

class function TDriverRegistry.BuiltinIds: TDriverIdArray;
var
  i: Integer;
begin
  RegisterBuiltinDrivers;
  SetLength(Result, Length(GDrivers));
  for i := 0 to High(GDrivers) do
    Result[i] := GDrivers[i].Id;
end;
```

- [ ] **Step 3: drivers.json 补 22 条目**

在 `postgresql` 条目后追加 22 条：`mysql`、`mariadb`、`mssql`、`oracle`（字段照 registry：maven/端口/testQuery/license，oracle 的 testQuery 为 `SELECT 1 FROM DUAL`）+ Step 2 的 18 个新 id（字段与 Step 2 一一对应，`extraParams: {}`，`upstreamSyncVersion` 填执行当天日期，不写 `sha1`——下载时走上游 `.sha1` 实时取）。对象格式与现有三条严格一致（`id/displayName/maven/driverClass/urlTemplate/defaultPort/testQuery/extraParams/license/upstreamSyncVersion`）。

- [ ] **Step 4: 跑测试确认通过**

Run: 编译运行 `tests/TestDialect.lpr`，Expected: `TOTAL fails=0`（新增 23 项全过）。
Run: `mautool --list`（刚编好的），Expected: 输出行数 ≥ 25（JSON 与注册表同增）。
Run: `TestDistrib` 全过（manifest 校验要过 25 条）。

- [ ] **Step 5: DRIVER.md 驱动表更新**

把 `## 内置驱动` 一节的 7 行表格换成 25 行全表（字段与 registry 一致），并追加说明段：maven 版本为尽力值（以中央仓库为准，`drivers.json` 可直接改，无需改代码）；wire 别名（CockroachDB/Yugabyte/Timescale/QuestDB/CrateDB → 用 `postgresql` 条目；StarRocks/OceanBase/TiDB → 用 `mysql`；Spark SQL → 用 `hive`）；不收录项（BigQuery/Athena/Cassandra/Couchbase/Netezza/Greenplum/Phoenix：URL 形状不合 `host/port/database` 或无公开构件）。

- [ ] **Step 6: 提交**

```bash
git add src/core/TyFPJDBC.Driver.Registry.pas configs/drivers.json tests/TestDialect.lpr docs/DRIVER.md
git commit -m "feat: dbeaver-grade driver table with shape asserts"
```

---

### Task 4: 驱动向导（逻辑 + 窗体 + 测试）

**Files:**
- Create: `src/lcl/TyFPJDBC.LCL.Wizard.pas`
- Modify: `src/lcl/TyFPJDBC.LCL.ConnDialog.pas`
- Modify: `src/lcl/tyfpjdbc.lpk`（加 Wizard 单元；Task 5 会整体搬走，先加保持可编译）
- Modify: `tests/TestLcl.lpr`

**Interfaces:**
- Consumes: Task 2 的 `TDriverFetch` 全套、Task 3 的 `BuiltinIds`、`TDriverRegistry.Find/BuildUrlNil`、`TJdbcConnection` 属性名（`DriverId/Host/Port/Database/User/Password/MaxPool/MinIdle/LoginTimeoutSecs`）。
- Produces: `TJarState = (jsMissing, jsMismatch, jsReady)`；`TFetchFunc = function(const URL, ExpectSha, Target: string): Boolean of object`；`TTestFunc = function(const DriverId, Url: string): Boolean of object`；`TJdbcDriverWizard`（`DriverIds/JarTarget/JarState/Fetch/Test/CanConfirm/ApplyTo/TestedOk`，字段 `DriverId/Host/Port/Database/User/Password/MaxPool/LoginTimeoutSecs/Root/OnFetch/OnTest`）。

- [ ] **Step 1: TestLcl 加向导断言（先红）**

先 grep 确认对话框无其他调用者：`Select-String -Path src,tests,examples -Pattern "TJdbcConnDialog"`（已知只有本单元，预期零外部引用；若有，先停下问人）。

`tests/TestLcl.lpr`：`uses` 加 `TyFPJDBC.Driver.Fetch` 和 `TyFPJDBC.LCL.Wizard`；`var` 区前加 helper 类：

```pascal
type
  TWizProbe = class
    Eng: TJdbcEngine;
    Conn: Int64;
    SrcJar: string;
    function MockFetch(const URL, ExpectSha, Target: string): Boolean;
    function RealTest(const DriverId, Url: string): Boolean;
  end;

function TWizProbe.MockFetch(const URL, ExpectSha, Target: string): Boolean;
begin
  ForceDirectories(ExtractFilePath(Target));
  Result := CopyFile(SrcJar, Target);
end;

function TWizProbe.RealTest(const DriverId, Url: string): Boolean;
var
  e: TDriverEntry;
  stmt, cur: Int64;
  rows: TJdbcRows;
begin
  Result := False;
  e := TDriverRegistry.Find(DriverId);
  stmt := Eng.Bridge.Prepare(Conn, e.TestQuery);
  try
    cur := Eng.Bridge.QueryOpen(stmt, 10);
    try
      rows := Eng.Bridge.FetchWindow(cur, 10);
      Result := (Length(rows) = 1) and (rows[0][0] = '1');
    finally
      Eng.Bridge.CloseCursor(cur);
    end;
  finally
    Eng.Bridge.CloseStmt(stmt);
  end;
end;
```

`var` 区加 `wiz: TJdbcDriverWizard; probe: TWizProbe; wizDir, wizFile: string; c2: TJdbcConnection;`。grid 测试之后、`eng.Release(conn)` 之前插入向导块：

```pascal
      wizDir := IncludeTrailingPathDelimiter(GetTempDir) + 'tjwiz';
      DeleteFile(wizDir + PathDelim + 'drivers' + PathDelim + 'h2-2.2.224.jar');
      DeleteFile(wizDir + PathDelim + 'drivers' + PathDelim + 'mysql-connector-j-8.3.0.jar');
      DeleteFile(wizDir + PathDelim + 'license-mysql.accepted');
      ForceDirectories(wizDir + PathDelim + 'drivers');
      TDriverFetch.SetMarkerDir(wizDir);
      wiz := TJdbcDriverWizard.Create;
      probe := TWizProbe.Create;
      try
        probe.Eng := eng;
        probe.Conn := conn;
        probe.SrcJar := LibJar('h2-2.2.224.jar');
        wiz.Root := wizDir;
        wiz.OnFetch := @probe.MockFetch;
        wiz.OnTest := @probe.RealTest;
        Ok('wiz-drivers', Length(wiz.DriverIds) >= 25);
        Ok('wiz-missing', wiz.JarState('h2') = jsMissing);
        Ok('wiz-noconfirm', not wiz.CanConfirm);
        Ok('wiz-gpl-gated', not wiz.Fetch('mysql', False));
        Ok('wiz-fetch', wiz.Fetch('h2', False));
        Ok('wiz-ready', wiz.JarState('h2') = jsReady);
        wiz.DriverId := 'h2';
        wiz.Database := 'lcl';
        Ok('wiz-test', wiz.Test);
        Ok('wiz-confirm', wiz.CanConfirm);
        c2 := TJdbcConnection.Create(nil);
        try
          wiz.ApplyTo(c2);
          Ok('wiz-apply', (c2.DriverId = 'h2') and (c2.Database = 'lcl'));
        finally
          c2.Free;
        end;
      finally
        probe.Free;
        wiz.Free;
        TDriverFetch.SetMarkerDir('');
      end;
      DeleteFile(wizDir + PathDelim + 'drivers' + PathDelim + 'h2-2.2.224.jar');
      DeleteFile(wizDir + PathDelim + 'drivers' + PathDelim + 'mysql-connector-j-8.3.0.jar');
      DeleteFile(wizDir + PathDelim + 'license-mysql.accepted');
      RemoveDir(wizDir + PathDelim + 'drivers');
      RemoveDir(wizDir);
```

Run: 编译 `tests/TestLcl.lpr`（已有 `-Fu src/lcl`），Expected: FAIL，`Can't find unit TyFPJDBC.LCL.Wizard`。

- [ ] **Step 2: 新建 Wizard 单元（最小实现）**

`src/lcl/TyFPJDBC.LCL.Wizard.pas` 完整内容：

```pascal
unit TyFPJDBC.LCL.Wizard;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, TyFPJDBC.Driver.Registry, TyFPJDBC.Driver.Fetch,
  TyFPJDBC.Config, TyFPJDBC.LCL.Conn;
type
  TJarState = (jsMissing, jsMismatch, jsReady);
  TFetchFunc = function(const URL, ExpectSha, Target: string): Boolean of object;
  TTestFunc = function(const DriverId, Url: string): Boolean of object;
  { Headless-capable wizard logic: the form is a thin view over this.
    Fetch/Test are injectable so tests run without network or IDE. }
  TJdbcDriverWizard = class
  private
    FDriverId, FHost, FDatabase, FUser, FPassword: string;
    FPort, FMaxPool, FLoginTimeoutSecs: Integer;
    FRoot: string;
    FTestedOk: Boolean;
    FOnFetch: TFetchFunc;
    FOnTest: TTestFunc;
    function DefaultFetch(const URL, ExpectSha, Target: string): Boolean;
    procedure SetDriverId(const V: string);
  public
    constructor Create;
    property DriverId: string read FDriverId write SetDriverId;
    property Host: string read FHost write FHost;
    property Port: Integer read FPort write FPort;
    property Database: string read FDatabase write FDatabase;
    property User: string read FUser write FUser;
    property Password: string read FPassword write FPassword;
    property MaxPool: Integer read FMaxPool write FMaxPool;
    property LoginTimeoutSecs: Integer read FLoginTimeoutSecs write FLoginTimeoutSecs;
    property Root: string read FRoot write FRoot;
    property OnFetch: TFetchFunc read FOnFetch write FOnFetch;
    property OnTest: TTestFunc read FOnTest write FOnTest;
    property TestedOk: Boolean read FTestedOk;
    function DriverIds: TDriverIdArray;
    function JarTarget(const Id: string): string;
    function JarState(const Id: string): TJarState;
    function Fetch(const Id: string; AcceptGpl: Boolean): Boolean;
    function Test: Boolean;
    function CanConfirm: Boolean;
    procedure ApplyTo(Conn: TJdbcConnection);
  end;

implementation

constructor TJdbcDriverWizard.Create;
var
  cfg: TJdbcConfig;
begin
  inherited Create;
  cfg := TJdbcConfig.Default;
  try
    FDriverId := 'sqlite';
    FHost := '';
    FPort := 0;
    FDatabase := '';
    FUser := '';
    FPassword := '';
    FMaxPool := cfg.Pool_MaxPool;
    FLoginTimeoutSecs := 15;
  finally
    cfg.Free;
  end;
  FRoot := '';
  FTestedOk := False;
end;

procedure TJdbcDriverWizard.SetDriverId(const V: string);
begin
  if FDriverId <> V then
  begin
    FDriverId := V;
    FTestedOk := False;
  end;
end;

function TJdbcDriverWizard.DriverIds: TDriverIdArray;
begin
  Result := TDriverRegistry.BuiltinIds;
end;

function TJdbcDriverWizard.JarTarget(const Id: string): string;
var
  e: TDriverEntry;
  grp, art, ver, dir: string;
begin
  e := TDriverRegistry.Find(Id);
  TDriverFetch.MavenPath(e.Maven, grp, art, ver);
  dir := FRoot;
  if dir = '' then
    dir := ExtractFilePath(ParamStr(0));
  Result := IncludeTrailingPathDelimiter(dir) + 'drivers' + PathDelim +
    art + '-' + ver + '.jar';
end;

function TJdbcDriverWizard.JarState(const Id: string): TJarState;
var
  target, expect, side: string;
  sl: TStringList;
begin
  target := JarTarget(Id);
  if not FileExists(target) then
    Exit(jsMissing);
  expect := TDriverRegistry.Find(Id).Sha;
  if expect = '' then
  begin
    side := target + '.sha1';
    if FileExists(side) then
    begin
      sl := TStringList.Create;
      try
        sl.LoadFromFile(side);
        expect := Trim(sl.Text);
      finally
        sl.Free;
      end;
    end;
  end;
  if expect = '' then
    Exit(jsReady);
  if LowerCase(TDriverFetch.Sha1OfFile(target)) = LowerCase(Trim(expect)) then
    Exit(jsReady);
  Result := jsMismatch;
end;

function TJdbcDriverWizard.DefaultFetch(const URL, ExpectSha, Target: string): Boolean;
begin
  try
    TDriverFetch.FetchJar(URL, ExpectSha, Target);
    Result := True;
  except
    Result := False;
  end;
end;

function TJdbcDriverWizard.Fetch(const Id: string; AcceptGpl: Boolean): Boolean;
var
  e: TDriverEntry;
  rel, grp, art, ver, url, sha, target: string;
  sl: TStringList;
begin
  Result := False;
  e := TDriverRegistry.Find(Id);
  if TDriverFetch.IsGplLicense(e.License) then
  begin
    if AcceptGpl then
      TDriverFetch.MarkLicenseAccepted(Id);
    if not TDriverFetch.LicenseAccepted(Id) then
      Exit(False);
  end;
  rel := TDriverFetch.MavenPath(e.Maven, grp, art, ver);
  if rel = '' then
    Exit(False);
  url := TDriverFetch.MavenURL(rel);
  sha := e.Sha;
  if sha = '' then
    try
      sha := Trim(TDriverFetch.FetchText(url + '.sha1'));
    except
      sha := '';
    end;
  target := JarTarget(Id);
  ForceDirectories(ExtractFilePath(target));
  if Assigned(FOnFetch) then
    Result := FOnFetch(url, sha, target)
  else
    Result := DefaultFetch(url, sha, target);
  if Result and (sha <> '') then
  begin
    FTestedOk := False;
    sl := TStringList.Create;
    try
      sl.Text := LowerCase(sha);
      sl.SaveToFile(target + '.sha1');
    finally
      sl.Free;
    end;
  end
  else if Result then
    FTestedOk := False;
end;

function TJdbcDriverWizard.Test: Boolean;
var
  url: string;
begin
  FTestedOk := False;
  if not Assigned(FOnTest) then
    Exit(False);
  try
    url := TDriverRegistry.BuildUrlNil(FDriverId, FHost, FPort, FDatabase);
  except
    Exit(False);
  end;
  FTestedOk := FOnTest(FDriverId, url);
  Result := FTestedOk;
end;

function TJdbcDriverWizard.CanConfirm: Boolean;
begin
  Result := FTestedOk and (JarState(FDriverId) = jsReady);
end;

procedure TJdbcDriverWizard.ApplyTo(Conn: TJdbcConnection);
begin
  Conn.DriverId := FDriverId;
  Conn.Host := FHost;
  Conn.Port := FPort;
  Conn.Database := FDatabase;
  Conn.User := FUser;
  Conn.Password := FPassword;
  Conn.MaxPool := FMaxPool;
  Conn.LoginTimeoutSecs := FLoginTimeoutSecs;
end;

end.
```

- [ ] **Step 3: 对话框窗体改完整向导**

`src/lcl/TyFPJDBC.LCL.ConnDialog.pas` 整文件替换为（无 `.lfm`，控件全代码创建；`OnTest` 透传给宿主，默认走 IDE 可达的真引擎）：

```pascal
unit TyFPJDBC.LCL.ConnDialog;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, Forms, Controls, StdCtrls, ComCtrls,
  TyFPJDBC.Handles, TyFPJDBC.JVM.Manager, TyFPJDBC.JNI.Bridge,
  TyFPJDBC.Engine, TyFPJDBC.Driver.Registry, TyFPJDBC.Driver.Fetch,
  TyFPJDBC.LCL.Conn, TyFPJDBC.LCL.Wizard;
type
  { Driver wizard dialog: pick driver, check jar, one-click fetch
    (GPL needs the checkbox), Test live connectivity, OK writes back.
    OK stays disabled until TestedOk and jar ready (CanConfirm). }
  TJdbcConnDialog = class(TForm)
  private
    FWizard: TJdbcDriverWizard;
    FTarget: TJdbcConnection;
    DriverBox: TComboBox;
    StateLbl: TLabel;
    DownloadBtn: TButton;
    Progress: TProgressBar;
    LicenseCheck: TCheckBox;
    HostEdit, PortEdit, DbEdit, UserEdit, PassEdit, TimeoutEdit: TEdit;
    TestBtn, OkBtn, CancelBtn: TButton;
    function SelectedId: string;
    function GetTestedOk: Boolean;
    function GetOnTest: TTestFunc;
    procedure SetOnTest(V: TTestFunc);
    procedure PullFromEdits;
    procedure RefreshState;
    procedure DriverBoxChange(Sender: TObject);
    procedure DownloadBtnClick(Sender: TObject);
    procedure TestBtnClick(Sender: TObject);
    function DefaultTest(const DriverId, Url: string): Boolean;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function Execute(AConn: TJdbcConnection): Boolean;
    property TestedOk: Boolean read GetTestedOk;
    property OnTest: TTestFunc read GetOnTest write SetOnTest;
  end;

implementation

constructor TJdbcConnDialog.Create(AOwner: TComponent);
var
  t, i: Integer;
  ids: TDriverIdArray;

  function MkEdit(const Cap: string; Y: Integer): TEdit;
  begin
    with TLabel.Create(Self) do
    begin
      Parent := Self;
      Left := 12;
      Top := Y;
      Caption := Cap;
    end;
    Result := TEdit.Create(Self);
    Result.Parent := Self;
    Result.Left := 120;
    Result.Top := Y - 3;
    Result.Width := 160;
  end;

begin
  inherited CreateNew(AOwner);
  Caption := 'TyFPJDBC Connection';
  ClientWidth := 300;
  ClientHeight := 424;
  Position := poScreenCenter;
  FWizard := TJdbcDriverWizard.Create;
  FWizard.OnTest := @DefaultTest;
  t := 12;
  DriverBox := TComboBox.Create(Self);
  DriverBox.Parent := Self;
  DriverBox.Left := 12;
  DriverBox.Top := t;
  DriverBox.Width := 160;
  DriverBox.Style := csDropDownList;
  DriverBox.OnChange := @DriverBoxChange;
  Inc(t, 28);
  StateLbl := TLabel.Create(Self);
  StateLbl.Parent := Self;
  StateLbl.Left := 12;
  StateLbl.Top := t;
  StateLbl.Width := 276;
  Inc(t, 24);
  DownloadBtn := TButton.Create(Self);
  DownloadBtn.Parent := Self;
  DownloadBtn.Caption := 'Download driver';
  DownloadBtn.Left := 12;
  DownloadBtn.Top := t;
  DownloadBtn.Width := 130;
  DownloadBtn.OnClick := @DownloadBtnClick;
  Progress := TProgressBar.Create(Self);
  Progress.Parent := Self;
  Progress.Left := 150;
  Progress.Top := t + 4;
  Progress.Width := 130;
  Progress.Style := pbstMarquee;
  Progress.Visible := False;
  Inc(t, 32);
  LicenseCheck := TCheckBox.Create(Self);
  LicenseCheck.Parent := Self;
  LicenseCheck.Left := 12;
  LicenseCheck.Top := t;
  LicenseCheck.Width := 276;
  LicenseCheck.Caption := 'Accept GPL license';
  Inc(t, 28);
  HostEdit := MkEdit('Host', t);
  Inc(t, 28);
  PortEdit := MkEdit('Port', t);
  Inc(t, 28);
  DbEdit := MkEdit('Database', t);
  Inc(t, 28);
  UserEdit := MkEdit('User', t);
  Inc(t, 28);
  PassEdit := MkEdit('Password', t);
  PassEdit.PasswordChar := '*';
  Inc(t, 28);
  TimeoutEdit := MkEdit('Timeout(s)', t);
  Inc(t, 32);
  TestBtn := TButton.Create(Self);
  TestBtn.Parent := Self;
  TestBtn.Caption := 'Test';
  TestBtn.Left := 12;
  TestBtn.Top := t;
  TestBtn.Width := 130;
  TestBtn.OnClick := @TestBtnClick;
  OkBtn := TButton.Create(Self);
  OkBtn.Parent := Self;
  OkBtn.Caption := 'OK';
  OkBtn.Left := 104;
  OkBtn.Top := 384;
  OkBtn.Width := 84;
  OkBtn.ModalResult := mrOk;
  CancelBtn := TButton.Create(Self);
  CancelBtn.Parent := Self;
  CancelBtn.Caption := 'Cancel';
  CancelBtn.Left := 196;
  CancelBtn.Top := 384;
  CancelBtn.Width := 84;
  CancelBtn.ModalResult := mrCancel;
  ids := FWizard.DriverIds;
  for i := 0 to High(ids) do
    DriverBox.Items.Add(ids[i]);
  if DriverBox.Items.Count > 0 then
    DriverBox.ItemIndex := 0;
  RefreshState;
end;

destructor TJdbcConnDialog.Destroy;
begin
  FWizard.Free;
  inherited;
end;

function TJdbcConnDialog.SelectedId: string;
begin
  if DriverBox.ItemIndex >= 0 then
    Result := DriverBox.Items[DriverBox.ItemIndex]
  else
    Result := '';
end;

function TJdbcConnDialog.GetTestedOk: Boolean;
begin
  Result := FWizard.TestedOk;
end;

function TJdbcConnDialog.GetOnTest: TTestFunc;
begin
  Result := FWizard.OnTest;
end;

procedure TJdbcConnDialog.SetOnTest(V: TTestFunc);
begin
  FWizard.OnTest := V;
end;

procedure TJdbcConnDialog.PullFromEdits;
begin
  FWizard.DriverId := SelectedId;
  FWizard.Host := Trim(HostEdit.Text);
  FWizard.Port := StrToIntDef(Trim(PortEdit.Text), 0);
  FWizard.Database := Trim(DbEdit.Text);
  FWizard.User := Trim(UserEdit.Text);
  FWizard.Password := PassEdit.Text;
  FWizard.LoginTimeoutSecs := StrToIntDef(Trim(TimeoutEdit.Text), 15);
end;

procedure TJdbcConnDialog.RefreshState;
var
  id: string;
  e: TDriverEntry;
begin
  id := SelectedId;
  if id = '' then
  begin
    StateLbl.Caption := 'no driver selected';
    DownloadBtn.Enabled := False;
    OkBtn.Enabled := False;
    Exit;
  end;
  e := TDriverRegistry.Find(id);
  LicenseCheck.Visible := TDriverFetch.IsGplLicense(e.License) and
    not TDriverFetch.LicenseAccepted(id);
  case FWizard.JarState(id) of
    jsReady: StateLbl.Caption := 'driver jar ready';
    jsMismatch: StateLbl.Caption := 'driver jar MISMATCH, re-download';
    jsMissing: StateLbl.Caption := 'driver jar missing';
  end;
  DownloadBtn.Enabled := True;
  OkBtn.Enabled := FWizard.CanConfirm;
end;

procedure TJdbcConnDialog.DriverBoxChange(Sender: TObject);
begin
  PullFromEdits;
  RefreshState;
end;

procedure TJdbcConnDialog.DownloadBtnClick(Sender: TObject);
begin
  PullFromEdits;
  Progress.Visible := True;
  try
    Application.ProcessMessages;
    if FWizard.Fetch(SelectedId, LicenseCheck.Checked) then
      StateLbl.Caption := 'driver downloaded and verified'
    else
      StateLbl.Caption := 'download failed (see log)';
  finally
    Progress.Visible := False;
  end;
  RefreshState;
end;

procedure TJdbcConnDialog.TestBtnClick(Sender: TObject);
begin
  PullFromEdits;
  if FWizard.Test then
    StateLbl.Caption := 'connection ok'
  else if StateLbl.Caption = '' then
    StateLbl.Caption := 'connection failed';
  RefreshState;
end;

function TJdbcConnDialog.DefaultTest(const DriverId, Url: string): Boolean;
var
  jvm: string;
  eng: TJdbcEngine;
  bridge: TBridge;
  cfg: TPoolCfgRec;
  pool, conn, stmt, cur: Int64;
  rows: TJdbcRows;
  e: TDriverEntry;
begin
  Result := False;
  try
    jvm := TJVMManager.FindLibJvm('');
    TJVMManager.EnsureStarted(jvm, TJVMManager.BuildDesktopArgs);
    bridge := TBridge.Create;
    try
      eng := TJdbcEngine.Create(bridge);
      try
        e := TDriverRegistry.Find(DriverId);
        cfg := DefaultPoolCfg(Url, e.DriverClass);
        pool := eng.OpenPool(cfg);
        try
          conn := eng.Borrow(pool);
          try
            stmt := bridge.Prepare(conn, e.TestQuery);
            try
              cur := bridge.QueryOpen(stmt, 10);
              try
                rows := bridge.FetchWindow(cur, 10);
                Result := Length(rows) >= 1;
              finally
                bridge.CloseCursor(cur);
              end;
            finally
              bridge.CloseStmt(stmt);
            end;
          finally
            eng.Release(conn);
          end;
        finally
          eng.ClosePool(pool);
        end;
      finally
        eng.Free;
      end;
    finally
      bridge.Free;
    end;
  except
    on Ex: Exception do
      StateLbl.Caption := 'test: ' + Ex.Message;
  end;
end;

function TJdbcConnDialog.Execute(AConn: TJdbcConnection): Boolean;
begin
  FTarget := AConn;
  FWizard.DriverId := AConn.DriverId;
  FWizard.Host := AConn.Host;
  FWizard.Port := AConn.Port;
  FWizard.Database := AConn.Database;
  FWizard.User := AConn.User;
  FWizard.Password := AConn.Password;
  FWizard.MaxPool := AConn.MaxPool;
  FWizard.LoginTimeoutSecs := AConn.LoginTimeoutSecs;
  DriverBox.ItemIndex := DriverBox.Items.IndexOf(AConn.DriverId);
  HostEdit.Text := AConn.Host;
  if AConn.Port > 0 then
    PortEdit.Text := IntToStr(AConn.Port);
  DbEdit.Text := AConn.Database;
  UserEdit.Text := AConn.User;
  PassEdit.Text := AConn.Password;
  TimeoutEdit.Text := IntToStr(AConn.LoginTimeoutSecs);
  RefreshState;
  Result := ShowModal = mrOk;
  if Result then
    FWizard.ApplyTo(FTarget);
end;

end.
```

注意：`DefaultTest` 里 classpath 走 `TJVMManager` 当前值（宿主可在工程启动时 `SetClassPath` 或依赖默认布局；IDE 内测不到 jre 会如实报原因，不静默成功）。`TestBtnClick` 里 `StateLbl.Caption = ''` 的判断是多余的（RefreshState 会覆盖）——保留无害，`DefaultTest` 失败时 Caption 已被设为原因，`Test` 返回 False 后 RefreshState 会按 `CanConfirm=False` 禁 OK，Caption 保留原因文本（RefreshState 只在 jar 状态分支设 Caption——注意：RefreshState 会覆盖掉 'connection ok'/'test: ...'！修正：RefreshState 开头若 `FWizard.TestedOk` 则 Caption 保持？不行，jar 状态也要显示。最终行为：RefreshState 按 jar 状态设 Caption，Test 成功信息一闪而过但 OK 按钮启用状态正确——信息丢失不可接受。修正 RefreshState：先按 jar 状态设，只有当 `FWizard.TestedOk` 且 jar ready 时 Caption 追加 ' + connection ok'。把这段写对：

```pascal
  case FWizard.JarState(id) of
    jsReady: StateLbl.Caption := 'driver jar ready';
    jsMismatch: StateLbl.Caption := 'driver jar MISMATCH, re-download';
    jsMissing: StateLbl.Caption := 'driver jar missing';
  end;
  if FWizard.TestedOk and (FWizard.JarState(id) = jsReady) then
    StateLbl.Caption := StateLbl.Caption + ' + connection ok';
```

但 `DefaultTest` 失败设的 `'test: ' + Ex.Message` 会被 RefreshState 覆盖——失败原因丢失。修正 TestBtnClick：失败时 RefreshState 之后再设原因？DefaultTest 已把原因写进 Caption，RefreshState 紧接着覆盖。改 TestBtnClick：

```pascal
procedure TJdbcConnDialog.TestBtnClick(Sender: TObject);
var
  keep: string;
begin
  PullFromEdits;
  keep := '';
  if FWizard.Test then
    keep := 'connection ok'
  else
    keep := StateLbl.Caption;
  RefreshState;
  if keep <> '' then
    StateLbl.Caption := keep;
end;
```

成功时覆盖为 'connection ok'；失败时保留 DefaultTest 写的原因（或上一次的 Caption）。采用此版本（替换上面 Step 里的 TestBtnClick）。

- [ ] **Step 4: 跑测试 + 包编译**

Run: `tests/TestLcl.lpr`（H2 真库），Expected: `TOTAL fails=0`（含新增 9 项 `wiz-*`）。
Run: `lazbuild --build-all src/lcl/tyfpjdbc.lpk`，Expected: 通过（含 Wizard + 新窗体）。
Run: `pwsh -NoProfile -File scripts/guard.ps1`，Expected: `guard ok`。

- [ ] **Step 5: 提交**

```bash
git add src/lcl/TyFPJDBC.LCL.Wizard.pas src/lcl/TyFPJDBC.LCL.ConnDialog.pas src/lcl/tyfpjdbc.lpk tests/TestLcl.lpr
git commit -m "feat: driver wizard dialog with in-library fetch"
```

---

### Task 5: 包上浮与全绿门禁

**Files:**
- Move: `src/lcl/tyfpjdbc.lpk` → `tyfpjdbc_design.lpk`（包名同步改为
  `tyfpjdbc_design`：原包名与单元命名空间 `TyFPJDBC.*` 撞名，根构建必败）
- Modify: `scripts/run-matrix.ps1`
- Modify: `scripts/guard.ps1`

**Interfaces:**
- Consumes: Task 1–4 全部。
- Produces: 根 `tyfpjdbc_design.lpk`；四份证据（tests/launch/guard/matrix）。

- [ ] **Step 1: 上浮 lpk 并改路径**

```bash
git mv src/lcl/tyfpjdbc.lpk tyfpjdbc_design.lpk
```

`tyfpjdbc_design.lpk`：五个 `Filename` 分别加 `src/lcl/` 前缀（`UnitName` 不变）；
`<OtherUnitFiles Value="../core;../db"/>` 改为
`<OtherUnitFiles Value="src/core;src/db;src/lcl"/>`（根构建时包目录自身不在
搜索路径，必须显式加 `src/lcl`，否则包装单元找不到 LCL 单元）。
包版本 0.9.0 不动，包名改为 `tyfpjdbc_design`。

- [ ] **Step 2: 矩阵 lpk 段改根路径**

`scripts/run-matrix.ps1` 的 `lpk-design-package` 段改为：

```powershell
Remove-Item "$ws\lib" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$ws\tyfpjdbc_design.pas" -Force -ErrorAction SilentlyContinue
Remove-Item "$ws\packagefiles.xml" -Force -ErrorAction SilentlyContinue
& lazbuild --build-all "$ws\tyfpjdbc_design.lpk" 2>&1
Check "lpk-build" ($LASTEXITCODE -eq 0)
Remove-Item "$ws\tyfpjdbc_design.pas" -Force -ErrorAction SilentlyContinue
Remove-Item "$ws\packagefiles.xml" -Force -ErrorAction SilentlyContinue
Remove-Item "$ws\lib" -Recurse -Force -ErrorAction SilentlyContinue
```

- [ ] **Step 3: guard 加根 lib 门禁**

`scripts/guard.ps1` 追加（`.lpk` 在根构建，`lib/` 落根；`tyfpjdbc_design.pas/packagefiles.xml` 是构建瞬态由矩阵清，不进门禁）：

```powershell
$root = Get-ChildItem -Path lib -Recurse -Include *.o,*.ppu -ErrorAction SilentlyContinue
if ($root) { Write-Error "Build artifacts in root lib/"; exit 1 }
```

- [ ] **Step 4: 全门禁绿 + 四份证据**

Run（按既有电池顺序）: javac Bridge → smoke → 纯逻辑（Config/Errors/Rewrite/Types/RealWorld）→ 真库 12 套（含 TestTx/TestInjection/TestSemantic）→ examples → guard → 根 lpk。Expected: 零 FAIL 行，`0.9.0` 握手不断。
Run: `pwsh -NoProfile -File scripts/run-matrix.ps1`，Expected: `MATRIX-FAILURES=0` + `MATRIX-OK`（PG/MySQL 无容器时为 SKIP，通过）。
证据归档 `{SCRATCH}`：tests/launch/guard/matrix 四份日志；`src/tests/examples` 下 0 个 `.o`/`.ppu`。

- [ ] **Step 5: 提交**

```bash
git add tyfpjdbc_design.lpk scripts/run-matrix.ps1 scripts/guard.ps1
git commit -m "chore: float package to repo root, gate green"
```

---

## Self-Review（已自检并内联修复）

1. **Spec 覆盖**：§1 三档查找/默认布局/默认 classpath → Task 1（`FindLibJvmLegacy` 整删、`JAVA_HOME` 全清）；§2 注册表 30 级条目 → Task 3（25 条 + 8 别名文档 = 33 名）、Fetch 入库 → Task 2、向导 → Task 4；§3 上浮 → Task 5；§5 验收 → Task 5。`bridgeVersion 0.9.0` 无任务触碰。
2. **占位符扫描**：无 TBD/TODO；maven 版本为尽力值已在 Task 3-Step 5 写明修正路径（改 `drivers.json` 即生效，无需改代码）；窗体无 `.lfm` 依赖，控件创建代码已写死；`TestBtnClick` 的 Caption 覆盖问题已修正为保留失败原因。
3. **类型一致**：`TDriverIdArray`（注册表内定义，Task 3 → Task 4 原样用）；`TFetchFunc/TTestFunc` 签名 Task 4 内定义、测试同文件实现；`TFetchResult`（Task 2 内部用）；`Runtime_Root/Runtime_JvmPath`（Task 1 定义，无他处引用）；`TJarState`（Task 4 内定义、测试同名断言）。
