unit TyFPJDBC.Script;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes;
type
  TJDBCScript = class
    class function Split(const SQL: string): TStringList; static;
  end;
implementation
class function TJDBCScript.Split(const SQL: string): TStringList;
var
  i, n: Integer;
  ch: Char;
  cur: string;
begin
  Result := TStringList.Create;
  cur := '';
  i := 1;
  n := Length(SQL);
  while i <= n do
  begin
    ch := SQL[i];
    if ch = '''' then
    begin
      cur := cur + ch;
      Inc(i);
      while i <= n do
      begin
        cur := cur + SQL[i];
        if SQL[i] = '''' then
        begin
          if (i < n) and (SQL[i + 1] = '''') then
          begin
            cur := cur + '''';
            Inc(i, 2);
            Continue;
          end;
          Inc(i);
          Break;
        end;
        Inc(i);
      end;
      Continue;
    end;
    if (ch = '-') and (i < n) and (SQL[i + 1] = '-') then
    begin
      while (i <= n) and (SQL[i] <> #10) do
      begin
        cur := cur + SQL[i];
        Inc(i);
      end;
      Continue;
    end;
    if (ch = '/') and (i < n) and (SQL[i + 1] = '*') then
    begin
      cur := cur + '/*';
      Inc(i, 2);
      while i <= n do
      begin
        if (SQL[i] = '*') and (i < n) and (SQL[i + 1] = '/') then
        begin
          cur := cur + '*/';
          Inc(i, 2);
          Break;
        end;
        cur := cur + SQL[i];
        Inc(i);
      end;
      Continue;
    end;
    if ch = ';' then
    begin
      if Trim(cur) <> '' then
        Result.Add(Trim(cur));
      cur := '';
      Inc(i);
      Continue;
    end;
    cur := cur + ch;
    Inc(i);
  end;
  if Trim(cur) <> '' then
    Result.Add(Trim(cur));
end;
end.
