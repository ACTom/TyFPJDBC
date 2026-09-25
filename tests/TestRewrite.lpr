program TestRewrite;

{$mode objfpc}{$H+}

{ Named-parameter rewrite on the shipped pure function
  RewriteNamedParams (src/db/TyFPJDBC.Command.pas): no JVM, no DB.
  Every value travels via bindings; the rewrite only maps :name to ?
  while leaving strings, quoted idents, comments, casts, $$  bodies,
  host :/, time literals, JSON ?|/?& and lone ? untouched. }

uses
  SysUtils, Classes, TyFPJDBC.Command;

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

procedure Check(const Name, SQL, WantSql: string; const WantParams: array of string);
var
  r: TRewriteResult;
  i: Integer;
begin
  r := RewriteNamedParams(SQL);
  if r.JdbcSql <> WantSql then
    Ng(Name + '-sql', 'got: ' + r.JdbcSql)
  else
    Ok(Name + '-sql');
  if Length(r.ParamOrder) <> Length(WantParams) then
    Ng(Name + '-count', 'got ' + IntToStr(Length(r.ParamOrder)) + ' want ' + IntToStr(Length(WantParams)))
  else
  begin
    Ok(Name + '-count');
    for i := 0 to High(WantParams) do
      if r.ParamOrder[i] <> WantParams[i] then
      begin
        Ng(Name + '-order', 'pos ' + IntToStr(i) + ' got ' + r.ParamOrder[i]);
        Exit;
      end;
    Ok(Name + '-order');
  end;
end;

begin
  Check('dup',
    'SELECT * FROM t WHERE a=:id OR b=:id',
    'SELECT * FROM t WHERE a=? OR b=?',
    ['id', 'id']);
  Check('quoted-single',
    'SELECT '':id'' FROM t WHERE a=:name',
    'SELECT '':id'' FROM t WHERE a=?',
    ['name']);
  Check('quoted-double',
    'SELECT ":id" FROM t',
    'SELECT ":id" FROM t',
    []);
  Check('quoted-backtick',
    'SELECT `:id` FROM t WHERE a=:x',
    'SELECT `:id` FROM t WHERE a=?',
    ['x']);
  Check('line-comment',
    'SELECT 1::int, '':id'' FROM t -- :nope',
    'SELECT 1::int, '':id'' FROM t -- :nope',
    []);
  Check('block-comment',
    'SELECT a /* :x */ FROM t WHERE b=:ok',
    'SELECT a /* :x */ FROM t WHERE b=?',
    ['ok']);
  Check('double-colon',
    'SELECT v::int FROM t WHERE a=:id',
    'SELECT v::int FROM t WHERE a=?',
    ['id']);
  Check('time-literal',
    'SELECT * FROM t WHERE tm = 12:30 AND a=:id',
    'SELECT * FROM t WHERE tm = 12:30 AND a=?',
    ['id']);
  Check('walrus',
    'SELECT a := 1, b:=:id FROM t',
    'SELECT a := 1, b:=? FROM t',
    ['id']);
  Check('host-slash',
    'SELECT * FROM t WHERE a=:id AND b=:/x',
    'SELECT * FROM t WHERE a=? AND b=:/x',
    ['id']);
  Check('json-qmark',
    'SELECT j ? ''k'' FROM t WHERE a=:id',
    'SELECT j ? ''k'' FROM t WHERE a=?',
    ['id']);
  Check('json-ops',
    'SELECT * FROM t WHERE j ?| ARRAY[''a''] AND k ?& ARRAY[''b'']',
    'SELECT * FROM t WHERE j ?| ARRAY[''a''] AND k ?& ARRAY[''b'']',
    []);
  Check('lone-qmark',
    'SELECT * FROM t WHERE a=? AND b=:id',
    'SELECT * FROM t WHERE a=? AND b=?',
    ['id']);
  Check('dollar-body',
    'SELECT $$:nope$$ FROM t WHERE a=:id',
    'SELECT $$:nope$$ FROM t WHERE a=?',
    ['id']);
  Check('pg-where-order',
    'SELECT id, name FROM users WHERE age > :minAge AND city = :city ORDER BY id LIMIT 10 OFFSET 20',
    'SELECT id, name FROM users WHERE age > ? AND city = ? ORDER BY id LIMIT 10 OFFSET 20',
    ['minAge', 'city']);
  Check('pg-insert-returning',
    'INSERT INTO t (a, b) VALUES (:a, :b) RETURNING id',
    'INSERT INTO t (a, b) VALUES (?, ?) RETURNING id',
    ['a', 'b']);
  Check('pg-cast-json',
    'SELECT created::date, payload->>''name'' FROM events WHERE id=:id',
    'SELECT created::date, payload->>''name'' FROM events WHERE id=?',
    ['id']);
  Check('pg-like-escape',
    'SELECT * FROM t WHERE name LIKE :kw ESCAPE ''\''',
    'SELECT * FROM t WHERE name LIKE ? ESCAPE ''\''',
    ['kw']);
  Check('repeat-param',
    'UPDATE inventory SET qty=qty-:n WHERE sku=:sku AND qty>=:n',
    'UPDATE inventory SET qty=qty-? WHERE sku=? AND qty>=?',
    ['n', 'sku', 'n']);
  Check('inject-shape',
    'SELECT * FROM t WHERE a=:id',
    'SELECT * FROM t WHERE a=?',
    ['id']);
  WriteLn('TOTAL pass=', PassCount, ' fail=', FailCount);
  if FailCount > 0 then
    Halt(1);
end.
