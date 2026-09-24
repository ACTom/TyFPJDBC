program TestPerfTiers;

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
  SysUtils, Classes, TyFPJDBC.JVM.Manager, TyFPJDBC.JNI.Bridge;

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

procedure RunTier(bridge: TBridgeClient; const WorkDir: string; NRows: Integer);
var
  db: string;
  pool, c: Int64;
  batch: TJavaRows;
  nulls: TJavaNulls;
  i, off, cnt, pages: Integer;
  fetched: TJavaRows;
  t0, msIns, msScan, msPage, msUpd: Int64;
  cntStr, sumStr, want: string;
begin
  db := WorkDir + PathDelim + 'tier-' + IntToStr(NRows) + '-' +
    IntToStr(GetProcessID) + '.db';
  if FileExists(db) then
    DeleteFile(db);
  pool := bridge.CreatePool('jdbc:sqlite:' + db, '', '', 4, 1);
  c := bridge.BorrowConnection(pool);
  try
    bridge.ExecUpdate(c,
      'CREATE TABLE bench(id INTEGER PRIMARY KEY, name TEXT, payload TEXT, qty INT)');
    SetLength(batch, 100);
    SetLength(nulls, 100);
    for i := 0 to 99 do
    begin
      batch[i] := TJavaRow.Create(IntToStr(i + 1), 'w-' + IntToStr(i + 1),
        UTF8String('预热-') + UTF8String(IntToStr(i + 1)), IntToStr(i mod 100));
      nulls[i] := TJavaNullRow.Create(False, False, False, False);
    end;
    bridge.ExecBatch(c, 'INSERT INTO bench VALUES(?,?,?,?)', batch, nulls);
    bridge.FetchBatch(c, 'SELECT COUNT(*) FROM bench', 0, 10, 100);
    bridge.ExecUpdate(c, 'DELETE FROM bench');

    t0 := GetTickCount64;
    { One execBatch per 1000-row chunk: each call is one transaction, so
      chunk count = commit count and Java-side batch memory stays bounded. }
    for off := 0 to (NRows div 1000) - 1 do
    begin
      SetLength(batch, 1000);
      SetLength(nulls, 1000);
      for i := 0 to 999 do
      begin
        batch[i] := TJavaRow.Create(IntToStr(off * 1000 + i + 1),
          'row-' + IntToStr(off * 1000 + i + 1),
          UTF8String('payload-中文-') +
          UTF8String(IntToStr(off * 1000 + i + 1)),
          IntToStr((off * 1000 + i + 1) mod 100));
        nulls[i] := TJavaNullRow.Create(False, False, False, False);
      end;
      if bridge.ExecBatch(c, 'INSERT INTO bench VALUES(?,?,?,?)',
        batch, nulls) <> 1000 then
        raise Exception.Create('short batch write');
    end;
    msIns := GetTickCount64 - t0;
    WriteLn('PERF tier=', NRows, ' insert ms=', msIns, ' rows_per_sec=',
      (Int64(NRows) * 1000) div (msIns + 1));

    fetched := bridge.FetchBatch(c, 'SELECT COUNT(*) FROM bench', 0, 10, 100);
    cntStr := string(fetched[0][0]);
    Ok('tier-' + IntToStr(NRows) + '-count', cntStr = IntToStr(NRows));

    t0 := GetTickCount64;
    off := 0; cnt := 0;
    while True do
    begin
      fetched := bridge.FetchBatch(c,
        'SELECT id, name, payload, qty FROM bench ORDER BY id LIMIT 1000 OFFSET ' +
        IntToStr(off), 0, 1000, 1000);
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
      fetched := bridge.FetchBatch(c,
        'SELECT id, name FROM bench ORDER BY id LIMIT 1000 OFFSET ' +
        IntToStr(off), 0, 1000, 1000);
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
    bridge.ExecUpdate(c, 'UPDATE bench SET qty=qty+1 WHERE id%2=0');
    msUpd := GetTickCount64 - t0;
    fetched := bridge.FetchBatch(c, 'SELECT SUM(qty) FROM bench', 0, 10, 100);
    sumStr := string(fetched[0][0]);
    want := IntToStr((Int64(NRows div 100) * 4950) + (NRows div 2));
    Ok('tier-' + IntToStr(NRows) + '-checksum', sumStr = want);
    WriteLn('PERF tier=', NRows, ' update ms=', msUpd, ' checksum=', sumStr);

    WriteLn('PERF tier=', NRows, ' fpc-peak-kb=', FpcPeakKB,
      ' heap-used=', bridge.HeapUsedBytes,
      ' heap-max=', bridge.HeapMaxBytes);
    bridge.ReleaseConnection(c);
  finally
    bridge.DestroyPool(pool);
  end;
  if FileExists(db) then
    DeleteFile(db);
end;

var
  classesDir, workDir: string;
  bridge: TBridgeClient;
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
  bridge := TBridgeClient.Create;
  try
    for tier := 1 to maxTier do
      case tier of
        1: RunTier(bridge, workDir, 10000);
        2: RunTier(bridge, workDir, 100000);
        3: RunTier(bridge, workDir, 1000000);
      end;
    WriteLn('PERF-REP rep=', rep, ' done');
  finally
    bridge.Free;
  end;
  TJVMManager.DetachThread;
  WriteLn('--- fails=', Fails);
  if Fails > 0 then
    Halt(1);
end.
