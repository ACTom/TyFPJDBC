program TestBinding;

{$mode objfpc}{$H+}
{$codepage UTF8}

{ Binding matrix skeleton: NULL-bit chain first, more asserts in later tasks.
  Usage: TestBinding <classesDir>. PG/MySQL via TJDBC_PG_URL/TJDBC_MYSQL_URL
  env or local defaults when jars exist; unreachable DB = SKIP, H2 must pass. }

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
end;

function FindJvmDll: string;
begin
  Result := 'C:\Tools\ms-jdks\win64\jdk-25.0.4.1+1\bin\server\jvm.dll';
end;

procedure RunNullSplit(eng: TJdbcEngine; bridge: TBridge;
  const DbId, Url, User, Pw, Driver: string);
var
  cfg: TPoolCfgRec;
  pool, conn, stmt, cur: Int64;
  page: TFetchPage;
  cmd: TJdbcCommand;
  r: TBoundRow;
begin
  cfg := DefaultPoolCfg(Url, Driver);
  cfg.User := UTF8String(User);
  cfg.Password := UTF8String(Pw);
  pool := eng.OpenPool(cfg);
  conn := eng.Borrow(pool);
  bridge.ExecDirect(conn, 'CREATE TABLE nsplit(id BIGINT PRIMARY KEY, v VARCHAR(50))');
  cmd := TJdbcCommand.Create(eng, conn);
  try
    cmd.SetSQL('INSERT INTO nsplit VALUES(:id,:v)');
    SetLength(r, 2);
    r[0] := BInt64(1);
    r[1] := BStr('');
    Ok(DbId + '-empty-insert', cmd.ExecUpdate(r) = 1);
    SetLength(r, 2);
    r[0] := BInt64(2);
    r[1] := BNull(12);
    Ok(DbId + '-null-insert', cmd.ExecUpdate(r) = 1);
    stmt := bridge.Prepare(conn, 'SELECT v FROM nsplit ORDER BY id');
    try
      cur := bridge.QueryOpen(stmt, 10);
      try
        page := bridge.FetchPage(cur, 10);
        Ok(DbId + '-rows-2', Length(page.Rows) = 2);
        Ok(DbId + '-empty-not-null', (Length(page.Nulls) = 2) and (not page.Nulls[0][0]));
        Ok(DbId + '-null-is-null', (Length(page.Nulls) = 2) and page.Nulls[1][0]);
        Ok(DbId + '-empty-value', page.Rows[0][0] = '');
      finally
        bridge.CloseCursor(cur);
      end;
    finally
      bridge.CloseStmt(stmt);
    end;
  finally
    cmd.Free;
  end;
  eng.Release(conn);
  eng.ClosePool(pool);
end;

var
  classesDir: string;
  bridge: TBridge;
  eng: TJdbcEngine;
begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: TestBinding <classesDir>');
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
      RunNullSplit(eng, bridge, 'h2', 'jdbc:h2:mem:tjbind;DB_CLOSE_DELAY=-1',
        '', '', 'org.h2.Driver');
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
