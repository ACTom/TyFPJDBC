program TestInjection;

{$mode objfpc}{$H+}
{$codepage UTF8}

{ Hostile-value roundtrip on H2: every hostile string travels via bindings
  only, reads back verbatim, and the table survives. Usage:
  TestInjection <classesDir>. }

uses
  SysUtils, Classes, TyFPJDBC.Handles, TyFPJDBC.JVM.Manager,
  TyFPJDBC.JNI.Bridge, TyFPJDBC.Engine, TyFPJDBC.Command;

const
  HOSTILE: array[0..9] of string = (
    '''; DROP TABLE inj;--',
    'a''b"c`d',
    'back\slash',
    'percent%under_score',
    '--comment',
    '/*block*/',
    '中文测试''注入',
    'wide-中文-''";--',
    'semi;colon;colon',
    'quote''''doubled'
  );

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
  cmd: TJdbcCommand;
  r: TBoundRow;
  back: TJdbcRows;
  i: Integer;
  okAll: Boolean;
begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: TestInjection <classesDir>');
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
      cfg := DefaultPoolCfg('jdbc:h2:mem:tjinj;DB_CLOSE_DELAY=-1', 'org.h2.Driver');
      pool := eng.OpenPool(cfg);
      conn := eng.Borrow(pool);
      Ok('ddl', bridge.ExecDirect(conn,
        'CREATE TABLE inj(id BIGINT PRIMARY KEY, v VARCHAR(200))') = 0);
      cmd := TJdbcCommand.Create(eng, conn);
      try
        cmd.SetSQL('INSERT INTO inj VALUES(:id,:v)');
        for i := 0 to High(HOSTILE) do
        begin
          SetLength(r, 2);
          r[0] := BInt64(i + 1);
          r[1] := BStr(HOSTILE[i]);
          if cmd.ExecUpdate(r) <> 1 then
          begin
            Ok('inject-insert-' + IntToStr(i), False);
            Break;
          end;
        end;
        Ok('inject-insert-10', True);
        stmt := bridge.Prepare(conn, 'SELECT id,v FROM inj ORDER BY id');
        try
          cur := bridge.QueryOpen(stmt, 20);
          try
            back := bridge.FetchWindow(cur, 20);
            okAll := Length(back) = 10;
            if okAll then
              for i := 0 to 9 do
                if back[i][1] <> HOSTILE[i] then
                begin
                  okAll := False;
                  Break;
                end;
            Ok('inject-verbatim-10', okAll);
          finally
            bridge.CloseCursor(cur);
          end;
        finally
          bridge.CloseStmt(stmt);
        end;
        { Table structure survived: still writable and countable. }
        SetLength(r, 2);
        r[0] := BInt64(11);
        r[1] := BStr('aftermath');
        cmd.SetSQL('INSERT INTO inj VALUES(:id,:v)');
        Ok('inject-table-alive', cmd.ExecUpdate(r) = 1);
        stmt := bridge.Prepare(conn, 'SELECT COUNT(*) FROM inj');
        try
          cur := bridge.QueryOpen(stmt, 10);
          try
            back := bridge.FetchWindow(cur, 10);
            Ok('inject-count-11', (Length(back) = 1) and (back[0][0] = '11'));
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
