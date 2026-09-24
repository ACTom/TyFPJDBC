program TestLiveBridge;

{$mode objfpc}{$H+}
{$codepage UTF8}

{ Live end-to-end through the SHIPPED units, no simulation:
  TJVMManager (real JNI_CreateJavaVM) -> TBridgeClient (real JNI calls
  into tyfpjdbc.Bridge) -> HikariCP -> sqlite-jdbc file DB / H2.
  Covers: version handshake, SELECT 1, Chinese roundtrip, paged fetch,
  ApplyUpdates inserts + edits landing in the same real table with re-read,
  tx commit/rollback/savepoint, BLOB bytes, error chain, 10k bulk,
  pool stats, concurrent borrow, cancel, query timeout, heap peaks. }

uses
  SysUtils, Classes, DB, TyFPJDBC.JVM.Manager, TyFPJDBC.JNI.Bridge,
  TyFPJDBC.Connection, TyFPJDBC.Query;

var
  Fails: Integer = 0;

procedure Ok(const N: string; C: Boolean);
begin
  if C then WriteLn('PASS ', N) else begin Inc(Fails); WriteLn('FAIL ', N); end;
end;

function ExeDir: string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
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

type
  TWorkThread = class(TThread)
    Bridge: TBridgeClient;
    Pool: Int64;
    OkFlag: Boolean;
    ErrMsg: string;
    procedure Execute; override;
  end;

procedure TWorkThread.Execute;
var
  c: Int64;
  rows: TJavaRows;
begin
  try
    c := Bridge.BorrowConnection(Pool);
    try
      rows := Bridge.FetchBatch(c, 'SELECT 1', 0, 10, 100);
      OkFlag := (Length(rows) = 1) and (rows[0][0] = '1');
    finally
      Bridge.ReleaseConnection(c);
    end;
  except
    on E: Exception do
    begin
      OkFlag := False;
      ErrMsg := E.Message;
    end;
  end;
end;

type
  TCancelThread = class(TThread)
    Bridge: TBridgeClient;
    Conn: Int64;
    Done: Boolean;
    GotError: Boolean;
    GotMsg: string;
    procedure Execute; override;
  end;

procedure TCancelThread.Execute;
var
  rows: TJavaRows;
begin
  try
    rows := Bridge.FetchBatch(Conn,
      'SELECT COUNT(*) FROM SYSTEM_RANGE(1,200000) A, SYSTEM_RANGE(1,200) B',
      0, 5, 100);
    GotError := False;
    GotMsg := 'completed rows=' + IntToStr(Length(rows));
  except
    on E: Exception do
    begin
      GotError := True;
      GotMsg := E.Message;
    end;
  end;
  Done := True;
end;

var
  bridge: TBridgeClient;
  classesDir, workDir, dbPath, h2tag: string;
  pool, c, c2, hpool, hc: Int64;
  rows: TJavaRows;
  batch: TJavaRows;
  nulls: TJavaNulls;
  i, off, total, maxPage, n: Integer;
  q: TJDBCQuery;
  blob, back: TBytes;
  t0: Int64;
  th1, th2: TWorkThread;
  cth: TCancelThread;
  raised: Boolean;
  chain: string;
  waited: Int64;
begin
  if ParamStr(1) <> '' then
    classesDir := ParamStr(1)
  else
    classesDir := ExpandFileName(ExeDir + '..' + PathDelim + 'work' +
      PathDelim + 'jmain');
  if ParamStr(2) <> '' then
    workDir := ParamStr(2)
  else
    workDir := ExpandFileName(ExeDir + '..' + PathDelim + 'work');
  if not DirectoryExists(classesDir + PathDelim + 'tyfpjdbc') then
    raise Exception.Create('bridge classes missing: ' + classesDir);
  ForceDirectories(workDir);
  dbPath := workDir + PathDelim + 'live-' + IntToStr(GetProcessID) + '.db';
  if FileExists(dbPath) then
    DeleteFile(dbPath);

  TJVMManager.ResetForTests;
  TJVMManager.SetClassPath(classesDir + ';' + LibJar('HikariCP-5.1.0.jar') +
    ';' + LibJar('slf4j-api-2.0.9.jar') + ';' + LibJar('h2-2.2.224.jar') +
    ';' + LibJar('sqlite-jdbc-3.46.1.0.jar'));
  TJVMManager.EnsureStarted(FindJvmDll, TJVMManager.BuildDesktopArgs);
  Ok('jvm-started', TJVMManager.IsStarted);
  TJVMManager.AttachThread;
  Ok('attach-count', TJVMManager.AttachedCount = 1);

  bridge := TBridgeClient.Create;
  try
    Ok('version', bridge.GetVersion = '1.0.0');

    pool := bridge.CreatePool('jdbc:sqlite:' + dbPath, '', '', 4, 1);
    Ok('pool-created', pool > 0);
    c := bridge.BorrowConnection(pool);
    c2 := bridge.BorrowConnection(pool);
    Ok('distinct-conns', c <> c2);
    Ok('stats', Pos('active=', bridge.PoolStats(pool)) > 0);
    bridge.ReleaseConnection(c2);

    rows := bridge.FetchBatch(c, 'SELECT 1', 0, 10, 100);
    Ok('select-1', (Length(rows) = 1) and (rows[0][0] = '1'));

    Ok('ddl', bridge.ExecUpdate(c,
      'CREATE TABLE live_t(id INTEGER PRIMARY KEY, name TEXT)') = 0);
    SetLength(batch, 3);
    SetLength(nulls, 3);
    batch[0] := TJavaRow.Create('1', 'hello');
    batch[1] := TJavaRow.Create('2', '中文测试');
    batch[2] := TJavaRow.Create('3', 'jdbc-bridge');
    for i := 0 to 2 do
      nulls[i] := TJavaNullRow.Create(False, False);
    Ok('batch-3', bridge.ExecBatch(c,
      'INSERT INTO live_t VALUES(?,?)', batch, nulls) = 3);
    rows := bridge.FetchBatch(c, 'SELECT id,name FROM live_t ORDER BY id',
      0, 10, 100);
    Ok('chinese-verbatim', (Length(rows) = 3) and (rows[1][1] = UTF8String('中文测试')));

    Ok('ddl-big', bridge.ExecUpdate(c,
      'CREATE TABLE page_t(id INTEGER PRIMARY KEY, name TEXT)') = 0);
    SetLength(batch, 2500);
    SetLength(nulls, 2500);
    for i := 0 to 2499 do
    begin
      batch[i] := TJavaRow.Create(IntToStr(i + 1), 'row-' + IntToStr(i + 1));
      nulls[i] := TJavaNullRow.Create(False, False);
    end;
    Ok('batch-2500', bridge.ExecBatch(c,
      'INSERT INTO page_t VALUES(?,?)', batch, nulls) = 2500);
    off := 0; total := 0; maxPage := 0;
    while True do
    begin
      rows := bridge.FetchBatch(c,
        'SELECT id,name FROM page_t ORDER BY id LIMIT 1000 OFFSET ' +
        IntToStr(off), 0, 1000, 1000);
      if Length(rows) = 0 then
        Break;
      if Length(rows) > maxPage then
        maxPage := Length(rows);
      Inc(total, Length(rows));
      Inc(off, Length(rows));
    end;
    Ok('paged-total', total = 2500);
    Ok('paged-bounded', maxPage <= 1000);

    q := TJDBCQuery.Create(nil);
    try
      q.LoadRowsLive(bridge, c, 'live_t',
        'SELECT id,name FROM live_t ORDER BY id',
        ['id', 'name'], ['INTEGER', 'NVARCHAR']);
      Ok('live-load', q.RecordCount = 3);
      q.CachedUpdates := True;
      q.UpdateOptions.ReadOnly := False;
      q.UpdateOptions.AutoIncField := 'id';
      q.UpdateOptions.KeyFields := 'id';
      q.Append;
      q.FieldFromUTF8(q.Fields[1], '新增一');
      q.Post;
      q.Append;
      q.FieldFromUTF8(q.Fields[1], '新增二');
      q.Post;
      Ok('live-pending', q.PendingInserts = 2);
      q.ApplyUpdates;
      Ok('live-applied', (q.AppliedInserts = 2) and (q.PendingInserts = 0));
      Ok('live-genkey', q.GetGeneratedKeys = 1001);
      rows := bridge.FetchBatch(c,
        'SELECT id,name FROM live_t WHERE id>=1000 ORDER BY id', 0, 10, 100);
      Ok('live-reread', (Length(rows) = 2) and (rows[0][0] = '1000') and
        (rows[0][1] = UTF8String('新增一')) and (rows[1][1] = UTF8String('新增二')));
      q.First;
      q.Edit;
      q.FieldFromUTF8(q.Fields[1], '改名');
      q.Post;
      q.ApplyUpdates;
      rows := bridge.FetchBatch(c,
        'SELECT name FROM live_t WHERE id=1', 0, 10, 100);
      Ok('live-edit', (Length(rows) = 1) and (rows[0][0] = UTF8String('改名')));
    finally
      q.Free;
    end;

    bridge.SetAutoCommit(c, False);
    bridge.ExecUpdate(c, 'INSERT INTO live_t VALUES(9000,''tx'')');
    bridge.Rollback(c);
    rows := bridge.FetchBatch(c,
      'SELECT COUNT(*) FROM live_t WHERE id=9000', 0, 10, 100);
    Ok('tx-rollback', rows[0][0] = '0');
    bridge.ExecUpdate(c, 'INSERT INTO live_t VALUES(9000,''tx'')');
    bridge.Commit(c);
    rows := bridge.FetchBatch(c,
      'SELECT COUNT(*) FROM live_t WHERE id=9000', 0, 10, 100);
    Ok('tx-commit', rows[0][0] = '1');
    bridge.Savepoint(c, 'sp1');
    bridge.ExecUpdate(c, 'INSERT INTO live_t VALUES(9001,''sp'')');
    bridge.RollbackToSavepoint(c, 'sp1');
    bridge.ReleaseSavepoint(c, 'sp1');
    bridge.Commit(c);
    rows := bridge.FetchBatch(c,
      'SELECT COUNT(*) FROM live_t WHERE id=9001', 0, 10, 100);
    Ok('tx-savepoint', rows[0][0] = '0');
    bridge.SetAutoCommit(c, True);

    Ok('ddl-blob', bridge.ExecUpdate(c,
      'CREATE TABLE blob_t(id INTEGER PRIMARY KEY, data BLOB)') = 0);
    SetLength(blob, 256);
    for i := 0 to 255 do
      blob[i] := Byte(i);
    Ok('blob-write', bridge.WriteBlob(c,
      'INSERT INTO blob_t VALUES(1,?)', blob) = 1);
    back := bridge.FetchBlob(c, 'SELECT data FROM blob_t WHERE id=1');
    Ok('blob-len', Length(back) = 256);
    n := 0;
    for i := 0 to 255 do
      if back[i] <> Byte(i) then
        Inc(n);
    Ok('blob-bytes', n = 0);
    SetLength(blob, 0);
    Ok('blob-empty', bridge.WriteBlob(c,
      'INSERT INTO blob_t VALUES(2,?)', blob) = 1);
    back := bridge.FetchBlob(c, 'SELECT data FROM blob_t WHERE id=2');
    Ok('blob-empty-back', Length(back) = 0);

    raised := False;
    try
      bridge.ExecUpdate(c, 'SELECT * FROM no_such_table_xyz');
    except
      on E: EJDBCError do
        raised := True;
    end;
    Ok('bad-sql-raises', raised);
    chain := bridge.GetErrorChain;
    Ok('error-chain', chain <> '');

    Ok('ddl-bulk', bridge.ExecUpdate(c,
      'CREATE TABLE bulk_t(id INTEGER PRIMARY KEY, name TEXT)') = 0);
    SetLength(batch, 10000);
    SetLength(nulls, 10000);
    for i := 0 to 9999 do
    begin
      batch[i] := TJavaRow.Create(IntToStr(i + 1), 'b-' + IntToStr(i + 1));
      nulls[i] := TJavaNullRow.Create(False, False);
    end;
    t0 := GetTickCount64;
    Ok('bulk-10k', bridge.ExecBatch(c,
      'INSERT INTO bulk_t VALUES(?,?)', batch, nulls) = 10000);
    WriteLn('PERF live-bulk-10k ms=', GetTickCount64 - t0);
    rows := bridge.FetchBatch(c, 'SELECT COUNT(*) FROM bulk_t', 0, 10, 100);
    Ok('bulk-count', rows[0][0] = '10000');

    Ok('heap-used', bridge.HeapUsedBytes > 0);
    Ok('heap-max', bridge.HeapMaxBytes > 0);
    WriteLn('PERF heap-used=', bridge.HeapUsedBytes,
      ' heap-max=', bridge.HeapMaxBytes);

    th1 := TWorkThread.Create(True);
    th2 := TWorkThread.Create(True);
    th1.Bridge := bridge;
    th1.Pool := pool;
    th2.Bridge := bridge;
    th2.Pool := pool;
    th1.Start;
    th2.Start;
    th1.WaitFor;
    th2.WaitFor;
    Ok('concurrent-1', th1.OkFlag);
    Ok('concurrent-2', th2.OkFlag);
    th1.Free;
    th2.Free;

    h2tag := IntToStr(GetTickCount64);
    hpool := bridge.CreatePool('jdbc:h2:mem:live' + h2tag +
      ';DB_CLOSE_DELAY=-1', 'sa', '', 4, 1);
    hc := bridge.BorrowConnection(hpool);
    try
      cth := TCancelThread.Create(True);
      cth.Bridge := bridge;
      cth.Conn := hc;
      cth.Start;
      Sleep(800);
      bridge.Cancel(hc);
      waited := GetTickCount64;
      while (not cth.Done) and (GetTickCount64 - waited < 30000) do
        Sleep(100);
      Ok('cancel-done', cth.Done);
      Ok('cancel-raised', cth.GotError);
      WriteLn('cancel-msg=', Copy(cth.GotMsg, 1, 120));
      cth.Free;
      raised := False;
      try
        bridge.ExecUpdateTimeout(hc,
          'CREATE TABLE tmo AS SELECT A.X AS a, B.X AS b FROM ' +
          'SYSTEM_RANGE(1,300000) A, SYSTEM_RANGE(1,300) B', 2);
      except
        on E: EJDBCError do
          raised := True;
      end;
      Ok('timeout-raised', raised);
      try
        bridge.ExecUpdate(hc, 'DROP TABLE IF EXISTS tmo');
      except
      end;
    finally
      bridge.ReleaseConnection(hc);
      bridge.DestroyPool(hpool);
    end;

    bridge.ReleaseConnection(c);
    bridge.DestroyPool(pool);
  finally
    bridge.Free;
  end;
  TJVMManager.DetachThread;
  Ok('detach-count', TJVMManager.AttachedCount = 0);
  if FileExists(dbPath) then
    DeleteFile(dbPath);

  WriteLn('--- fails=', Fails);
  if Fails > 0 then
    Halt(1);
end.
