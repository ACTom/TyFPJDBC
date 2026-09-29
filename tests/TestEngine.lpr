program TestEngine;

{$mode objfpc}{$H+}
{$codepage UTF8}

{ Engine live loopback: JVM (real JNI_CreateJavaVM) -> Bridge (real JNI)
  -> HikariCP -> H2 mem DB. Covers: version, bad-handle local reject,
  pool/borrow, typed batch via direct prepare, windowed fetch, savepoint
  rollback with re-read, structured pool stats, handle count归零.
  Usage: TestEngine <classesDir>. }

uses
  SysUtils, Classes, TyFPJDBC.Handles, TyFPJDBC.JVM.Manager,
  TyFPJDBC.JNI.Bridge, TyFPJDBC.Engine;

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

var
  classesDir: string;
  bridge: TBridge;
  eng: TJdbcEngine;
  cfg: TPoolCfgRec;
  pool, conn, stmt, cur: Int64;
  dconn: Int64;
  cfgBad: TPoolCfgRec;
  rows: TJdbcRows;
  raised: Boolean;
  st: string;
begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: TestEngine <classesDir>');
    Halt(2);
  end;
  classesDir := ParamStr(1);
  TJVMManager.ResetForTests;
  TJVMManager.SetClassPath(classesDir + ';' + LibJar('HikariCP-5.1.0.jar') +
    ';' + LibJar('slf4j-api-2.0.9.jar') + ';' + LibJar('h2-2.2.224.jar') +
    ';' + LibJar('sqlite-jdbc-3.46.1.0.jar'));
  TJVMManager.EnsureStarted(FindJvmDll, TJVMManager.BuildDesktopArgs);
  Ok('jvm-started', TJVMManager.IsStarted);

  bridge := TBridge.Create;
  try
    Ok('bridge-version', bridge.GetVersion = '0.9.0');
    try
      bridge.BorrowConn(0);
      Ok('bad-handle-local', False);
    except
      on E: EJDBCError do
        Ok('bad-handle-local', (E.SQLState = 'HY000') and (E.VendorCode = 99));
    end;
    st := bridge.ErrorChain;
    Ok('errorchain-thread', True);

    eng := TJdbcEngine.Create(bridge);
    try
      cfg := DefaultPoolCfg('jdbc:h2:mem:tjeng;DB_CLOSE_DELAY=-1', 'org.h2.Driver');
      pool := eng.OpenPool(cfg);
      Ok('pool-open', pool > 0);
      conn := eng.Borrow(pool);
      Ok('borrow', conn > 0);
      Ok('isvalid', bridge.IsValid(conn, 2));
      st := bridge.DatabaseMeta(conn);
      Ok('dbmeta-h2', Pos('H2', st) > 0);

      Ok('ddl', bridge.ExecDirect(conn,
        'CREATE TABLE t(id BIGINT PRIMARY KEY, amt DECIMAL(10,2), name VARCHAR(50))') = 0);
      stmt := bridge.Prepare(conn, 'INSERT INTO t VALUES(?,?,?)');
      try
        bridge.BindLong(stmt, 1, 1);
        bridge.BindBigDecimal(stmt, 2, '19.99');
        bridge.BindString(stmt, 3, 'hi');
        bridge.AddBatch(stmt);
        bridge.BindLong(stmt, 1, 2);
        bridge.BindBigDecimal(stmt, 2, '3.50');
        bridge.BindString(stmt, 3, 'ho');
        bridge.AddBatch(stmt);
        Ok('typed-batch-2', bridge.ExecBatch(stmt) = 2);
      finally
        bridge.CloseStmt(stmt);
      end;

      stmt := bridge.Prepare(conn, 'SELECT id,amt,name FROM t ORDER BY id');
      try
        cur := bridge.QueryOpen(stmt, 1);
        try
          Ok('cursor-cols', bridge.CursorCols(cur) = 3);
          rows := bridge.FetchWindow(cur, 1);
          Ok('window-1', (Length(rows) = 1) and (rows[0][0] = '1') and (rows[0][1] = '19.99'));
          rows := bridge.FetchWindow(cur, 10);
          Ok('window-2', (Length(rows) = 1) and (rows[0][0] = '2'));
        finally
          bridge.CloseCursor(cur);
        end;
      finally
        bridge.CloseStmt(stmt);
      end;

      eng.SetAutoCommit(conn, False);
      stmt := bridge.Prepare(conn, 'INSERT INTO t VALUES(?,?,?)');
      try
        bridge.BindLong(stmt, 1, 3);
        bridge.BindBigDecimal(stmt, 2, '1.00');
        bridge.BindString(stmt, 3, 'tmp');
        bridge.ExecUpdate(stmt);
        eng.Savepoint(conn, 'sp1');
        bridge.BindLong(stmt, 1, 4);
        bridge.BindBigDecimal(stmt, 2, '2.00');
        bridge.BindString(stmt, 3, 'tmp2');
        bridge.ExecUpdate(stmt);
        eng.RollbackTo(conn, 'sp1');
        eng.ReleaseSavepoint(conn, 'sp1');
        eng.Commit(conn);
      finally
        bridge.CloseStmt(stmt);
      end;
      stmt := bridge.Prepare(conn, 'SELECT COUNT(*) FROM t');
      try
        cur := bridge.QueryOpen(stmt, 10);
        try
          rows := bridge.FetchWindow(cur, 10);
          Ok('savepoint-count', (Length(rows) = 1) and (rows[0][0] = '3'));
        finally
          bridge.CloseCursor(cur);
        end;
      finally
        bridge.CloseStmt(stmt);
      end;
      eng.SetAutoCommit(conn, True);

      raised := False;
      try
        eng.Savepoint(conn, 'evil name!');
      except
        on E: EJDBCError do
          raised := E.SQLState = 'HY092';
      end;
      Ok('savepoint-whitelist', raised);

      Ok('pool-active', eng.PoolActive(pool) >= 0);
      Ok('pool-idle', eng.PoolIdle(pool) >= 0);
      Ok('pool-waiting', eng.PoolWaiting(pool) >= 0);

      eng.Release(conn);
      eng.ClosePool(pool);
      Ok('handles-zero', eng.HandleCount = 0);
      Ok('audit-zero', eng.AuditReport = 'pools=0 conns=0 stmts=0 cursors=0');

      dconn := eng.OpenDirect(cfg);
      Ok('direct-open', (dconn > 0) and (eng.PoolCount = 0) and (eng.ConnCount = 1));
      Ok('direct-ddl', bridge.ExecDirect(dconn,
        'CREATE TABLE dt(id BIGINT PRIMARY KEY, v VARCHAR(20))') = 0);
      stmt := bridge.Prepare(dconn, 'INSERT INTO dt VALUES(?,?)');
      try
        bridge.BindLong(stmt, 1, 7);
        bridge.BindString(stmt, 2, 'seven');
        Ok('direct-exec', bridge.ExecUpdate(stmt) = 1);
      finally
        bridge.CloseStmt(stmt);
      end;
      stmt := bridge.Prepare(dconn, 'SELECT v FROM dt WHERE id=7');
      try
        cur := bridge.QueryOpen(stmt, 10);
        try
          rows := bridge.FetchWindow(cur, 10);
          Ok('direct-read', (Length(rows) = 1) and (rows[0][0] = 'seven'));
        finally
          bridge.CloseCursor(cur);
        end;
      finally
        bridge.CloseStmt(stmt);
      end;
      eng.Release(dconn);
      Ok('direct-release-zero', (eng.HandleCount = 0) and
        (eng.AuditReport = 'pools=0 conns=0 stmts=0 cursors=0'));
      cfgBad := DefaultPoolCfg('jdbc:h2:mem:bad;DB_CLOSE_DELAY=-1', 'no.such.Driver');
      raised := False;
      try
        eng.OpenDirect(cfgBad);
      except
        on E: EJDBCError do
          raised := E.SQLState = '08000';
      end;
      Ok('direct-badclass', raised);
    finally
      eng.Free;
    end;
  finally
    bridge.Free;
  end;
  TJVMManager.ShutdownJvm;
  Ok('shutdown', True);
  WriteLn('TOTAL fails=', Fails);
  if Fails > 0 then Halt(1);
end.
