unit TyFPJDBC.Connection;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes;
type
  TJDBCIsolation = (ilReadUncommitted, ilReadCommitted, ilRepeatableRead, ilSerializable);

  EJDBCError = class(Exception)
    SQLState: string;
    VendorCode: Integer;
    Chain: TStringList;
    constructor CreateChain(const Msg, State: string; Code: Integer; const Next: string);
    destructor Destroy; override;
  end;

  TJDBCConnection = class
  private
    class var FNextId: Integer;
  public
    ConnectionId: Integer;
    AutoCommit: Boolean;
    Isolation: TJDBCIsolation;
    ReadOnly: Boolean;
    Borrowed: Boolean;
    TransactionActive: Boolean;
    Savepoints: TStringList;
    constructor Create; virtual;
    destructor Destroy; override;
    procedure Borrow; virtual;
    procedure Release; virtual;
    procedure StartTransaction; virtual;
    procedure Commit; virtual;
    procedure Rollback; virtual;
    procedure Savepoint(const Name: string); virtual;
    procedure RollbackToSavepoint(const Name: string); virtual;
    procedure ReleaseSavepoint(const Name: string); virtual;
    class procedure ResetIdsForTests; static;
  end;

implementation

constructor EJDBCError.CreateChain(const Msg, State: string; Code: Integer; const Next: string);
begin
  inherited Create(Msg + ' caused by ' + Next);
  SQLState := State;
  VendorCode := Code;
  Chain := TStringList.Create;
  Chain.Add(Msg);
  Chain.Add(Next);
end;

destructor EJDBCError.Destroy;
begin
  Chain.Free;
  inherited;
end;

constructor TJDBCConnection.Create;
begin
  inherited Create;
  Inc(FNextId);
  ConnectionId := FNextId;
  AutoCommit := True;
  Isolation := ilReadCommitted;
  ReadOnly := False;
  Borrowed := False;
  TransactionActive := False;
  Savepoints := TStringList.Create;
end;

destructor TJDBCConnection.Destroy;
begin
  Savepoints.Free;
  inherited;
end;

class procedure TJDBCConnection.ResetIdsForTests;
begin
  FNextId := 0;
end;

procedure TJDBCConnection.Borrow;
begin
  if Borrowed then
    raise EJDBCError.CreateChain('already borrowed', '08000', 1, 'double borrow');
  Borrowed := True;
end;

procedure TJDBCConnection.Release;
begin
  if not Borrowed then
    raise EJDBCError.CreateChain('not borrowed', '08000', 2, 'double release');
  if TransactionActive then
    Rollback;
  Borrowed := False;
end;

procedure TJDBCConnection.StartTransaction;
begin
  if AutoCommit then
    raise EJDBCError.CreateChain('autocommit on', '25000', 3, 'disable AutoCommit first');
  if TransactionActive then
    raise EJDBCError.CreateChain('tx active', '25000', 4, 'nested tx not allowed');
  TransactionActive := True;
end;

procedure TJDBCConnection.Commit;
begin
  if AutoCommit then
    raise EJDBCError.CreateChain('autocommit on', '25000', 5, 'commit not allowed');
  if not TransactionActive then
    raise EJDBCError.CreateChain('no tx', '25000', 6, 'nothing to commit');
  TransactionActive := False;
  Savepoints.Clear;
end;

procedure TJDBCConnection.Rollback;
begin
  if AutoCommit then
    Exit;
  TransactionActive := False;
  Savepoints.Clear;
end;

procedure TJDBCConnection.Savepoint(const Name: string);
begin
  if not TransactionActive then
    raise EJDBCError.CreateChain('no tx', '25000', 7, 'savepoint needs tx');
  if Savepoints.IndexOf(Name) >= 0 then
    raise EJDBCError.CreateChain('dup savepoint', '25000', 8, Name);
  Savepoints.Add(Name);
end;

procedure TJDBCConnection.RollbackToSavepoint(const Name: string);
var
  idx, i: Integer;
begin
  idx := Savepoints.IndexOf(Name);
  if idx < 0 then
    raise EJDBCError.CreateChain('unknown savepoint', '25000', 9, Name);
  for i := Savepoints.Count - 1 downto idx + 1 do
    Savepoints.Delete(i);
end;

procedure TJDBCConnection.ReleaseSavepoint(const Name: string);
var
  idx: Integer;
begin
  idx := Savepoints.IndexOf(Name);
  if idx < 0 then
    raise EJDBCError.CreateChain('unknown savepoint', '25000', 10, Name);
  Savepoints.Delete(idx);
end;

end.
