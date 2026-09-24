program TestLiveGrid;

{$mode objfpc}{$H+}
{$codepage UTF8}

{ Headless proof of the ex09 GUI data path: drives the SHIPPED
  GridData.TryLoadLive (the exact unit the form uses) on the real
  Pascal -> JNI -> Bridge -> sqlite path, then edits + ApplyUpdates and
  re-reads from the same real table. The form binds this query to
  DBGrid/DBEdit/DBNavigator in unit1.lfm. }

uses
  SysUtils, Classes, DB, TyFPJDBC.Query, TyFPJDBC.JNI.Bridge, GridData;

var
  Fails: Integer = 0;

procedure Ok(const N: string; C: Boolean);
begin
  if C then WriteLn('PASS ', N) else begin Inc(Fails); WriteLn('FAIL ', N); end;
end;

var
  q: TJDBCQuery;
  owned: TObject;
  pool, conn: Int64;
  note: string;
  classesDir, workDir: string;
  rows: TJavaRows;
  bridge: TBridgeClient;
begin
  if ParamStr(1) <> '' then
    classesDir := ParamStr(1)
  else
    classesDir := 'work-jmain';
  if ParamStr(2) <> '' then
    workDir := ParamStr(2)
  else
    workDir := 'work-grid';
  ForceDirectories(workDir);

  q := TJDBCQuery.Create(nil);
  try
    Ok('try-live', TryLoadLive(q, classesDir, workDir, owned, pool, conn,
      note));
    WriteLn('NOTE ', note);
    Ok('grid-rows', q.RecordCount = 3);
    q.First;
    q.Next;
    Ok('grid-chinese', q.FieldToUTF8(q.Fields[1]) = UTF8String('中文测试'));
    Ok('grid-cached', q.CachedUpdates);

    q.Append;
    q.FieldFromUTF8(q.Fields[1], UTF8String('网格新增'));
    q.Post;
    q.ApplyUpdates;
    Ok('grid-applied', (q.AppliedInserts = 1) and (q.PendingInserts = 0));
    bridge := TBridgeClient(owned);
    rows := bridge.FetchBatch(conn,
      'SELECT id,name FROM grid_t WHERE id>=1000 ORDER BY id', 0, 10, 100);
    Ok('grid-reread', (Length(rows) = 1) and (rows[0][0] = '1000') and
      (rows[0][1] = UTF8String('网格新增')));

    q.First;
    q.Edit;
    q.FieldFromUTF8(q.Fields[1], UTF8String('网格改名'));
    q.Post;
    q.ApplyUpdates;
    rows := bridge.FetchBatch(conn,
      'SELECT name FROM grid_t WHERE id=1', 0, 10, 100);
    Ok('grid-edit', (Length(rows) = 1) and
      (rows[0][0] = UTF8String('网格改名')));
    q.Close;
    FreeLive(owned, pool);
    owned := nil;
  finally
    if owned <> nil then
      FreeLive(owned, pool);
    q.Free;
  end;

  WriteLn('--- fails=', Fails);
  if Fails > 0 then
    Halt(1);
end.
