program TestPerfCompare;

{$mode objfpc}{$H+}

{ Perf harness: Lazarus built-in sqlite3conn (TSQLite3Connection) against a
  file DB. Same workload as java PerfCompare (Bridge + sqlite-jdbc):
  bulk insert / full scan / paged fetch / bulk update.
  Connect + warmup happen BEFORE the timers, so connection/JVM startup is
  never counted. Prints PERF lines parsed by scripts/run-matrix.ps1. }

uses
  SysUtils, Classes, DB, sqlite3conn, sqldb;

var
  Fails: Integer = 0;
  GTr: TSQLTransaction = nil;

procedure Ok(const N: string; C: Boolean);
begin
  if C then WriteLn('PASS ', N) else begin Inc(Fails); WriteLn('FAIL ', N); end;
end;

procedure BeginTx;
begin
  { SELECTs auto-activate the transaction and leave it open; never nest. }
  if GTr.Active then
    GTr.Commit;
  GTr.StartTransaction;
end;

procedure EndTx;
begin
  if (GTr <> nil) and GTr.Active then
    GTr.Commit;
end;

var
  DbPath: string;
  Rows, i, cnt: Integer;
  c: TSQLite3Connection;
  tr: TSQLTransaction;
  q: TSQLQuery;
  t0, msIns, msScan, msPage, msUpd: Int64;
  sum: Int64;
  pages: Integer;
begin
  DbPath := ParamStr(1);
  if DbPath = '' then
    DbPath := 'perf-fpc.db';
  Rows := StrToIntDef(ParamStr(2), 20000);
  if FileExists(DbPath) then
    DeleteFile(DbPath);

  c := TSQLite3Connection.Create(nil);
  tr := TSQLTransaction.Create(nil);
  q := TSQLQuery.Create(nil);
  try
    c.DatabaseName := DbPath;
    c.Transaction := tr;
    tr.Database := c;
    c.Open;
    q.DataBase := c;
    q.Transaction := tr;
    GTr := tr;

    { --- warmup (not timed): create + 100 rows + 1 scan --- }
    BeginTx;
    q.SQL.Text := 'CREATE TABLE bench(id INTEGER PRIMARY KEY, name TEXT, payload TEXT, qty INT)';
    q.ExecSQL;
    EndTx;
    BeginTx;
    q.SQL.Text := 'INSERT INTO bench VALUES(:id,:nm,:pl,:q)';
    q.Prepare;
    for i := 1 to 100 do
    begin
      q.Params.ParamByName('id').AsInteger := i;
      q.Params.ParamByName('nm').AsString := 'row-' + IntToStr(i);
      q.Params.ParamByName('pl').AsString := 'payload-中文-' + IntToStr(i);
      q.Params.ParamByName('q').AsInteger := i mod 100;
      q.ExecSQL;
    end;
    EndTx;
    q.SQL.Text := 'SELECT COUNT(*) FROM bench';
    q.Open;
    q.Close;
    q.SQL.Text := 'DELETE FROM bench';
    q.ExecSQL;
    EndTx;

    { --- phase 1: bulk insert, single transaction, parameterized --- }
    t0 := GetTickCount64;
    BeginTx;
    q.SQL.Text := 'INSERT INTO bench VALUES(:id,:nm,:pl,:q)';
    q.Prepare;
    for i := 1 to Rows do
    begin
      q.Params.ParamByName('id').AsInteger := i;
      q.Params.ParamByName('nm').AsString := 'row-' + IntToStr(i);
      q.Params.ParamByName('pl').AsString := 'payload-中文-' + IntToStr(i);
      q.Params.ParamByName('q').AsInteger := i mod 100;
      q.ExecSQL;
    end;
    EndTx;
    msIns := GetTickCount64 - t0;
    WriteLn('PERF fpc-insert ms=', msIns, ' rows=', Rows,
      ' rows_per_sec=', (Int64(Rows) * 1000) div (msIns + 1));

    { --- phase 2: full scan, read every field --- }
    t0 := GetTickCount64;
    cnt := 0; sum := 0;
    q.SQL.Text := 'SELECT id, name, payload, qty FROM bench ORDER BY id';
    q.Open;
    while not q.EOF do
    begin
      Inc(cnt);
      sum := sum + q.Fields[3].AsInteger + Length(q.Fields[1].AsString) * 0;
      q.Next;
    end;
    q.Close;
    msScan := GetTickCount64 - t0;
    Ok('scan-count', cnt = Rows);
    WriteLn('PERF fpc-scan ms=', msScan, ' rows=', cnt,
      ' rows_per_sec=', (Int64(cnt) * 1000) div (msScan + 1));

    { --- phase 3: paged fetch 1000 --- }
    t0 := GetTickCount64;
    cnt := 0; pages := 0; i := 0;
    while i < Rows do
    begin
      q.SQL.Text := 'SELECT id, name FROM bench ORDER BY id LIMIT 1000 OFFSET ' + IntToStr(i);
      q.Open;
      while not q.EOF do
      begin
        Inc(cnt);
        q.Next;
      end;
      q.Close;
      Inc(pages);
      i := i + 1000;
    end;
    msPage := GetTickCount64 - t0;
    Ok('paged-count', cnt = Rows);
    Ok('paged-pages', pages = ((Rows + 999) div 1000));
    WriteLn('PERF fpc-paged ms=', msPage, ' rows=', cnt, ' pages=', pages,
      ' rows_per_sec=', (Int64(cnt) * 1000) div (msPage + 1));

    { --- phase 4: bulk update half the rows --- }
    t0 := GetTickCount64;
    BeginTx;
    q.SQL.Text := 'UPDATE bench SET qty=qty+1 WHERE id%2=0';
    q.ExecSQL;
    EndTx;
    msUpd := GetTickCount64 - t0;
    q.SQL.Text := 'SELECT SUM(qty) FROM bench';
    q.Open;
    sum := q.Fields[0].AsLargeInt;
    q.Close;
    WriteLn('PERF fpc-update ms=', msUpd, ' checksum=', sum);
    Ok('update-checksum', sum = (Int64(Rows div 100) * 4950) + (Rows div 2));
  finally
    q.Free;
    tr.Free;
    c.Free;
  end;

  WriteLn('--- fails=', Fails);
  if Fails > 0 then Halt(1);
end.
