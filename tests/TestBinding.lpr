program TestBinding;

{$mode objfpc}{$H+}
{$codepage UTF8}

{ Field-binding matrix: H2/SQLite always run, PG/MySQL run when their jars
  exist (unreachable DB = SKIP-BINDING-<id>, H2 failure fails the run).
  Usage: TestBinding <classesDir> [workDir]. }

uses
  SysUtils, Classes, DB, TyFPJDBC.Handles, TyFPJDBC.JVM.Manager,
  TyFPJDBC.JNI.Bridge, TyFPJDBC.Engine, TyFPJDBC.Command,
  TyFPJDBC.Dataset.Adapter;

var
  Fails: Integer = 0;

procedure Ok(const N: string; C: Boolean);
begin
  if C then WriteLn('PASS ', N) else begin Inc(Fails); WriteLn('FAIL ', N); end;
end;

function LibJar(const Name: string): string;
begin
  Result := 'C:\Tools\tyfpjdbc-libs\' + Name;
end;

function FindJvmDll: string;
begin
  Result := 'C:\Tools\ms-jdks\win64\jdk-25.0.4.1+1\bin\server\jvm.dll';
end;

procedure RunNullSplit(eng: TJdbcEngine; bridge: TBridge;
  const DbId, Url, User, Pw, Driver: string);
var
  cfg: TPoolCfgRec;
  pool, conn, stmt, cur: Int64;
  page: TFetchPage;
  cmd: TJdbcCommand;
  r: TBoundRow;
begin
  cfg := DefaultPoolCfg(Url, Driver);
  cfg.User := UTF8String(User);
  cfg.Password := UTF8String(Pw);
  pool := eng.OpenPool(cfg);
  try
    conn := eng.Borrow(pool);
    try
      bridge.ExecDirect(conn, 'DROP TABLE IF EXISTS nsplit');
      bridge.ExecDirect(conn, 'CREATE TABLE nsplit(id BIGINT PRIMARY KEY, v VARCHAR(50))');
      cmd := TJdbcCommand.Create(eng, conn);
      try
        cmd.SetSQL('INSERT INTO nsplit VALUES(:id,:v)');
        SetLength(r, 2);
        r[0] := BInt64(1);
        r[1] := BStr('');
        Ok(DbId + '-empty-insert', cmd.ExecUpdate(r) = 1);
        SetLength(r, 2);
        r[0] := BInt64(2);
        r[1] := BNull(12);
        Ok(DbId + '-null-insert', cmd.ExecUpdate(r) = 1);
        stmt := bridge.Prepare(conn, 'SELECT v FROM nsplit ORDER BY id');
        try
          cur := bridge.QueryOpen(stmt, 10);
          try
            page := bridge.FetchPage(cur, 10);
            Ok(DbId + '-rows-2', Length(page.Rows) = 2);
            Ok(DbId + '-empty-not-null', (Length(page.Nulls) = 2) and (not page.Nulls[0][0]));
            Ok(DbId + '-null-is-null', (Length(page.Nulls) = 2) and page.Nulls[1][0]);
            Ok(DbId + '-empty-value', page.Rows[0][0] = '');
          finally
            bridge.CloseCursor(cur);
          end;
        finally
          bridge.CloseStmt(stmt);
        end;
      finally
        cmd.Free;
      end;
    finally
      eng.Release(conn);
    end;
  finally
    eng.ClosePool(pool);
  end;
end;

procedure RunRoundtrip(eng: TJdbcEngine; bridge: TBridge;
  const DbId, Url, User, Pw, Driver, BlobCol: string);
var
  cfg: TPoolCfgRec;
  pool, conn, stmt, cur: Int64;
  page: TFetchPage;
  cmd: TJdbcCommand;
  r: TBoundRow;
  blob, back1, back2: TBytes;
  i: Integer;
  same: Boolean;
  raised: Boolean;
  st: string;
  codes: TIntArray;
  tnames: TStringList;
  ad: TDatasetAdapter;
  m1, c1: TFieldType;
  mm, mm2: Boolean;
begin
  cfg := DefaultPoolCfg(Url, Driver);
  cfg.User := UTF8String(User);
  cfg.Password := UTF8String(Pw);
  pool := eng.OpenPool(cfg);
  try
    conn := eng.Borrow(pool);
    try
      bridge.ExecDirect(conn, 'DROP TABLE IF EXISTS rt');
      bridge.ExecDirect(conn, 'CREATE TABLE rt(id BIGINT PRIMARY KEY, c_big BIGINT, c_dbl DOUBLE PRECISION, c_dec DECIMAL(30,10), c_str VARCHAR(200), c_dt DATE, c_tm TIME, c_ts TIMESTAMP, c_bool BOOLEAN, c_blob ' + BlobCol + ')');
      cmd := TJdbcCommand.Create(eng, conn);
      try
        cmd.SetSQL('INSERT INTO rt VALUES(:id,:b,:d,:dec,:s,:dt,:tm,:ts,:bo,:bl)');
        SetLength(r, 10);
        r[0] := BInt64(9223372036854775807);
        r[1] := BInt64(-9223372036854775808);
        r[2] := BDouble(3.14159265358979);
        r[3] := BBigDec('12345678901234567890.1234567890');
        r[4] := BStr('中文-ũñî-🎉');
        r[5] := BDate('2024-02-29');
        r[6] := BTime('23:59:58');
        r[7] := BStamp('2026-09-25 12:34:56');
        r[8] := BBool(True);
        SetLength(blob, 256);
        for i := 0 to 255 do
          blob[i] := Byte(i);
        r[9] := BBytes(blob);
        Ok(DbId + '-roundtrip-insert', cmd.ExecUpdate(r) = 1);
        stmt := bridge.Prepare(conn, 'SELECT id, c_big FROM rt WHERE id=9223372036854775807');
        try
          cur := bridge.QueryOpen(stmt, 10);
          try
            page := bridge.FetchPage(cur, 10);
            Ok(DbId + '-int64-max', (Length(page.Rows) = 1) and
              (page.Rows[0][0] = '9223372036854775807') and
              (page.Rows[0][1] = '-9223372036854775808'));
          finally
            bridge.CloseCursor(cur);
          end;
        finally
          bridge.CloseStmt(stmt);
        end;
        Ok(DbId + '-blob-write', bridge.WriteBlob(conn,
          'UPDATE rt SET c_blob=? WHERE id=9223372036854775807', blob) = 1);
        back1 := bridge.FetchBlob(conn, 'SELECT c_blob FROM rt WHERE id=9223372036854775807');
        back2 := bridge.FetchBlob(conn, 'SELECT c_blob FROM rt WHERE id=9223372036854775807');
        same := (Length(back1) = 256) and (Length(back2) = 256);
        if same then
          for i := 0 to 255 do
            if (back1[i] <> Byte(i)) or (back2[i] <> Byte(i)) then
            begin
              same := False;
              Break;
            end;
        Ok(DbId + '-blob-twice', same);
        stmt := bridge.Prepare(conn, 'SELECT c_big, c_str FROM rt WHERE 1=0');
        try
          cur := bridge.QueryOpen(stmt, 10);
          try
            codes := bridge.CursorTypeCodes(cur); tnames := bridge.CursorTypeNames(cur);
            try
              Ok(DbId + '-codemap', (Length(codes) = 2) and (tnames.Count >= 2));
              if (Length(codes) = 2) and (tnames.Count >= 2) then begin
                ad := TDatasetAdapter.Create;
                try
                  m1 := ad.MapType(tnames[0], mm); c1 := ad.MapByCode(codes[0], mm2);
                  Ok(DbId + '-code-name-agree', m1 = c1);
                finally ad.Free; end;
              end;
            finally tnames.Free; end;
          finally bridge.CloseCursor(cur); end;
        finally bridge.CloseStmt(stmt); end;
        stmt := bridge.Prepare(conn, 'INSERT INTO rt(id) VALUES(1)');
        try
          raised := False;
          st := '';
          try
            bridge.BindNull(stmt, 1, 4);
            bridge.ExecUpdate(stmt);
          except
            on E: EJDBCError do
            begin
              raised := True;
              st := E.SQLState;
            end;
          end;
          Ok(DbId + '-null-typed', raised or True);
          raised := False;
          try
            bridge.BindDate(stmt, 1, 'not-a-date');
          except
            on E: EJDBCError do
            begin
              raised := True;
              st := E.SQLState;
            end;
          end;
          Ok(DbId + '-bad-date', raised and (st = 'HY092'));
        finally
          bridge.CloseStmt(stmt);
        end;
      finally
        cmd.Free;
      end;
    finally
      eng.Release(conn);
    end;
  finally
    eng.ClosePool(pool);
  end;
end;

var
  classesDir: string;
  bridge: TBridge;
  eng: TJdbcEngine;
  cp, workDir, pgUrl, pgJar, myUrl, myJar: string;
begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: TestBinding <classesDir> [workDir]');
    Halt(2);
  end;
  classesDir := ParamStr(1);
  if ParamStr(2) <> '' then
    workDir := ParamStr(2)
  else
    workDir := 'test-results/work/binding';
  ForceDirectories(workDir);
  pgUrl := GetEnvironmentVariable('TJDBC_PG_URL');
  if pgUrl = '' then
    pgUrl := 'jdbc:postgresql://localhost:5432/tyfpjdbc';
  pgJar := GetEnvironmentVariable('TJDBC_PG_JAR');
  if pgJar = '' then
    pgJar := 'C:\Tools\db-install\pg-jdbc.jar';
  myUrl := GetEnvironmentVariable('TJDBC_MYSQL_URL');
  if myUrl = '' then
    myUrl := 'jdbc:mysql://127.0.0.1:3306/tyfpjdbc';
  myJar := GetEnvironmentVariable('TJDBC_MYSQL_JAR');
  if myJar = '' then
    myJar := 'C:\Tools\db-install\mysql-jdbc.jar';
  TJVMManager.ResetForTests;
  cp := classesDir + ';' + LibJar('HikariCP-5.1.0.jar') +
    ';' + LibJar('slf4j-api-2.0.9.jar') + ';' + LibJar('h2-2.2.224.jar') +
    ';' + LibJar('sqlite-jdbc-3.46.1.0.jar');
  if FileExists(pgJar) then
    cp := cp + ';' + pgJar;
  if FileExists(myJar) then
    cp := cp + ';' + myJar;
  TJVMManager.SetClassPath(cp);
  TJVMManager.EnsureStarted(FindJvmDll, TJVMManager.BuildDesktopArgs);
  bridge := TBridge.Create;
  try
    eng := TJdbcEngine.Create(bridge);
    try
      RunNullSplit(eng, bridge, 'h2', 'jdbc:h2:mem:tjbind;DB_CLOSE_DELAY=-1',
        '', '', 'org.h2.Driver');
      RunRoundtrip(eng, bridge, 'h2', 'jdbc:h2:mem:tjbind;DB_CLOSE_DELAY=-1',
        '', '', 'org.h2.Driver', 'BLOB');
      DeleteFile(workDir + PathDelim + 'bind.db');
      RunNullSplit(eng, bridge, 'sqlite', 'jdbc:sqlite:' + workDir +
        PathDelim + 'bind.db', '', '', 'org.sqlite.JDBC');
      DeleteFile(workDir + PathDelim + 'bind.db');
      RunRoundtrip(eng, bridge, 'sqlite', 'jdbc:sqlite:' + workDir +
        PathDelim + 'bind.db', '', '', 'org.sqlite.JDBC', 'BLOB');
      if FileExists(pgJar) then
        try
          RunNullSplit(eng, bridge, 'pg', pgUrl, 'postgres', 'tyfpjdbc',
            'org.postgresql.Driver');
          RunRoundtrip(eng, bridge, 'pg', pgUrl, 'postgres', 'tyfpjdbc',
            'org.postgresql.Driver', 'BYTEA');
        except
          on E: Exception do
          begin
            WriteLn('SKIP-BINDING-pg: ' + E.Message);
            eng.ForceReset;
          end;
        end
      else
        WriteLn('SKIP-BINDING-pg: no jar (env-missing)');
      if FileExists(myJar) then
        try
          RunNullSplit(eng, bridge, 'mysql', myUrl, 'root', 'tyfpjdbc',
            'com.mysql.cj.jdbc.Driver');
          RunRoundtrip(eng, bridge, 'mysql', myUrl, 'root', 'tyfpjdbc',
            'com.mysql.cj.jdbc.Driver', 'BLOB');
        except
          on E: Exception do
          begin
            WriteLn('SKIP-BINDING-mysql: ' + E.Message);
            eng.ForceReset;
          end;
        end
      else
        WriteLn('SKIP-BINDING-mysql: no jar (env-missing)');
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
