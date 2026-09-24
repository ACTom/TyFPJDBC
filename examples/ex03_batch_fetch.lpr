program ex03_batch_fetch;

{$mode objfpc}{$H+}

{ ex03: buffered fetch in 1000-row pages over a 20k stream. }

uses
  SysUtils, Classes, DB, TyFPJDBC.Options, TyFPJDBC.Query, TyFPJDBC.Mock.Engine;

var
  eng: TMockEngine;
  q: TJDBCQuery;
  rows: TStringList;
  tot, off, cnt, pages, maxPage: Integer;
begin
  eng := TMockEngine.Create(20000);
  q := TJDBCQuery.Create(nil);
  try
    q.FetchOptions.RowsetSize := 1000;
    q.FetchOptions.Mode := fmAll;
    q.SQL.Text := 'SELECT id, name FROM big ORDER BY id';
    WriteLn('jdbc => ', Trim(q.JdbcSql));

    off := 0; cnt := 0; pages := 0; maxPage := 0;
    while off < eng.LargeTotal do
    begin
      rows := eng.FetchLarge(off, q.FetchOptions.RowsetSize, tot);
      try
        if rows.Count > maxPage then maxPage := rows.Count;
        Inc(cnt, rows.Count);
        Inc(pages);
        off := off + rows.Count;
        if rows.Count = 0 then Break;
      finally
        rows.Free;
      end;
    end;
    WriteLn('fetched=', cnt, ' pages=', pages, ' maxPage=', maxPage);
  finally
    q.Free;
    eng.Free;
  end;
  WriteLn('ex03 ok');
end.
