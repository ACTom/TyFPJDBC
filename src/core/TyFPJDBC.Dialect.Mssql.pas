unit TyFPJDBC.Dialect.Mssql;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, TyFPJDBC.Dialect.Api, TyFPJDBC.Dialect.Base;
function MssqlDialect: IJdbcDialect;
implementation
type
  TMs = class(TBaseDialect)
    function PagedSQL(const SQL: string; Limit, Offset: Int64): string; override;
    function QuoteIdent(const N: string): string; override;
  end;
function TMs.PagedSQL(const SQL: string; Limit, Offset: Int64): string;
begin
  { OFFSET/FETCH requires ORDER BY; callers order by key. FId guards misuse. }
  Result := Trim(SQL) + ' OFFSET ' + IntToStr(Offset) + ' ROWS FETCH NEXT ' +
    IntToStr(Limit) + ' ROWS ONLY';
end;
function TMs.QuoteIdent(const N: string): string;
begin
  Result := '[' + StringReplace(N, ']', ']]', [rfReplaceAll]) + ']';
end;
var
  G: IJdbcDialect = nil;
function MssqlDialect: IJdbcDialect;
begin
  if G = nil then
  begin
    G := TMs.Create('mssql');
    RegisterDialect(G);
  end;
  Result := G;
end;
initialization
  MssqlDialect;
end.
