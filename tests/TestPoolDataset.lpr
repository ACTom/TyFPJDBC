program TestPoolDataset;
{$mode objfpc}{$H+}
{$codepage UTF8}
uses
  SysUtils, Classes, TyFPJDBC.Connection, TyFPJDBC.Statement,
  TyFPJDBC.Hikari.Pool, TyFPJDBC.Options, TyFPJDBC.Query, TyFPJDBC.Mock.Engine;

var
  Fails: Integer = 0;

procedure Ok(const N: string; C: Boolean);
begin
  if C then WriteLn('PASS ', N) else begin Inc(Fails); WriteLn('FAIL ', N); end;
end;

type
  TStats = class
    procedure Stats(A, I, W: Integer);
    procedure Slow(const S: string; Ms: Int64);
  end;

var
  slowHits: Integer = 0;

procedure TStats.Slow(const S: string; Ms: Int64);
begin
  Inc(slowHits);
end;

procedure TStats.Stats(A, I, W: Integer);
begin
end;

var
  pool: TJDBCHikariPool;
  sink: TStats;
  eng: TMockEngine;
  ca, cb: TJDBCConnection;
  st: TJDBCStatement;
  q: TJDBCQuery;
  rows: TStringList;
  tot, off, streamed, maxBuf: Integer;
begin
  TJDBCConnection.ResetIdsForTests;
  pool := TJDBCHikariPool.Create;
  sink := TStats.Create;
  eng := TMockEngine.Create(20000);
  try
    pool.MaximumPoolSize := 4;
    pool.OnPoolStats := @sink.Stats;
    pool.OnSlowQuery := @sink.Slow;
    pool.SlowQueryThresholdMs := 500;

    ca := pool.Borrow;
    cb := pool.Borrow;
    try
      Ok('distinct-connections', ca.ConnectionId <> cb.ConnectionId);
      Ok('active-two', pool.ActiveCount = 2);

      st := TJDBCStatement.Create;
      try
        st.SQL := 'SELECT * FROM big WHERE id=:id';
        st.SetQueryTimeout(1);
        st.SimulateSlowMs := 3000;
        try
          st.ExecUpdate(1);
          Ok('slow-cancel-or-timeout', False);
        except
          on E: EJDBCError do
            Ok('slow-cancel-or-timeout', (E.SQLState = 'HYT00') or (E.SQLState = 'HY008'));
        end;
        st.Cancelled := False;
        st.SimulateSlowMs := 0;
        st.Cancel;
        try
          st.ExecUpdate(1);
          Ok('cancel-observed', False);
        except
          on E: EJDBCError do Ok('cancel-observed', E.SQLState = 'HY008');
        end;
      finally
        st.Free;
      end;
      pool.ReportSlow('SELECT * FROM big', 1200);
      Ok('slow-reported', slowHits = 1);
    finally
      pool.ReleaseConnection(ca);
      pool.ReleaseConnection(cb);
    end;
    Ok('released-idle', pool.IdleCount = 2);

    q := TJDBCQuery.Create(nil);
    try
      q.FetchOptions.Mode := fmAll;
      rows := eng.FetchSmall(0, 10, tot);
      try
        q.LoadRowsBuffered(['id', 'name'], ['INTEGER', 'NVARCHAR'], rows);
        Ok('small-full', (tot = 3) and (q.RecordCount = 3));
        q.First; q.Next;
        Ok('small-chinese', q.FieldToUTF8(q.Fields[1]) = UTF8String('中文测试'));
      finally
        rows.Free;
      end;

      q.FetchOptions.Mode := fmOnDemand;
      q.FetchOptions.Unidirectional := True;
      q.FetchOptions.RowsetSize := 1000;
      off := 0; streamed := 0; maxBuf := 0;
      while off < eng.LargeTotal do
      begin
        rows := eng.FetchLarge(off, q.FetchOptions.RowsetSize, tot);
        try
          if rows.Count > maxBuf then maxBuf := rows.Count;
          Inc(streamed, rows.Count);
          off := off + rows.Count;
          if rows.Count = 0 then Break;
        finally
          rows.Free;
        end;
      end;
      Ok('stream-total', streamed = 20000);
      Ok('stream-bounded', maxBuf <= 1000);

      q.Close;
      rows := eng.FetchSmall(0, 3, tot);
      try
        q.LoadRowsBuffered(['id', 'name'], ['INTEGER', 'NVARCHAR'], rows);
        q.CachedUpdates := True;
        q.UpdateOptions.ReadOnly := False;
        q.UpdateOptions.AutoIncField := 'id';
        q.Append;
        q.Fields[1].AsString := 'srv-row';
        q.Post;
        Ok('pending-one', q.PendingInserts = 1);
        q.ApplyUpdates;
        Ok('edit-genkey', q.GetGeneratedKeys = 1000);
        Ok('edit-genkey-in-row', q.Fields[0].AsString = '1000');
        Ok('edit-applied', (q.AppliedInserts = 1) and (q.PendingInserts = 0));
      finally
        rows.Free;
      end;
    finally
      q.Free;
    end;
  finally
    eng.Free;
    sink.Free;
    pool.Free;
  end;

  WriteLn('--- fails=', Fails);
  if Fails > 0 then Halt(1);
end.
