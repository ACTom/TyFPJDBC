program ex07_script_migrate;

{$mode objfpc}{$H+}

{ ex07: multi-statement migration script split; semicolons inside
  strings/comments do not split. }

uses
  SysUtils, Classes, TyFPJDBC.Script, TyFPJDBC.Sql.Parser;

var
  parts: TStringList;
  i: Integer;
  r: TSqlParseResult;
begin
  parts := TJDBCScript.Split(
    'CREATE TABLE wp_posts(id INT PRIMARY KEY, title VARCHAR(255));' + sLineBreak +
    'CREATE INDEX idx_posts_title ON wp_posts(title);' + sLineBreak +
    'INSERT INTO wp_posts VALUES(1, ''a;b'');' + sLineBreak +
    'ALTER TABLE wp_posts ADD COLUMN views INT DEFAULT 0;');
  try
    WriteLn('statements=', parts.Count);
    for i := 0 to parts.Count - 1 do
    begin
      r := TSqlParser.Parse(parts[i]);
      WriteLn('--- [', i, '] params=', Length(r.ParamOrder), ' ', Trim(r.JdbcSql));
    end;
  finally
    parts.Free;
  end;
  WriteLn('ex07 ok');
end.
