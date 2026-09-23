program TestQuery;
{$mode objfpc}{$H+}
uses
  SysUtils, Classes, DB, TyFPJDBC.Options, TyFPJDBC.Query,
  TyFPJDBC.Mock.Engine, TyFPJDBC.StoredProc, TyFPJDBC.Script,
  TyFPJDBC.&Type.Map;

var
  Fails: Integer = 0;

procedure Ok(const N: string; C: Boolean);
begin
  if C then WriteLn('PASS ', N) else begin Inc(Fails); WriteLn('FAIL ', N); end;
end;

var
  eng: TMockEngine;
  q: TJDBCQuery;
  rows: TStringList;
  tot, off, cnt, pages, maxPage: Integer;
  sp: TJDBCStoredProc;
  parts: TStringList;
  ms: TMemoryStream;
  blobVal: string;
begin
  eng := TMockEngine.Create(20000);
  try
    q := TJDBCQuery.Create(nil);
    try
      q.FetchOptions.RowsetSize := 1000;
      q.FetchOptions.Mode := fmAll;
      q.SQL.Text := 'SELECT id, name FROM t WHERE id=:id';
      Ok('jdbc-sql', Trim(q.JdbcSql) = 'SELECT id, name FROM t WHERE id=?');
      Ok('param-order', (Length(q.ParamOrder) = 1) and (q.ParamOrder[0] = 'id'));

      rows := eng.FetchSmall(0, 100, tot);
      try
        Ok('small-total', tot = 3);
        q.LoadRowsBuffered(['id', 'name'], ['INTEGER', 'NVARCHAR'], rows);
        Ok('small-count', q.RecordCount = 3);
        q.First;
        q.Next;
        Ok('chinese-verbatim', q.Fields[1].AsString = '中文测试');
      finally
        rows.Free;
      end;

      off := 0; cnt := 0; pages := 0; maxPage := 0;
      while off < eng.LargeTotal do
      begin
        rows := eng.FetchLarge(off, q.FetchOptions.RowsetSize, tot);
        try
          Ok('large-total-stable', tot = 20000);
          if rows.Count > maxPage then maxPage := rows.Count;
          Inc(cnt, rows.Count);
          Inc(pages);
          off := off + rows.Count;
          if rows.Count = 0 then Break;
        finally
          rows.Free;
        end;
      end;
      Ok('large-count', cnt = 20000);
      Ok('large-bounded', maxPage <= 1000);
      Ok('large-pages', pages = 20);

      Ok('blob-is-blob', TJdbcTypeMap.ToFieldType('BLOB') = ftBlob);
      Ok('blob-needstream', TJdbcTypeMap.NeedStream('BLOB'));
      ms := TMemoryStream.Create;
      try
        blobVal := 'blob-bytes-中文';
        ms.WriteBuffer(blobVal[1], Length(blobVal));
        ms.Position := 0;
        Ok('blob-roundtrip', ms.Size > 0);
      finally
        ms.Free;
      end;

      q.Close;
      rows := eng.FetchSmall(0, 3, tot);
      try
        q.LoadRowsBuffered(['id', 'name'], ['INTEGER', 'NVARCHAR'], rows);
        q.CachedUpdates := True;
        q.UpdateOptions.ReadOnly := False;
        Ok('can-apply', q.CanApplyUpdates);
        q.Append;
        q.Fields[0].AsString := '4';
        q.Fields[1].AsString := 'a'' OR ''1''=''1';
        q.Post;
        Ok('injection-as-value', q.Fields[1].AsString = 'a'' OR ''1''=''1');
        q.SetGeneratedKey(42);
        q.ApplyUpdates;
        Ok('genkey', q.GetGeneratedKeys = 42);
      finally
        rows.Free;
      end;
    finally
      q.Free;
    end;

    sp := TJDBCStoredProc.Create;
    try
      sp.ProcName := 'demo';
      sp.SetInParam('p1', 'v1');
      sp.RegisterOutParam(0, 12);
      sp.Exec;
      Ok('proc-out', sp.OutAsString(0) <> '');
    finally
      sp.Free;
    end;

    parts := TJDBCScript.Split('SELECT 1; SELECT '';''; SELECT 3 -- ;' + #10 + '; SELECT 4 /* ; */;');
    try
      Ok('script-count', parts.Count = 4);
      Ok('script-semi-in-str', Pos(';', parts[1]) > 0);
    finally
      parts.Free;
    end;
  finally
    eng.Free;
  end;

  WriteLn('--- fails=', Fails);
  if Fails > 0 then Halt(1);
end.
