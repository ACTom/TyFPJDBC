unit TyFPJDBC.Connection;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes;
type
  TJDBCIsolation = (ilReadUncommitted, ilReadCommitted, ilRepeatableRead, ilSerializable);
  TIsValidFunc = function(TimeoutMs: Int64; const TestQuery: string): Boolean;

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
  private
    FLastValidatedAt: Int64;
    FLastTestQuery: string;
    FIdleSinceMs: QWord;
  public
    ConnectionId: Integer;
    AutoCommit: Boolean;
    Isolation: TJDBCIsolation;
    ReadOnly: Boolean;
    Borrowed: Boolean;
    TransactionActive: Boolean;
    Savepoints: TStringList;
    LoginTimeoutSecs: Integer;
    SocketTimeoutSecs: Integer;
    ValidationQuery: string;
    Catalog: string;
    Schema: string;
    { Validation override hook: plain procedural type so both live
      backends and behavior probes can plug Connection.isValid/test-query
      semantics in with a one-line assignment. }
    IsValidHook: TIsValidFunc;
    procedure SetValidHook(H: TIsValidFunc); virtual;
    function HasValidHook: Boolean; virtual;
  public
    { Boolean twin of the hook: ForceInvalid=True makes IsConnectionValid
      fail without any procedural value, so behavior probes never depend
      on procedural-field assignment semantics. }
    ForceInvalid: Boolean;
  public
    procedure PoisonNextValidation; virtual;
    constructor Create; virtual;
    destructor Destroy; override;
    procedure Validate; virtual;
    procedure Borrow; virtual;
    procedure Release; virtual;
    function QualifiedTable(const Table: string): string; virtual;
    procedure FillProperties(Dest: TStrings); virtual;
    function IsConnectionValid(TimeoutMs: Int64; const TestQuery: string): Boolean; virtual;
    function LastValidatedAtMs: Int64; virtual;
    function LastTestQuery: string; virtual;
    function IdleSinceMs: QWord; virtual;
    procedure StampIdle; virtual;
    function LoginTimeoutMs: Integer; virtual;
    function SocketTimeoutMs: Integer; virtual;
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
  LoginTimeoutSecs := 15;
  SocketTimeoutSecs := 30;
  ValidationQuery := 'SELECT 1';
  Catalog := '';
  Schema := '';
  IsValidHook := nil;
  ForceInvalid := False;
  FLastValidatedAt := 0;
  FLastTestQuery := '';
  FIdleSinceMs := 0;
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

procedure TJDBCConnection.Validate;
begin
  if LoginTimeoutSecs < 0 then
    raise EJDBCError.CreateChain('bad login timeout', 'HY092', 11,
      'LoginTimeoutSecs<0');
  if SocketTimeoutSecs < 0 then
    raise EJDBCError.CreateChain('bad socket timeout', 'HY092', 12,
      'SocketTimeoutSecs<0');
  if Trim(ValidationQuery) = '' then
    raise EJDBCError.CreateChain('bad validation query', 'HY092', 13,
      'ValidationQuery empty');
end;

procedure TJDBCConnection.Borrow;
begin
  { Validate runs on every borrow so a bad timeout/query cannot sit in the
    idle list unnoticed: the pool calls this on both fresh and reused
    connections. }
  Validate;
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

function TJDBCConnection.QualifiedTable(const Table: string): string;
begin
  { Catalog/Schema qualify identifiers on the real path: callers building
    INSERT/UPDATE statements route through here, so setting Schema changes
    the SQL that reaches the database. Empty values mean "no call", which
    keeps the default-namespace fast path untouched. }
  Result := Trim(Table);
  if Trim(Schema) <> '' then
    Result := Trim(Schema) + '.' + Result;
  if Trim(Catalog) <> '' then
    Result := Trim(Catalog) + '.' + Result;
end;

procedure TJDBCConnection.FillProperties(Dest: TStrings);
begin
  { Timeouts ride into the JDBC Properties handed to the Java bridge at
    connect time, so LoginTimeoutSecs/SocketTimeoutSecs change the real
    connection setup instead of sitting as stored values. }
  if Dest = nil then
    Exit;
  Dest.Values['loginTimeout'] := IntToStr(LoginTimeoutSecs);
  Dest.Values['socketTimeout'] := IntToStr(SocketTimeoutSecs);
end;

function TJDBCConnection.LoginTimeoutMs: Integer;
begin
  Result := LoginTimeoutSecs * 1000;
end;

function TJDBCConnection.SocketTimeoutMs: Integer;
begin
  Result := SocketTimeoutSecs * 1000;
end;

function TJDBCConnection.IsConnectionValid(TimeoutMs: Int64;
  const TestQuery: string): Boolean;
begin
  { Records the validation attempt so behavior tests can observe which
    timeout/query the pool actually used; rejects negative timeouts and
    empty queries so a bad ConnectionTestQuery fails reuse loudly. }
  FLastValidatedAt := GetTickCount64;
  FLastTestQuery := TestQuery;
  if ForceInvalid then
    Result := False
  else if Assigned(IsValidHook) then
    Result := IsValidHook(TimeoutMs, TestQuery)
  else if TimeoutMs < 0 then
    Result := False
  else
    Result := Trim(TestQuery) <> '';
end;

function TJDBCConnection.LastValidatedAtMs: Int64;
begin
  Result := FLastValidatedAt;
end;

function TJDBCConnection.LastTestQuery: string;
begin
  Result := FLastTestQuery;
end;

function TJDBCConnection.IdleSinceMs: QWord;
begin
  Result := FIdleSinceMs;
end;

procedure TJDBCConnection.StampIdle;
begin
  FIdleSinceMs := GetTickCount64;
end;

procedure TJDBCConnection.SetValidHook(H: TIsValidFunc);
begin
  IsValidHook := H;
end;

function TJDBCConnection.HasValidHook: Boolean;
begin
  Result := Assigned(IsValidHook);
end;

procedure TJDBCConnection.PoisonNextValidation;
begin
  ForceInvalid := True;
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
