unit TyFPJDBC.Handles;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes;
type
  { Opaque handles: Java owns pool/conn/stmt/cursor, Pascal holds ids only. }
  TJdbcPoolId = Int64;
  TJdbcConnId = Int64;
  TJdbcStmtId = Int64;
  TJdbcCursorId = Int64;

  EJDBCError = class(Exception)
    SQLState: string;
    VendorCode: Integer;
    Chain: TStringList;
    constructor CreateChain(const Msg, State: string; Code: Integer; const Next: string);
    destructor Destroy; override;
  end;

function JdbcOk(const Id: Int64): Boolean;
procedure CheckHandle(const Name: string; Id: Int64);

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

function JdbcOk(const Id: Int64): Boolean;
begin
  Result := Id > 0;
end;

procedure CheckHandle(const Name: string; Id: Int64);
begin
  if Id <= 0 then
    raise EJDBCError.CreateChain('bad handle', 'HY000', 99, Name + '=0');
end;

end.
