program ex01_connect_select;

{$mode objfpc}{$H+}

{ ex01: connect + SELECT 1 + Chinese read/write via Lazarus built-in
  sqlite3conn (TSQLite3Connection). Needs sqlite3.dll next to the exe. }

uses
  SysUtils, DB, sqlite3conn, sqldb;

var
  c: TSQLite3Connection;
  tr: TSQLTransaction;
  q: TSQLQuery;
begin
  c := TSQLite3Connection.Create(nil);
  tr := TSQLTransaction.Create(nil);
  q := TSQLQuery.Create(nil);
  try
    c.DatabaseName := ':memory:';
    c.Transaction := tr;
    tr.Database := c;
    c.Open;
    q.DataBase := c;
    q.Transaction := tr;

    tr.StartTransaction;
    q.SQL.Text := 'SELECT 1 AS one';
    q.Open;
    WriteLn('SELECT 1 => ', q.Fields[0].AsString);
    q.Close;
    if tr.Active then tr.Commit;

    tr.StartTransaction;
    q.SQL.Text := 'CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)';
    q.ExecSQL;
    if tr.Active then tr.Commit;

    tr.StartTransaction;
    q.SQL.Text := 'INSERT INTO t VALUES(1,''hello'')';
    q.ExecSQL;
    q.SQL.Text := 'INSERT INTO t VALUES(2,''中文测试'')';
    q.ExecSQL;
    if tr.Active then tr.Commit;

    q.SQL.Text := 'SELECT name FROM t ORDER BY id';
    q.Open;
    while not q.EOF do
    begin
      WriteLn('row => ', q.Fields[0].AsString);
      q.Next;
    end;
    q.Close;
    if tr.Active then tr.Commit;
  finally
    q.Free;
    tr.Free;
    c.Free;
  end;
  WriteLn('ex01 ok');
end.
