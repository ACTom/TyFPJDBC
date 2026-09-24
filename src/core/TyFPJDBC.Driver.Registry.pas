unit TyFPJDBC.Driver.Registry;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, TyFPJDBC.Connection;
type
  { URL builder matching configs/drivers.json urlTemplate/defaultPort.
    Pure logic: no I/O, no JVM. Unknown id raises EJDBCError 08000. }
  TDriverRegistry = class
    class function DefaultPort(const DriverId: string): Integer; static;
    class function UrlFor(const DriverId, Host: string; Port: Integer;
      const Database: string): string; static;
  end;
implementation

class function TDriverRegistry.DefaultPort(const DriverId: string): Integer;
var
  id: string;
begin
  id := LowerCase(Trim(DriverId));
  if id = 'postgresql' then
    Exit(5432);
  if (id = 'h2') or (id = 'sqlite') then
    Exit(0);
  raise EJDBCError.CreateChain('unknown driver', '08000', 40, DriverId);
end;

class function TDriverRegistry.UrlFor(const DriverId, Host: string;
  Port: Integer; const Database: string): string;
var
  id: string;
  p: Integer;
begin
  id := LowerCase(Trim(DriverId));
  if id = 'sqlite' then
    Exit('jdbc:sqlite:' + Database);
  if id = 'h2' then
    Exit('jdbc:h2:mem:' + Database);
  if id = 'postgresql' then
  begin
    p := Port;
    if p <= 0 then
      p := 5432;
    if Trim(Host) = '' then
      raise EJDBCError.CreateChain('host required', '08000', 41, DriverId);
    if Trim(Database) = '' then
      raise EJDBCError.CreateChain('database required', '08000', 42,
        DriverId);
    Exit('jdbc:postgresql://' + Trim(Host) + ':' + IntToStr(p) + '/' +
      Trim(Database));
  end;
  raise EJDBCError.CreateChain('unknown driver', '08000', 40, DriverId);
end;

end.
