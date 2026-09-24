program ex02_named_params;

{$mode objfpc}{$H+}

{ ex02: named :params convert to JDBC ? placeholders in order.
  Values always travel via bindings; hostile text stays data. }

uses
  SysUtils, TyFPJDBC.Sql.Parser;

procedure Show(const SQL: string);
var
  r: TSqlParseResult;
  i: Integer;
begin
  r := TSqlParser.Parse(SQL);
  Write('SQL : ', SQL, '  =>  ', r.JdbcSql, '   params[');
  for i := 0 to High(r.ParamOrder) do
  begin
    if i > 0 then Write(',');
    Write(r.ParamOrder[i]);
  end;
  WriteLn(']');
end;

begin
  Show('SELECT * FROM wp_posts WHERE status=:st ORDER BY created DESC LIMIT :lim');
  Show('SELECT * FROM t WHERE a=:id OR b=:id');
  Show('UPDATE inventory SET qty=qty-:n WHERE sku=:sku AND qty>=:n');
  Show('SELECT * FROM t WHERE name LIKE :kw ESCAPE ''\''');
  { Macro is identifiers-only (whitelist); values never go through Macro. }
  WriteLn('macro wp_posts => ',
    TSqlParser.ExpandMacro('SELECT * FROM &t WHERE id=:id', 't', 'wp_posts'));
  WriteLn('macro hostile accepted? ',
    BoolToStr(TSqlParser.CheckMacro('t; DROP TABLE users--'), True));
  WriteLn('ex02 ok');
end.
