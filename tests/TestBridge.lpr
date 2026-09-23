program TestBridge;
{$mode objfpc}{$H+}
uses
  SysUtils, Classes, TyFPJDBC.Bridge.Intf, TyFPJDBC.JVM.Manager,
  TyFPJDBC.Connection, TyFPJDBC.Statement, TyFPJDBC.Hikari.Pool;

var
  Fails: Integer = 0;

procedure Ok(const N: string; C: Boolean);
begin
  if C then WriteLn('PASS ', N) else begin Inc(Fails); WriteLn('FAIL ', N); end;
end;

const
  REAL_JVM = 'C:\Tools\jdk25\jdk-25.0.4.1+1\bin\server\jvm.dll';

var
  c1, c2: TJDBCConnection;
  pool: TJDBCHikariPool;
  st: TJDBCStatement;
  tot: Integer;
  b: TRowBlock;
  statsCalls: Integer = 0;

type
  TStatsSink = class
    procedure OnStats(A, I, W: Integer);
  end;

procedure TStatsSink.OnStats(A, I, W: Integer);
begin
  Inc(statsCalls);
end;

type
  TExecThread = class(TThread)
    St: TJDBCStatement;
    GotState: string;
    GotCode: Integer;
    procedure Execute; override;
  end;

procedure TExecThread.Execute;
begin
  try
    St.ExecUpdate(1);
    GotState := 'NO-RAISE';
  except
    on E: EJDBCError do
    begin
      GotState := E.SQLState;
      GotCode := E.VendorCode;
    end;
    on E: Exception do
      GotState := 'WRONG:' + E.ClassName;
  end;
end;

var
  sink: TStatsSink;
  th: TExecThread;
  raised: Boolean;

begin
  Ok('bridge-version', BRIDGE_VERSION = '1.0.0');
  Ok('fetch-default', FETCH_BATCH_DEFAULT = 1000);

  TJVMManager.ResetForTests;
  raised := False;
  try
    TJVMManager.EnsureStarted('C:/fake/jvm.dll', TJVMManager.BuildDesktopArgs);
  except
    raised := True;
  end;
  Ok('jvm-fake-path-rejected', raised and not TJVMManager.IsStarted);
  Ok('real-jvm-present', FileExists(REAL_JVM));
  TJVMManager.EnsureStarted(REAL_JVM, TJVMManager.BuildDesktopArgs);
  Ok('jvm-started', TJVMManager.IsStarted);
  TJVMManager.AttachThread;
  Ok('attach', TJVMManager.AttachedCount = 1);
  TJVMManager.DetachThread;
  Ok('detach', TJVMManager.AttachedCount = 0);

  TJDBCConnection.ResetIdsForTests;
  c1 := TJDBCConnection.Create;
  c2 := TJDBCConnection.Create;
  try
    Ok('distinct-ids', c1.ConnectionId <> c2.ConnectionId);
    c1.Borrow; c2.Borrow;
    c1.AutoCommit := False;
    c1.StartTransaction;
    c1.Savepoint('sp1');
    c1.RollbackToSavepoint('sp1');
    c1.Commit;
    Ok('tx-savepoint', (not c1.TransactionActive) and (c1.Savepoints.Count = 0));
    try
      c1.Commit;
      Ok('commit-no-tx-fails', False);
    except
      on E: EJDBCError do Ok('commit-no-tx-fails', (E.SQLState = '25000') and (E.Chain.Count >= 2));
    end;
    c1.Release; c2.Release;
  finally
    c1.Free; c2.Free;
  end;

  pool := TJDBCHikariPool.Create;
  sink := TStatsSink.Create;
  try
    pool.MaximumPoolSize := 2;
    pool.OnPoolStats := @sink.OnStats;
    c1 := pool.Borrow;
    c2 := pool.Borrow;
    Ok('pool-distinct', c1.ConnectionId <> c2.ConnectionId);
    Ok('pool-active', pool.ActiveCount = 2);
    try
      pool.Borrow;
      Ok('pool-exhaust-fails', False);
    except
      on E: EJDBCError do Ok('pool-exhaust-fails', E.SQLState = '08001');
    end;
    pool.ReleaseConnection(c1);
    pool.ReleaseConnection(c2);
    Ok('pool-idle', pool.IdleCount = 2);
    Ok('stats-fired', statsCalls >= 4);
  finally
    sink.Free;
    pool.Free;
  end;

  st := TJDBCStatement.Create;
  try
    st.SetQueryTimeout(5);
    Ok('timeout-set', st.QueryTimeoutSecs = 5);
    st.SimulateSlowMs := 0;
    Ok('exec-update', st.ExecUpdate(3) = 3);
    st.BatchItemMs := 0;
    Ok('exec-batch', st.ExecBatch(1000) = 1000);
    st.Cancel;
    try
      st.ExecUpdate(1);
      Ok('cancel-observed', False);
    except
      on E: EJDBCError do Ok('cancel-observed', E.SQLState = 'HY008');
    end;
    st.ResetCancel;
    st.SetQueryTimeout(1);
    st.SimulateSlowMs := 1500;
    try
      st.ExecUpdate(1);
      Ok('timeout-observed', False);
    except
      on E: EJDBCError do Ok('timeout-observed', E.SQLState = 'HYT00');
    end;
    b := st.FetchBatch(0, 10, tot);
    Ok('fetch-no-hook', (tot = 0) and (Length(b) = 0));
  finally
    st.Free;
  end;

  st := TJDBCStatement.Create;
  try
    st.SetQueryTimeout(30);
    st.SimulateSlowMs := 10000;
    th := TExecThread.Create(True);
    th.St := st;
    th.Start;
    Sleep(300);
    st.Cancel;
    th.WaitFor;
    Ok('cross-thread-cancel', th.GotState = 'HY008');
    th.Free;
  finally
    st.Free;
  end;

  WriteLn('--- fails=', Fails);
  if Fails > 0 then Halt(1);
end.
