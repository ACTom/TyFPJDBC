program TestTypeMap;

{$mode objfpc}{$H+}

uses
  SysUtils, DB, TypInfo, TyFPJDBC.&Type.Map;

var
  PassCount: Integer = 0;
  FailCount: Integer = 0;

function FTName(f: TFieldType): string;
begin
  Result := GetEnumName(TypeInfo(TFieldType), Ord(f));
end;

procedure CheckMap(const J: string; Expected: TFieldType);
var
  got: TFieldType;
begin
  got := TJdbcTypeMap.ToFieldType(J);
  if got = Expected then
  begin
    Inc(PassCount);
    WriteLn('PASS: ', J, ' -> ', FTName(got));
  end
  else
  begin
    Inc(FailCount);
    WriteLn('FAIL: ', J, ' got ', FTName(got), ' want ', FTName(Expected));
  end;
end;

procedure CheckStream(const J: string; Expected: Boolean);
var
  got: Boolean;
begin
  got := TJdbcTypeMap.NeedStream(J);
  if got = Expected then
  begin
    Inc(PassCount);
    WriteLn('PASS: stream(', J, ') = ', got);
  end
  else
  begin
    Inc(FailCount);
    WriteLn('FAIL: stream(', J, ') got ', got, ' want ', Expected);
  end;
end;

begin
  CheckMap('VARCHAR', ftWideString);
  CheckMap('CHARACTER VARYING', ftWideString);
  CheckMap('NVARCHAR', ftWideString);
  CheckMap('CHAR', ftWideString);
  CheckMap('CHARACTER', ftWideString);
  CheckMap('TEXT', ftWideMemo);
  CheckMap('CLOB', ftWideMemo);
  CheckMap('NCLOB', ftWideMemo);
  CheckMap('SQLXML', ftWideMemo);
  CheckMap('JSON', ftWideMemo);
  CheckMap('JSONB', ftWideMemo);
  CheckMap('UUID', ftWideMemo);
  CheckMap('INTEGER', ftInteger);
  CheckMap('INT', ftInteger);
  CheckMap('SMALLINT', ftInteger);
  CheckMap('INT2', ftInteger);
  CheckMap('BIGINT', ftLargeint);
  CheckMap('INT8', ftLargeint);
  CheckMap('NUMERIC', ftFmtBCD);
  CheckMap('DECIMAL', ftFmtBCD);
  CheckMap('FLOAT', ftFloat);
  CheckMap('FLOAT8', ftFloat);
  CheckMap('DOUBLE', ftFloat);
  CheckMap('DOUBLE PRECISION', ftFloat);
  CheckMap('REAL', ftFloat);
  CheckMap('FLOAT4', ftFloat);
  CheckMap('BOOLEAN', ftBoolean);
  CheckMap('BOOL', ftBoolean);
  CheckMap('BIT', ftBoolean);
  CheckMap('DATE', ftDate);
  CheckMap('TIME', ftTime);
  CheckMap('TIMESTAMP', ftDateTime);
  CheckMap('TIMESTAMP WITH TIME ZONE', ftDateTime);
  CheckMap('BLOB', ftBlob);
  CheckMap('BYTEA', ftBlob);
  CheckMap('BINARY', ftBlob);
  CheckMap('VARBINARY', ftBlob);
  CheckMap('IMAGE', ftBlob);
  CheckMap('ARRAY', ftWideMemo);
  CheckMap('STRUCT', ftWideMemo);
  CheckMap('WHATEVER_XYZ', ftWideString);
  CheckMap('varchar', ftWideString);
  CheckMap('numeric(10,2)', ftFmtBCD);
  CheckStream('BLOB', True);
  CheckStream('BYTEA', True);
  CheckStream('BINARY', True);
  CheckStream('VARBINARY', True);
  CheckStream('VARCHAR', False);
  CheckStream('CLOB', False);
  CheckStream('INTEGER', False);
  WriteLn('TOTAL pass=', PassCount, ' fail=', FailCount);
  if FailCount > 0 then
    Halt(1);
end.
