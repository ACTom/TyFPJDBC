program TestPhase2Config;

{$mode objfpc}{$H+}
{$codepage UTF8}

{ Phase-2 module configurability: representative settings take effect.
  Pure-logic units only (DriverRegistry, JVMOptions, pool Validate,
  Options.Validate, TypeMap custom/PG types); the live JNI path stays in
  TestLiveBridge/TestLiveGrid/TestPerfTiers. }

uses
  SysUtils, Classes, DB, TyFPJDBC.Connection, TyFPJDBC.Driver.Registry,
  TyFPJDBC.JVM.Manager, TyFPJDBC.Hikari.Pool, TyFPJDBC.Options,
  TyFPJDBC.&Type.Map;

var
  Fails: Integer = 0;

procedure Ok(const N: string; C: Boolean);
begin
  if C then WriteLn('PASS ', N) else begin Inc(Fails); WriteLn('FAIL ', N); end;
end;

var
  c: TJDBCConnection;
  pool: TJDBCHikariPool;
  opt: TJVMOptions;
  fo: TFetchOptions;
  uo: TUpdateOptions;
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
      c.LoginTimeoutSecs := -1;
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
    finally
      uo.Free;
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
