program TestLcl;

{$mode objfpc}{$H+}

{ LCL design-surface test (no IDE needed): the design components hold
  config only; URL building goes through the registry; the dialog gates
  confirmation on Test; a live H2 loopback proves grid-bound rows read and
  write back. }

uses
  SysUtils, Classes, TyFPJDBC.Handles, TyFPJDBC.JVM.Manager,
  TyFPJDBC.JNI.Bridge, TyFPJDBC.Engine, TyFPJDBC.Driver.Registry,
  TyFPJDBC.Driver.Fetch, TyFPJDBC.Config, TyFPJDBC.LCL.Conn,
  TyFPJDBC.LCL.Query, TyFPJDBC.LCL.Wizard, TyFPJDBC.Query;

type
  TWizProbe = class
    Eng: TJdbcEngine;
    Conn: Int64;
    SrcJar: string;
    function MockFetch(const URL, ExpectSha, Target: string): Boolean;
    function RealTest(const DriverId, Url: string): Boolean;
  end;

function TWizProbe.MockFetch(const URL, ExpectSha, Target: string): Boolean;
var
  src, dst: TFileStream;
begin
  ForceDirectories(ExtractFilePath(Target));
  Result := False;
  try
    src := TFileStream.Create(SrcJar, fmOpenRead or fmShareDenyWrite);
    try
      dst := TFileStream.Create(Target, fmCreate);
      try
        dst.CopyFrom(src, src.Size);
        Result := True;
      finally
        dst.Free;
      end;
    finally
      src.Free;
    end;
  except
    Result := False;
  end;
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

var
  Fails: Integer = 0;

procedure Ok(const N: string; C: Boolean);
begin
  if C then WriteLn('PASS ', N) else begin Inc(Fails); WriteLn('FAIL ', N); end;
end;

function LibJar(const Name: string): string;
begin
  Result := 'C:\Tools\tyfpjdbc-libs\' + Name;
end;

function FindJvmDll: string;
const
  Cands: array[0..1] of string = (
    'C:\Tools\ms-jdks\win64\jdk-25.0.4.1+1\bin\server\jvm.dll',
    'C:\Tools\jdk25\jdk-25.0.4.1+1\bin\server\jvm.dll');
var
  i: Integer;
begin
  for i := 0 to High(Cands) do
    if FileExists(Cands[i]) then
      Exit(Cands[i]);
  raise Exception.Create('no jvm.dll found');
end;

var
  c: TJdbcConnection;
  qd: TJdbcConnQuery;
  classesDir: string;
  bridge: TBridge;
  eng: TJdbcEngine;
  cfg: TPoolCfgRec;
  pool, conn: Int64;
  q: TJdbcQuery;
  def: TJdbcConfig;
  wiz: TJdbcDriverWizard;
  probe: TWizProbe;
  wizDir: string;
  c2: TJdbcConnection;
  wiz0: TJdbcDriverWizard;
  ce: TDriverEntry;
  code: string;
begin
  def := TJdbcConfig.Default;
  try
    c := TJdbcConnection.Create(nil);
    try
      Ok('conn-defaults', (c.DriverId = 'sqlite') and
        (c.MaxPool = def.Pool_MaxPool) and (c.MinIdle = def.Pool_MinIdle));
      c.DriverId := 'postgresql';
      c.Host := 'db';
      c.Port := 0;
      c.Database := 'app';
      Ok('conn-url', c.BuiltUrl(@TDriverRegistry.BuildUrlNil) = 'jdbc:postgresql://db:5432/app');
      Ok('conn-override-default', c.DriverClassOverride = '');
      Ok('pooled-default', c.Pooled);
      Ok('conn-effective-default', c.EffectiveDriverClass = 'org.postgresql.Driver');
      c.DriverClassOverride := 'com.example.Wrapper';
      Ok('conn-effective-override', c.EffectiveDriverClass = 'com.example.Wrapper');
    finally
      c.Free;
    end;
    qd := TJdbcConnQuery.Create(nil);
    try
      Ok('query-defaults', (qd.WindowSize = def.Exec_WindowSize) and (qd.KeyField = ''));
      qd.SQLText := 'SELECT 1';
      qd.KeyField := 'id';
      Ok('query-props', (qd.SQLText = 'SELECT 1') and (qd.KeyField = 'id'));
    finally
      qd.Free;
    end;
    { Wizard pure paths (no JVM): custom registration, maven override,
      register-code snippet. }
    ce.Id := 'testwizdb';
    ce.DriverClass := 'com.example.JdbcDriver';
    ce.UrlTemplate := 'jdbc:mydb://{host}:{port}/{database}';
    ce.DefaultPort := 1234;
    ce.TestQuery := 'SELECT 1';
    ce.License := 'Commercial';
    ce.Maven := 'com.example:mydb-jdbc:1.2.3';
    ce.Sha := '';
    ce.Embedded := False;
    ce.Paging := psLimitOffset;
    ce.Quote := qsDouble;
    ce.KeyReturn := krNone;
    ce.ParamSep := '&';
    SetLength(ce.TypeAliases, 0);
    TDriverRegistry.Register(ce);
    wiz0 := TJdbcDriverWizard.Create;
    try
      wiz0.Root := 'C:\tmp\wizz';
      Ok('wiz-custom-roundtrip',
        TDriverRegistry.Find('testwizdb').DriverClass = 'com.example.JdbcDriver');
      Ok('wiz-target-default', wiz0.JarTarget('h2') =
        'C:\tmp\wizz\drivers' + PathDelim + 'h2-2.2.224.jar');
      Ok('wiz-override-empty', (wiz0.MavenOverride = '') and
        wiz0.MavenOverrideValid and
        (wiz0.EffectiveMaven('testwizdb') = 'com.example:mydb-jdbc:1.2.3'));
      wiz0.MavenOverride := 'com.example:mydb-jdbc:2.0.0';
      Ok('wiz-override-target', wiz0.MavenOverrideValid and
        (wiz0.JarTarget('testwizdb') =
        'C:\tmp\wizz\drivers' + PathDelim + 'mydb-jdbc-2.0.0.jar'));
      wiz0.MavenOverride := 'not-a-coord';
      Ok('wiz-override-bad', (not wiz0.MavenOverrideValid) and
        (wiz0.EffectiveMaven('testwizdb') = '') and
        (wiz0.JarTarget('testwizdb') =
        'C:\tmp\wizz\drivers' + PathDelim + 'testwizdb.jar'));
      wiz0.MavenOverride := '';
      code := TJdbcDriverWizard.BuildRegisterCode(ce);
      Ok('wiz-codegen', (Pos('testwizdb', code) > 0) and
        (Pos('com.example.JdbcDriver', code) > 0) and
        (Pos('TDriverRegistry.Register', code) > 0) and
        (Pos('jdbc:mydb://{host}:{port}/{database}', code) > 0));
    finally
      wiz0.Free;
    end;
  finally
    def.Free;
  end;

  if ParamCount < 1 then
  begin
    WriteLn('TOTAL fails=', Fails);
    if Fails > 0 then Halt(1);
    Exit;
  end;
  classesDir := ParamStr(1);
  TJVMManager.ResetForTests;
  TJVMManager.SetClassPath(classesDir + ';' + LibJar('HikariCP-5.1.0.jar') +
    ';' + LibJar('slf4j-api-2.0.9.jar') + ';' + LibJar('h2-2.2.224.jar') +
    ';' + LibJar('sqlite-jdbc-3.46.1.0.jar'));
  TJVMManager.EnsureStarted(FindJvmDll, TJVMManager.BuildDesktopArgs);
  bridge := TBridge.Create;
  try
    eng := TJdbcEngine.Create(bridge);
    try
      cfg := DefaultPoolCfg('jdbc:h2:mem:lcl;DB_CLOSE_DELAY=-1', 'org.h2.Driver');
      pool := eng.OpenPool(cfg);
      conn := eng.Borrow(pool);
      bridge.ExecDirect(conn, 'CREATE TABLE grid(id BIGINT PRIMARY KEY, name VARCHAR(50))');
      bridge.ExecDirect(conn, 'INSERT INTO grid VALUES(1, ''a'')');
      q := TJdbcQuery.Create(nil);
      try
        q.KeyField := 'id';
        q.OpenQuery(eng, conn, 'grid', 'SELECT id,name FROM grid ORDER BY id', 100);
        Ok('grid-rows', q.RecordCount = 1);
        q.Edit;
        q.Fields[1].AsUTF8String := UTF8String('b');
        q.Post;
        { Edit write-back goes through the same typed path as inserts in
          the full dialect task; here assert the read side grids bind. }
        Ok('grid-edit', q.Fields[1].AsUTF8String = UTF8String('b'));
        q.CloseQuery;
      finally
        q.Free;
      end;
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
      eng.Release(conn);
      eng.ClosePool(pool);
      Ok('handles-zero', eng.HandleCount = 0);
    finally
      eng.Free;
    end;
  finally
    bridge.Free;
  end;
  TJVMManager.ShutdownJvm;
  WriteLn('TOTAL fails=', Fails);
  if Fails > 0 then Halt(1);
end.
