unit TyFPJDBC.Sql.Parser;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

type
  TSqlParseResult = record
    JdbcSql: string;
    ParamOrder: array of string;
  end;

  TSqlParser = class
    class function Parse(const SQL: string): TSqlParseResult; static;
    class function ExpandMacro(const SQL, Name, Value: string): string; static;
    class function CheckMacro(const Value: string): Boolean; static;
  end;

implementation

uses
  TyFPJDBC.JNI.Utils;

class function TSqlParser.CheckMacro(const Value: string): Boolean;
begin
  Result := TJniUtils.IsWhiteIdent(Value);
end;

class function TSqlParser.ExpandMacro(const SQL, Name, Value: string): string;
begin
  if not CheckMacro(Value) then
    raise Exception.Create('bad macro: ' + Value);
  Result := StringReplace(SQL, '&' + Name, Value, [rfReplaceAll]);
end;

class function TSqlParser.Parse(const SQL: string): TSqlParseResult;
var
  i, n: Integer;
  ch, q: Char;
  inStr: Boolean;
  outp, nm: string;
begin
  outp := '';
  Result.JdbcSql := '';
  SetLength(Result.ParamOrder, 0);
  i := 1;
  n := Length(SQL);
  inStr := False;
  q := #0;
  while i <= n do
  begin
    ch := SQL[i];
    if inStr then
    begin
      outp := outp + ch;
      { Standard SQL strings end only on a lone quote ('' doubles).
        Backslash is a literal char here (ESCAPE '\' must not swallow
        the closing quote); E'' escapes are out of scope for V1. }
      if ch = q then
      begin
        if (i < n) and (SQL[i + 1] = q) then
        begin
          outp := outp + SQL[i + 1];
          Inc(i, 2);
          Continue;
        end;
        inStr := False;
      end;
      Inc(i);
      Continue;
    end;
    if (ch = '$') and (i < n) and (SQL[i + 1] = '$') then
    begin
      outp := outp + '$$';
      Inc(i, 2);
      while i <= n do
      begin
        if (SQL[i] = '$') and (i < n) and (SQL[i + 1] = '$') then
        begin
          outp := outp + '$$';
          Inc(i, 2);
          Break;
        end;
        outp := outp + SQL[i];
        Inc(i);
      end;
      Continue;
    end;
    if (ch = '''') or (ch = '"') or (ch = '`') then
    begin
      inStr := True;
      q := ch;
      outp := outp + ch;
      Inc(i);
      Continue;
    end;
    if (ch = '-') and (i < n) and (SQL[i + 1] = '-') then
    begin
      while (i <= n) and (SQL[i] <> #10) do
      begin
        outp := outp + SQL[i];
        Inc(i);
      end;
      Continue;
    end;
    if (ch = '/') and (i < n) and (SQL[i + 1] = '*') then
    begin
      outp := outp + '/*';
      Inc(i, 2);
      while i <= n do
      begin
        if (SQL[i] = '*') and (i < n) and (SQL[i + 1] = '/') then
        begin
          outp := outp + '*/';
          Inc(i, 2);
          Break;
        end;
        outp := outp + SQL[i];
        Inc(i);
      end;
      Continue;
    end;
    if (ch = ':') and (i < n) and (SQL[i + 1] = ':') then
    begin
      outp := outp + '::';
      Inc(i, 2);
      Continue;
    end;
    if (ch = ':') and (i < n) and (SQL[i + 1] = '=') then
    begin
      outp := outp + ':=';
      Inc(i, 2);
      Continue;
    end;
    if (ch = ':') and (i < n) and (SQL[i + 1] = '/') then
    begin
      outp := outp + ':';
      Inc(i);
      Continue;
    end;
    if (ch = ':') and (i < n) and (SQL[i + 1] in ['A'..'Z', 'a'..'z', '_']) then
    begin
      nm := '';
      Inc(i);
      while (i <= n) and (SQL[i] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) do
      begin
        nm := nm + SQL[i];
        Inc(i);
      end;
      outp := outp + '?';
      SetLength(Result.ParamOrder, Length(Result.ParamOrder) + 1);
      Result.ParamOrder[High(Result.ParamOrder)] := nm;
      Continue;
    end;
    if ch = '?' then
    begin
      if (i < n) and (SQL[i + 1] in ['|', '&']) then
      begin
        outp := outp + '?' + SQL[i + 1];
        Inc(i, 2);
        Continue;
      end;
      outp := outp + '?';
      Inc(i);
      Continue;
    end;
    outp := outp + ch;
    Inc(i);
  end;
  Result.JdbcSql := outp;
end;

end.
