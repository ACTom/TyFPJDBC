unit TyFPJDBC.Driver.Registry;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, TyFPJDBC.Handles;
type
  { Driver entry: arbitrary JDBC drivers register here. Unknown ids
    raise 08000; no silent fallback. }
  TDriverEntry = record
    Id, DriverClass, UrlTemplate: string;
    DefaultPort: Integer;
    TestQuery, License, Maven, Sha: string;
  end;

  TDriverRegistry = class
    class procedure Register(const E: TDriverEntry); static;
    class function Find(const DriverId: string): TDriverEntry; static;
    class function DefaultPort(const DriverId: string): Integer; static;
    class function BuildUrl(const DriverId, Host: string; Port: Integer;
      const Database: string; Extra: TStrings): string; static;
    class function BuildUrlNil(const DriverId, Host: string; Port: Integer;
      const Database: string): string; static;
    class procedure BuildProperties(const DriverId: string; LoginTimeoutSecs,
      SocketTimeoutSecs: Integer; ReadOnly: Boolean; Dest: TStrings); static;
  end;

procedure RegisterBuiltinDrivers;

implementation

var
  GDrivers: array of TDriverEntry;

procedure RegisterBuiltinDrivers;
var
  e: TDriverEntry;
begin
  if Length(GDrivers) > 0 then
    Exit;
  e.Id := 'postgresql'; e.DriverClass := 'org.postgresql.Driver';
  e.UrlTemplate := 'jdbc:postgresql://{host}:{port}/{database}';
  e.DefaultPort := 5432; e.TestQuery := 'SELECT 1';
  e.License := 'BSD-2'; e.Maven := 'org.postgresql:postgresql:42.7.3'; e.Sha := '';
  TDriverRegistry.Register(e);
  e.Id := 'mysql'; e.DriverClass := 'com.mysql.cj.jdbc.Driver';
  e.UrlTemplate := 'jdbc:mysql://{host}:{port}/{database}';
  e.DefaultPort := 3306; e.TestQuery := 'SELECT 1';
  e.License := 'GPL-2'; e.Maven := 'com.mysql:mysql-connector-j:8.3.0'; e.Sha := '';
  TDriverRegistry.Register(e);
  e.Id := 'mariadb'; e.DriverClass := 'org.mariadb.jdbc.Driver';
  e.UrlTemplate := 'jdbc:mariadb://{host}:{port}/{database}';
  e.DefaultPort := 3306; e.TestQuery := 'SELECT 1';
  e.License := 'LGPL-2.1'; e.Maven := 'org.mariadb.jdbc:mariadb-java-client:3.3.2'; e.Sha := '';
  TDriverRegistry.Register(e);
  e.Id := 'mssql'; e.DriverClass := 'com.microsoft.sqlserver.jdbc.SQLServerDriver';
  e.UrlTemplate := 'jdbc:sqlserver://{host}:{port};databaseName={database}';
  e.DefaultPort := 1433; e.TestQuery := 'SELECT 1';
  e.License := 'MIT'; e.Maven := 'com.microsoft.sqlserver:mssql-jdbc:12.6.1.jre11'; e.Sha := '';
  TDriverRegistry.Register(e);
  e.Id := 'oracle'; e.DriverClass := 'oracle.jdbc.OracleDriver';
  e.UrlTemplate := 'jdbc:oracle:thin:@{host}:{port}:{database}';
  e.DefaultPort := 1521; e.TestQuery := 'SELECT 1 FROM DUAL';
  e.License := 'OTN'; e.Maven := 'com.oracle.database.jdbc:ojdbc11:23.3.0.23.09'; e.Sha := '';
  TDriverRegistry.Register(e);
  e.Id := 'sqlite'; e.DriverClass := 'org.sqlite.JDBC';
  e.UrlTemplate := 'jdbc:sqlite:{database}';
  e.DefaultPort := 0; e.TestQuery := 'SELECT 1';
  e.License := 'Apache-2.0'; e.Maven := 'org.xerial:sqlite-jdbc:3.46.1.0'; e.Sha := '';
  TDriverRegistry.Register(e);
  e.Id := 'h2'; e.DriverClass := 'org.h2.Driver';
  e.UrlTemplate := 'jdbc:h2:mem:{database}';
  e.DefaultPort := 0; e.TestQuery := 'SELECT 1';
  e.License := 'MPL-2.0'; e.Maven := 'com.h2database:h2:2.2.224'; e.Sha := '';
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

class function TDriverRegistry.BuildUrl(const DriverId, Host: string;
  Port: Integer; const Database: string; Extra: TStrings): string;
var
  e: TDriverEntry;
  p, i: Integer;
  q: string;
begin
  e := Find(DriverId);
  Result := e.UrlTemplate;
  p := Port;
  if p <= 0 then
    p := e.DefaultPort;
  if (LowerCase(e.Id) = 'sqlite') or (LowerCase(e.Id) = 'h2') then
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
        q := q + '&';
      q := q + Extra.Names[i] + '=' + Extra.ValueFromIndex[i];
    end;
    if Pos('?', Result) > 0 then
      Result := Result + '&' + q
    else if LowerCase(e.Id) = 'mssql' then
      Result := Result + ';' + StringReplace(q, '&', ';', [rfReplaceAll])
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

initialization
  RegisterBuiltinDrivers;
end.
