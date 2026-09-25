unit TyFPJDBC.Engine;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, TyFPJDBC.Handles, TyFPJDBC.JNI.Bridge;

type
  { Engine: thin handle facade. No pool/conn/tx state lives here; every
    call validates handles locally then forwards to Bridge, which is the
    single state machine. Counts only track open handles for leak asserts. }
  TJdbcEngine = class
  private
    FBridge: TBridge;
    FPools, FConns, FStmts, FCursors: TList;
    function IdxOf(L: TList; Id: Int64): Integer;
    procedure Track(L: TList; Id: Int64);
    procedure Untrack(L: TList; Id: Int64);
  public
    constructor Create(ABridge: TBridge);
    destructor Destroy; override;
    function HandleCount: Integer;
    function OpenPool(const Cfg: TPoolCfgRec): Int64;
    procedure ClosePool(PoolId: Int64);
    function Borrow(PoolId: Int64): Int64;
    procedure Release(ConnId: Int64);
    procedure SetAutoCommit(ConnId: Int64; Auto: Boolean);
    procedure Commit(ConnId: Int64);
    procedure Rollback(ConnId: Int64);
    procedure Savepoint(ConnId: Int64; const Name: UTF8String);
    procedure RollbackTo(ConnId: Int64; const Name: UTF8String);
    procedure ReleaseSavepoint(ConnId: Int64; const Name: UTF8String);
    function PoolActive(PoolId: Int64): Integer;
    function PoolIdle(PoolId: Int64): Integer;
    function PoolWaiting(PoolId: Int64): Integer;
    property Bridge: TBridge read FBridge;
  end;

implementation

constructor TJdbcEngine.Create(ABridge: TBridge);
begin
  inherited Create;
  if ABridge = nil then
    raise EJDBCError.CreateChain('bridge required', 'HY000', 99, 'nil');
  FBridge := ABridge;
  FPools := TList.Create;
  FConns := TList.Create;
  FStmts := TList.Create;
  FCursors := TList.Create;
end;

destructor TJdbcEngine.Destroy;
begin
  FPools.Free;
  FConns.Free;
  FStmts.Free;
  FCursors.Free;
  inherited;
end;

function TJdbcEngine.IdxOf(L: TList; Id: Int64): Integer;
var
  i: Integer;
begin
  for i := 0 to L.Count - 1 do
    if Int64(PtrUInt(L[i])) = Id then
      Exit(i);
  Result := -1;
end;

procedure TJdbcEngine.Track(L: TList; Id: Int64);
begin
  if IdxOf(L, Id) < 0 then
    L.Add(Pointer(PtrUInt(Id)));
end;

procedure TJdbcEngine.Untrack(L: TList; Id: Int64);
var
  i: Integer;
begin
  i := IdxOf(L, Id);
  if i >= 0 then
    L.Delete(i);
end;

function TJdbcEngine.HandleCount: Integer;
begin
  Result := FPools.Count + FConns.Count + FStmts.Count + FCursors.Count;
end;

function TJdbcEngine.OpenPool(const Cfg: TPoolCfgRec): Int64;
begin
  Result := FBridge.CreatePool(Cfg);
  CheckHandle('pool', Result);
  Track(FPools, Result);
end;

procedure TJdbcEngine.ClosePool(PoolId: Int64);
begin
  CheckHandle('pool', PoolId);
  FBridge.DestroyPool(PoolId);
  Untrack(FPools, PoolId);
end;

function TJdbcEngine.Borrow(PoolId: Int64): Int64;
begin
  CheckHandle('pool', PoolId);
  Result := FBridge.BorrowConn(PoolId);
  CheckHandle('conn', Result);
  Track(FConns, Result);
end;

procedure TJdbcEngine.Release(ConnId: Int64);
begin
  CheckHandle('conn', ConnId);
  FBridge.CloseConn(ConnId);
  Untrack(FConns, ConnId);
end;

procedure TJdbcEngine.SetAutoCommit(ConnId: Int64; Auto: Boolean);
begin
  CheckHandle('conn', ConnId);
  FBridge.SetAutoCommit(ConnId, Auto);
end;

procedure TJdbcEngine.Commit(ConnId: Int64);
begin
  CheckHandle('conn', ConnId);
  FBridge.Commit(ConnId);
end;

procedure TJdbcEngine.Rollback(ConnId: Int64);
begin
  CheckHandle('conn', ConnId);
  FBridge.Rollback(ConnId);
end;

procedure TJdbcEngine.Savepoint(ConnId: Int64; const Name: UTF8String);
var
  i: Integer;
begin
  CheckHandle('conn', ConnId);
  if (Name = '') or (Length(Name) > 64) then
    raise EJDBCError.CreateChain('bad savepoint', 'HY092', 41, string(Name));
  if not (Name[1] in ['A'..'Z', 'a'..'z', '_']) then
    raise EJDBCError.CreateChain('bad savepoint', 'HY092', 41, string(Name));
  for i := 2 to Length(Name) do
    if not (Name[i] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
      raise EJDBCError.CreateChain('bad savepoint', 'HY092', 41, string(Name));
  FBridge.Savepoint(ConnId, Name);
end;

procedure TJdbcEngine.RollbackTo(ConnId: Int64; const Name: UTF8String);
begin
  CheckHandle('conn', ConnId);
  FBridge.RollbackTo(ConnId, Name);
end;

procedure TJdbcEngine.ReleaseSavepoint(ConnId: Int64; const Name: UTF8String);
begin
  CheckHandle('conn', ConnId);
  FBridge.ReleaseSavepoint(ConnId, Name);
end;

function TJdbcEngine.PoolActive(PoolId: Int64): Integer;
begin
  CheckHandle('pool', PoolId);
  Result := FBridge.PoolStats(PoolId).Active;
end;

function TJdbcEngine.PoolIdle(PoolId: Int64): Integer;
begin
  CheckHandle('pool', PoolId);
  Result := FBridge.PoolStats(PoolId).Idle;
end;

function TJdbcEngine.PoolWaiting(PoolId: Int64): Integer;
begin
  CheckHandle('pool', PoolId);
  Result := FBridge.PoolStats(PoolId).Waiting;
end;

end.
