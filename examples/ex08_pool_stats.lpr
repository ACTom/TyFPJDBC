program ex08_pool_stats;

{$mode objfpc}{$H+}

{ ex08: pool stats + slow-query callbacks for monitoring. }

uses
  SysUtils, TyFPJDBC.Connection, TyFPJDBC.Statement, TyFPJDBC.Hikari.Pool;

type
  TMon = class
    procedure Stats(A, I, W: Integer);
    procedure Slow(const S: string; Ms: Int64);
  end;

var
  slowHits: Integer = 0;

procedure TMon.Stats(A, I, W: Integer);
begin
  WriteLn('stats active=', A, ' idle=', I, ' wait=', W);
end;

procedure TMon.Slow(const S: string; Ms: Int64);
begin
  Inc(slowHits);
  WriteLn('slow: ', S, ' ms=', Ms);
end;

var
  pool: TJDBCHikariPool;
  mon: TMon;
  ca: TJDBCConnection;
  st: TJDBCStatement;
begin
  TJDBCConnection.ResetIdsForTests;
  pool := TJDBCHikariPool.Create;
  mon := TMon.Create;
  try
    pool.MaximumPoolSize := 4;
    pool.OnPoolStats := @mon.Stats;
    pool.OnSlowQuery := @mon.Slow;
    pool.SlowQueryThresholdMs := 500;

    ca := pool.Borrow;
    try
      st := TJDBCStatement.Create;
      try
        st.SetQueryTimeout(30);
        WriteLn('timeout=', st.QueryTimeoutSecs);
        pool.ReportSlow('SELECT * FROM big', 1200);
      finally
        st.Free;
      end;
    finally
      pool.ReleaseConnection(ca);
    end;
    WriteLn('slowHits=', slowHits, ' idle=', pool.IdleCount);
  finally
    mon.Free;
    pool.Free;
  end;
  WriteLn('ex08 ok');
end.
