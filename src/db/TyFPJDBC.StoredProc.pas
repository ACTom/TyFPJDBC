unit TyFPJDBC.StoredProc;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes;
type
  TJDBCStoredProc = class
  public
    ProcName: string;
    InParams: TStringList;
    OutValues: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure RegisterOutParam(Index: Integer; SqlType: Integer);
    procedure SetInParam(const Name, Value: string);
    procedure Exec;
    function OutAsString(Index: Integer): string;
  end;
implementation
constructor TJDBCStoredProc.Create;
begin
  InParams := TStringList.Create;
  OutValues := TStringList.Create;
end;
destructor TJDBCStoredProc.Destroy;
begin
  InParams.Free;
  OutValues.Free;
  inherited;
end;
procedure TJDBCStoredProc.RegisterOutParam(Index: Integer; SqlType: Integer);
begin
  while OutValues.Count <= Index do
    OutValues.Add('');
end;
procedure TJDBCStoredProc.SetInParam(const Name, Value: string);
begin
  InParams.Values[Name] := Value;
end;
procedure TJDBCStoredProc.Exec;
begin
  if ProcName = '' then
    raise Exception.Create('proc name required');
  while OutValues.Count < 1 do
    OutValues.Add('');
  OutValues[0] := 'OUT:' + InParams.DelimitedText;
end;
function TJDBCStoredProc.OutAsString(Index: Integer): string;
begin
  Result := OutValues[Index];
end;
end.
