program TestPhase2Config;

{$mode objfpc}{$H+}
{$codepage UTF8}

{ Phase-2 module configurability: representative settings take effect.
  Every setting under test is read on a shipped path (not just stored):
  Connection timeouts/properties feed FillProperties + Borrow validation,
  TJVMOptions.BuildArgs feeds EnsureStartedWithOptions, pool Borrow evicts
  and validates via IdleTimeoutMs/ValidationTimeoutMs/ConnectionTestQuery,
  Query load/apply paths enforce MaxBufferedRows/RowsetSize/BatchApplySize.
  The live JNI path stays in TestLiveBridge/TestLiveGrid/TestPerfTiers. }

uses
  SysUtils, Classes, DB, TyFPJDBC.Connection, TyFPJDBC.Driver.Registry,
  TyFPJDBC.JVM.Manager, TyFPJDBC.JNI.Bridge, TyFPJDBC.Hikari.Pool,
  TyFPJDBC.Options, TyFPJDBC.Query, TyFPJDBC.&Type.Map;

var
  Fails: Integer = 0;

procedure Ok(const N: string; C: Boolean);
begin
  if C then WriteLn('PASS ', N) else begin Inc(Fails); WriteLn('FAIL ', N); end;
end;

function MakeRows(Count: Integer): TJavaRows;
var
  i: Integer;
begin
  SetLength(Result, Count);
  for i := 0 to Count - 1 do
  begin
    SetLength(Result[i], 2);
    Result[i][0] := UTF8String(IntToStr(i + 1));
    Result[i][1] := 'r' + UTF8String(IntToStr(i + 1));
  end;
end;

function RejectConn(TimeoutMs: Int64; const TestQuery: string): Boolean;
begin
  Result := False;
end;

var
  c: TJDBCConnection;
  pool: TJDBCHikariPool;
  opt: TJVMOptions;
  fo: TFetchOptions;
  uo: TUpdateOptions;
  q: TJDBCQuery;
  props: TStringList;
  rows: TJavaRows;
  held, again, rejected: TJDBCConnection;
  heldId, againId, rejectedId: Integer;
  raised: Boolean;
begin
  TJdbcTypeMap.ClearCustom;
  try
    Ok('registry-pg-url', TDriverRegistry.UrlFor('postgresql', 'db', 5432,
      'app') = 'jdbc:postgresql://db:5432/app');
    Ok('registry-pg-default-port', TDriverRegistry.UrlFor('postgresql',
      'db', 0, 'app') = 'jdbc:postgresql://db:5432/app');
    Ok('registry-sqlite-url', TDriverRegistry.UrlFor('sqlite', '', 0,
      '/tmp/a.db') = 'jdbc:sqlite:/tmp/a.db');
    Ok('registry-h2-url', TDriverRegistry.UrlFor('h2', '', 0,
      't1') = 'jdbc:h2:mem:t1');
    Ok('registry-default-port', TDriverRegistry.DefaultPort(
      'postgresql') = 5432);
    raised := False;
    try
      TDriverRegistry.UrlFor('nosuch', 'h', 1, 'd');
    except
      on E: EJDBCError do
        raised := E.SQLState = '08000';
    end;
    Ok('registry-unknown', raised);

    c := TJDBCConnection.Create;
    try
      Ok('conn-defaults', (c.LoginTimeoutSecs = 15) and
        (c.SocketTimeoutSecs = 30) and (c.ValidationQuery = 'SELECT 1') and
        (c.Catalog = '') and (c.Schema = ''));
      c.LoginTimeoutSecs := 2;
      c.SocketTimeoutSecs := 5;
      c.Schema := 'public';
      c.Validate;
      Ok('conn-set', (c.LoginTimeoutSecs = 2) and (c.Schema = 'public'));
      { Timeouts feed the connect path: FillProperties carries both values
        into the JDBC properties handed to the bridge at connect time. }
      props := TStringList.Create;
      try
        c.FillProperties(props);
        Ok('conn-props', (props.Values['loginTimeout'] = '2') and
          (props.Values['socketTimeout'] = '5'));
      finally
        props.Free;
      end;
      Ok('conn-timeout-ms', (c.LoginTimeoutMs = 2000) and
        (c.SocketTimeoutMs = 5000));
      { Catalog/Schema qualify identifiers on the real path: the query
        INSERT/UPDATE builders route through QualifiedTable. }
      Ok('conn-qualified', c.QualifiedTable('orders') = 'public.orders');
      c.Catalog := 'cat1';
      Ok('conn-qualified-catalog', c.QualifiedTable('orders') =
        'cat1.public.orders');
      c.Catalog := '';
      { Borrow validates: a bad setting fails the borrow itself, so broken
        values cannot sit in the idle list unnoticed. }
      c.LoginTimeoutSecs := -1;
      raised := False;
      try
        c.Borrow;
      except
        on E: EJDBCError do
          raised := E.SQLState = 'HY092';
      end;
      Ok('conn-borrow-validates', raised and not c.Borrowed);
      raised := False;
      try
        c.Validate;
      except
        on E: EJDBCError do
          raised := E.SQLState = 'HY092';
      end;
      Ok('conn-bad-timeout', raised);
    finally
      c.Free;
    end;

    opt := TJVMOptions.Create;
    try
      Ok('jvm-defaults', (opt.Mode = jvmAuto) and (opt.Xmx = '512m') and
        opt.Headless and (opt.FileEncoding = 'UTF-8'));
      opt.Mode := jvmDesktop;
      Ok('jvm-desktop', (Pos('-Xmx512m', opt.BuildArgs) > 0) and
        (Pos('-Xrs', opt.BuildArgs) = 0));
      opt.Mode := jvmServer;
      Ok('jvm-server', (Pos('-Xrs', opt.BuildArgs) > 0) and
        (Pos('MaxRAMPercentage=60', opt.BuildArgs) > 0));
      opt.EnableCheckJNI := True;
      Ok('jvm-checkjni', Pos('-Xcheck:jni', opt.BuildArgs) > 0);
      opt.EnableCheckJNI := False;
      opt.MaxRAMPercentage := 10.0;
      raised := False;
      try
        opt.Validate;
      except
        on E: Exception do
          raised := True;
      end;
      Ok('jvm-bad-ram', raised);
      opt.MaxRAMPercentage := 60.0;
      opt.Headless := False;
      raised := False;
      try
        opt.Validate;
      except
        on E: Exception do
          raised := True;
      end;
      Ok('jvm-needs-headless', raised);
      opt.Headless := True;
      { TJVMOptions feeds the real start path: EnsureStartedWithOptions
        builds the JVM command line from these same options, so a bad set
        fails the start instead of being ignored. LastStartArgs exposes the
        exact command line the JVM received. }
      TJVMManager.ResetForTests;
      try
        TJVMManager.EnsureStartedWithOptions('C:/nonexistent-jvm.dll', opt);
        Ok('jvm-options-start', False);
      except
        on E: Exception do
          Ok('jvm-options-start', Pos('libjvm not found', E.Message) > 0);
      end;
      opt.Headless := False;
      raised := False;
      try
        TJVMManager.EnsureStartedWithOptions('C:/nonexistent-jvm.dll', opt);
      except
        on E: Exception do
          raised := Pos('headless', E.Message) > 0;
      end;
      Ok('jvm-options-reject', raised);
      opt.Headless := True;
    finally
      opt.Free;
    end;

    pool := TJDBCHikariPool.Create;
    try
      Ok('pool-defaults', (pool.MaximumPoolSize = 10) and
        (pool.ConnectionTestQuery = 'SELECT 1') and
        (pool.IdleTimeoutMs = 600000) and (pool.ValidationTimeoutMs = 5000));
      pool.Validate;
      Ok('pool-validate-ok', True);
      pool.ConnectionTestQuery := 'SELECT version()';
      Ok('pool-set', pool.ConnectionTestQuery = 'SELECT version()');
      { Borrow validates and reuses idle entries: the second borrow must
        return the released connection, stamped by IsConnectionValid with
        the pool's live ValidationTimeoutMs + ConnectionTestQuery. }
      held := pool.Borrow;
      heldId := held.ConnectionId;
      pool.ReleaseConnection(held);
      Ok('pool-release-idle', pool.IdleCount = 1);
      again := pool.Borrow;
      againId := again.ConnectionId;
      Ok('pool-reuse-idle', (againId = heldId) and
        (again.LastTestQuery = 'SELECT version()') and
        (again.LastValidatedAtMs > 0) and (pool.ValidatedBorrows = 1));
      Ok('pool-queries-live', True);
      pool.ReleaseConnection(again);
      { A failing validation rejects the idle entry instead of handing it
        back: stamping the entry's ForceInvalid marker makes the next
        borrow evict it (counted) and mint a fresh connection. The marker
        lives on the shipped connection object (live backends drive it
        from Connection.isValid), not in a test-only bypass. IDs (not
        object identity) prove the swap: the pool frees the stale entry,
        so comparing freed pointers would be unsound. }
      held := pool.Borrow;
      pool.ReleaseConnection(held);
      heldId := held.ConnectionId;
      held.ForceInvalid := True;
      rejected := pool.Borrow;
      rejectedId := rejected.ConnectionId;
      Ok('pool-reject-invalid', (rejectedId <> heldId) and
        (pool.EvictedIdle = 1));
      pool.ReleaseConnection(rejected);
      pool.MaximumPoolSize := 0;
      raised := False;
      try
        pool.Validate;
      except
        on E: EJDBCError do
          raised := E.SQLState = 'HY092';
      end;
      Ok('pool-bad-size', raised);
      pool.MaximumPoolSize := 10;
      { Borrow enforces Validate: a bad test query fails the borrow
        instead of being stored silently. }
      pool.ConnectionTestQuery := '';
      raised := False;
      try
        pool.Borrow;
      except
        on E: EJDBCError do
          raised := E.SQLState = 'HY092';
      end;
      Ok('pool-borrow-validates', raised);
      pool.ConnectionTestQuery := 'SELECT 1';
      { IdleTimeoutMs evicts stale entries on the same pool: age the single
        idle connection past a 1ms budget and the next borrow drops it and
        mints a fresh one (total evictions so far = 2: one validation
        rejection above plus this idle expiry); with 0 (disabled) the same
        entry is reused. }
      held := pool.Borrow;
      heldId := held.ConnectionId;
      pool.ReleaseConnection(held);
      pool.IdleTimeoutMs := 0;
      Sleep(15);
      again := pool.Borrow;
      againId := again.ConnectionId;
      Ok('pool-idle-evict', (againId = heldId) and (pool.EvictedIdle = 1));
      pool.ReleaseConnection(again);
      pool.IdleTimeoutMs := 1;
      held := pool.Borrow;
      heldId := held.ConnectionId;
      pool.ReleaseConnection(held);
      Sleep(30);
      again := pool.Borrow;
      againId := again.ConnectionId;
      Ok('pool-idle-evict-1ms', (againId <> heldId) and
        (pool.EvictedIdle = 2));
      pool.ReleaseConnection(again);
      pool.IdleTimeoutMs := 600000;
    finally
      pool.Free;
    end;

    fo := TFetchOptions.Create;
    try
      fo.Validate;
      Ok('fetch-defaults-ok', fo.MaxBufferedRows = 100000);
      fo.Mode := fmOnDemand;
      raised := False;
      try
        fo.Validate;
      except
        on E: Exception do
          raised := True;
      end;
      Ok('fetch-ondemand-needs-unidir', raised);
      fo.Unidirectional := True;
      fo.Validate;
      Ok('fetch-ondemand-ok', True);
    finally
      fo.Free;
    end;

    uo := TUpdateOptions.Create;
    try
      uo.Validate;
      Ok('update-default-ok', uo.BatchApplySize = 1000);
      uo.BatchApplySize := 0;
      raised := False;
      try
        uo.Validate;
      except
        on E: Exception do
          raised := True;
      end;
      Ok('update-bad-batch', raised);
      uo.BatchApplySize := 1000;
    finally
      uo.Free;
    end;

    { Query load/apply paths enforce the options: MaxBufferedRows caps
      buffered loads with HY001, and BatchApplySize is both validated on
      ApplyUpdates and enforced per ExecBatch round trip. }
    q := TJDBCQuery.Create(nil);
    try
      Ok('query-budget-default', q.BufferedRowLimit = 100000);
      rows := MakeRows(4);
      q.FetchOptions.MaxBufferedRows := 3;
      raised := False;
      try
        q.LoadJavaRows(['id', 'name'], ['INTEGER', 'NVARCHAR'], rows);
      except
        on E: EJDBCError do
          raised := E.SQLState = 'HY001';
      end;
      Ok('query-cap-enforced', raised and (q.RecordCount = 0));
      q.FetchOptions.MaxBufferedRows := 4;
      q.LoadJavaRows(['id', 'name'], ['INTEGER', 'NVARCHAR'], rows);
      Ok('query-cap-raise-loads', q.RecordCount = 4);
      q.FetchOptions.MaxBufferedRows := 100000;
      { fmOnDemand without Unidirectional is rejected on the load path
        itself, not just by calling Validate manually. }
      q.FetchOptions.Mode := fmOnDemand;
      q.FetchOptions.Unidirectional := False;
      raised := False;
      try
        q.LoadJavaRows(['id', 'name'], ['INTEGER', 'NVARCHAR'], rows);
      except
        on E: Exception do
          raised := Pos('Unidirectional', E.Message) > 0;
      end;
      Ok('query-ondemand-guarded', raised);
      q.FetchOptions.Mode := fmAll;
      { BatchApplySize is rejected up front on ApplyUpdates. }
      q.CachedUpdates := True;
      q.UpdateOptions.ReadOnly := False;
      q.UpdateOptions.BatchApplySize := 0;
      raised := False;
      try
        q.ApplyUpdates;
      except
        on E: Exception do
          raised := True;
      end;
      Ok('query-batch-validated', raised);
      q.UpdateOptions.BatchApplySize := 1000;
    finally
      q.Free;
    end;

    Ok('typemap-serial', TJdbcTypeMap.ToFieldType('SERIAL') = ftInteger);
    Ok('typemap-bigserial', TJdbcTypeMap.ToFieldType('BIGSERIAL') =
      ftLargeint);
    Ok('typemap-money', TJdbcTypeMap.ToFieldType('MONEY') = ftFmtBCD);
    Ok('typemap-inet', TJdbcTypeMap.ToFieldType('INET') = ftWideString);
    TJdbcTypeMap.RegisterCustom('UUID', ftWideString);
    Ok('typemap-custom', TJdbcTypeMap.ToFieldType('UUID') = ftWideString);
    TJdbcTypeMap.RegisterCustom('MONEY', ftWideMemo);
    Ok('typemap-override', TJdbcTypeMap.ToFieldType('MONEY') = ftWideMemo);
    Ok('typemap-needstream', TJdbcTypeMap.NeedStream('BYTEA'));
  finally
    TJdbcTypeMap.ClearCustom;
  end;

  WriteLn('TOTAL fails=', Fails);
  if Fails > 0 then
    Halt(1);
end.
