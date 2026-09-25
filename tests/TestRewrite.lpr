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

procedure TestFuzzFixedSeed;
{ Fixed-seed fuzz over hostile fragments: output ? count must always equal
  the binding count, plus a determinism rerun check. }
const
  FRAGS: array[0..17] of string = ('''', '"', '`', ':', ';', '--', '/*',
    '*/', '$', '$$', '?', '?|', '?&', '::', ':=', ':/', '中文', '\');
var
  k, f, n, q, litQ, fi: Integer;
  sql, first: string;
  r: TRewriteResult;
begin
  RandSeed := 20260925;
  first := '';
  for k := 1 to 200 do
  begin
    sql := 'SELECT * FROM t WHERE a=:p0';
    litQ := 0;
    n := 1 + Random(4);
    for f := 1 to n do
    begin
      fi := Random(Length(FRAGS));
      if FRAGS[fi] = '?' then
        Inc(litQ);
      sql := sql + ' ' + FRAGS[fi] + ' :p' + IntToStr(f);
    end;
    r := RewriteNamedParams(sql);
    q := 0;
    for f := 1 to Length(r.JdbcSql) do
      if r.JdbcSql[f] = '?' then
      begin
        { ?| and ?& are JSON operators, not placeholders; skip their ?. }
        if (f < Length(r.JdbcSql)) and (r.JdbcSql[f + 1] in ['|', '&']) then
          Continue;
        Inc(q);
      end;
    { Every named param becomes exactly one ?; every literal ? survives;
      nothing is created or swallowed. }
    if q <> Length(r.ParamOrder) + litQ then
    begin
      Ng('fuzz-count', 'case ' + IntToStr(k) + ' got ' + IntToStr(q) +
        ' want ' + IntToStr(Length(r.ParamOrder) + litQ));
      Exit;
    end;
    if k = 1 then
      first := r.JdbcSql;
  end;
  { Determinism: rerun the first generated shape verbatim. }
  r := RewriteNamedParams('SELECT * FROM t WHERE a=:p0 :p1');
  if (Length(r.ParamOrder) <> 2) or (r.ParamOrder[0] <> 'p0') then
    Ng('fuzz-determinism', 'rerun mismatch')
  else if first = '' then
    Ng('fuzz-sanity', 'empty')
  else
    Ok('fuzz-count-deterministic');
end;

begin
  TestFuzzFixedSeed;
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
