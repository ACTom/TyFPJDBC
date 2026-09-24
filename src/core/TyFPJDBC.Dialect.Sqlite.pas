unit TyFPJDBC.Dialect.Sqlite;
{$mode objfpc}{$H+}
interface
uses
  TyFPJDBC.Dialect.Api, TyFPJDBC.Dialect.Base;
function SqliteDialect: IJdbcDialect;
implementation
var
  G: IJdbcDialect = nil;
function SqliteDialect: IJdbcDialect;
begin
  if G = nil then
  begin
    G := TBaseDialect.Create('sqlite');
    RegisterDialect(G);
  end;
  Result := G;
end;
initialization
  SqliteDialect;
end.
