unit TyFPJDBC.Dataset.Adapter;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, DB, BufDataset, TyFPJDBC.Handles,
  TyFPJDBC.JNI.BridgeV2, TyFPJDBC.Command;

type
  { Window-to-dataset mapping. FieldDefs come from cursor metadata
    (names + JDBC type names); unknown types raise unless
    UnknownTypeFallback is set explicitly. }
  TUnknownFallback = (ufError, ufString, ufBytes);

  TDatasetAdapter = class
  public
    UnknownTypeFallback: TUnknownFallback;
    constructor Create;
    function MapType(const JdbcType: string; out AsMemo: Boolean): TFieldType;
    procedure BuildFields(AQuery: TBufDataset; Names, TypeNames: TStrings);
    procedure FillField(F: TField; const U: UTF8String);
    procedure FillWindow(AQuery: TBufDataset; const Rows: TV2Rows);
    function CollectRow(AQuery: TBufDataset): TBoundRow;
  end;

implementation

constructor TDatasetAdapter.Create;
begin
  inherited Create;
  UnknownTypeFallback := ufError;
end;

function TDatasetAdapter.MapType(const JdbcType: string; out AsMemo: Boolean): TFieldType;
var
  t, base: string;
  p: Integer;
begin
  AsMemo := False;
  t := UpperCase(Trim(JdbcType));
  p := Pos('(', t);
  if p > 0 then
    t := Copy(t, 1, p - 1);
  p := Pos(' ', t);
  if p > 0 then
    t := Copy(t, 1, p - 1);
  t := Trim(t);
  base := t;
  if (base = 'VARCHAR') or (base = 'CHARACTER VARYING') or (base = 'NVARCHAR') or
    (base = 'CHAR') or (base = 'CHARACTER') or (base = 'NCHAR') then
    Exit(ftWideString);
  if (base = 'CLOB') or (base = 'NCLOB') or (base = 'TEXT') or (base = 'NTEXT') or
    (base = 'SQLXML') or (base = 'JSON') or (base = 'JSONB') or (base = 'UUID') or
    (base = 'XML') then
  begin
    AsMemo := True;
    Exit(ftWideMemo);
  end;
  if (base = 'INTEGER') or (base = 'INT') or (base = 'SMALLINT') or (base = 'INT2') or
    (base = 'SERIAL') or (base = 'TINYINT') or (base = 'MEDIUMINT') or (base = 'YEAR') then
    Exit(ftInteger);
  if (base = 'BIGINT') or (base = 'INT8') or (base = 'BIGSERIAL') or
    (base = 'SMALLSERIAL') then
    Exit(ftLargeint);
  if (base = 'NUMERIC') or (base = 'DECIMAL') or (base = 'MONEY') or
    (base = 'SMALLMONEY') then
    Exit(ftFmtBCD);
  if (base = 'FLOAT') or (base = 'FLOAT8') or (base = 'DOUBLE') or
    (base = 'DOUBLE PRECISION') or (base = 'REAL') or (base = 'FLOAT4') then
    Exit(ftFloat);
  if (base = 'BOOLEAN') or (base = 'BOOL') or (base = 'BIT') then
    Exit(ftBoolean);
  if base = 'DATE' then
    Exit(ftDate);
  if (base = 'TIME') or (base = 'TIMETZ') then
    Exit(ftTime);
  if (base = 'TIMESTAMP') or (base = 'TIMESTAMPTZ') or (base = 'DATETIME') or
    (base = 'SMALLDATETIME') then
    Exit(ftDateTime);
  if (base = 'BLOB') or (base = 'BYTEA') or (base = 'BINARY') or (base = 'VARBINARY') or
    (base = 'IMAGE') or (base = 'LONGBLOB') or (base = 'BYTE') then
    Exit(ftBlob);
  if (base = 'ARRAY') or (base = 'STRUCT') or (base = 'OTHER') then
  begin
    AsMemo := True;
    Exit(ftWideMemo);
  end;
  case UnknownTypeFallback of
    ufString: Exit(ftWideString);
    ufBytes: Exit(ftBlob);
  else
    raise EJDBCError.CreateChain('unknown jdbc type', 'HY000', 45, JdbcType);
  end;
end;

procedure TDatasetAdapter.BuildFields(AQuery: TBufDataset; Names, TypeNames: TStrings);
var
  i: Integer;
  ft: TFieldType;
  memo: Boolean;
begin
  AQuery.Close;
  AQuery.FieldDefs.Clear;
  for i := 0 to Names.Count - 1 do
  begin
    ft := MapType(TypeNames[i], memo);
    if ft in [ftWideString, ftWideMemo] then
      AQuery.FieldDefs.Add(Names[i], ft, 255)
    else
      AQuery.FieldDefs.Add(Names[i], ft);
  end;
  AQuery.CreateDataset;
  AQuery.Open;
end;

procedure TDatasetAdapter.FillField(F: TField; const U: UTF8String);
begin
  { Proven V1 pattern: AsUTF8String bypasses the ANSI codepage on this FPC
    build; UTF8Decode/AsWideString corrupts CJK here (verified red). }
  if F.IsNull and (U = '') then
    Exit;
  if U = '' then
  begin
    F.Clear;
    Exit;
  end;
  if F.DataType = ftBlob then
  begin
    if (Length(U) > 6) and (Copy(U, 1, 6) = '<blob:') then
      F.Clear
    else
      F.AsUTF8String := U;
    Exit;
  end;
  F.AsUTF8String := U;
end;

procedure TDatasetAdapter.FillWindow(AQuery: TBufDataset; const Rows: TV2Rows);
var
  r, c: Integer;
begin
  for r := 0 to High(Rows) do
  begin
    AQuery.Append;
    for c := 0 to AQuery.FieldCount - 1 do
      if c <= High(Rows[r]) then
      begin
        if Rows[r][c] = '' then
        begin
          { Empty string from JNI means SQL NULL (fetchWindow maps null to
            nil jstring). Real empty strings round-trip as '' too; counts
            must use IS NULL, same contract as V1. }
          AQuery.Fields[c].Clear;
        end
        else
          FillField(AQuery.Fields[c], Rows[r][c]);
      end;
    AQuery.Post;
  end;
end;

function TDatasetAdapter.CollectRow(AQuery: TBufDataset): TBoundRow;
var
  i: Integer;
  F: TField;
  s: UTF8String;
begin
  { Collect via AsUTF8String (proven V1 pattern): the field content leaves
    as exact UTF-8 bytes for JNI, no ANSI round trip. }
  SetLength(Result, AQuery.FieldCount);
  for i := 0 to AQuery.FieldCount - 1 do
  begin
    F := AQuery.Fields[i];
    if F.IsNull then
    begin
      Result[i] := BNull(SQL_VARCHAR);
      Continue;
    end;
    case F.DataType of
      ftInteger, ftSmallint:
        Result[i] := BInt(F.AsInteger);
      ftLargeint, ftAutoInc:
        Result[i] := BInt64(F.AsLargeInt);
      ftFloat, ftCurrency, ftBCD, ftFmtBCD:
        begin
          s := F.AsUTF8String;
          Result[i] := BBigDec(StringReplace(string(s), ',', '.', [rfReplaceAll]));
        end;
      ftBoolean:
        Result[i] := BInt(Ord(F.AsBoolean));
      ftDate:
        Result[i] := BDate(FormatDateTime('yyyy-mm-dd', F.AsDateTime));
      ftTime:
        Result[i] := BTime(FormatDateTime('hh:nn:ss', F.AsDateTime));
      ftDateTime:
        Result[i] := BStamp(FormatDateTime('yyyy-mm-dd hh:nn:ss', F.AsDateTime));
    else
      Result[i] := BStr(F.AsUTF8String);
    end;
  end;
end;

end.
