program ex05_transaction;

{$mode objfpc}{$H+}

{ ex05: transaction + savepoint + pool borrow/release semantics. }

uses
  SysUtils, TyFPJDBC.Connection, TyFPJDBC.Hikari.Pool;

var
  pool: TJDBCHikariPool;
  ca, cb: TJDBCConnection;
begin
  TJDBCConnection.ResetIdsForTests;
  pool := TJDBCHikariPool.Create;
  try
    pool.MaximumPoolSize := 2;
    ca := pool.Borrow;
    cb := pool.Borrow;
    try
      WriteLn('borrowed ids: ', ca.ConnectionId, ' / ', cb.ConnectionId,
        ' active=', pool.ActiveCount);
      ca.AutoCommit := False;
      ca.StartTransaction;
      ca.Savepoint('sp1');
      ca.RollbackToSavepoint('sp1');
      ca.Commit;
      WriteLn('tx committed, active=', BoolToStr(ca.TransactionActive, True));
    finally
      pool.ReleaseConnection(ca);
      pool.ReleaseConnection(cb);
    end;
    WriteLn('idle=', pool.IdleCount);
  finally
    pool.Free;
  end;
  WriteLn('ex05 ok');
end.
