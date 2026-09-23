unit TyFPJDBC.&Type.Map;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, DB;
type
  TJdbcTypeMap = class
    class function ToFieldType(const J: string): TFieldType; static;
    class function NeedStream(const J: string): Boolean; static;
  end;
implementation
class function TJdbcTypeMap.ToFieldType(const J: string): TFieldType;
var
  u, t: string;
  p: Integer;
begin
  u := UpperCase(Trim(J));
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
  if (t = 'VARCHAR') or (t = 'NVARCHAR') or (t = 'CHAR') then
    Exit(ftWideString);
  if (t = 'CLOB') or (t = 'NCLOB') or (t = 'SQLXML') or (t = 'JSON') or
    (t = 'JSONB') or (t = 'UUID') then
    Exit(ftWideMemo);
  if (t = 'INTEGER') or (t = 'SMALLINT') then
    Exit(ftInteger);
  if t = 'BIGINT' then
    Exit(ftLargeint);
  if (t = 'NUMERIC') or (t = 'DECIMAL') then
    Exit(ftFmtBCD);
  if (t = 'FLOAT') or (t = 'DOUBLE') or (t = 'REAL') then
    Exit(ftFloat);
  if (t = 'BOOLEAN') or (t = 'BIT') then
    Exit(ftBoolean);
  if t = 'DATE' then
    Exit(ftDate);
  if t = 'TIME' then
    Exit(ftTime);
  if (t = 'BLOB') or (t = 'BYTEA') or (t = 'BINARY') or (t = 'VARBINARY') then
    Exit(ftBlob);
  if (t = 'ARRAY') or (t = 'STRUCT') then
    Exit(ftWideMemo);
  Result := ftWideString;
end;

class function TJdbcTypeMap.NeedStream(const J: string): Boolean;
begin
  Result := ToFieldType(J) = ftBlob;
end;
end.
