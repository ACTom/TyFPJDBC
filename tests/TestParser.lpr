program TestParser;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, TyFPJDBC.Sql.Parser;

var
  PassCount: Integer = 0;
  FailCount: Integer = 0;

procedure Ok(const Name: string);
begin
  Inc(PassCount);
  WriteLn('PASS: ', Name);
end;

procedure Ng(const Name, Detail: string);
begin
  Inc(FailCount);
  WriteLn('FAIL: ', Name, ' -- ', Detail);
end;

procedure TestDuplicateParams;
var
  r: TSqlParseResult;
begin
  r := TSqlParser.Parse('SELECT * FROM t WHERE a=:id OR b=:id');
  if r.JdbcSql <> 'SELECT * FROM t WHERE a=? OR b=?' then
    Ng('dup-sql', 'got: ' + r.JdbcSql)
  else
    Ok('dup-sql');
  if Length(r.ParamOrder) <> 2 then
    Ng('dup-count', IntToStr(Length(r.ParamOrder)))
  else
    Ok('dup-count');
  if (Length(r.ParamOrder) = 2) and (r.ParamOrder[0] = 'id') and (r.ParamOrder[1] = 'id') then
    Ok('dup-names')
  else
    Ng('dup-names', 'order mismatch');
end;

procedure TestQuotedUntouched;
var
  r: TSqlParseResult;
begin
  r := TSqlParser.Parse('SELECT '':id'' FROM t WHERE a=:name');
  if r.JdbcSql <> 'SELECT '':id'' FROM t WHERE a=?' then
    Ng('quoted-single', 'got: ' + r.JdbcSql)
  else
    Ok('quoted-single');
  if (Length(r.ParamOrder) = 1) and (r.ParamOrder[0] = 'name') then
    Ok('quoted-single-order')
  else
    Ng('quoted-single-order', IntToStr(Length(r.ParamOrder)));
  r := TSqlParser.Parse('SELECT ":id" FROM t');
  if (r.JdbcSql <> 'SELECT ":id" FROM t') or (Length(r.ParamOrder) <> 0) then
    Ng('quoted-double', 'got: ' + r.JdbcSql)
  else
    Ok('quoted-double');
end;

procedure TestLineComment;
var
  r: TSqlParseResult;
begin
  r := TSqlParser.Parse('SELECT 1::int, '':id'' FROM t -- :nope');
  if r.JdbcSql <> 'SELECT 1::int, '':id'' FROM t -- :nope' then
    Ng('line-comment', 'got: ' + r.JdbcSql)
  else
    Ok('line-comment');
  if Length(r.ParamOrder) <> 0 then
    Ng('line-comment-order', IntToStr(Length(r.ParamOrder)))
  else
    Ok('line-comment-order');
end;

procedure TestBlockComment;
var
  r: TSqlParseResult;
begin
  r := TSqlParser.Parse('SELECT a /* :x */ FROM t WHERE b=:ok');
  if r.JdbcSql <> 'SELECT a /* :x */ FROM t WHERE b=?' then
    Ng('block-comment', 'got: ' + r.JdbcSql)
  else
    Ok('block-comment');
  if (Length(r.ParamOrder) = 1) and (r.ParamOrder[0] = 'ok') then
    Ok('block-comment-order')
  else
    Ng('block-comment-order', 'order mismatch');
end;

procedure TestDoubleColon;
var
  r: TSqlParseResult;
begin
  r := TSqlParser.Parse('SELECT v::int FROM t WHERE a=:id');
  if r.JdbcSql <> 'SELECT v::int FROM t WHERE a=?' then
    Ng('double-colon', 'got: ' + r.JdbcSql)
  else
    Ok('double-colon');
  r := TSqlParser.Parse('SELECT * FROM t WHERE tm = 12:30 AND a=:id');
  if r.JdbcSql <> 'SELECT * FROM t WHERE tm = 12:30 AND a=?' then
    Ng('time-literal', 'got: ' + r.JdbcSql)
  else
    Ok('time-literal');
  r := TSqlParser.Parse('SELECT a := 1, b:=:id FROM t');
  if r.JdbcSql <> 'SELECT a := 1, b:=? FROM t' then
    Ng('walrus', 'got: ' + r.JdbcSql)
  else
    Ok('walrus');
end;

procedure TestJsonOps;
var
  r: TSqlParseResult;
begin
  r := TSqlParser.Parse('SELECT j ? ''k'' FROM t WHERE a=:id');
  if (Pos('?', r.JdbcSql) = 0) or (Length(r.ParamOrder) <> 1) then
    Ng('json-qmark', 'got: ' + r.JdbcSql)
  else
    Ok('json-qmark');
  r := TSqlParser.Parse('SELECT * FROM t WHERE j ?| ARRAY[''a''] AND k ?& ARRAY[''b'']');
  if r.JdbcSql <> 'SELECT * FROM t WHERE j ?| ARRAY[''a''] AND k ?& ARRAY[''b'']' then
    Ng('json-ops', 'got: ' + r.JdbcSql)
  else
    Ok('json-ops');
  if Length(r.ParamOrder) <> 0 then
    Ng('json-ops-order', IntToStr(Length(r.ParamOrder)))
  else
    Ok('json-ops-order');
  r := TSqlParser.Parse('SELECT * FROM t WHERE a=? AND b=:id');
  if (r.JdbcSql <> 'SELECT * FROM t WHERE a=? AND b=?') or (Length(r.ParamOrder) <> 1) then
    Ng('lone-qmark', 'got: ' + r.JdbcSql)
  else
    Ok('lone-qmark');
end;

procedure TestDollarBody;
var
  r: TSqlParseResult;
begin
  r := TSqlParser.Parse('SELECT $$:nope$$ FROM t WHERE a=:id');
  if r.JdbcSql <> 'SELECT $$:nope$$ FROM t WHERE a=?' then
    Ng('dollar-body', 'got: ' + r.JdbcSql)
  else
    Ok('dollar-body');
  if (Length(r.ParamOrder) = 1) and (r.ParamOrder[0] = 'id') then
    Ok('dollar-body-order')
  else
    Ng('dollar-body-order', 'order mismatch');
end;

procedure TestInjectionValue;
var
  r: TSqlParseResult;
  v: string;
begin
  v := ''' OR ''1''=''1';
  r := TSqlParser.Parse('SELECT * FROM t WHERE a=:id');
  if r.JdbcSql <> 'SELECT * FROM t WHERE a=?' then
    Ng('inject-shape', 'got: ' + r.JdbcSql)
  else
    Ok('inject-shape');
  if Pos(v, r.JdbcSql) <> 0 then
    Ng('inject-noconcat', 'value leaked into SQL')
  else
    Ok('inject-noconcat');
  if Pos('OR', r.JdbcSql) <> 0 then
    Ng('inject-noor', 'got: ' + r.JdbcSql)
  else
    Ok('inject-noor');
  r := TSqlParser.Parse('SELECT * FROM t WHERE a=''' + '--');
  if Pos('--', r.JdbcSql) = 0 then
    Ng('inject-dashdash', 'comment marker lost: ' + r.JdbcSql)
  else
    Ok('inject-dashdash');
end;

procedure TestMacroReject;
var
  raised: Boolean;
begin
  if TSqlParser.CheckMacro('a; DROP') then
    Ng('macro-reject-check', 'accepted')
  else
    Ok('macro-reject-check');
  raised := False;
  try
    TSqlParser.ExpandMacro('SELECT * FROM &t', 't', 'a; DROP');
  except
    on E: Exception do
      raised := True;
  end;
  if raised then
    Ok('macro-reject-expand')
  else
    Ng('macro-reject-expand', 'no exception');
end;

procedure TestMacroAccept;
var
  s: string;
begin
  if not TSqlParser.CheckMacro('myschema.mytable') then
    Ng('macro-accept-check', 'rejected')
  else
    Ok('macro-accept-check');
  s := TSqlParser.ExpandMacro('SELECT * FROM &t ORDER BY &t', 't', 'myschema.mytable');
  if s <> 'SELECT * FROM myschema.mytable ORDER BY myschema.mytable' then
    Ng('macro-accept-expand', 'got: ' + s)
  else
    Ok('macro-accept-expand');
end;

procedure TestPgCompat;
var
  r: TSqlParseResult;
begin
  r := TSqlParser.Parse('SELECT id, name FROM users WHERE age > :minAge AND city = :city ORDER BY id LIMIT 10 OFFSET 20');
  if r.JdbcSql <> 'SELECT id, name FROM users WHERE age > ? AND city = ? ORDER BY id LIMIT 10 OFFSET 20' then
    Ng('pg-where-order', 'got: ' + r.JdbcSql)
  else
    Ok('pg-where-order');
  if (Length(r.ParamOrder) <> 2) or (r.ParamOrder[0] <> 'minAge') or (r.ParamOrder[1] <> 'city') then
    Ng('pg-where-order-names', 'order mismatch')
  else
    Ok('pg-where-order-names');
  r := TSqlParser.Parse('INSERT INTO t (a, b) VALUES (:a, :b) RETURNING id');
  if r.JdbcSql <> 'INSERT INTO t (a, b) VALUES (?, ?) RETURNING id' then
    Ng('pg-insert-returning', 'got: ' + r.JdbcSql)
  else
    Ok('pg-insert-returning');
  if (Length(r.ParamOrder) <> 2) or (r.ParamOrder[0] <> 'a') or (r.ParamOrder[1] <> 'b') then
    Ng('pg-insert-returning-names', 'order mismatch')
  else
    Ok('pg-insert-returning-names');
  r := TSqlParser.Parse('SELECT created::date, payload->>''name'' FROM events WHERE id=:id');
  if r.JdbcSql <> 'SELECT created::date, payload->>''name'' FROM events WHERE id=?' then
    Ng('pg-cast-json', 'got: ' + r.JdbcSql)
  else
    Ok('pg-cast-json');
  if (Length(r.ParamOrder) <> 1) or (r.ParamOrder[0] <> 'id') then
    Ng('pg-cast-json-names', 'order mismatch')
  else
    Ok('pg-cast-json-names');
  r := TSqlParser.Parse('SELECT * FROM t WHERE name LIKE :kw ESCAPE ''\''');
  if r.JdbcSql <> 'SELECT * FROM t WHERE name LIKE ? ESCAPE ''\''' then
    Ng('pg-like-escape', 'got: ' + r.JdbcSql)
  else
    Ok('pg-like-escape');
  if (Length(r.ParamOrder) <> 1) or (r.ParamOrder[0] <> 'kw') then
    Ng('pg-like-escape-names', 'order mismatch')
  else
    Ok('pg-like-escape-names');
  if TSqlParser.CheckMacro('DESC') then
    Ok('macro-desc-ident')
  else
    Ng('macro-desc-ident', 'rejected');
  if TSqlParser.CheckMacro('a b') then
    Ng('macro-space-reject', 'accepted')
  else
    Ok('macro-space-reject');
end;

begin
  TestDuplicateParams;
  TestQuotedUntouched;
  TestLineComment;
  TestBlockComment;
  TestDoubleColon;
  TestJsonOps;
  TestDollarBody;
  TestInjectionValue;
  TestMacroReject;
  TestMacroAccept;
  TestPgCompat;
  WriteLn('TOTAL pass=', PassCount, ' fail=', FailCount);
  if FailCount > 0 then
    Halt(1);
end.
