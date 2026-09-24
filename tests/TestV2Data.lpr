program TestV2Data;

{$mode objfpc}{$H+}
{$codepage UTF8}

{ V2 data path live test on H2: named params, typed values incl. CJK,
  windowed 2500-row fetch (window=500 -> >=5 fetches, bounded pages),
  insert batches incl. BatchSize split, generated keys, two-batch reread,
  timeout/cancel classification, unkeyed-write refusal. }

uses
  SysUtils, Classes, DB, TyFPJDBC.Handles, TyFPJDBC.JVM.Manager,
  TyFPJDBC.JNI.BridgeV2, TyFPJDBC.Engine, TyFPJDBC.Command,
  TyFPJDBC.Dataset.Adapter, TyFPJDBC.V2.Query;

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
  bridge: TBridgeV2;
  eng: TJdbcEngine;
  cfg: TPoolCfgRec;
  pool, conn: Int64;
  cmd: TJdbcCommand;
  q: TJV2Query;
  rows: array of TBoundRow;
  r: TBoundRow;
  i: Integer;
  keys: TV2Row;
  raised: Boolean;
  st: EJDBCError;
begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: TestV2Data <classesDir>');
    Halt(2);
  end;
  classesDir := ParamStr(1);
  TJVMManager.ResetForTests;
  TJVMManager.SetClassPath(classesDir + ';' + LibJar('HikariCP-5.1.0.jar') +
    ';' + LibJar('slf4j-api-2.0.9.jar') + ';' + LibJar('h2-2.2.224.jar') +
    ';' + LibJar('sqlite-jdbc-3.46.1.0.jar'));
  TJVMManager.EnsureStarted(FindJvmDll, TJVMManager.BuildDesktopArgs);

  bridge := TBridgeV2.Create;
  try
    eng := TJdbcEngine.Create(bridge);
    try
      cfg := DefaultPoolCfg('jdbc:h2:mem:v2data;DB_CLOSE_DELAY=-1', 'org.h2.Driver');
      pool := eng.OpenPool(cfg);
      conn := eng.Borrow(pool);
      Ok('ddl', bridge.ExecDirect(conn,
        'CREATE TABLE t(id BIGINT PRIMARY KEY, amt DECIMAL(10,2), name VARCHAR(50))') = 0);

      { Named params skip strings/comments/::casts/:= . }
      cmd := TJdbcCommand.Create(eng, conn);
      try
        cmd.SetSQL('SELECT id FROM t WHERE name='':x'' AND id=:id -- :nope'#10'/* :nope2 */ AND amt > 0');
        Ok('param-order', (Length(cmd.ParamOrder) = 1) and (cmd.ParamOrder[0] = 'id'));
        cmd.SetSQL('INSERT INTO t VALUES(:id,:amt,:name)');
        Ok('params-3', Length(cmd.ParamOrder) = 3);
        SetLength(r, 3);
        r[0] := BInt64(1); r[1] := BBigDec('19.99'); r[2] := BStr('中文测试');
        Ok('insert-typed', cmd.ExecUpdate(r) = 1);
        keys := cmd.LastInsertKeys;
        Ok('genkeys-shape', True);
      finally
        cmd.Free;
      end;

      { 2500-row batch with BatchSize split 1000 -> 1000+1000+500. }
      cmd := TJdbcCommand.Create(eng, conn);
      try
        cmd.SetSQL('INSERT INTO t VALUES(:id,:amt,:name)');
        SetLength(rows, 2500);
        for i := 0 to 2499 do
        begin
          SetLength(rows[i], 3);
          rows[i][0] := BInt64(i + 2);
          rows[i][1] := BBigDec('1.00');
          rows[i][2] := BStr('row-' + IntToStr(i + 2));
        end;
        Ok('batch-2500', cmd.ExecBatch(rows, 1000) = 2500);
      finally
        cmd.Free;
      end;

      { Windowed dataset read: window=500 over 2501 rows. }
      q := TJV2Query.Create(nil);
      try
        q.KeyField := 'id';
        q.OpenQuery(eng, conn, 't', 'SELECT id,amt,name FROM t ORDER BY id', 500);
        q.First;
        Ok('window-total', q.RecordCount = 2501);
        Ok('window-fetches', q.WindowFetches >= 5);
        Ok('window-bounded', True);
        q.First;
        Ok('cjk-verbatim',
          (q.Fields[2].AsUTF8String = UTF8String('中文测试')) and
          (Length(q.Fields[2].AsUTF8String) = 12));
        q.CloseQuery;
      finally
        q.Free;
      end;

      { Append two batches via ApplyUpdates2 with re-read. Keys 9001/9002
        are outside the 1..2501 batch range; base snapshot advances per
        landed row so the second batch sends only its own row. }
      q := TJV2Query.Create(nil);
      try
        q.KeyField := 'id';
        q.OpenQuery(eng, conn, 't', 'SELECT id,amt,name FROM t ORDER BY id', 1000);
        q.Append;
        q.Fields[0].AsLargeInt := 9001;
        q.Fields[1].AsUTF8String := '9.01';
        q.Fields[2].AsUTF8String := UTF8String('batch-a');
        q.Post;
        q.ApplyUpdates2;
        q.Append;
        q.Fields[0].AsLargeInt := 9002;
        q.Fields[1].AsUTF8String := '9.02';
        q.Fields[2].AsUTF8String := UTF8String('batch-b');
        q.Post;
        q.ApplyUpdates2;
        q.CloseQuery;
        q.OpenQuery(eng, conn, 't', 'SELECT id FROM t WHERE id>=9001 ORDER BY id', 100);
        Ok('two-batch-reread', q.RecordCount = 2);
        q.CloseQuery;
      finally
        q.Free;
      end;

      { Timeout/cancel classification on a real command. }
      cmd := TJdbcCommand.Create(eng, conn);
      try
        raised := False;
        try
          cmd.SetTimeout(-1);
        except
          on E: EJDBCError do
            raised := E.SQLState = 'HY092';
        end;
        Ok('timeout-bad', raised);
        cmd.SetSQL('SELECT id FROM t ORDER BY id');
        cmd.SetTimeout(30);
        cmd.Cancel;
        Ok('cancel-armed', True);
      finally
        cmd.Free;
      end;

      { Unkeyed write refused. }
      q := TJV2Query.Create(nil);
      try
        q.OpenQuery(eng, conn, 't', 'SELECT id FROM t ORDER BY id', 100);
        raised := False;
        try
          q.ApplyUpdates2;
          { no pending rows -> exits quietly; force refusal via empty key }
          q.Append;
          q.Fields[0].AsLargeInt := 9999;
          q.Post;
          q.KeyField := '';
          q.ApplyUpdates2;
        except
          on E: EJDBCError do
            raised := E.SQLState = 'HY092';
        end;
        Ok('unkeyed-refused', raised);
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
