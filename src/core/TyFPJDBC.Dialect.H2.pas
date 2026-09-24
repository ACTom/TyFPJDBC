unit TyFPJDBC.Dialect.H2;
{$mode objfpc}{$H+}
interface
uses
  TyFPJDBC.Dialect.Api, TyFPJDBC.Dialect.Base;
function H2Dialect: IJdbcDialect;
implementation
var
  G: IJdbcDialect = nil;
function H2Dialect: IJdbcDialect;
begin
  if G = nil then
  begin
    G := TBaseDialect.Create('h2');
    RegisterDialect(G);
  end;
  Result := G;
end;
initialization
  H2Dialect;
end.
