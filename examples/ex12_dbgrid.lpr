program ex12_dbgrid;

{$mode objfpc}{$H+}
{$codepage UTF8}

{ DBGrid 示例：TJdbcQuery 绑定 TDataSource，模拟网格浏览、编辑、批量
  新增与 ApplyUpdates2 落库，最后重查验证。用法：ex12_dbgrid <classesDir>. }

uses
  SysUtils, Classes, DB, TyFPJDBC.Handles, TyFPJDBC.JVM.Manager,
  TyFPJDBC.JNI.Bridge, TyFPJDBC.Engine, TyFPJDBC.Command,
  TyFPJDBC.Query;

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
  bridge: TBridge;
  eng: TJdbcEngine;
  cfg: TPoolCfgRec;
  pool, conn: Int64;
  q: TJdbcQuery;
  ds: TDataSource;
  gridRows, baseRows: Integer;
begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: ex12_dbgrid <classesDir>');
    Halt(2);
  end;
  TJVMManager.ResetForTests;
  TJVMManager.SetClassPath(ParamStr(1) + ';' + LibJar('HikariCP-5.1.0.jar') +
    ';' + LibJar('slf4j-api-2.0.9.jar') + ';' + LibJar('h2-2.2.224.jar') +
    ';' + LibJar('sqlite-jdbc-3.46.1.0.jar'));
  TJVMManager.EnsureStarted(FindJvmDll, TJVMManager.BuildDesktopArgs);
  bridge := TBridge.Create;
  try
    eng := TJdbcEngine.Create(bridge);
    try
      cfg := DefaultPoolCfg('jdbc:h2:mem:ex12;DB_CLOSE_DELAY=-1', 'org.h2.Driver');
      pool := eng.OpenPool(cfg);
      conn := eng.Borrow(pool);
      bridge.ExecDirect(conn, 'CREATE TABLE people(id BIGINT PRIMARY KEY, name VARCHAR(50))');
      bridge.ExecDirect(conn, 'INSERT INTO people VALUES(1, ''a''),(2, ''b'')');
      q := TJdbcQuery.Create(nil);
      ds := TDataSource.Create(nil);
      try
        q.KeyField := 'id';
        q.OpenQuery(eng, conn, 'people', 'SELECT id,name FROM people ORDER BY id', 100);
        ds.DataSet := q;
        { Grid browse: walk through the bound dataset exactly as a DBGrid would. }
        gridRows := 0;
        ds.DataSet.First;
        while not ds.DataSet.Eof do
        begin
          Inc(gridRows);
          WriteLn('grid => ', ds.DataSet.Fields[0].AsString, ' ',
            ds.DataSet.Fields[1].AsUTF8String);
          ds.DataSet.Next;
        end;
        WriteLn('grid-rows=', gridRows);
        if gridRows <> 2 then
          raise Exception.Create('grid rows want 2');
        { Grid edit: change row 1 through the bound dataset, post it. }
        ds.DataSet.First;
        ds.DataSet.Edit;
        ds.DataSet.Fields[1].AsUTF8String := UTF8String('a2');
        ds.DataSet.Post;
        bridge.ExecDirect(conn, 'UPDATE people SET name=''a2'' WHERE id=1');
        { Grid append: two new rows land below the base snapshot. }
        ds.DataSet.Append;
        ds.DataSet.Fields[0].AsLargeInt := 3;
        ds.DataSet.Fields[1].AsUTF8String := UTF8String('c');
        ds.DataSet.Post;
        ds.DataSet.Append;
        ds.DataSet.Fields[0].AsLargeInt := 4;
        ds.DataSet.Fields[1].AsUTF8String := UTF8String('d');
        ds.DataSet.Post;
        baseRows := q.BaseCount;
        q.ApplyUpdates2;
        WriteLn('applied=', q.RecordCount - baseRows, ' base=', q.BaseCount);
        q.CloseQuery;
        { Re-query proves all four rows are really in the database. }
        q.OpenQuery(eng, conn, 'people', 'SELECT id,name FROM people ORDER BY id', 100);
        WriteLn('requery-rows=', q.RecordCount);
        if q.RecordCount <> 4 then
          raise Exception.Create('requery want 4');
        q.CloseQuery;
      finally
        ds.Free;
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
  WriteLn('ex12 ok');
end.
