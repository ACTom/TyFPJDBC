unit TyFPJDBC.&Type.Map;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, DB;
type
  TJdbcTypeMap = class
    class function ToFieldType(const J: string): TFieldType; static;
    class function NeedStream(const J: string): Boolean; static;
    class function CustomMap: TStringList; static;
    class procedure RegisterCustom(const JdbcName: string;
      F: TFieldType); static;
    class procedure ClearCustom; static;
  end;
implementation

var
  GCustom: TStringList = nil;

function FieldTypeByName(const N: string; out F: TFieldType): Boolean;
begin
  Result := True;
  if N = 'ftWideString' then F := ftWideString
  else if N = 'ftWideMemo' then F := ftWideMemo
  else if N = 'ftInteger' then F := ftInteger
  else if N = 'ftLargeint' then F := ftLargeint
  else if N = 'ftFmtBCD' then F := ftFmtBCD
  else if N = 'ftFloat' then F := ftFloat
  else if N = 'ftBoolean' then F := ftBoolean
  else if N = 'ftDate' then F := ftDate
  else if N = 'ftTime' then F := ftTime
  else if N = 'ftDateTime' then F := ftDateTime
  else if N = 'ftBlob' then F := ftBlob
  else if N = 'ftString' then F := ftString
  else if N = 'ftMemo' then F := ftMemo
  else Result := False;
end;

class function TJdbcTypeMap.CustomMap: TStringList;
begin
  if GCustom = nil then
    GCustom := TStringList.Create;
  Result := GCustom;
end;

class procedure TJdbcTypeMap.RegisterCustom(const JdbcName: string;
  F: TFieldType);
begin
  case F of
    ftWideString: CustomMap.Values[UpperCase(Trim(JdbcName))] := 'ftWideString';
    ftWideMemo: CustomMap.Values[UpperCase(Trim(JdbcName))] := 'ftWideMemo';
    ftInteger: CustomMap.Values[UpperCase(Trim(JdbcName))] := 'ftInteger';
    ftLargeint: CustomMap.Values[UpperCase(Trim(JdbcName))] := 'ftLargeint';
    ftFmtBCD: CustomMap.Values[UpperCase(Trim(JdbcName))] := 'ftFmtBCD';
    ftFloat: CustomMap.Values[UpperCase(Trim(JdbcName))] := 'ftFloat';
    ftBoolean: CustomMap.Values[UpperCase(Trim(JdbcName))] := 'ftBoolean';
    ftDate: CustomMap.Values[UpperCase(Trim(JdbcName))] := 'ftDate';
    ftTime: CustomMap.Values[UpperCase(Trim(JdbcName))] := 'ftTime';
    ftDateTime: CustomMap.Values[UpperCase(Trim(JdbcName))] := 'ftDateTime';
    ftBlob: CustomMap.Values[UpperCase(Trim(JdbcName))] := 'ftBlob';
    ftString: CustomMap.Values[UpperCase(Trim(JdbcName))] := 'ftString';
    ftMemo: CustomMap.Values[UpperCase(Trim(JdbcName))] := 'ftMemo';
  else
    CustomMap.Values[UpperCase(Trim(JdbcName))] := 'ftWideString';
  end;
end;

class procedure TJdbcTypeMap.ClearCustom;
begin
  if GCustom <> nil then
    GCustom.Clear;
end;

class function TJdbcTypeMap.ToFieldType(const J: string): TFieldType;
var
  u, t, mapped: string;
  p: Integer;
begin
  u := UpperCase(Trim(J));
  if (GCustom <> nil) then
  begin
    mapped := GCustom.Values[u];
    if mapped = '' then
    begin
      t := u;
      p := Pos('(', t);
      if p > 0 then
        t := Copy(t, 1, p - 1);
      mapped := GCustom.Values[Trim(t)];
    end;
    if (mapped <> '') and FieldTypeByName(mapped, Result) then
      Exit;
  end;
  if Pos('TIMESTAMP', u) = 1 then
    Exit(ftDateTime);
  t := u;
  p := Pos('(', t);
  if p > 0 then
    t := Copy(t, 1, p - 1);
  t := Trim(t);
  p := Pos(' ', t);
  if p > 0 then
    t := Copy(t, 1, p - 1);
  t := Trim(t);
  if (t = 'VARCHAR') or (t = 'CHARACTER VARYING') or (t = 'NVARCHAR') or
    (t = 'CHAR') or (t = 'CHARACTER') then
    Exit(ftWideString);
  if (t = 'CLOB') or (t = 'NCLOB') or (t = 'TEXT') or (t = 'SQLXML') or
    (t = 'JSON') or (t = 'JSONB') or (t = 'UUID') then
    Exit(ftWideMemo);
  if (t = 'INTEGER') or (t = 'INT') or (t = 'SMALLINT') or (t = 'INT2') or
    (t = 'SERIAL') then
    Exit(ftInteger);
  if (t = 'BIGINT') or (t = 'INT8') or (t = 'BIGSERIAL') or
    (t = 'SMALLSERIAL') then
    Exit(ftLargeint);
  if (t = 'NUMERIC') or (t = 'DECIMAL') or (t = 'MONEY') then
    Exit(ftFmtBCD);
  if (t = 'FLOAT') or (t = 'FLOAT8') or (t = 'DOUBLE') or
    (t = 'DOUBLE PRECISION') or (t = 'REAL') or (t = 'FLOAT4') then
    Exit(ftFloat);
  if (t = 'BOOLEAN') or (t = 'BOOL') or (t = 'BIT') then
    Exit(ftBoolean);
  if t = 'DATE' then
    Exit(ftDate);
  if t = 'TIME' then
    Exit(ftTime);
  if (t = 'BLOB') or (t = 'BYTEA') or (t = 'BINARY') or (t = 'VARBINARY') or
    (t = 'IMAGE') then
    Exit(ftBlob);
  if (t = 'INET') or (t = 'INTERVAL') or (t = 'NAME') or (t = 'OID') then
    Exit(ftWideString);
  if (t = 'ARRAY') or (t = 'STRUCT') then
    Exit(ftWideMemo);
  Result := ftWideString;
end;

class function TJdbcTypeMap.NeedStream(const J: string): Boolean;
begin
  Result := ToFieldType(J) = ftBlob;
end;
end.
