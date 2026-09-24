program TestV2Dialect;

{$mode objfpc}{$H+}

{ V2 dialect + registry pure-logic tests: no JVM, no DB. }

uses
  SysUtils, Classes, TyFPJDBC.Handles, TyFPJDBC.Dialect.Api,
  TyFPJDBC.Dialect.Base, TyFPJDBC.Dialect.Pg, TyFPJDBC.Dialect.Mysql,
  TyFPJDBC.Dialect.Mssql, TyFPJDBC.Dialect.Oracle, TyFPJDBC.Dialect.Sqlite,
  TyFPJDBC.Dialect.H2, TyFPJDBC.Driver.Registry;

var
  Fails: Integer = 0;

procedure Ok(const N: string; C: Boolean);
begin
  if C then WriteLn('PASS ', N) else begin Inc(Fails); WriteLn('FAIL ', N); end;
end;

var
  raised: Boolean;
  props: TStringList;
  extra: TStringList;
  e: TDriverEntry;
begin
  Ok('pg-page', DialectFor('postgresql').PagedSQL('SELECT * FROM t ORDER BY id', 10, 20) =
    'SELECT * FROM t ORDER BY id LIMIT 10 OFFSET 20');
  Ok('pg-quote', DialectFor('postgresql').QuoteIdent('weird"name') = '"weird""name"');
  Ok('pg-returning', DialectFor('postgresql').KeyReturn('t', 'id') = ' RETURNING "id"');
  Ok('mysql-quote', DialectFor('mysql').QuoteIdent('weird`name') = '`weird``name`');
  Ok('mysql-page', DialectFor('mariadb').PagedSQL('SELECT * FROM t', 5, 0) =
    'SELECT * FROM t LIMIT 5 OFFSET 0');
  Ok('mssql-page', DialectFor('mssql').PagedSQL('SELECT * FROM t ORDER BY id', 10, 20) =
    'SELECT * FROM t ORDER BY id OFFSET 20 ROWS FETCH NEXT 10 ROWS ONLY');
  Ok('mssql-quote', DialectFor('mssql').QuoteIdent('a]b') = '[a]]b]');
  Ok('oracle-page', DialectFor('oracle').PagedSQL('SELECT * FROM t ORDER BY id', 10, 20) =
    'SELECT * FROM t ORDER BY id OFFSET 20 ROWS FETCH FIRST 10 ROWS ONLY');
  Ok('sqlite-page', DialectFor('sqlite').PagedSQL('SELECT * FROM t', 7, 3) =
    'SELECT * FROM t LIMIT 7 OFFSET 3');
  Ok('h2-page', DialectFor('h2').PagedSQL('SELECT * FROM t', 7, 3) =
    'SELECT * FROM t LIMIT 7 OFFSET 3');
  raised := False;
  try
    DialectFor('nosuch');
  except
    on E: EJDBCError do
      raised := E.SQLState = '08000';
  end;
  Ok('unknown-dialect', raised);

  Ok('pg-url', TDriverRegistry.BuildUrl('postgresql', 'db', 5432, 'app', nil) =
    'jdbc:postgresql://db:5432/app');
  Ok('pg-default-port', TDriverRegistry.BuildUrl('postgresql', 'db', 0, 'app', nil) =
    'jdbc:postgresql://db:5432/app');
  Ok('sqlite-url', TDriverRegistry.BuildUrl('sqlite', '', 0, '/tmp/a.db', nil) =
    'jdbc:sqlite:/tmp/a.db');
  Ok('h2-url', TDriverRegistry.BuildUrl('h2', '', 0, 't1', nil) =
    'jdbc:h2:mem:t1');
  extra := TStringList.Create;
  try
    extra.Values['ssl'] := 'true';
    Ok('pg-extra', TDriverRegistry.BuildUrl('postgresql', 'db', 5432, 'app', extra) =
      'jdbc:postgresql://db:5432/app?ssl=true');
  finally
    extra.Free;
  end;
  raised := False;
  try
    TDriverRegistry.BuildUrl('nosuch', 'h', 1, 'd', nil);
  except
    on E: EJDBCError do
      raised := E.SQLState = '08000';
  end;
  Ok('unknown-driver', raised);
  props := TStringList.Create;
  try
    TDriverRegistry.BuildProperties('postgresql', 2, 5, True, props);
    Ok('props', (props.Values['loginTimeout'] = '2') and
      (props.Values['socketTimeout'] = '5') and (props.Values['readOnly'] = 'true'));
  finally
    props.Free;
  end;
  e.Id := 'mydb'; e.DriverClass := 'com.example.Driver';
  e.UrlTemplate := 'jdbc:mydb://{host}:{port}/{database}';
  e.DefaultPort := 1234; e.TestQuery := 'SELECT 1';
  e.License := 'MIT'; e.Maven := 'com.example:mydb:1.0'; e.Sha := '';
  TDriverRegistry.Register(e);
  Ok('custom-driver', TDriverRegistry.BuildUrl('mydb', 'h', 0, 'd', nil) =
    'jdbc:mydb://h:1234/d');

  WriteLn('TOTAL fails=', Fails);
  if Fails > 0 then Halt(1);
end.
