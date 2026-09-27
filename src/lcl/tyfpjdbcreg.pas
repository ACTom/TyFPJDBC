unit tyfpjdbcreg;
{$mode objfpc}{$H+}
interface
uses
  Classes, SysUtils;
procedure Register;
implementation
uses
  TyFPJDBC.LCL.Conn, TyFPJDBC.LCL.Query
  {$IFNDEF NoIDE}, TyFPJDBC.LCL.Editors{$ENDIF};
procedure Register;
begin
  RegisterComponents('TyFPJDBC', [TJdbcConnection, TJdbcConnQuery]);
  {$IFNDEF NoIDE}
  TyFPJDBC.LCL.Editors.Register;
  {$ENDIF}
end;
end.
