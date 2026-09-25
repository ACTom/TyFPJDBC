unit TyFPJDBC.Driver.Registry;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, TyFPJDBC.Handles;
type
  TDriverIdArray = array of string;

  { Driver entry: arbitrary JDBC drivers register here. Unknown ids
    raise 08000; no silent fallback. }
  TPagingStyle = (psLimitOffset, psOffsetFetchNext, psOffsetFetchFirst);
  TQuoteStyle = (qsDouble, qsBacktick, qsBracket);
  TKeyReturnStyle = (krNone, krReturning);

  TDriverEntry = record
    Id, DriverClass, UrlTemplate: string;
    DefaultPort: Integer;
    TestQuery, License, Maven, Sha: string;
    Embedded: Boolean;
    Paging: TPagingStyle;
    Quote: TQuoteStyle;
    KeyReturn: TKeyReturnStyle;
    ParamSep: string;
    TypeAliases: TStringArray;
  end;

  TDriverRegistry = class
    class procedure Register(const E: TDriverEntry); static;
    class function Find(const DriverId: string): TDriverEntry; static;
    class function IsEmbedded(const DriverId: string): Boolean; static;
    class function BuiltinIds: TDriverIdArray; static;
    class function DefaultPort(const DriverId: string): Integer; static;
    class function BuildUrl(const DriverId, Host: string; Port: Integer;
      const Database: string; Extra: TStrings): string; static;
    class function BuildUrlNil(const DriverId, Host: string; Port: Integer;
      const Database: string): string; static;
    class procedure BuildProperties(const DriverId: string; LoginTimeoutSecs,
      SocketTimeoutSecs: Integer; ReadOnly: Boolean; Dest: TStrings); static;
    class procedure LoadStylesFromJson(const Path: string); static;
  end;

procedure RegisterBuiltinDrivers;

implementation

uses
  fpjson, jsonparser;

var
  GDrivers: array of TDriverEntry;

procedure InitStyle(var E: TDriverEntry);
begin
  E.Embedded := False; E.Paging := psLimitOffset; E.Quote := qsDouble;
  E.KeyReturn := krNone; E.ParamSep := '&'; SetLength(E.TypeAliases, 0);
end;

procedure RegisterBuiltinDrivers;
var
  e: TDriverEntry;
begin
  if Length(GDrivers) > 0 then
    Exit;
  InitStyle(e);
  e.Id := 'postgresql'; e.DriverClass := 'org.postgresql.Driver';
  e.UrlTemplate := 'jdbc:postgresql://{host}:{port}/{database}';
  e.DefaultPort := 5432; e.TestQuery := 'SELECT 1';
  e.License := 'BSD-2'; e.Maven := 'org.postgresql:postgresql:42.7.3'; e.Sha := '';
  e.KeyReturn := krReturning;
  TDriverRegistry.Register(e);
  InitStyle(e);
  e.Id := 'mysql'; e.DriverClass := 'com.mysql.cj.jdbc.Driver';
  e.UrlTemplate := 'jdbc:mysql://{host}:{port}/{database}';
  e.DefaultPort := 3306; e.TestQuery := 'SELECT 1';
  e.License := 'GPL-2'; e.Maven := 'com.mysql:mysql-connector-j:8.3.0'; e.Sha := '';
  e.Quote := qsBacktick;
  TDriverRegistry.Register(e);
  InitStyle(e);
  e.Id := 'mariadb'; e.DriverClass := 'org.mariadb.jdbc.Driver';
  e.UrlTemplate := 'jdbc:mariadb://{host}:{port}/{database}';
  e.DefaultPort := 3306; e.TestQuery := 'SELECT 1';
  e.License := 'LGPL-2.1'; e.Maven := 'org.mariadb.jdbc:mariadb-java-client:3.3.2'; e.Sha := '';
  e.Quote := qsBacktick;
  TDriverRegistry.Register(e);
  InitStyle(e);
  e.Id := 'mssql'; e.DriverClass := 'com.microsoft.sqlserver.jdbc.SQLServerDriver';
  e.UrlTemplate := 'jdbc:sqlserver://{host}:{port};databaseName={database}';
  e.DefaultPort := 1433; e.TestQuery := 'SELECT 1';
  e.License := 'MIT'; e.Maven := 'com.microsoft.sqlserver:mssql-jdbc:12.6.1.jre11'; e.Sha := '';
  e.Paging := psOffsetFetchNext; e.Quote := qsBracket; e.ParamSep := ';';
  TDriverRegistry.Register(e);
  InitStyle(e);
  e.Id := 'oracle'; e.DriverClass := 'oracle.jdbc.OracleDriver';
  e.UrlTemplate := 'jdbc:oracle:thin:@{host}:{port}:{database}';
  e.DefaultPort := 1521; e.TestQuery := 'SELECT 1 FROM DUAL';
  e.License := 'OTN'; e.Maven := 'com.oracle.database.jdbc:ojdbc11:23.3.0.23.09'; e.Sha := '';
  e.Paging := psOffsetFetchFirst;
  TDriverRegistry.Register(e);
  InitStyle(e);
  e.Id := 'sqlite'; e.DriverClass := 'org.sqlite.JDBC';
  e.UrlTemplate := 'jdbc:sqlite:{database}';
  e.DefaultPort := 0; e.TestQuery := 'SELECT 1';
  e.License := 'Apache-2.0'; e.Maven := 'org.xerial:sqlite-jdbc:3.46.1.0'; e.Sha := '';
  e.Embedded := True;
  TDriverRegistry.Register(e);
  InitStyle(e);
  e.Id := 'h2'; e.DriverClass := 'org.h2.Driver';
  e.UrlTemplate := 'jdbc:h2:mem:{database}';
  e.DefaultPort := 0; e.TestQuery := 'SELECT 1';
  e.License := 'MPL-2.0'; e.Maven := 'com.h2database:h2:2.2.224'; e.Sha := '';
  e.Embedded := True;
  TDriverRegistry.Register(e);
  InitStyle(e);
  e.Id := 'duckdb'; e.DriverClass := 'org.duckdb.DuckDBDriver';
  e.UrlTemplate := 'jdbc:duckdb:{database}';
  e.DefaultPort := 0; e.TestQuery := 'SELECT 1';
  e.License := 'MIT'; e.Maven := 'org.duckdb:duckdb_jdbc:1.0.0'; e.Sha := '';
  e.Embedded := True;
  TDriverRegistry.Register(e);
  InitStyle(e);
  e.Id := 'derby'; e.DriverClass := 'org.apache.derby.jdbc.EmbeddedDriver';
  e.UrlTemplate := 'jdbc:derby:{database};create=true';
  e.DefaultPort := 0; e.TestQuery := 'SELECT 1';
  e.License := 'Apache-2.0'; e.Maven := 'org.apache.derby:derby:10.17.1.0'; e.Sha := '';
  e.Embedded := True;
  TDriverRegistry.Register(e);
  InitStyle(e);
  e.Id := 'hsqldb'; e.DriverClass := 'org.hsqldb.jdbc.JDBCDriver';
  e.UrlTemplate := 'jdbc:hsqldb:file:{database}';
  e.DefaultPort := 0; e.TestQuery := 'SELECT 1';
  e.License := 'BSD-3-Clause'; e.Maven := 'org.hsqldb:hsqldb:2.7.2'; e.Sha := '';
  e.Embedded := True;
  TDriverRegistry.Register(e);
  InitStyle(e);
  e.Id := 'firebird'; e.DriverClass := 'org.firebirdsql.jdbc.FBDriver';
  e.UrlTemplate := 'jdbc:firebirdsql://{host}:{port}/{database}';
  e.DefaultPort := 3050; e.TestQuery := 'SELECT 1 FROM RDB$DATABASE';
  e.License := 'IPL-1.0'; e.Maven := 'org.firebirdsql.jdbc:jaybird:4.0.9.java11'; e.Sha := '';
  TDriverRegistry.Register(e);
  InitStyle(e);
  e.Id := 'db2'; e.DriverClass := 'com.ibm.db2.jcc.DB2Driver';
  e.UrlTemplate := 'jdbc:db2://{host}:{port}/{database}';
  e.DefaultPort := 50000; e.TestQuery := 'SELECT 1 FROM SYSIBM.SYSDUMMY1';
  e.License := 'Proprietary'; e.Maven := 'com.ibm.db2:jcc:11.5.9.0'; e.Sha := '';
  TDriverRegistry.Register(e);
  InitStyle(e);
  e.Id := 'informix'; e.DriverClass := 'com.informix.jdbc.IfxDriver';
  e.UrlTemplate := 'jdbc:informix-sqli://{host}:{port}/{database}';
  e.DefaultPort := 9088; e.TestQuery := 'SELECT 1 FROM SYSTABLES';
  e.License := 'Proprietary'; e.Maven := 'com.ibm.informix:jdbc:4.50.10'; e.Sha := '';
  TDriverRegistry.Register(e);
  InitStyle(e);
  e.Id := 'sybase'; e.DriverClass := 'net.sourceforge.jtds.jdbc.Driver';
  e.UrlTemplate := 'jdbc:jtds:sybase://{host}:{port}/{database}';
  e.DefaultPort := 5000; e.TestQuery := 'SELECT 1';
  e.License := 'LGPL-2.1'; e.Maven := 'net.sourceforge.jtds:jtds:1.3.1'; e.Sha := '';
  TDriverRegistry.Register(e);
  InitStyle(e);
  e.Id := 'teradata'; e.DriverClass := 'com.teradata.jdbc.TeraDriver';
  e.UrlTemplate := 'jdbc:teradata://{host}/{database}';
  e.DefaultPort := 1025; e.TestQuery := 'SELECT 1';
  e.License := 'Proprietary'; e.Maven := 'com.teradata.jdbc:terajdbc4:17.20.00.12'; e.Sha := '';
  TDriverRegistry.Register(e);
  InitStyle(e);
  e.Id := 'vertica'; e.DriverClass := 'com.vertica.jdbc.Driver';
  e.UrlTemplate := 'jdbc:vertica://{host}:{port}/{database}';
  e.DefaultPort := 5433; e.TestQuery := 'SELECT 1';
  e.License := 'Proprietary'; e.Maven := 'com.vertica.jdbc:vertica-jdbc:23.4.0-0'; e.Sha := '';
  TDriverRegistry.Register(e);
  InitStyle(e);
  e.Id := 'clickhouse'; e.DriverClass := 'com.clickhouse.jdbc.ClickHouseDriver';
  e.UrlTemplate := 'jdbc:clickhouse://{host}:{port}/{database}';
  e.DefaultPort := 8123; e.TestQuery := 'SELECT 1';
  e.License := 'Apache-2.0'; e.Maven := 'com.clickhouse:clickhouse-jdbc:0.6.0'; e.Sha := '';
  TDriverRegistry.Register(e);
  InitStyle(e);
  e.Id := 'trino'; e.DriverClass := 'io.trino.jdbc.TrinoDriver';
  e.UrlTemplate := 'jdbc:trino://{host}:{port}/{database}';
  e.DefaultPort := 8080; e.TestQuery := 'SELECT 1';
  e.License := 'Apache-2.0'; e.Maven := 'io.trino:trino-jdbc:435'; e.Sha := '';
  TDriverRegistry.Register(e);
  InitStyle(e);
  e.Id := 'presto'; e.DriverClass := 'com.facebook.presto.jdbc.PrestoDriver';
  e.UrlTemplate := 'jdbc:presto://{host}:{port}/{database}';
  e.DefaultPort := 8080; e.TestQuery := 'SELECT 1';
  e.License := 'Apache-2.0'; e.Maven := 'com.facebook.presto:presto-jdbc:0.288'; e.Sha := '';
  TDriverRegistry.Register(e);
  InitStyle(e);
  e.Id := 'hive'; e.DriverClass := 'org.apache.hive.jdbc.HiveDriver';
  e.UrlTemplate := 'jdbc:hive2://{host}:{port}/{database}';
  e.DefaultPort := 10000; e.TestQuery := 'SELECT 1';
  e.License := 'Apache-2.0'; e.Maven := 'org.apache.hive:hive-jdbc:3.1.3'; e.Sha := '';
  TDriverRegistry.Register(e);
  InitStyle(e);
  e.Id := 'snowflake'; e.DriverClass := 'net.snowflake.client.jdbc.SnowflakeDriver';
  e.UrlTemplate := 'jdbc:snowflake://{host}.snowflakecomputing.com/{database}';
  e.DefaultPort := 443; e.TestQuery := 'SELECT 1';
  e.License := 'Apache-2.0'; e.Maven := 'net.snowflake:snowflake-jdbc:3.16.1'; e.Sha := '';
  TDriverRegistry.Register(e);
  InitStyle(e);
  e.Id := 'redshift'; e.DriverClass := 'com.amazon.redshift.jdbc42.Driver';
  e.UrlTemplate := 'jdbc:redshift://{host}:{port}/{database}';
  e.DefaultPort := 5439; e.TestQuery := 'SELECT 1';
  e.License := 'Apache-2.0'; e.Maven := 'software.amazon.redshift:redshift-jdbc42:2.1.0.9'; e.Sha := '';
  TDriverRegistry.Register(e);
  InitStyle(e);
  e.Id := 'exasol'; e.DriverClass := 'com.exasol.jdbc.EXADriver';
  e.UrlTemplate := 'jdbc:exa:{host}:{port};schema={database}';
  e.DefaultPort := 8563; e.TestQuery := 'SELECT 1';
  e.License := 'MIT'; e.Maven := 'com.exasol:exasol-jdbc:24.1.0'; e.Sha := '';
  TDriverRegistry.Register(e);
  InitStyle(e);
  e.Id := 'monetdb'; e.DriverClass := 'nl.cwi.monetdb.jdbc.MonetDriver';
  e.UrlTemplate := 'jdbc:monetdb://{host}:{port}/{database}';
  e.DefaultPort := 50000; e.TestQuery := 'SELECT 1';
  e.License := 'MPL-2.0'; e.Maven := 'org.monetdb:monetdb-jdbc:3.2'; e.Sha := '';
  TDriverRegistry.Register(e);
  InitStyle(e);
  e.Id := 'hana'; e.DriverClass := 'com.sap.db.jdbc.Driver';
  e.UrlTemplate := 'jdbc:sap://{host}:{port}/?databaseName={database}';
  e.DefaultPort := 30015; e.TestQuery := 'SELECT 1 FROM DUMMY';
  e.License := 'Proprietary'; e.Maven := 'com.sap.cloud.db.jdbc:ngdbc:2.18.16'; e.Sha := '';
  TDriverRegistry.Register(e);
end;

class procedure TDriverRegistry.Register(const E: TDriverEntry);
var
  i: Integer;
begin
  for i := 0 to High(GDrivers) do
    if LowerCase(GDrivers[i].Id) = LowerCase(Trim(E.Id)) then
    begin
      GDrivers[i] := E;
      Exit;
    end;
  SetLength(GDrivers, Length(GDrivers) + 1);
  GDrivers[High(GDrivers)] := E;
end;

class function TDriverRegistry.Find(const DriverId: string): TDriverEntry;
var
  i: Integer;
begin
  RegisterBuiltinDrivers;
  for i := 0 to High(GDrivers) do
    if LowerCase(GDrivers[i].Id) = LowerCase(Trim(DriverId)) then
      Exit(GDrivers[i]);
  raise EJDBCError.CreateChain('unknown driver', '08000', 40, DriverId);
end;

class function TDriverRegistry.DefaultPort(const DriverId: string): Integer;
begin
  Result := Find(DriverId).DefaultPort;
end;

class function TDriverRegistry.IsEmbedded(const DriverId: string): Boolean;
begin
  try
    Result := Find(DriverId).Embedded;
  except
    Result := False;
  end;
end;

class function TDriverRegistry.BuiltinIds: TDriverIdArray;
var
  i: Integer;
begin
  RegisterBuiltinDrivers;
  SetLength(Result, Length(GDrivers));
  for i := 0 to High(GDrivers) do
    Result[i] := GDrivers[i].Id;
end;

class function TDriverRegistry.BuildUrl(const DriverId, Host: string;
  Port: Integer; const Database: string; Extra: TStrings): string;
var
  e: TDriverEntry;
  p, i: Integer;
  q, sep: string;
begin
  e := Find(DriverId);
  Result := e.UrlTemplate;
  p := Port;
  if p <= 0 then
    p := e.DefaultPort;
  sep := e.ParamSep;
  if sep = '' then
    sep := '&';
  if e.Embedded then
  begin
    Result := StringReplace(Result, '{database}', Database, [rfReplaceAll]);
    Exit(Result);
  end;
  if Trim(Host) = '' then
    raise EJDBCError.CreateChain('host required', '08000', 41, DriverId);
  if Trim(Database) = '' then
    raise EJDBCError.CreateChain('database required', '08000', 42, DriverId);
  Result := StringReplace(Result, '{host}', Trim(Host), [rfReplaceAll]);
  Result := StringReplace(Result, '{port}', IntToStr(p), [rfReplaceAll]);
  Result := StringReplace(Result, '{database}', Trim(Database), [rfReplaceAll]);
  if (Extra <> nil) and (Extra.Count > 0) then
  begin
    q := '';
    for i := 0 to Extra.Count - 1 do
    begin
      if q <> '' then
        q := q + sep;
      q := q + Extra.Names[i] + '=' + Extra.ValueFromIndex[i];
    end;
    if Pos('?', Result) > 0 then
      Result := Result + sep + q
    else if sep = ';' then
      Result := Result + ';' + q
    else
      Result := Result + '?' + q;
  end;
end;

class procedure TDriverRegistry.BuildProperties(const DriverId: string;
  LoginTimeoutSecs, SocketTimeoutSecs: Integer; ReadOnly: Boolean;
  Dest: TStrings);
begin
  Find(DriverId);
  if Dest = nil then
    Exit;
  Dest.Values['loginTimeout'] := IntToStr(LoginTimeoutSecs);
  Dest.Values['socketTimeout'] := IntToStr(SocketTimeoutSecs);
  Dest.Values['readOnly'] := LowerCase(BoolToStr(ReadOnly, True));
end;

class function TDriverRegistry.BuildUrlNil(const DriverId, Host: string;
  Port: Integer; const Database: string): string;
begin
  Result := BuildUrl(DriverId, Host, Port, Database, nil);
end;

function StyleFileStr(O: TJSONObject; const K, Def: string): string;
var
  d: TJSONData;
begin
  d := O.Find(K);
  if (d = nil) or (d.JSONType <> jtString) then
    Exit(Def);
  Result := d.AsString;
end;

function StyleFileBool(O: TJSONObject; const K: string; Def: Boolean): Boolean;
var
  d: TJSONData;
begin
  d := O.Find(K);
  if (d = nil) or ((d.JSONType <> jtBoolean) and (d.JSONType <> jtNumber)) then
    Exit(Def);
  Result := d.AsBoolean;
end;

function PagingStyleOfFile(const S, Ctx: string): TPagingStyle;
begin
  if S = 'limit-offset' then Exit(psLimitOffset);
  if S = 'offset-fetch-next' then Exit(psOffsetFetchNext);
  if S = 'offset-fetch-first' then Exit(psOffsetFetchFirst);
  raise EJDBCError.CreateChain('bad driver style file', 'HY000', 45, Ctx + '.paging=' + S);
end;

function QuoteStyleOfFile(const S, Ctx: string): TQuoteStyle;
begin
  if S = 'double' then Exit(qsDouble);
  if S = 'backtick' then Exit(qsBacktick);
  if S = 'bracket' then Exit(qsBracket);
  raise EJDBCError.CreateChain('bad driver style file', 'HY000', 45, Ctx + '.quote=' + S);
end;

function KeyReturnStyleOfFile(const S, Ctx: string): TKeyReturnStyle;
begin
  if S = 'none' then Exit(krNone);
  if S = 'returning' then Exit(krReturning);
  raise EJDBCError.CreateChain('bad driver style file', 'HY000', 45, Ctx + '.keyReturn=' + S);
end;

procedure CheckAliasClass(const Cls, Ctx: string);
begin
  case LowerCase(Trim(Cls)) of
    'widestring', 'widememo', 'integer', 'largeint', 'fmtbcd', 'float',
    'boolean', 'date', 'time', 'datetime', 'blob': Exit;
  else
    raise EJDBCError.CreateChain('bad driver style file', 'HY000', 45, Ctx + '.typeAliases=' + Cls);
  end;
end;

class procedure TDriverRegistry.LoadStylesFromJson(const Path: string);
var
  sl: TStringList;
  j: TJSONData;
  arr: TJSONArray;
  i, k: Integer;
  o, al: TJSONObject;
  id, ctx: string;
  e: TDriverEntry;
  known: Boolean;
  sep: string;
begin
  if not FileExists(Path) then
    Exit;
  sl := TStringList.Create;
  try
    sl.LoadFromFile(Path);
    j := GetJSON(sl.Text);
  finally
    sl.Free;
  end;
  try
    arr := TJSONArray(TJSONObject(j).FindPath('drivers'));
    if arr = nil then
      raise EJDBCError.CreateChain('bad driver style file', 'HY000', 45, Path + ': missing drivers[]');
    for i := 0 to arr.Count - 1 do
    begin
      o := arr.Objects[i];
      id := StyleFileStr(o, 'id', '');
      ctx := Path + ': drivers[' + IntToStr(i) + ']=' + id;
      if Trim(id) = '' then
        raise EJDBCError.CreateChain('bad driver style file', 'HY000', 45, Path + ': drivers[' + IntToStr(i) + '] missing id');
      known := True;
      try
        e := Find(id);
      except
        known := False;
      end;
      if not known then
      begin
        InitStyle(e);
        e.Id := id;
        e.DriverClass := StyleFileStr(o, 'driverClass', '');
        e.UrlTemplate := StyleFileStr(o, 'urlTemplate', '');
        e.DefaultPort := StrToIntDef(StyleFileStr(o, 'defaultPort', '0'), 0);
        e.TestQuery := StyleFileStr(o, 'testQuery', 'SELECT 1');
        e.License := StyleFileStr(o, 'license', '');
        e.Maven := StyleFileStr(o, 'maven', '');
        e.Sha := StyleFileStr(o, 'sha1', '');
        if Trim(e.DriverClass) = '' then
          raise EJDBCError.CreateChain('bad driver style file', 'HY000', 45, ctx + ' missing driverClass');
        if Trim(e.UrlTemplate) = '' then
          raise EJDBCError.CreateChain('bad driver style file', 'HY000', 45, ctx + ' missing urlTemplate');
      end;
      e.Embedded := StyleFileBool(o, 'embedded', e.Embedded);
      if o.Find('paging') <> nil then
        e.Paging := PagingStyleOfFile(StyleFileStr(o, 'paging', ''), ctx);
      if o.Find('quote') <> nil then
        e.Quote := QuoteStyleOfFile(StyleFileStr(o, 'quote', ''), ctx);
      if o.Find('keyReturn') <> nil then
        e.KeyReturn := KeyReturnStyleOfFile(StyleFileStr(o, 'keyReturn', ''), ctx);
      sep := StyleFileStr(o, 'paramSep', e.ParamSep);
      if sep = '' then
        sep := '&';
      if (sep <> '&') and (sep <> ';') then
        raise EJDBCError.CreateChain('bad driver style file', 'HY000', 45, ctx + '.paramSep=' + sep);
      e.ParamSep := sep;
      al := TJSONObject(o.Find('typeAliases'));
      if al <> nil then
      begin
        SetLength(e.TypeAliases, al.Count);
        for k := 0 to al.Count - 1 do
        begin
          CheckAliasClass(al.Items[k].AsString, ctx);
          e.TypeAliases[k] := UpperCase(Trim(al.Names[k])) + '=' + LowerCase(Trim(al.Items[k].AsString));
        end;
      end;
      Register(e);
    end;
  finally
    j.Free;
  end;
end;

initialization
  RegisterBuiltinDrivers;
end.
