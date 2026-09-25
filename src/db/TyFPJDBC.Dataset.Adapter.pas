unit TyFPJDBC.Dataset.Adapter;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, DB, BufDataset, TyFPJDBC.Handles,
  TyFPJDBC.JNI.Bridge, TyFPJDBC.Command;

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
    function MapByCode(Code: Integer; out AsMemo: Boolean): TFieldType;
    procedure BuildFields(AQuery: TBufDataset; Names, TypeNames: TStrings);
    procedure FillField(F: TField; const U: UTF8String);
    procedure FillWindow(AQuery: TBufDataset; const Rows: TJdbcRows);
    procedure FillPage(AQuery: TBufDataset; const Page: TFetchPage);
    function CollectRow(AQuery: TBufDataset): TBoundRow;
  end;

implementation

uses
  TyFPJDBC.Config;

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
    // single truth table with MapByCode
    raise EJDBCError.CreateChain('unknown jdbc type', 'HY000', 45, JdbcType);
  end;
end;

function TDatasetAdapter.MapByCode(Code: Integer; out AsMemo: Boolean): TFieldType;
begin
  AsMemo := False;
  case Code of
    -5: Exit(ftLargeint);
    4, 5, -6, -7: Exit(ftInteger);
    2, 3: Exit(ftFmtBCD);
    6, 7, 8: Exit(ftFloat);
    16: Exit(ftBoolean);
    91: Exit(ftDate);
    92: Exit(ftTime);
    93: Exit(ftDateTime);
    -2, -3, -4, 2004: Exit(ftBlob);
    1, 12, -9, -15: Exit(ftWideString);
    2005, 2011, 2003, 2002, 1111:
      begin AsMemo := True; Exit(ftWideMemo); end;
  end;
  case UnknownTypeFallback of
    ufString: Exit(ftWideString);
    ufBytes: Exit(ftBlob);
  else
    raise EJDBCError.CreateChain('unknown jdbc code', 'HY000', 45, IntToStr(Code));
  end;
end;

procedure TDatasetAdapter.BuildFields(AQuery: TBufDataset; Names, TypeNames: TStrings);
var
  i, wide: Integer;
  ft: TFieldType;
  memo: Boolean;
  cfg: TJdbcConfig;
begin
  AQuery.Close;
  AQuery.FieldDefs.Clear;
  cfg := TJdbcConfig.Default;
  try
    wide := cfg.Field_WideWidth;
  finally
    cfg.Free;
  end;
  for i := 0 to Names.Count - 1 do
  begin
    ft := MapType(TypeNames[i], memo);
    if ft in [ftWideString, ftWideMemo] then
      AQuery.FieldDefs.Add(Names[i], ft, wide)
    else
      AQuery.FieldDefs.Add(Names[i], ft);
  end;
  AQuery.CreateDataset;
  AQuery.Open;
end;

procedure TDatasetAdapter.FillField(F: TField; const U: UTF8String);
var
  us: string;
begin
  { Proven pattern: AsUTF8String bypasses the ANSI codepage on this FPC
    build; UTF8Decode/AsWideString corrupts CJK here (verified red). }
  if F.IsNull and (U = '') then
    Exit;
  if U = '' then
  begin
    F.Clear;
    Exit;
  end;
  if F.DataType = ftBoolean then
  begin
    us := UpperCase(Trim(U));
    F.AsBoolean := (us = '1') or (us = 'TRUE') or (us = 'T') or (us = 'Y');
    Exit;
  end;
  if F.DataType = ftBlob then
  begin
    { Blob placeholder: window carries length only; content via
      Bridge.FetchBlob. Contract, not data loss. }
    if (Length(U) > 6) and (Copy(U, 1, 6) = '<blob:') then
      F.Clear
    else
      F.AsUTF8String := U;
    Exit;
  end;
  F.AsUTF8String := U;
end;

procedure TDatasetAdapter.FillWindow(AQuery: TBufDataset; const Rows: TJdbcRows);
var
  r, c: Integer;
begin
  { Legacy: conflates empty with NULL; new code uses FillPage. }
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

procedure TDatasetAdapter.FillPage(AQuery: TBufDataset; const Page: TFetchPage);
var
  r, c: Integer;
  isNull: Boolean;
begin
  for r := 0 to High(Page.Rows) do
  begin
    AQuery.Append;
    for c := 0 to AQuery.FieldCount - 1 do
      if c <= High(Page.Rows[r]) then
      begin
        isNull := (r <= High(Page.Nulls)) and (c <= High(Page.Nulls[r])) and
          Page.Nulls[r][c];
        if isNull then
          AQuery.Fields[c].Clear
        else
          FillField(AQuery.Fields[c], Page.Rows[r][c]);
      end;
    AQuery.Post;
  end;
end;

function TDatasetAdapter.CollectRow(AQuery: TBufDataset): TBoundRow;
var
  i: Integer;
  F: TField;
  s: UTF8String;
  InvFS, LocFS: TFormatSettings;
  ms: TMemoryStream;
  bb: TBytes;
begin
  { Collect via AsUTF8String (proven V1 pattern): the field content leaves
    as exact UTF-8 bytes for JNI, no ANSI round trip. }
  SetLength(Result, AQuery.FieldCount);
  for i := 0 to AQuery.FieldCount - 1 do
  begin
    F := AQuery.Fields[i];
    if F.IsNull then
    begin
      case F.DataType of
        ftInteger, ftSmallint:
          Result[i] := BNull(4);
        ftLargeint, ftAutoInc:
          Result[i] := BNull(-5);
        ftFloat, ftCurrency, ftBCD, ftFmtBCD:
          Result[i] := BNull(8);
        ftDate:
          Result[i] := BNull(91);
        ftTime:
          Result[i] := BNull(92);
        ftDateTime:
          Result[i] := BNull(93);
        ftBlob, ftMemo, ftWideMemo:
          Result[i] := BNull(2004);
        ftBoolean:
          Result[i] := BNull(16);
      else
        Result[i] := BNull(12);
      end;
      Continue;
    end;
    case F.DataType of
      ftInteger, ftSmallint:
        Result[i] := BInt(F.AsInteger);
      ftLargeint, ftAutoInc:
        Result[i] := BInt64(F.AsLargeInt);
      ftFloat:
        begin
          InvFS := DefaultFormatSettings;
          InvFS.DecimalSeparator := '.';
          InvFS.ThousandSeparator := #0;
          s := UTF8String(FormatFloat('0.###############', F.AsFloat, InvFS));
          Result[i] := BBigDec(string(s));
        end;
      ftCurrency, ftBCD, ftFmtBCD:
        begin
          { High-precision decimals never go through Double: keep the
            dataset string and normalize separators to invariant '.'. }
          s := F.AsUTF8String;
          LocFS := DefaultFormatSettings;
          if LocFS.DecimalSeparator <> '.' then
          begin
            if LocFS.ThousandSeparator <> #0 then
              s := UTF8String(StringReplace(string(s),
                string(LocFS.ThousandSeparator), '', [rfReplaceAll]));
            s := UTF8String(StringReplace(string(s),
              string(LocFS.DecimalSeparator), '.', [rfReplaceAll]));
          end
          else if LocFS.ThousandSeparator <> #0 then
            s := UTF8String(StringReplace(string(s),
              string(LocFS.ThousandSeparator), '', [rfReplaceAll]));
          Result[i] := BBigDec(string(s));
        end;
      ftBoolean:
        Result[i] := BBool(F.AsBoolean);
      ftDate:
        Result[i] := BDate(FormatDateTime('yyyy-mm-dd', F.AsDateTime));
      ftTime:
        Result[i] := BTime(FormatDateTime('hh:nn:ss', F.AsDateTime));
      ftDateTime:
        Result[i] := BStamp(FormatDateTime('yyyy-mm-dd hh:nn:ss', F.AsDateTime));
      ftBlob:
        begin
          { Binary-safe: blob bytes via stream, never AsUTF8String which
            truncates NULs and mangles non-UTF8 bytes. }
          ms := TMemoryStream.Create;
          try
            TBlobField(F).SaveToStream(ms);
            SetLength(bb, ms.Size);
            if ms.Size > 0 then
            begin
              ms.Position := 0;
              ms.ReadBuffer(bb[0], ms.Size);
            end;
            Result[i] := BBytes(bb);
          finally
            ms.Free;
          end;
        end;
    else
      Result[i] := BStr(F.AsUTF8String);
    end;
  end;
end;

end.
