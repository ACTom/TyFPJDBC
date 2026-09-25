program TestTiers;

{$mode objfpc}{$H+}
{$codepage UTF8}

{ Tiered perf on the SHIPPED live path: Pascal -> JNI -> Bridge ->
  sqlite-jdbc file DB. Same workload per tier: bulk insert N rows
  (4 cols incl. Chinese payload), full scan touching every field,
  paged fetch-1000, bulk update of half the rows. Connection + warmup
  run BEFORE the timers, so JVM/Hikari startup never counts.
  Each tier asserts row counts and a shared checksum so the three runs
  are comparable; prints PERF lines plus FPC WorkingSet peak. }

uses
  SysUtils, Classes, TyFPJDBC.Handles, TyFPJDBC.JVM.Manager,
  TyFPJDBC.JNI.Bridge, TyFPJDBC.Engine, TyFPJDBC.Command;

var
  Fails: Integer = 0;

procedure Ok(const N: string; C: Boolean);
begin
  if C then WriteLn('PASS ', N) else begin Inc(Fails); WriteLn('FAIL ', N); end;
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
  raise Exception.Create('no jvm.dll found in known locations');
end;

function LibJar(const Name: string): string;
begin
  Result := 'C:\Tools\tyfpjdbc-libs\' + Name;
  if not FileExists(Result) then
    raise Exception.Create('missing jar: ' + Result);
end;

function FpcPeakKB: Int64;
begin
  Result := GetHeapStatus.TotalAllocated div 1024;
end;

procedure RunTier(B: TBridge; Eng: TJdbcEngine; const WorkDir: string; NRows: Integer);
var
  db: string;
  pool, c, stmt, cur: Int64;
  cfg: TPoolCfgRec;
  cmd: TJdbcCommand;
  batch: array of TBoundRow;
  i, off, cnt, pages: Integer;
  fetched: TJdbcRows;
  t0, msIns, msScan, msPage, msUpd: Int64;
  cntStr, sumStr, want: string;

  procedure FetchAll(const SQL: string; Size: Integer; out Rows: TJdbcRows);
  var
    s2, c2: Int64;
    w: TJdbcRows;
    k: Integer;
  begin
    SetLength(Rows, 0);
    s2 := B.Prepare(c, SQL);
    try
      c2 := B.QueryOpen(s2, Size);
      try
        repeat
          w := B.FetchWindow(c2, Size);
          if Length(w) = 0 then
            Break;
          for k := 0 to High(w) do
          begin
            SetLength(Rows, Length(Rows) + 1);
            Rows[High(Rows)] := w[k];
          end;
        until False;
      finally
        B.CloseCursor(c2);
      end;
    finally
      B.CloseStmt(s2);
    end;
  end;

begin
  db := WorkDir + PathDelim + 'tier-' + IntToStr(NRows) + '-' +
    IntToStr(GetProcessID) + '.db';
  if FileExists(db) then
    DeleteFile(db);
  cfg := DefaultPoolCfg('jdbc:sqlite:' + db, 'org.sqlite.JDBC');
  cfg.MaximumPoolSize := 4;
  cfg.MinimumIdle := 1;
  pool := Eng.OpenPool(cfg);
  c := Eng.Borrow(pool);
  try
    B.ExecDirect(c,
      'CREATE TABLE bench(id INTEGER PRIMARY KEY, name TEXT, payload TEXT, qty INT)');
    cmd := TJdbcCommand.Create(Eng, c);
    try
      cmd.SetSQL('INSERT INTO bench VALUES(:id,:name,:payload,:qty)');
      SetLength(batch, 100);
      for i := 0 to 99 do
      begin
        SetLength(batch[i], 4);
        batch[i][0] := BInt64(i + 1);
        batch[i][1] := BStr('w-' + IntToStr(i + 1));
        batch[i][2] := BStr('预热-' + IntToStr(i + 1));
        batch[i][3] := BInt64(i mod 100);
      end;
      cmd.ExecBatch(batch, 1000);
    finally
      cmd.Free;
    end;
    FetchAll('SELECT COUNT(*) FROM bench', 10, fetched);
    B.ExecDirect(c, 'DELETE FROM bench');

    t0 := GetTickCount64;
    { One ExecBatch per 1000-row chunk: each call is one transaction, so
      chunk count = commit count and Java-side batch memory stays bounded. }
    cmd := TJdbcCommand.Create(Eng, c);
    try
      cmd.SetSQL('INSERT INTO bench VALUES(:id,:name,:payload,:qty)');
      for off := 0 to (NRows div 1000) - 1 do
      begin
        SetLength(batch, 1000);
        for i := 0 to 999 do
        begin
          SetLength(batch[i], 4);
          batch[i][0] := BInt64(off * 1000 + i + 1);
          batch[i][1] := BStr('row-' + IntToStr(off * 1000 + i + 1));
          batch[i][2] := BStr('payload-中文-' + IntToStr(off * 1000 + i + 1));
          batch[i][3] := BInt64((off * 1000 + i + 1) mod 100);
        end;
        if cmd.ExecBatch(batch, 1000) <> 1000 then
          raise Exception.Create('short batch write');
      end;
    finally
      cmd.Free;
    end;
    msIns := GetTickCount64 - t0;
    WriteLn('PERF tier=', NRows, ' insert ms=', msIns, ' rows_per_sec=',
      (Int64(NRows) * 1000) div (msIns + 1));

    FetchAll('SELECT COUNT(*) FROM bench', 10, fetched);
    cntStr := string(fetched[0][0]);
    Ok('tier-' + IntToStr(NRows) + '-count', cntStr = IntToStr(NRows));

    t0 := GetTickCount64;
    off := 0; cnt := 0;
    while True do
    begin
      stmt := B.Prepare(c,
        'SELECT id, name, payload, qty FROM bench ORDER BY id LIMIT 1000 OFFSET ' +
        IntToStr(off));
      try
        cur := B.QueryOpen(stmt, 1000);
        try
          fetched := B.FetchWindow(cur, 1000);
        finally
          B.CloseCursor(cur);
        end;
      finally
        B.CloseStmt(stmt);
      end;
      if Length(fetched) = 0 then
        Break;
      for i := 0 to High(fetched) do
        Inc(cnt);
      Inc(off, Length(fetched));
    end;
    msScan := GetTickCount64 - t0;
    Ok('tier-' + IntToStr(NRows) + '-scan', cnt = NRows);
    WriteLn('PERF tier=', NRows, ' scan ms=', msScan, ' rows_per_sec=',
      (Int64(cnt) * 1000) div (msScan + 1));

    t0 := GetTickCount64;
    off := 0; cnt := 0; pages := 0;
    while off < NRows do
    begin
      stmt := B.Prepare(c,
        'SELECT id, name FROM bench ORDER BY id LIMIT 1000 OFFSET ' +
        IntToStr(off));
      try
        cur := B.QueryOpen(stmt, 1000);
        try
          fetched := B.FetchWindow(cur, 1000);
        finally
          B.CloseCursor(cur);
        end;
      finally
        B.CloseStmt(stmt);
      end;
      if Length(fetched) = 0 then
        Break;
      Inc(cnt, Length(fetched));
      Inc(off, Length(fetched));
      Inc(pages);
    end;
    msPage := GetTickCount64 - t0;
    Ok('tier-' + IntToStr(NRows) + '-paged',
      (cnt = NRows) and (pages = ((NRows + 999) div 1000)));
    WriteLn('PERF tier=', NRows, ' paged ms=', msPage, ' pages=', pages);

    t0 := GetTickCount64;
    B.ExecDirect(c, 'UPDATE bench SET qty=qty+1 WHERE id%2=0');
    msUpd := GetTickCount64 - t0;
    FetchAll('SELECT SUM(qty) FROM bench', 10, fetched);
    sumStr := string(fetched[0][0]);
    want := IntToStr((Int64(NRows div 100) * 4950) + (NRows div 2));
    Ok('tier-' + IntToStr(NRows) + '-checksum', sumStr = want);
    WriteLn('PERF tier=', NRows, ' update ms=', msUpd, ' checksum=', sumStr);

    WriteLn('PERF tier=', NRows, ' fpc-peak-kb=', FpcPeakKB,
      ' heap-used=', B.HeapUsed,
      ' heap-max=', B.HeapMax);
    Eng.Release(c);
  finally
    Eng.ClosePool(pool);
  end;
  if FileExists(db) then
    DeleteFile(db);
end;

var
  classesDir, workDir: string;
  eng: TJdbcEngine;
  bridge: TBridge;
  rep, tier, maxTier: Integer;
begin
  if ParamStr(1) <> '' then
    classesDir := ParamStr(1)
  else
    classesDir := 'work-jmain';
  if ParamStr(2) <> '' then
    workDir := ParamStr(2)
  else
    workDir := 'work-perf';
  ForceDirectories(workDir);
  rep := StrToIntDef(ParamStr(3), 1);
  { In-matrix runs pass skip1M: the 1M tier lives in the 3x scratch perf.log
    runs instead (a single 1M pass already takes minutes). }
  maxTier := 3;
  if ParamStr(4) = 'skip1M' then
    maxTier := 2;

  TJVMManager.ResetForTests;
  TJVMManager.SetClassPath(classesDir + ';' + LibJar('HikariCP-5.1.0.jar') +
    ';' + LibJar('slf4j-api-2.0.9.jar') + ';' + LibJar('h2-2.2.224.jar') +
    ';' + LibJar('sqlite-jdbc-3.46.1.0.jar'));
  TJVMManager.EnsureStarted(FindJvmDll, TJVMManager.BuildDesktopArgs);
  TJVMManager.AttachThread;
  bridge := TBridge.Create;
  eng := TJdbcEngine.Create(bridge);
  try
    for tier := 1 to maxTier do
      case tier of
        1: RunTier(bridge, eng, workDir, 10000);
        2: RunTier(bridge, eng, workDir, 100000);
        3: RunTier(bridge, eng, workDir, 1000000);
      end;
    WriteLn('PERF-REP rep=', rep, ' done');
  finally
    eng.Free;
    bridge.Free;
  end;
  TJVMManager.DetachThread;
  WriteLn('--- fails=', Fails);
  if Fails > 0 then
    Halt(1);
end.
