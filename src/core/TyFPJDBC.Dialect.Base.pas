unit TyFPJDBC.Dialect.Base;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, TyFPJDBC.Dialect.Api, TyFPJDBC.Driver.Registry;

type
  { Generic dialect: configured from driver-description style enums.
    No per-database subclasses; new DBs only add a TDriverEntry. }
  TGenericDialect = class(TInterfacedObject, IJdbcDialect)
  private
    FId: string;
    FPaging: TPagingStyle;
    FQuote: TQuoteStyle;
    FKeyReturn: TKeyReturnStyle;
    function Q(const N, L, R: string): string;
  public
    constructor Create(const Id: string; Paging: TPagingStyle;
      Quote: TQuoteStyle; KeyReturn: TKeyReturnStyle);
    function DialectId: string;
    function PagedSQL(const SQL: string; Limit, Offset: Int64): string;
    function QuoteIdent(const N: string): string;
    function KeyReturn(const Table, Key: string): string;
  end;

function DialectForEntry(const E: TDriverEntry): IJdbcDialect;

implementation

constructor TGenericDialect.Create(const Id: string; Paging: TPagingStyle;
  Quote: TQuoteStyle; KeyReturn: TKeyReturnStyle);
begin
  inherited Create;
  FId := LowerCase(Trim(Id));
  FPaging := Paging;
  FQuote := Quote;
  FKeyReturn := KeyReturn;
end;

function TGenericDialect.DialectId: string;
begin
  Result := FId;
end;

function TGenericDialect.Q(const N, L, R: string): string;
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

function TGenericDialect.PagedSQL(const SQL: string; Limit, Offset: Int64): string;
begin
  case FPaging of
    psOffsetFetchNext:
      Result := Trim(SQL) + ' OFFSET ' + IntToStr(Offset) + ' ROWS FETCH NEXT ' +
        IntToStr(Limit) + ' ROWS ONLY';
    psOffsetFetchFirst:
      Result := Trim(SQL) + ' OFFSET ' + IntToStr(Offset) +
        ' ROWS FETCH FIRST ' + IntToStr(Limit) + ' ROWS ONLY';
  else
    Result := Trim(SQL) + ' LIMIT ' + IntToStr(Limit) + ' OFFSET ' + IntToStr(Offset);
  end;
end;

function TGenericDialect.QuoteIdent(const N: string): string;
begin
  case FQuote of
    qsBacktick:
      Result := Q(N, '`', '`');
    qsBracket:
      Result := '[' + StringReplace(N, ']', ']]', [rfReplaceAll]) + ']';
  else
    Result := Q(N, '"', '"');
  end;
end;

function TGenericDialect.KeyReturn(const Table, Key: string): string;
begin
  if FKeyReturn = krReturning then
    Result := ' RETURNING ' + QuoteIdent(Key)
  else
    Result := '';
end;

function DialectForEntry(const E: TDriverEntry): IJdbcDialect;
begin
  Result := TGenericDialect.Create(E.Id, E.Paging, E.Quote, E.KeyReturn);
end;

end.
