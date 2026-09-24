unit TyFPJDBC.Dialect.Mysql;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, TyFPJDBC.Dialect.Api, TyFPJDBC.Dialect.Base;
function MysqlDialect: IJdbcDialect;
function MariaDialect: IJdbcDialect;
implementation
type
  TMy = class(TBaseDialect)
    function QuoteIdent(const N: string): string; override;
  end;
function TMy.QuoteIdent(const N: string): string;
begin
  Result := Q(N, '`', '`');
end;
var
  G1, G2: IJdbcDialect;
function MysqlDialect: IJdbcDialect;
begin
  if G1 = nil then
  begin
    G1 := TMy.Create('mysql');
    RegisterDialect(G1);
  end;
  Result := G1;
end;
function MariaDialect: IJdbcDialect;
begin
  if G2 = nil then
  begin
    G2 := TMy.Create('mariadb');
    RegisterDialect(G2);
  end;
  Result := G2;
end;
initialization
  MysqlDialect;
  MariaDialect;
end.
