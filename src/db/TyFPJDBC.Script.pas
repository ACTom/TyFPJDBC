unit TyFPJDBC.Script;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, TyFPJDBC.Handles, TyFPJDBC.JNI.Bridge, TyFPJDBC.Engine;

type
  { Script runner: splits on top-level semicolons (strings, line/block
    comments and $$ bodies untouched), executes each via ExecDirect in one
    transaction, reports the failing statement number. }
  TJDBCScript = class
    class function Split(const SQL: string): TStringList; static;
    class function ExecScript(AEngine: TJdbcEngine; AConn: Int64;
      const SQL: string): Integer; static;
  end;

implementation

uses
  TyFPJDBC.Errors;

class function TJDBCScript.Split(const SQL: string): TStringList;
var
  i, n: Integer;
  ch: Char;
  cur: string;
  dollar: string;
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
    if ch = '$' then
    begin
      dollar := '$';
      Inc(i);
      while (i <= n) and (SQL[i] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) do
      begin
        dollar := dollar + SQL[i];
        Inc(i);
      end;
      if (i <= n) and (SQL[i] = '$') then
      begin
        dollar := dollar + '$';
        Inc(i);
        cur := cur + dollar;
        while i <= n do
        begin
          if (SQL[i] = '$') and (Copy(SQL, i, Length(dollar)) = dollar) then
          begin
            cur := cur + dollar;
            Inc(i, Length(dollar));
            Break;
          end;
          cur := cur + SQL[i];
          Inc(i);
        end;
        Continue;
      end;
      cur := cur + '$';
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

class function TJDBCScript.ExecScript(AEngine: TJdbcEngine; AConn: Int64;
  const SQL: string): Integer;
var
  parts: TStringList;
  i: Integer;
begin
  CheckHandle('conn', AConn);
  if AEngine = nil then
    raise EJDBCError.CreateChain('engine required', 'HY000', 99, 'nil');
  parts := Split(SQL);
  try
    Result := 0;
    AEngine.SetAutoCommit(AConn, False);
    try
      for i := 0 to parts.Count - 1 do
      begin
        try
          AEngine.Bridge.ExecDirect(AConn, UTF8String(parts[i]));
        except
          on E: EJDBCError do
            raise EJDBCError.CreateChain('script stmt ' + IntToStr(i + 1) +
              ' failed', E.SQLState, E.VendorCode,
              parts[i] + '; ' + ErrAdvice(JdbcErrClassOf(E)));
        end;
        Inc(Result);
      end;
      AEngine.Commit(AConn);
    except
      try
        AEngine.Rollback(AConn);
      except
      end;
      raise;
    end;
  finally
    parts.Free;
    try
      AEngine.SetAutoCommit(AConn, True);
    except
    end;
  end;
end;

end.
