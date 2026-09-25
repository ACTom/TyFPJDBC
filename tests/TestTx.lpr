program TestTx;

{$mode objfpc}{$H+}
{$codepage UTF8}

{ Transaction + multi-connection matrix on H2: atomic commit, rollback,
  savepoint partial rollback, dual-connection no-dirty-read, pool
  exhaustion timeout. Usage: TestTx <classesDir>. }

uses
  SysUtils, Classes, TyFPJDBC.Handles, TyFPJDBC.JVM.Manager,
  TyFPJDBC.JNI.Bridge, TyFPJDBC.Engine, TyFPJDBC.Command;

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

function CountWhere(bridge: TBridge; conn: Int64; const SQL: string): string;
var
  stmt, cur: Int64;
  rows: TJdbcRows;
begin
  Result := '';
  stmt := bridge.Prepare(conn, SQL);
  try
    cur := bridge.QueryOpen(stmt, 10);
    try
      rows := bridge.FetchWindow(cur, 10);
      if Length(rows) = 1 then
        Result := string(rows[0][0]);
    finally
      bridge.CloseCursor(cur);
    end;
  finally
    bridge.CloseStmt(stmt);
  end;
end;

var
  classesDir: string;
  bridge: TBridge;
  eng: TJdbcEngine;
  cfg, small: TPoolCfgRec;
  pool, conn, connA, connB, spool, sconn, sconn2: Int64;
  raised: Boolean;
  exState, exMsg: string;
begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: TestTx <classesDir>');
    Halt(2);
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
      cfg := DefaultPoolCfg('jdbc:h2:mem:tjtx;DB_CLOSE_DELAY=-1', 'org.h2.Driver');
      pool := eng.OpenPool(cfg);
      conn := eng.Borrow(pool);

      { Atomic commit: two rows land together. }
      Ok('ddl', bridge.ExecDirect(conn,
        'CREATE TABLE tx1(id BIGINT PRIMARY KEY, v VARCHAR(20))') = 0);
      eng.SetAutoCommit(conn, False);
      bridge.ExecDirect(conn, 'INSERT INTO tx1 VALUES(1,''a'')');
      bridge.ExecDirect(conn, 'INSERT INTO tx1 VALUES(2,''b'')');
      eng.Commit(conn);
      Ok('tx-atomic-commit', CountWhere(bridge, conn,
        'SELECT COUNT(*) FROM tx1') = '2');

      { Rollback: nothing lands. }
      Ok('ddl2', bridge.ExecDirect(conn,
        'CREATE TABLE tx2(id BIGINT PRIMARY KEY, v VARCHAR(20))') = 0);
      bridge.ExecDirect(conn, 'INSERT INTO tx2 VALUES(1,''a'')');
      bridge.ExecDirect(conn, 'INSERT INTO tx2 VALUES(2,''b'')');
      eng.Rollback(conn);
      Ok('tx-rollback', CountWhere(bridge, conn,
        'SELECT COUNT(*) FROM tx2') = '0');

      { Savepoint partial rollback: sp1 survives, sp2 rolls back. }
      Ok('ddl3', bridge.ExecDirect(conn,
        'CREATE TABLE tx3(id BIGINT PRIMARY KEY, v VARCHAR(20))') = 0);
      bridge.ExecDirect(conn, 'INSERT INTO tx3 VALUES(1,''keep'')');
      eng.Savepoint(conn, 'sp1');
      bridge.ExecDirect(conn, 'INSERT INTO tx3 VALUES(2,''drop'')');
      eng.RollbackTo(conn, 'sp1');
      eng.ReleaseSavepoint(conn, 'sp1');
      eng.Commit(conn);
      Ok('savepoint-partial', (CountWhere(bridge, conn,
        'SELECT COUNT(*) FROM tx3') = '1') and (CountWhere(bridge, conn,
        'SELECT v FROM tx3 WHERE id=1') = 'keep'));
      eng.SetAutoCommit(conn, True);

      { Dual connection: uncommitted row on A is invisible on B. }
      Ok('ddl4', bridge.ExecDirect(conn,
        'CREATE TABLE tx4(id BIGINT PRIMARY KEY, v VARCHAR(20))') = 0);
      eng.Release(conn);
      connA := eng.Borrow(pool);
      connB := eng.Borrow(pool);
      eng.SetAutoCommit(connA, False);
      bridge.ExecDirect(connA, 'INSERT INTO tx4 VALUES(99,''dirty'')');
      Ok('dual-conn-no-dirty-read', CountWhere(bridge, connB,
        'SELECT COUNT(*) FROM tx4 WHERE id=99') = '0');
      eng.Rollback(connA);
      eng.SetAutoCommit(connA, True);
      Ok('dual-conn-rollback-clean', CountWhere(bridge, connB,
        'SELECT COUNT(*) FROM tx4') = '0');
      eng.Release(connA);
      eng.Release(connB);

      { Pool exhaustion: MaxPool=1 held, second borrow times out. }
      small := DefaultPoolCfg('jdbc:h2:mem:tjtxsmall;DB_CLOSE_DELAY=-1',
        'org.h2.Driver');
      small.MaximumPoolSize := 1;
      small.MinimumIdle := 1;
      small.ConnectionTimeoutMs := 2000;
      spool := eng.OpenPool(small);
      sconn := eng.Borrow(spool);
      raised := False;
      exState := '';
      exMsg := '';
      try
        sconn2 := eng.Borrow(spool);
        eng.Release(sconn2);
      except
        on E: EJDBCError do
        begin
          raised := True;
          exState := E.SQLState;
          exMsg := E.Message;
        end;
      end;
      WriteLn('pool-exhaust-state=', exState);
      Ok('pool-exhaust-timeout', raised and (exState = 'HY000') and
        (Pos('timed out', exMsg) > 0));
      eng.Release(sconn);
      eng.ClosePool(spool);

      eng.ClosePool(pool);
      Ok('handles-zero', eng.HandleCount = 0);
      Ok('audit-zero', eng.AuditReport = 'pools=0 conns=0 stmts=0 cursors=0');
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
