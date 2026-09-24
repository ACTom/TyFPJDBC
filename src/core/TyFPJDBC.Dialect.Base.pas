unit TyFPJDBC.Dialect.Base;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, TyFPJDBC.Dialect.Api;

type
  TBaseDialect = class(TInterfacedObject, IJdbcDialect)
  protected
    FId: string;
    function Q(const N, L, R: string): string;
  public
    constructor Create(const Id: string);
    function DialectId: string;
    function PagedSQL(const SQL: string; Limit, Offset: Int64): string; virtual;
    function QuoteIdent(const N: string): string; virtual;
    function KeyReturn(const Table, Key: string): string; virtual;
  end;

implementation

constructor TBaseDialect.Create(const Id: string);
begin
  inherited Create;
  FId := LowerCase(Trim(Id));
end;

function TBaseDialect.DialectId: string;
begin
  Result := FId;
end;

function TBaseDialect.Q(const N, L, R: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(N) do
    if N[i] = R then
      Result := Result + R + R
    else
      Result := Result + N[i];
  Result := L + Result + R;
end;

function TBaseDialect.PagedSQL(const SQL: string; Limit, Offset: Int64): string;
begin
  Result := Trim(SQL) + ' LIMIT ' + IntToStr(Limit) + ' OFFSET ' + IntToStr(Offset);
end;

function TBaseDialect.QuoteIdent(const N: string): string;
begin
  Result := Q(N, '"', '"');
end;

function TBaseDialect.KeyReturn(const Table, Key: string): string;
begin
  Result := '';
end;

end.
