program ex04_edit_apply;

{$mode objfpc}{$H+}

{ ex04: CachedUpdates + ApplyUpdates + generated-keys回取.
  Hostile text is stored as a plain value, never concatenated. }

uses
  SysUtils, Classes, DB, TyFPJDBC.Options, TyFPJDBC.Query, TyFPJDBC.Mock.Engine;

var
  eng: TMockEngine;
  q: TJDBCQuery;
  rows: TStringList;
  tot: Integer;
begin
  eng := TMockEngine.Create(20000);
  q := TJDBCQuery.Create(nil);
  try
    rows := eng.FetchSmall(0, 3, tot);
    try
      q.LoadRowsBuffered(['id', 'name'], ['INTEGER', 'NVARCHAR'], rows);
      q.CachedUpdates := True;
      q.UpdateOptions.ReadOnly := False;
      q.UpdateOptions.AutoIncField := 'id';

      q.Append;
      q.Fields[1].AsString := 'a'' OR ''1''=''1';
      q.Post;
      WriteLn('stored value => ', q.Fields[1].AsString);
      q.ApplyUpdates;
      WriteLn('genkey => ', q.GetGeneratedKeys,
        ' applied=', q.AppliedInserts, ' pending=', q.PendingInserts);
    finally
      rows.Free;
    end;
  finally
    q.Free;
    eng.Free;
  end;
  WriteLn('ex04 ok');
end.
