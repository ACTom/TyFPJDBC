unit TyFPJDBC.Dialect.Oracle;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, TyFPJDBC.Dialect.Api, TyFPJDBC.Dialect.Base;
function OracleDialect: IJdbcDialect;
implementation
type
  TOra = class(TBaseDialect)
    function PagedSQL(const SQL: string; Limit, Offset: Int64): string; override;
  end;
function TOra.PagedSQL(const SQL: string; Limit, Offset: Int64): string;
begin
  { 12c+ row-limiting clause; callers order by key for determinism. }
  Result := Trim(SQL) + ' OFFSET ' + IntToStr(Offset) +
    ' ROWS FETCH FIRST ' + IntToStr(Limit) + ' ROWS ONLY';
end;
var
  G: IJdbcDialect = nil;
function OracleDialect: IJdbcDialect;
begin
  if G = nil then
  begin
    G := TOra.Create('oracle');
    RegisterDialect(G);
  end;
  Result := G;
end;
initialization
  OracleDialect;
end.
