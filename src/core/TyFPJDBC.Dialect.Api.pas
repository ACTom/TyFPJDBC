unit TyFPJDBC.Dialect.Api;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, TyFPJDBC.Handles;

type
  { Dialect contract: paging, identifier quoting, key-return strategy.
    Implementations are pure logic (no I/O), unknown driver ids raise 08000. }
  IJdbcDialect = interface
    ['{A1B2C3D4-1111-4222-8333-444455556666}']
    function DialectId: string;
    function PagedSQL(const SQL: string; Limit, Offset: Int64): string;
    function QuoteIdent(const N: string): string;
    function KeyReturn(const Table, Key: string): string;
  end;

function DialectFor(const DriverId: string): IJdbcDialect;
procedure RegisterDialect(D: IJdbcDialect);

implementation

uses
  Classes;

var
  GDialects: TInterfaceList = nil;

function List: TInterfaceList;
begin
  if GDialects = nil then
    GDialects := TInterfaceList.Create;
  Result := GDialects;
end;

procedure RegisterDialect(D: IJdbcDialect);
begin
  List.Add(D);
end;

function DialectFor(const DriverId: string): IJdbcDialect;
var
  i: Integer;
  id: string;
begin
  id := LowerCase(Trim(DriverId));
  for i := 0 to List.Count - 1 do
    if IJdbcDialect(List[i]).DialectId = id then
      Exit(IJdbcDialect(List[i]));
  raise EJDBCError.CreateChain('unknown dialect', '08000', 40, DriverId);
end;

end.
