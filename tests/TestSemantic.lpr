program TestSemantic;

{$mode objfpc}{$H+}
{$codepage UTF8}

{ Per-database semantic baseline: paging executes, generated keys reread,
  identifier case-folding observed, timeout attribute harmless, error states
  sampled. H2 + SQLite always run; PG runs when TJDBC_PG_URL/TJDBC_PG_JAR
  are set; MySQL when TJDBC_MYSQL_URL/TJDBC_MYSQL_JAR are set. Every probe
  writes test-results/work/semantic/baseline-<dbid>.txt.
  Usage: TestSemantic <classesDir> [workDir]. }

uses
  SysUtils, Classes, TyFPJDBC.Handles, TyFPJDBC.JVM.Manager,
  TyFPJDBC.JNI.Bridge, TyFPJDBC.Engine, TyFPJDBC.Command;

var
  Fails: Integer = 0;
  WorkDir: string;

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

procedure WriteBaseline(const DbId, Name, Got: string);
var
  f: TextFile;
begin
  ForceDirectories(WorkDir);
  AssignFile(f, WorkDir + PathDelim + 'baseline-' + DbId + '.txt');
  if FileExists(WorkDir + PathDelim + 'baseline-' + DbId + '.txt') then
    Append(f)
  else
    Rewrite(f);
  try
    WriteLn(f, Name + '=' + Got);
  finally
    CloseFile(f);
  end;
end;

function BaselineLines(const DbId: string): Integer;
var
  sl: TStringList;
begin
  sl := TStringList.Create;
  try
    sl.LoadFromFile(WorkDir + PathDelim + 'baseline-' + DbId + '.txt');
    Result := sl.Count;
  finally
    sl.Free;
  end;
end;

function FetchValue(bridge: TBridge; conn: Int64; const SQL: string): string;
var
  stmt, cur: Int64;
  rows: TJdbcRows;
begin
  Result := '';
  stmt := bridge.Prepare(conn, SQL);
  try
    cur := bridge.QueryOpen(stmt, 10);
    try
      rows := bridge.FetchWindow(cur, 10);
      if Length(rows) = 1 then
        Result := string(rows[0][0]);
    finally
      bridge.CloseCursor(cur);
    end;
  finally
    bridge.CloseStmt(stmt);
  end;
end;

procedure RunSemantic(eng: TJdbcEngine; bridge: TBridge;
  const DbId, Url, User, Pw, DriverClass, DdlAuto: string);
var
  cfg: TPoolCfgRec;
  pool, conn, stmt, cur: Int64;
  cmd: TJdbcCommand;
  r: TBoundRow;
  rows: TJdbcRows;
  keys, keys2: TJdbcRow;
  tabs: TJdbcRows;
  i: Integer;
  names: string;
  errState: string;
begin
  if FileExists(WorkDir + PathDelim + 'baseline-' + DbId + '.txt') then
    DeleteFile(WorkDir + PathDelim + 'baseline-' + DbId + '.txt');
  cfg := DefaultPoolCfg(Url, DriverClass);
  cfg.User := UTF8String(User);
  cfg.Password := UTF8String(Pw);
  pool := eng.OpenPool(cfg);
  conn := eng.Borrow(pool);

  { Paging executes with real rows back. }
  bridge.ExecDirect(conn, 'CREATE TABLE sem(id BIGINT PRIMARY KEY, v VARCHAR(20))');
  cmd := TJdbcCommand.Create(eng, conn);
  try
    cmd.SetSQL('INSERT INTO sem VALUES(:id,:v)');
    for i := 1 to 5 do
    begin
      SetLength(r, 2);
      r[0] := BInt64(i);
      r[1] := BStr('r' + IntToStr(i));
      cmd.ExecUpdate(r);
    end;
  finally
    cmd.Free;
  end;
  stmt := bridge.Prepare(conn, 'SELECT id FROM sem ORDER BY id LIMIT 2 OFFSET 1');
  try
    cur := bridge.QueryOpen(stmt, 10);
    try
      rows := bridge.FetchWindow(cur, 10);
      Ok(DbId + '-paging', (Length(rows) = 2) and (rows[0][0] = '2') and
        (rows[1][0] = '3'));
      WriteBaseline(DbId, 'paging-2-offset-1', rows[0][0] + ',' + rows[1][0]);
    finally
      bridge.CloseCursor(cur);
    end;
  finally
    bridge.CloseStmt(stmt);
  end;

  { Generated keys reread identically. }
  bridge.ExecDirect(conn, 'CREATE TABLE semkeys(id ' + DdlAuto +
    ', name VARCHAR(50))');
  cmd := TJdbcCommand.Create(eng, conn);
  try
    cmd.SetSQL('INSERT INTO semkeys(name) VALUES(:name)');
    SetLength(r, 1);
    r[0] := BStr('g1');
    Ok(DbId + '-genkeys-insert', cmd.ExecUpdate(r) = 1);
    keys := cmd.LastInsertKeys;
    Ok(DbId + '-genkeys-shape', (Length(keys) >= 1) and
      (Trim(string(keys[0])) <> ''));
    r[0] := BStr('g2');
    cmd.ExecUpdate(r);
    keys2 := cmd.LastInsertKeys;
    Ok(DbId + '-genkeys-reread',
      (FetchValue(bridge, conn, 'SELECT name FROM semkeys WHERE id=' +
      string(keys[0])) = 'g1') and (FetchValue(bridge, conn,
      'SELECT name FROM semkeys WHERE id=' + string(keys2[0])) = 'g2'));
    WriteBaseline(DbId, 'genkeys', string(keys[0]) + ',' + string(keys2[0]));
  finally
    cmd.Free;
  end;

  { Case folding observed (not forced equal across vendors). }
  bridge.ExecDirect(conn, 'CREATE TABLE SemFold(id INT PRIMARY KEY, v VARCHAR(20))');
  bridge.ExecDirect(conn, 'INSERT INTO SemFold VALUES(1,''x'')');
  tabs := bridge.GetTables(conn, '%');
  names := '';
  for i := 0 to High(tabs) do
    if (Length(tabs[i]) > 0) and (Pos('FOLD', UpperCase(tabs[i][0])) > 0) then
      names := names + tabs[i][0] + ',';
  WriteBaseline(DbId, 'fold-observed', names);
  Ok(DbId + '-fold-readable', FetchValue(bridge, conn,
    'SELECT v FROM SemFold WHERE id=1') = 'x');

  { Timeout attribute accepted and harmless on a trivial query. }
  stmt := bridge.Prepare(conn, 'SELECT 1');
  try
    bridge.SetTimeout(stmt, 5);
    cur := bridge.QueryOpen(stmt, 10);
    try
      rows := bridge.FetchWindow(cur, 10);
      Ok(DbId + '-timeout-harmless', (Length(rows) = 1) and (rows[0][0] = '1'));
      WriteBaseline(DbId, 'timeout-attr', 'accepted');
    finally
      bridge.CloseCursor(cur);
    end;
  finally
    bridge.CloseStmt(stmt);
  end;

  { Error state sampled from a genuinely bad statement. }
  errState := '';
  try
    bridge.ExecDirect(conn, 'SELECT * FROM no_such_table_xyz');
  except
    on E: EJDBCError do
      errState := E.SQLState;
  end;
  Ok(DbId + '-error-sampled', errState <> '');
  WriteBaseline(DbId, 'error-state', errState);

  eng.Release(conn);
  eng.ClosePool(pool);
  Ok(DbId + '-baseline', BaselineLines(DbId) >= 5);
end;

var
  classesDir: string;
  bridge: TBridge;
  eng: TJdbcEngine;
  cp, pgUrl, pgJar, myUrl, myJar: string;
begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: TestSemantic <classesDir> [workDir]');
    Halt(2);
  end;
  classesDir := ParamStr(1);
  if ParamStr(2) <> '' then
    WorkDir := ParamStr(2)
  else
    WorkDir := 'test-results/work/semantic';
  pgUrl := GetEnvironmentVariable('TJDBC_PG_URL');
  pgJar := GetEnvironmentVariable('TJDBC_PG_JAR');
  myUrl := GetEnvironmentVariable('TJDBC_MYSQL_URL');
  myJar := GetEnvironmentVariable('TJDBC_MYSQL_JAR');
  TJVMManager.ResetForTests;
  cp := classesDir + ';' + LibJar('HikariCP-5.1.0.jar') +
    ';' + LibJar('slf4j-api-2.0.9.jar') + ';' + LibJar('h2-2.2.224.jar') +
    ';' + LibJar('sqlite-jdbc-3.46.1.0.jar');
  if (pgUrl <> '') and FileExists(pgJar) then
    cp := cp + ';' + pgJar;
  if (myUrl <> '') and FileExists(myJar) then
    cp := cp + ';' + myJar;
  TJVMManager.SetClassPath(cp);
  TJVMManager.EnsureStarted(FindJvmDll, TJVMManager.BuildDesktopArgs);
  bridge := TBridge.Create;
  try
    eng := TJdbcEngine.Create(bridge);
    try
      RunSemantic(eng, bridge, 'h2', 'jdbc:h2:mem:tjsem;DB_CLOSE_DELAY=-1',
        '', '', 'org.h2.Driver', 'BIGINT AUTO_INCREMENT PRIMARY KEY');
      ForceDirectories(WorkDir);
      RunSemantic(eng, bridge, 'sqlite', 'jdbc:sqlite:' + WorkDir +
        PathDelim + 'sem.db', '', '', 'org.sqlite.JDBC',
        'INTEGER PRIMARY KEY AUTOINCREMENT');
      if (pgUrl <> '') and FileExists(pgJar) then
        RunSemantic(eng, bridge, 'pg', pgUrl, 'postgres', 'tyfpjdbc',
          'org.postgresql.Driver', 'SERIAL PRIMARY KEY')
      else
        WriteLn('SKIP-SEMANTIC: pg no server (env-missing)');
      if (myUrl <> '') and FileExists(myJar) then
        RunSemantic(eng, bridge, 'mysql', myUrl, 'root', 'tyfpjdbc',
          'com.mysql.cj.jdbc.Driver', 'BIGINT AUTO_INCREMENT PRIMARY KEY')
      else
        WriteLn('SKIP-SEMANTIC: mysql no server (env-missing)');
      Ok('handles-zero', eng.HandleCount = 0);
      Ok('audit-zero', eng.AuditReport = 'pools=0 conns=0 stmts=0 cursors=0');
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
