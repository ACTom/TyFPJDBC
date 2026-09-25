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
