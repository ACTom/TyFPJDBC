program TestDialect;

{$mode objfpc}{$H+}

{ Dialect + registry pure-logic tests: no JVM, no DB. }

uses
  SysUtils, Classes, DB, TyFPJDBC.Handles, TyFPJDBC.Dialect.Api,
  TyFPJDBC.Dialect.Base, TyFPJDBC.Driver.Registry,
  TyFPJDBC.Dataset.Adapter;

var
  Fails: Integer = 0;

procedure Ok(const N: string; C: Boolean);
begin
  if C then WriteLn('PASS ', N) else begin Inc(Fails); WriteLn('FAIL ', N); end;
end;

procedure CheckUrl(const Id, Host: string; Port: Integer; const Db, Want: string);
begin
  try
    Ok('url-' + Id, TDriverRegistry.BuildUrl(Id, Host, Port, Db, nil) = Want);
  except
    Ok('url-' + Id, False);
  end;
end;

var
  raised: Boolean;
  props: TStringList;
  extra: TStringList;
  e: TDriverEntry;
  ad: TDatasetAdapter;
  memo: Boolean;
  tmp: string;
  sl: TStringList;
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
  e.Embedded := False; e.Paging := psLimitOffset; e.Quote := qsDouble;
  e.KeyReturn := krNone; e.ParamSep := ';'; SetLength(e.TypeAliases, 0);
  e.Paging := psOffsetFetchNext; e.Quote := qsBracket; e.KeyReturn := krReturning;
  SetLength(e.TypeAliases, 2);
  e.TypeAliases[0] := 'MYBLOB=blob';
  e.TypeAliases[1] := 'MYTEXT=widememo';
  TDriverRegistry.Register(e);
  Ok('custom-driver', TDriverRegistry.BuildUrl('mydb', 'h', 0, 'd', nil) =
    'jdbc:mydb://h:1234/d');
  extra := TStringList.Create;
  try
    extra.Values['ssl'] := 'true';
    Ok('custom-driver-sep', TDriverRegistry.BuildUrl('mydb', 'h', 0, 'd', extra) =
      'jdbc:mydb://h:1234/d;ssl=true');
  finally
    extra.Free;
  end;
  Ok('mydb-page', DialectFor('mydb').PagedSQL('SELECT * FROM t ORDER BY id', 10, 20) =
    'SELECT * FROM t ORDER BY id OFFSET 20 ROWS FETCH NEXT 10 ROWS ONLY');
  Ok('mydb-quote', DialectFor('mydb').QuoteIdent('a]b') = '[a]]b]');
  Ok('mydb-returning', DialectFor('mydb').KeyReturn('t', 'id') = ' RETURNING [id]');
  Ok('embedded-sqlite', TDriverRegistry.IsEmbedded('sqlite'));
  Ok('embedded-mydb-false', not TDriverRegistry.IsEmbedded('mydb'));
  Ok('embedded-unknown-false', not TDriverRegistry.IsEmbedded('nosuchdb'));
  CheckUrl('duckdb', '', 0, 'mem.db', 'jdbc:duckdb:mem.db');
  CheckUrl('derby', '', 0, 'appdb', 'jdbc:derby:appdb;create=true');
  CheckUrl('hsqldb', '', 0, 'appdb', 'jdbc:hsqldb:file:appdb');
  CheckUrl('firebird', 'db', 0, 'app', 'jdbc:firebirdsql://db:3050/app');
  CheckUrl('db2', 'db', 0, 'app', 'jdbc:db2://db:50000/app');
  CheckUrl('informix', 'db', 0, 'app', 'jdbc:informix-sqli://db:9088/app');
  CheckUrl('sybase', 'db', 0, 'app', 'jdbc:jtds:sybase://db:5000/app');
  CheckUrl('teradata', 'db', 0, 'app', 'jdbc:teradata://db/app');
  CheckUrl('vertica', 'db', 0, 'app', 'jdbc:vertica://db:5433/app');
  CheckUrl('clickhouse', 'db', 0, 'app', 'jdbc:clickhouse://db:8123/app');
  CheckUrl('trino', 'db', 0, 'app', 'jdbc:trino://db:8080/app');
  CheckUrl('presto', 'db', 0, 'app', 'jdbc:presto://db:8080/app');
  CheckUrl('hive', 'db', 0, 'app', 'jdbc:hive2://db:10000/app');
  CheckUrl('snowflake', 'myacct', 0, 'app', 'jdbc:snowflake://myacct.snowflakecomputing.com/app');
  CheckUrl('redshift', 'db', 0, 'app', 'jdbc:redshift://db:5439/app');
  CheckUrl('exasol', 'db', 0, 'app', 'jdbc:exa:db:8563;schema=app');
  CheckUrl('monetdb', 'db', 0, 'app', 'jdbc:monetdb://db:50000/app');
  CheckUrl('hana', 'db', 0, 'app', 'jdbc:sap://db:30015/?databaseName=app');
  CheckUrl('mysql', 'db', 0, 'app', 'jdbc:mysql://db:3306/app');
  CheckUrl('mariadb', 'db', 0, 'app', 'jdbc:mariadb://db:3306/app');
  CheckUrl('mssql', 'db', 0, 'app', 'jdbc:sqlserver://db:1433;databaseName=app');
  CheckUrl('oracle', 'db', 0, 'app', 'jdbc:oracle:thin:@db:1521:app');
  Ok('builtin-count', Length(TDriverRegistry.BuiltinIds) >= 25);
  ad := TDatasetAdapter.Create;
  try
    ad.UnknownTypeFallback := ufError;
    Ok('alias-blob', ad.MapTypeFor('mydb', 'MYBLOB(10)', memo) = ftBlob);
    Ok('alias-memo', (ad.MapTypeFor('mydb', 'mYtExT', memo) = ftWideMemo) and memo);
    Ok('alias-global-fallback', ad.MapTypeFor('mydb', 'VARCHAR', memo) = ftWideString);
    Ok('alias-unknown-driver', ad.MapTypeFor('nosuchdb', 'VARCHAR', memo) = ftWideString);
    tmp := GetTempFileName(GetTempDir, 'tyfstyle');
    sl := TStringList.Create;
    try
      sl.Text := '{"drivers": [{"id": "mydb2", "driverClass": "com.x.Driver", ' +
        '"urlTemplate": "jdbc:x://{host}:{port}/{database}", "defaultPort": 9999, ' +
        '"paging": "offset-fetch-first", "quote": "backtick", "keyReturn": "none", ' +
        '"paramSep": "&", "typeAliases": {"XBIN": "blob"}}]}';
      sl.SaveToFile(tmp);
      TDriverRegistry.LoadStylesFromJson(tmp);
      Ok('json-overlay-page', DialectFor('mydb2').PagedSQL('SELECT * FROM t', 10, 20) =
        'SELECT * FROM t OFFSET 20 ROWS FETCH FIRST 10 ROWS ONLY');
      Ok('json-overlay-quote', DialectFor('mydb2').QuoteIdent('a`b') = '`a``b`');
      Ok('json-overlay-alias', ad.MapTypeFor('mydb2', 'XBIN', memo) = ftBlob);
      sl.Text := '{"drivers": [{"id": "bad1", "driverClass": "com.x.D", ' +
        '"urlTemplate": "jdbc:x:d", "paging": "sideways"}]}';
      sl.SaveToFile(tmp);
      raised := False;
      try
        TDriverRegistry.LoadStylesFromJson(tmp);
      except
        on E: EJDBCError do
          raised := (E.SQLState = 'HY000') and (E.VendorCode = 45);
      end;
      Ok('json-bad-enum', raised);
    finally
      sl.Free;
      DeleteFile(tmp);
    end;
  finally
    ad.Free;
  end;

  WriteLn('TOTAL fails=', Fails);
  if Fails > 0 then Halt(1);
end.
