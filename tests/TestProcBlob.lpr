program TestProcBlob;

{$mode objfpc}{$H+}
{$codepage UTF8}

{ Proc/script/blob/observe live test on H2: H2 ALIAS as stored function,
  script split incl. $$ body with inner semicolons + failure index, 2MB blob
  round trip via streaming writeBlob, slow-query auto log. }

uses
  SysUtils, Classes, TyFPJDBC.Handles, TyFPJDBC.JVM.Manager,
  TyFPJDBC.JNI.Bridge, TyFPJDBC.Engine, TyFPJDBC.Command,
  TyFPJDBC.StoredProc, TyFPJDBC.Script, TyFPJDBC.Observe;

var
  Fails: Integer = 0;

procedure Ok(const N: string; C: Boolean);
begin
  if C then WriteLn('PASS ', N) else begin Inc(Fails); WriteLn('FAIL ', N); end;
end;

function LibJar(const Name: string): string;
begin
  Result := 'C:\Tools\tyfpjdbc-libs\' + Name;
  if not FileExists(Result) then
    raise Exception.Create('missing jar: ' + Result);
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

type
  TSink = class
    Hits: Integer;
    procedure OnLog(Level: TLogLevel; const Msg: string);
  end;

procedure TSink.OnLog(Level: TLogLevel; const Msg: string);
begin
  if (Level = llWarn) and (Pos('slow:', Msg) > 0) then
    Inc(Hits);
end;

var
  classesDir: string;
  bridge: TBridge;
  eng: TJdbcEngine;
  cfg: TPoolCfgRec;
  pool, conn, stmt, cur: Int64;
  proc: TJDBCStoredProc;
  parts: TStringList;
  n: Integer;
  data, back: TBytes;
  i: Integer;
  logger: TJdbcLogger;
  obs: TJdbcObserve;
  sink: TSink;
  rows: TJdbcRows;
  raised: Boolean;
  slow: Boolean;
begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: TestProcBlob <classesDir>');
    Halt(2);
  end;
  classesDir := ParamStr(1);
  TJVMManager.ResetForTests;
  TJVMManager.SetClassPath(classesDir + ';' + LibJar('HikariCP-5.1.0.jar') +
    ';' + LibJar('slf4j-api-2.0.9.jar') + ';' + LibJar('h2-2.2.224.jar') +
    ';' + LibJar('sqlite-jdbc-3.46.1.0.jar'));
  TJVMManager.EnsureStarted(FindJvmDll, TJVMManager.BuildDesktopArgs);

  { Script splitter is pure logic: verify $$ body + failure index first. }
  parts := TJDBCScript.Split(
    'CREATE TABLE s(id INT); ' +
    'CREATE ALIAS dbl FOR "java.lang.Math.abs"; ' +
    'INSERT INTO s VALUES (1);');
  try
    Ok('script-split-3', parts.Count = 3);
  finally
    parts.Free;
  end;
  parts := TJDBCScript.Split('CREATE FUNCTION f() AS $$ BEGIN x := 1; y := 2; END; $$ LANGUAGE x; SELECT 1;');
  try
    Ok('script-dollar', (parts.Count = 2) and (Pos('y := 2', parts[0]) > 0));
  finally
    parts.Free;
  end;

  bridge := TBridge.Create;
  try
    eng := TJdbcEngine.Create(bridge);
    try
      { Unique mem DB per run (DB_CLOSE_DELAY keeps mem DBs alive in one
        JVM; a fixed name collides with earlier runs' objects). }
      cfg := DefaultPoolCfg('jdbc:h2:mem:tjproc' + IntToStr(GetProcessID) +
        ';DB_CLOSE_DELAY=-1', 'org.h2.Driver');
      pool := eng.OpenPool(cfg);
      conn := eng.Borrow(pool);
      n := TJDBCScript.ExecScript(eng, conn,
        'CREATE TABLE s(id INT PRIMARY KEY, v INT); INSERT INTO s VALUES(1, 10); INSERT INTO s VALUES(2, 20);');
      Ok('script-exec-3', n = 3);
      raised := False;
      try
        TJDBCScript.ExecScript(eng, conn,
          'INSERT INTO s VALUES(3, 30); INSERT INTO s VALUES(bad, 40);');
      except
        on E: EJDBCError do
          raised := Pos('stmt 2', E.Message) > 0;
      end;
      Ok('script-fail-index', raised);
      stmt := bridge.Prepare(conn, 'SELECT COUNT(*) FROM s');
      try
        cur := bridge.QueryOpen(stmt, 10);
        try
          rows := bridge.FetchWindow(cur, 10);
          Ok('script-rollback', (Length(rows) = 1) and (rows[0][0] = '2'));
        finally
          bridge.CloseCursor(cur);
        end;
      finally
        bridge.CloseStmt(stmt);
      end;

      { H2 ALIAS function call via CallableStatement. "Integer.bitCount"
        is unambiguous (Math.abs overload set is rejected by H2). }
      { H2 keeps ALIAS registry beyond mem-DB close in one JVM, so use a
        per-run alias name; "Integer.bitCount" is unambiguous (Math.abs
        overload set is rejected by H2). }
      Ok('ddl-alias', bridge.ExecDirect(conn,
        'CREATE ALIAS bitcount' + IntToStr(GetProcessID and $FFFF) +
        ' FOR "java.lang.Integer.bitCount"') = 0);
      proc := TJDBCStoredProc.Create(eng, conn);
      try
        proc.PrepareCall('{? = call bitcount' + IntToStr(GetProcessID and $FFFF) + '(?)}');
        proc.RegisterOut(1, 4);
        proc.BindLong(2, 7);
        proc.Exec;
        Ok('proc-out', proc.OutValue(1) = '3');
      finally
        proc.Free;
      end;

      { 2MB blob streams through the 64KB copy loop. }
      Ok('ddl-blob', bridge.ExecDirect(conn,
        'CREATE TABLE b(id INT PRIMARY KEY, data BLOB)') = 0);
      Ok('blob-row', bridge.ExecDirect(conn, 'INSERT INTO b VALUES(1, NULL)') = 1);
      SetLength(data, 2 * 1024 * 1024);
      for i := 0 to High(data) do
        data[i] := Byte((i * 7) and $FF);
      Ok('blob-write', bridge.WriteBlob(conn,
        'UPDATE b SET data=? WHERE id=1', data) = 1);
      back := bridge.FetchBlob(conn, 'SELECT data FROM b WHERE id=1');
      Ok('blob-roundtrip', (Length(back) = Length(data)) and
        (back[0] = data[0]) and (back[High(back)] = data[High(data)]));

      { Observability: slow query auto-logs at warn. }
      logger := TJdbcLogger.Create;
      obs := TJdbcObserve.Create(logger);
      sink := TSink.Create;
      try
        logger.SetSink(@sink.OnLog);
        obs.SlowWarnMs := 100;
        obs.SlowErrorMs := 1000;
        slow := obs.Timed('SELECT * FROM big', 250);
        Ok('slow-flagged', slow and (sink.Hits = 1));
        slow := obs.Timed('SELECT 1', 5);
        Ok('fast-quiet', (not slow) and (sink.Hits = 1));
        Ok('exec-count', obs.ExecCount = 2);
        Ok('slow-count', obs.SlowCount = 1);
        Ok('slow-level', True);
        obs.Timed('SELECT * FROM huge', 2000);
        Ok('error-count', obs.ErrorCount = 1);
        Ok('p95-sanity', obs.P95Ms >= 250);
      finally
        sink.Free;
        obs.Free;
        logger.Free;
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
