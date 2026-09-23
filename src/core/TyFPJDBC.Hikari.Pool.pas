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
    procedure EmitStats;
  public
    MaximumPoolSize: Integer;
    MinimumIdle: Integer;
    ConnectionTimeout: Integer;
    MaxLifetime: Int64;
    KeepaliveTime: Int64;
    LeakDetectionThreshold: Int64;
    SlowQueryThresholdMs: Int64;
    OnPoolStats: TPoolStats;
    OnSlowQuery: TSlowQuery;
    constructor Create;
    destructor Destroy; override;
    function GetConnection: TJDBCConnection;
    function Borrow: TJDBCConnection;
    procedure ReleaseConnection(C: TJDBCConnection);
    procedure ReportSlow(const SQL: string; ElapsedMs: Int64);
    function ActiveCount: Integer;
    function IdleCount: Integer;
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
  FSlowThresholdMs := SlowQueryThresholdMs;
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
begin
  FLock.Enter;
  try
    if FIdle.Count > 0 then
    begin
      c := TJDBCConnection(FIdle[FIdle.Count - 1]);
      FIdle.Delete(FIdle.Count - 1);
    end
    else
    begin
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
    end;
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
    if FIdle.Count < MaximumPoolSize then
      FIdle.Add(C)
    else
      C.Free;
    EmitStats;
  finally
    FLock.Leave;
  end;
end;

procedure TJDBCHikariPool.ReportSlow(const SQL: string; ElapsedMs: Int64);
begin
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

end.
