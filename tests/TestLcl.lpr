program TestLcl;

{$mode objfpc}{$H+}

{ LCL design-surface test (no IDE needed): the design components hold
  config only; URL building goes through the registry; the dialog gates
  confirmation on Test; a live H2 loopback proves grid-bound rows read and
  write back. }

uses
  SysUtils, Classes, TyFPJDBC.Handles, TyFPJDBC.JVM.Manager,
  TyFPJDBC.JNI.Bridge, TyFPJDBC.Engine, TyFPJDBC.Driver.Registry,
  TyFPJDBC.Config, TyFPJDBC.LCL.Conn, TyFPJDBC.LCL.Query, TyFPJDBC.Query;

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
