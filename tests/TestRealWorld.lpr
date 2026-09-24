program TestRealWorld;

{$mode objfpc}{$H+}

{ Real-world SQL shapes modeled on large open-source projects:
  WordPress (wp_users / wp_posts / wp_postmeta / wp_comments),
  shop order/inventory flow (customers / orders / order_items / products),
  RBAC (app_users / roles / user_roles).
  Parser-level: every value must become a ? binding, identifiers stay inline. }

uses
  SysUtils, Classes, TyFPJDBC.Sql.Parser, TyFPJDBC.Script;

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

procedure CheckParse(const Name, SQL, WantSql: string; const WantParams: array of string);
var
  r: TSqlParseResult;
  i: Integer;
begin
  r := TSqlParser.Parse(SQL);
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
  { 1. Wide-table DDL passes through untouched, zero params }
  CheckParse('wide-ddl',
    'CREATE TABLE wp_posts(id BIGINT PRIMARY KEY, author_id BIGINT, title VARCHAR(255), body TEXT, excerpt TEXT, status VARCHAR(20), created TIMESTAMP, modified TIMESTAMP, views INT DEFAULT 0)',
    'CREATE TABLE wp_posts(id BIGINT PRIMARY KEY, author_id BIGINT, title VARCHAR(255), body TEXT, excerpt TEXT, status VARCHAR(20), created TIMESTAMP, modified TIMESTAMP, views INT DEFAULT 0)',
    []);

  { 2. Wide insert, 6 named params in order }
  CheckParse('wide-insert',
    'INSERT INTO wp_posts(id, author_id, title, body, status, created) VALUES(:id, :author, :title, :body, :status, :created)',
    'INSERT INTO wp_posts(id, author_id, title, body, status, created) VALUES(?, ?, ?, ?, ?, ?)',
    ['id', 'author', 'title', 'body', 'status', 'created']);

  { 3. Three-table join (posts -> users -> postmeta) }
  CheckParse('three-join',
    'SELECT p.id, p.title, u.login, m.mval FROM wp_posts p JOIN wp_users u ON u.id=p.author_id JOIN wp_postmeta m ON m.post_id=p.id WHERE p.status=:status AND u.id=:uid',
    'SELECT p.id, p.title, u.login, m.mval FROM wp_posts p JOIN wp_users u ON u.id=p.author_id JOIN wp_postmeta m ON m.post_id=p.id WHERE p.status=? AND u.id=?',
    ['status', 'uid']);

  { 4. LEFT JOIN + GROUP BY + HAVING }
  CheckParse('group-having',
    'SELECT u.id, u.login, COUNT(p.id) AS n FROM wp_users u LEFT JOIN wp_posts p ON p.author_id=u.id WHERE u.id>:minid GROUP BY u.id, u.login HAVING COUNT(p.id)>:minc',
    'SELECT u.id, u.login, COUNT(p.id) AS n FROM wp_users u LEFT JOIN wp_posts p ON p.author_id=u.id WHERE u.id>? GROUP BY u.id, u.login HAVING COUNT(p.id)>?',
    ['minid', 'minc']);

  { 5. Subquery IN }
  CheckParse('subquery-in',
    'SELECT id, title FROM wp_posts WHERE id IN (SELECT post_id FROM wp_postmeta WHERE mkey=:mk AND mval=:mv) AND status=:st',
    'SELECT id, title FROM wp_posts WHERE id IN (SELECT post_id FROM wp_postmeta WHERE mkey=? AND mval=?) AND status=?',
    ['mk', 'mv', 'st']);

  { 6. CTE }
  CheckParse('cte',
    'WITH recent AS (SELECT id FROM wp_posts WHERE created>:since) SELECT p.id, p.title FROM wp_posts p JOIN recent r ON r.id=p.id WHERE p.status=:st',
    'WITH recent AS (SELECT id FROM wp_posts WHERE created>?) SELECT p.id, p.title FROM wp_posts p JOIN recent r ON r.id=p.id WHERE p.status=?',
    ['since', 'st']);

  { 7. Window function }
  CheckParse('window',
    'SELECT id, title, ROW_NUMBER() OVER (PARTITION BY author_id ORDER BY created DESC) AS rn FROM wp_posts WHERE status=:st',
    'SELECT id, title, ROW_NUMBER() OVER (PARTITION BY author_id ORDER BY created DESC) AS rn FROM wp_posts WHERE status=?',
    ['st']);

  { 8. Paged listing }
  CheckParse('paged',
    'SELECT id, title FROM wp_posts WHERE status=:st ORDER BY created DESC LIMIT :lim OFFSET :off',
    'SELECT id, title FROM wp_posts WHERE status=? ORDER BY created DESC LIMIT ? OFFSET ?',
    ['st', 'lim', 'off']);

  { 9. Multi LIKE with ESCAPE }
  CheckParse('multi-like',
    'SELECT id FROM products WHERE name LIKE :kw ESCAPE ''\'' AND sku LIKE :sk ESCAPE ''\''',
    'SELECT id FROM products WHERE name LIKE ? ESCAPE ''\'' AND sku LIKE ? ESCAPE ''\''',
    ['kw', 'sk']);

  { 10. BETWEEN }
  CheckParse('between',
    'SELECT id FROM orders WHERE created BETWEEN :d1 AND :d2 AND total>:min',
    'SELECT id FROM orders WHERE created BETWEEN ? AND ? AND total>?',
    ['d1', 'd2', 'min']);

  { 11. IS NULL guard }
  CheckParse('is-null',
    'SELECT id FROM wp_posts WHERE deleted_at IS NULL AND status=:st',
    'SELECT id FROM wp_posts WHERE deleted_at IS NULL AND status=?',
    ['st']);

  { 12. Inventory decrement, repeated param bound 3x }
  CheckParse('decrement',
    'UPDATE inventory SET qty=qty-:n WHERE sku=:sku AND qty>=:n',
    'UPDATE inventory SET qty=qty-? WHERE sku=? AND qty>=?',
    ['n', 'sku', 'n']);

  { 13. Session cleanup delete }
  CheckParse('delete-old',
    'DELETE FROM sessions WHERE last_seen<:cutoff',
    'DELETE FROM sessions WHERE last_seen<?',
    ['cutoff']);

  { 14. DDL migrate untouched }
  CheckParse('alter-add',
    'ALTER TABLE wp_posts ADD COLUMN views INT DEFAULT 0',
    'ALTER TABLE wp_posts ADD COLUMN views INT DEFAULT 0',
    []);
  CheckParse('create-index',
    'CREATE INDEX idx_posts_author ON wp_posts(author_id, created)',
    'CREATE INDEX idx_posts_author ON wp_posts(author_id, created)',
    []);

  { 15. Upsert }
  CheckParse('upsert',
    'INSERT INTO products(id, name) VALUES(:id, :nm) ON CONFLICT(id) DO UPDATE SET name=:nm',
    'INSERT INTO products(id, name) VALUES(?, ?) ON CONFLICT(id) DO UPDATE SET name=?',
    ['id', 'nm', 'nm']);

  { 16. Macro table + parse chain }
  CheckParse('macro-chain',
    TSqlParser.ExpandMacro('SELECT * FROM &t WHERE id=:id', 't', 'wp_posts'),
    'SELECT * FROM wp_posts WHERE id=?',
    ['id']);

  { 17. Macro rejects hostile identifiers }
  if TSqlParser.CheckMacro('id; DROP TABLE users--') then
    Ng('macro-inject-reject', 'accepted')
  else
    Ok('macro-inject-reject');
  if TSqlParser.CheckMacro('a/b') then
    Ng('macro-slash-reject', 'accepted')
  else
    Ok('macro-slash-reject');
  if TSqlParser.CheckMacro('wp_posts') then
    Ok('macro-table-ok')
  else
    Ng('macro-table-ok', 'rejected');

  { 18. Migration script split: 4 statements, semicolons in strings ignored }
  with TJDBCScript.Split('CREATE TABLE a(id INT); CREATE INDEX i ON a(id); INSERT INTO a VALUES('';''); UPDATE a SET id=1 WHERE id=2;') do
  try
    if Count <> 4 then
      Ng('script-migrate-count', 'got ' + IntToStr(Count))
    else
      Ok('script-migrate-count');
  finally
    Free;
  end;

  WriteLn('TOTAL pass=', PassCount, ' fail=', FailCount);
  if FailCount > 0 then
    Halt(1);
end.
