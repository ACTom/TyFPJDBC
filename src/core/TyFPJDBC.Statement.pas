unit TyFPJDBC.Statement;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, syncobjs;
type
  TRowValues = array of string;
  TRowBlock = array of TRowValues;

  TFetchFunc = function(Offset, Limit: Integer; out Total: Integer): TRowBlock of object;

  TJDBCStatement = class
  private
    FLock: TCriticalSection;
    function IsCancelled: Boolean;
    procedure WaitInterruptible(WorkMs: Integer; StartTick: QWord);
  public
    SQL: string;
    QueryTimeoutSecs: Integer;
    Cancelled: Boolean;
    SimulateSlowMs: Integer;
    BatchItemMs: Integer;
    OnFetch: TFetchFunc;
    constructor Create;
    destructor Destroy; override;
    procedure SetQueryTimeout(Secs: Integer);
    procedure Cancel;
    procedure ResetCancel;
    function ExecUpdate(AffectedHook: Integer): Integer;
    function ExecBatch(Count: Integer): Integer;
    function FetchBatch(Offset, Limit: Integer; out Total: Integer): TRowBlock;
  end;

implementation

uses
  TyFPJDBC.Connection;

constructor TJDBCStatement.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TJDBCStatement.Destroy;
begin
  FLock.Free;
  inherited;
end;

function TJDBCStatement.IsCancelled: Boolean;
begin
  FLock.Enter;
  try
    Result := Cancelled;
  finally
    FLock.Leave;
  end;
end;

procedure TJDBCStatement.SetQueryTimeout(Secs: Integer);
begin
  if Secs < 0 then
    raise EJDBCError.CreateChain('bad timeout', 'HY092', 20, 'timeout<0');
  QueryTimeoutSecs := Secs;
end;

procedure TJDBCStatement.Cancel;
begin
  FLock.Enter;
  try
    Cancelled := True;
  finally
    FLock.Leave;
  end;
end;

procedure TJDBCStatement.ResetCancel;
begin
  FLock.Enter;
  try
    Cancelled := False;
  finally
    FLock.Leave;
  end;
end;

procedure TJDBCStatement.WaitInterruptible(WorkMs: Integer; StartTick: QWord);
var
  remaining: Integer;
begin
  remaining := WorkMs;
  while remaining > 0 do
  begin
    if IsCancelled then
      raise EJDBCError.CreateChain('cancelled', 'HY008', 21, 'statement cancelled');
    if (QueryTimeoutSecs > 0) and (GetTickCount64 - StartTick > QWord(QueryTimeoutSecs) * 1000) then
      raise EJDBCError.CreateChain('timeout', 'HYT00', 22, 'query timeout');
    if remaining > 10 then
    begin
      Sleep(10);
      Dec(remaining, 10);
    end
    else
    begin
      Sleep(remaining);
      remaining := 0;
    end;
  end;
  if IsCancelled then
    raise EJDBCError.CreateChain('cancelled', 'HY008', 21, 'statement cancelled');
  if (QueryTimeoutSecs > 0) and (GetTickCount64 - StartTick > QWord(QueryTimeoutSecs) * 1000) then
    raise EJDBCError.CreateChain('timeout', 'HYT00', 22, 'query timeout');
end;

function TJDBCStatement.ExecUpdate(AffectedHook: Integer): Integer;
var
  start: QWord;
begin
  start := GetTickCount64;
  WaitInterruptible(SimulateSlowMs, start);
  Result := AffectedHook;
end;

function TJDBCStatement.ExecBatch(Count: Integer): Integer;
var
  i: Integer;
  start: QWord;
begin
  start := GetTickCount64;
  for i := 1 to Count do
  begin
    if BatchItemMs > 0 then
      WaitInterruptible(BatchItemMs, start)
    else
    begin
      if (i mod 64 = 0) then
      begin
        if IsCancelled then
          raise EJDBCError.CreateChain('cancelled', 'HY008', 23, 'batch cancelled');
        if (QueryTimeoutSecs > 0) and (GetTickCount64 - start > QWord(QueryTimeoutSecs) * 1000) then
          raise EJDBCError.CreateChain('timeout', 'HYT00', 22, 'batch timeout');
      end;
    end;
  end;
  if IsCancelled then
    raise EJDBCError.CreateChain('cancelled', 'HY008', 23, 'batch cancelled');
  Result := Count;
end;

function TJDBCStatement.FetchBatch(Offset, Limit: Integer; out Total: Integer): TRowBlock;
begin
  Result := nil;
  if IsCancelled then
    raise EJDBCError.CreateChain('cancelled', 'HY008', 24, 'fetch cancelled');
  if not Assigned(OnFetch) then
  begin
    Total := 0;
    SetLength(Result, 0);
    Exit;
  end;
  Result := OnFetch(Offset, Limit, Total);
end;

end.
