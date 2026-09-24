unit TyFPJDBC.Dialect.Pg;
{$mode objfpc}{$H+}
interface
uses
  TyFPJDBC.Dialect.Api, TyFPJDBC.Dialect.Base;
function PgDialect: IJdbcDialect;
implementation
type
  TPg = class(TBaseDialect)
    function KeyReturn(const Table, Key: string): string; override;
  end;
function TPg.KeyReturn(const Table, Key: string): string;
begin
  Result := ' RETURNING ' + QuoteIdent(Key);
end;
var
  G: IJdbcDialect = nil;
function PgDialect: IJdbcDialect;
begin
  if G = nil then
  begin
    G := TPg.Create('postgresql');
    RegisterDialect(G);
  end;
  Result := G;
end;
initialization
  PgDialect;
end.
