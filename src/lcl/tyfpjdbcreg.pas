unit tyfpjdbcreg;
{$mode objfpc}{$H+}
interface
uses
  Classes, SysUtils;
procedure Register;
implementation
uses
  TyFPJDBC.LCL.Conn, TyFPJDBC.LCL.Query;
procedure Register;
begin
  RegisterComponents('TyFPJDBC', [TJdbcConnection, TJdbcQuery]);
end;
end.
