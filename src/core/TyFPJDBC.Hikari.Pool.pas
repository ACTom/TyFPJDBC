unit TyFPJDBC.Hikari.Pool;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, syncobjs, TyFPJDBC.Connection, TyFPJDBC.Pool.Intf;
type
  TPoolStats = procedure(Active, Idle, Waiting: Integer) of object;
  TSlowQuery = procedure(const SQL: string; ElapsedMs: Int64) of object;

  TJDBCHikariPool = class(TInterfacedObject, IJDBCConnectionPool)
  private
    FLock: TCriticalSection;
    FIdle: TList;
    FActive: Integer;
    FWaiting: Integer;
    FSlowThresholdMs: Int64;
    FValidatedBorrows: Int64;
    FEvictedIdle: Int64;
    procedure EmitStats;
  public
    MaximumPoolSize: Integer;
    MinimumIdle: Integer;
    ConnectionTimeout: Integer;
    MaxLifetime: Int64;
    KeepaliveTime: Int64;
    LeakDetectionThreshold: Int64;
    SlowQueryThresholdMs: Int64;
    IdleTimeoutMs: Int64;
    ValidationTimeoutMs: Int64;
    ConnectionTestQuery: string;
    OnPoolStats: TPoolStats;
    OnSlowQuery: TSlowQuery;
    constructor Create;
    destructor Destroy; override;
    procedure Validate;
    function GetConnection: TJDBCConnection;
    function Borrow: TJDBCConnection;
    procedure ReleaseConnection(C: TJDBCConnection);
    procedure ReportSlow(const SQL: string; ElapsedMs: Int64);
    function ActiveCount: Integer;
    function IdleCount: Integer;
    function ValidatedBorrows: Int64;
    function EvictedIdle: Int64;
  end;

implementation

constructor TJDBCHikariPool.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FIdle := TList.Create;
  MaximumPoolSize := 10;
  MinimumIdle := 2;
  ConnectionTimeout := 30000;
  MaxLifetime := 1800000;
  KeepaliveTime := 30000;
  LeakDetectionThreshold := 0;
  SlowQueryThresholdMs := 1000;
  IdleTimeoutMs := 600000;
  ValidationTimeoutMs := 5000;
  ConnectionTestQuery := 'SELECT 1';
  FSlowThresholdMs := SlowQueryThresholdMs;
end;

procedure TJDBCHikariPool.Validate;
begin
  if MaximumPoolSize < 1 then
    raise EJDBCError.CreateChain('bad pool size', 'HY092', 31,
      'MaximumPoolSize<1');
  if ConnectionTimeout < 0 then
    raise EJDBCError.CreateChain('bad connection timeout', 'HY092', 32,
      'ConnectionTimeout<0');
  if MinimumIdle < 0 then
    raise EJDBCError.CreateChain('bad minimum idle', 'HY092', 33,
      'MinimumIdle<0');
  if IdleTimeoutMs < 0 then
    raise EJDBCError.CreateChain('bad idle timeout', 'HY092', 35,
      'IdleTimeoutMs<0');
  if ValidationTimeoutMs < 0 then
    raise EJDBCError.CreateChain('bad validation timeout', 'HY092', 36,
      'ValidationTimeoutMs<0');
  if Trim(ConnectionTestQuery) = '' then
    raise EJDBCError.CreateChain('bad test query', 'HY092', 34,
      'ConnectionTestQuery empty');
end;

destructor TJDBCHikariPool.Destroy;
var
  i: Integer;
begin
  for i := 0 to FIdle.Count - 1 do
    TObject(FIdle[i]).Free;
  FIdle.Free;
  FLock.Free;
  inherited;
end;

procedure TJDBCHikariPool.EmitStats;
begin
  if Assigned(OnPoolStats) then
    OnPoolStats(FActive, FIdle.Count, FWaiting);
end;

function TJDBCHikariPool.GetConnection: TJDBCConnection;
begin
  Result := Borrow;
end;

function TJDBCHikariPool.Borrow: TJDBCConnection;
var
  c: TJDBCConnection;
  stale: Boolean;
  idx: Integer;
begin
  { Validate runs on every borrow so a bad pool/test-query setting fails
    here, not later. IdleTimeoutMs evicts stale idle entries (counted in
    EvictedIdle); ValidationTimeoutMs + ConnectionTestQuery gate reuse via
    IsConnectionValid (counted in ValidatedBorrows) so flipping the query
    or timeout observably changes which connections survive. }
  Validate;
  FLock.Enter;
  try
    while FIdle.Count > 0 do
    begin
      idx := FIdle.Count - 1;
      c := TJDBCConnection(FIdle[idx]);
      FIdle.Delete(idx);
      if not c.IsConnectionValid(ValidationTimeoutMs, ConnectionTestQuery) then
      begin
        Inc(FEvictedIdle);
        c.Free;
        Continue;
      end;
      stale := (IdleTimeoutMs > 0) and
        ((GetTickCount64 - c.IdleSinceMs) >= QWord(IdleTimeoutMs));
      if stale then
      begin
        Inc(FEvictedIdle);
        c.Free;
        Continue;
      end;
      Inc(FValidatedBorrows);
      Inc(FActive);
      c.Borrow;
      Result := c;
      EmitStats;
      Exit;
    end;
    if FActive >= MaximumPoolSize then
    begin
      Inc(FWaiting);
      try
        raise EJDBCError.CreateChain('pool exhausted', '08001', 30,
          'timeout after ' + IntToStr(ConnectionTimeout) + 'ms');
      finally
        Dec(FWaiting);
      end;
    end;
    c := TJDBCConnection.Create;
    Inc(FActive);
    c.Borrow;
    Result := c;
    EmitStats;
  finally
    FLock.Leave;
  end;
end;

procedure TJDBCHikariPool.ReleaseConnection(C: TJDBCConnection);
begin
  if C = nil then
    Exit;
  FLock.Enter;
  try
    C.Release;
    Dec(FActive);
    if (FIdle.Count < MaximumPoolSize) and (FIdle.IndexOf(C) < 0) then
    begin
      C.StampIdle;
      FIdle.Add(C);
    end
    else if FIdle.IndexOf(C) < 0 then
      C.Free;
    EmitStats;
  finally
    FLock.Leave;
  end;
end;

procedure TJDBCHikariPool.ReportSlow(const SQL: string; ElapsedMs: Int64);
begin
  { Read the live property (not the construction-time snapshot) so a
    threshold change via assignment takes effect immediately. }
  if (ElapsedMs >= SlowQueryThresholdMs) and Assigned(OnSlowQuery) then
    OnSlowQuery(SQL, ElapsedMs);
end;

function TJDBCHikariPool.ActiveCount: Integer;
begin
  FLock.Enter;
  try
    Result := FActive;
  finally
    FLock.Leave;
  end;
end;

function TJDBCHikariPool.IdleCount: Integer;
begin
  FLock.Enter;
  try
    Result := FIdle.Count;
  finally
    FLock.Leave;
  end;
end;

function TJDBCHikariPool.ValidatedBorrows: Int64;
begin
  FLock.Enter;
  try
    Result := FValidatedBorrows;
  finally
    FLock.Leave;
  end;
end;

function TJDBCHikariPool.EvictedIdle: Int64;
begin
  FLock.Enter;
  try
    Result := FEvictedIdle;
  finally
    FLock.Leave;
  end;
end;

end.
