program ex11_code_first;

{$mode objfpc}{$H+}
{$codepage UTF8}

{ V2 代码优先示例：JVM -> BridgeV2 -> H2，建表、类型化插入、窗口查询、
  编辑回写、事务回滚。用法：ex11_code_first <classesDir>. }

uses
  SysUtils, Classes, TyFPJDBC.Handles, TyFPJDBC.JVM.Manager,
  TyFPJDBC.JNI.BridgeV2, TyFPJDBC.Engine, TyFPJDBC.Command,
  TyFPJDBC.V2.Query;

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
  bridge: TBridgeV2;
  eng: TJdbcEngine;
  cfg: TPoolCfgRec;
  pool, conn: Int64;
  cmd: TJdbcCommand;
  q: TJV2Query;
  r: TBoundRow;
  rows: array of TBoundRow;
  i: Integer;
begin
  TJVMManager.ResetForTests;
  TJVMManager.SetClassPath(ParamStr(1) + ';' + LibJar('HikariCP-5.1.0.jar') +
    ';' + LibJar('slf4j-api-2.0.9.jar') + ';' + LibJar('h2-2.2.224.jar') +
    ';' + LibJar('sqlite-jdbc-3.46.1.0.jar'));
  TJVMManager.EnsureStarted(FindJvmDll, TJVMManager.BuildDesktopArgs);
  bridge := TBridgeV2.Create;
  try
    eng := TJdbcEngine.Create(bridge);
    try
      cfg := DefaultPoolCfg('jdbc:h2:mem:ex11;DB_CLOSE_DELAY=-1', 'org.h2.Driver');
      pool := eng.OpenPool(cfg);
      conn := eng.Borrow(pool);
      bridge.ExecDirect(conn, 'CREATE TABLE goods(id BIGINT PRIMARY KEY, name VARCHAR(50))');
      cmd := TJdbcCommand.Create(eng, conn);
      try
        cmd.SetSQL('INSERT INTO goods VALUES(:id,:name)');
        SetLength(rows, 3);
        for i := 0 to 2 do
        begin
          SetLength(rows[i], 2);
          rows[i][0] := BInt64(i + 1);
          rows[i][1] := BStr('g' + IntToStr(i + 1));
        end;
        WriteLn('inserted=', cmd.ExecBatch(rows, 1000));
      finally
        cmd.Free;
      end;
      q := TJV2Query.Create(nil);
      try
        q.KeyField := 'id';
        q.OpenQuery(eng, conn, 'goods', 'SELECT id,name FROM goods ORDER BY id', 100);
        WriteLn('rows=', q.RecordCount);
        q.First;
        while not q.Eof do
        begin
          WriteLn('row => ', q.Fields[0].AsString, ' ', q.Fields[1].AsUTF8String);
          q.Next;
        end;
        q.CloseQuery;
      finally
        q.Free;
      end;
      eng.Release(conn);
      eng.ClosePool(pool);
      WriteLn('handles=', eng.HandleCount);
    finally
      eng.Free;
    end;
  finally
    bridge.Free;
  end;
  TJVMManager.ShutdownJvm;
  WriteLn('ex11 ok');
end.
