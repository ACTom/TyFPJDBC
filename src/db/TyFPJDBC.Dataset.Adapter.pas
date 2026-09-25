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
    function MapTypeFor(const DriverId, JdbcType: string; out AsMemo: Boolean): TFieldType;
    function MapByCode(Code: Integer; out AsMemo: Boolean): TFieldType;
    procedure BuildFields(AQuery: TBufDataset; Names, TypeNames: TStrings);
    procedure FillField(F: TField; const U: UTF8String);
    procedure FillWindow(AQuery: TBufDataset; const Rows: TJdbcRows);
    procedure FillPage(AQuery: TBufDataset; const Page: TFetchPage);
    function CollectRow(AQuery: TBufDataset): TBoundRow;
  end;

implementation

uses
  TyFPJDBC.Config, TyFPJDBC.Driver.Registry;

type
  TTypeAlias = record
    Name, Cls: string;
    Memo: Boolean;
  end;

const
  GlobalTypeAliases: array[0..56] of TTypeAlias = (
    (Name: 'VARCHAR'; Cls: 'widestring'; Memo: False),
    (Name: 'CHARACTER VARYING'; Cls: 'widestring'; Memo: False),
    (Name: 'NVARCHAR'; Cls: 'widestring'; Memo: False),
    (Name: 'CHAR'; Cls: 'widestring'; Memo: False),
    (Name: 'CHARACTER'; Cls: 'widestring'; Memo: False),
    (Name: 'NCHAR'; Cls: 'widestring'; Memo: False),
    (Name: 'CLOB'; Cls: 'widememo'; Memo: True),
    (Name: 'NCLOB'; Cls: 'widememo'; Memo: True),
    (Name: 'TEXT'; Cls: 'widememo'; Memo: True),
    (Name: 'NTEXT'; Cls: 'widememo'; Memo: True),
    (Name: 'SQLXML'; Cls: 'widememo'; Memo: True),
    (Name: 'JSON'; Cls: 'widememo'; Memo: True),
    (Name: 'JSONB'; Cls: 'widememo'; Memo: True),
    (Name: 'UUID'; Cls: 'widememo'; Memo: True),
    (Name: 'XML'; Cls: 'widememo'; Memo: True),
    (Name: 'ARRAY'; Cls: 'widememo'; Memo: True),
    (Name: 'STRUCT'; Cls: 'widememo'; Memo: True),
    (Name: 'OTHER'; Cls: 'widememo'; Memo: True),
    (Name: 'INTEGER'; Cls: 'integer'; Memo: False),
    (Name: 'INT'; Cls: 'integer'; Memo: False),
    (Name: 'SMALLINT'; Cls: 'integer'; Memo: False),
    (Name: 'INT2'; Cls: 'integer'; Memo: False),
    (Name: 'SERIAL'; Cls: 'integer'; Memo: False),
    (Name: 'TINYINT'; Cls: 'integer'; Memo: False),
    (Name: 'MEDIUMINT'; Cls: 'integer'; Memo: False),
    (Name: 'YEAR'; Cls: 'integer'; Memo: False),
    (Name: 'BIGINT'; Cls: 'largeint'; Memo: False),
    (Name: 'INT8'; Cls: 'largeint'; Memo: False),
    (Name: 'BIGSERIAL'; Cls: 'largeint'; Memo: False),
    (Name: 'SMALLSERIAL'; Cls: 'largeint'; Memo: False),
    (Name: 'NUMERIC'; Cls: 'fmtbcd'; Memo: False),
    (Name: 'DECIMAL'; Cls: 'fmtbcd'; Memo: False),
    (Name: 'MONEY'; Cls: 'fmtbcd'; Memo: False),
    (Name: 'SMALLMONEY'; Cls: 'fmtbcd'; Memo: False),
    (Name: 'FLOAT'; Cls: 'float'; Memo: False),
    (Name: 'FLOAT8'; Cls: 'float'; Memo: False),
    (Name: 'DOUBLE'; Cls: 'float'; Memo: False),
    (Name: 'DOUBLE PRECISION'; Cls: 'float'; Memo: False),
    (Name: 'REAL'; Cls: 'float'; Memo: False),
    (Name: 'FLOAT4'; Cls: 'float'; Memo: False),
    (Name: 'BOOLEAN'; Cls: 'boolean'; Memo: False),
    (Name: 'BOOL'; Cls: 'boolean'; Memo: False),
    (Name: 'BIT'; Cls: 'boolean'; Memo: False),
    (Name: 'DATE'; Cls: 'date'; Memo: False),
    (Name: 'TIME'; Cls: 'time'; Memo: False),
    (Name: 'TIMETZ'; Cls: 'time'; Memo: False),
    (Name: 'TIMESTAMP'; Cls: 'datetime'; Memo: False),
    (Name: 'TIMESTAMPTZ'; Cls: 'datetime'; Memo: False),
    (Name: 'DATETIME'; Cls: 'datetime'; Memo: False),
    (Name: 'SMALLDATETIME'; Cls: 'datetime'; Memo: False),
    (Name: 'BLOB'; Cls: 'blob'; Memo: False),
    (Name: 'BYTEA'; Cls: 'blob'; Memo: False),
    (Name: 'BINARY'; Cls: 'blob'; Memo: False),
    (Name: 'VARBINARY'; Cls: 'blob'; Memo: False),
    (Name: 'IMAGE'; Cls: 'blob'; Memo: False),
    (Name: 'LONGBLOB'; Cls: 'blob'; Memo: False),
    (Name: 'BYTE'; Cls: 'blob'; Memo: False)
  );

function NormTypeName(const JdbcType: string): string;
var
  t: string;
  p: Integer;
begin
  t := UpperCase(Trim(JdbcType));
  p := Pos('(', t);
  if p > 0 then
    t := Copy(t, 1, p - 1);
  p := Pos(' ', t);
  if p > 0 then
    t := Copy(t, 1, p - 1);
  Result := Trim(t);
end;

function ClassToFieldType(const Cls: string; out AsMemo: Boolean): TFieldType;
var
  c: string;
begin
  AsMemo := False;
  c := LowerCase(Trim(Cls));
  if c = 'widestring' then Exit(ftWideString);
  if c = 'integer' then Exit(ftInteger);
  if c = 'largeint' then Exit(ftLargeint);
  if c = 'fmtbcd' then Exit(ftFmtBCD);
  if c = 'float' then Exit(ftFloat);
  if c = 'boolean' then Exit(ftBoolean);
  if c = 'date' then Exit(ftDate);
  if c = 'time' then Exit(ftTime);
  if c = 'datetime' then Exit(ftDateTime);
  if c = 'blob' then Exit(ftBlob);
  if c = 'widememo' then begin AsMemo := True; Exit(ftWideMemo); end;
  raise EJDBCError.CreateChain('unknown type class', 'HY000', 45, Cls);
end;

constructor TDatasetAdapter.Create;
begin
  inherited Create;
  UnknownTypeFallback := ufError;
end;

function TDatasetAdapter.MapType(const JdbcType: string; out AsMemo: Boolean): TFieldType;
var
  base: string;
  i: Integer;
begin
  base := NormTypeName(JdbcType);
  for i := 0 to High(GlobalTypeAliases) do
    if GlobalTypeAliases[i].Name = base then
    begin
      AsMemo := GlobalTypeAliases[i].Memo;
      Exit(ClassToFieldType(GlobalTypeAliases[i].Cls, AsMemo));
    end;
  case UnknownTypeFallback of
    ufString: Exit(ftWideString);
    ufBytes: Exit(ftBlob);
  else
    // single truth table with MapByCode
    raise EJDBCError.CreateChain('unknown jdbc type', 'HY000', 45, JdbcType);
  end;
end;

function TDatasetAdapter.MapTypeFor(const DriverId, JdbcType: string;
  out AsMemo: Boolean): TFieldType;
var
  e: TDriverEntry;
  base, item, nm: string;
  i, q: Integer;
begin
  base := NormTypeName(JdbcType);
  try
    e := TDriverRegistry.Find(DriverId);
  except
    Result := MapType(JdbcType, AsMemo);
    Exit;
  end;
  for i := 0 to High(e.TypeAliases) do
  begin
    item := e.TypeAliases[i];
    q := Pos('=', item);
    if q <= 0 then
      Continue;
    nm := UpperCase(Trim(Copy(item, 1, q - 1)));
    if nm = base then
    begin
      Result := ClassToFieldType(Trim(Copy(item, q + 1, MaxInt)), AsMemo);
      Exit;
    end;
  end;
  Result := MapType(JdbcType, AsMemo);
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
