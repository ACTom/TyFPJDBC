unit TyFPJDBC.Pool.Intf;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, TyFPJDBC.Connection;
type
  IJDBCConnectionPool = interface
    ['{7E3A1F2B-4C5D-4E6F-8A9B-0C1D2E3F4A5B}']
    function GetConnection: TJDBCConnection;
    procedure ReleaseConnection(C: TJDBCConnection);
    function ActiveCount: Integer;
    function IdleCount: Integer;
  end;
implementation
end.
