unit TyFPJDBC.Statement;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes;
type
  TRowValues = array of string;
  TRowBlock = array of TRowValues;

  TFetchFunc = function(Offset, Limit: Integer; out Total: Integer): TRowBlock of object;

  TJDBCStatement = class
  public
    SQL: string;
    QueryTimeoutSecs: Integer;
    Cancelled: Boolean;
    SimulateSlowMs: Integer;
    OnFetch: TFetchFunc;
    procedure SetQueryTimeout(Secs: Integer);
    procedure Cancel;
    function ExecUpdate(AffectedHook: Integer): Integer;
    function ExecBatch(Count: Integer): Integer;
    function FetchBatch(Offset, Limit: Integer; out Total: Integer): TRowBlock;
  end;

implementation

uses
  TyFPJDBC.Connection;

procedure TJDBCStatement.SetQueryTimeout(Secs: Integer);
begin
  if Secs < 0 then
    raise EJDBCError.CreateChain('bad timeout', 'HY092', 20, 'timeout<0');
  QueryTimeoutSecs := Secs;
end;

procedure TJDBCStatement.Cancel;
begin
  Cancelled := True;
end;

function TJDBCStatement.ExecUpdate(AffectedHook: Integer): Integer;
begin
  if Cancelled then
    raise EJDBCError.CreateChain('cancelled', 'HY008', 21, 'statement cancelled');
  if (QueryTimeoutSecs > 0) and (SimulateSlowMs > QueryTimeoutSecs * 1000) then
    raise EJDBCError.CreateChain('timeout', 'HYT00', 22, 'query timeout');
  Result := AffectedHook;
end;

function TJDBCStatement.ExecBatch(Count: Integer): Integer;
begin
  if Cancelled then
    raise EJDBCError.CreateChain('cancelled', 'HY008', 23, 'batch cancelled');
  Result := Count;
end;

function TJDBCStatement.FetchBatch(Offset, Limit: Integer; out Total: Integer): TRowBlock;
begin
  if Cancelled then
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
