unit TyFPJDBC.LCL.Conn;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, DB, TyFPJDBC.Config;
type
  TUrlForFunc = function(const DriverId, Host: string; Port: Integer;
    const Database: string): string;

  { Design-time connection component: configuration only (driver, url
    parts, credentials, pool sizes, timeouts). The Engine owns all live
    state at runtime; this component never opens sockets itself. }
  TJdbcConnection = class(TComponent)
  private
    FDriverId: string;
    FHost: string;
    FPort: Integer;
    FDatabase: string;
    FUser: string;
    FPassword: string;
    FMaxPool: Integer;
    FMinIdle: Integer;
    FLoginTimeoutSecs: Integer;
  public
    constructor Create(AOwner: TComponent); override;
    function BuiltUrl(UrlFor: TUrlForFunc): string;
  published
    property DriverId: string read FDriverId write FDriverId;
    property Host: string read FHost write FHost;
    property Port: Integer read FPort write FPort;
    property Database: string read FDatabase write FDatabase;
    property User: string read FUser write FUser;
    property Password: string read FPassword write FPassword;
    property MaxPool: Integer read FMaxPool write FMaxPool;
    property MinIdle: Integer read FMinIdle write FMinIdle;
    property LoginTimeoutSecs: Integer read FLoginTimeoutSecs write FLoginTimeoutSecs;
  end;

implementation

constructor TJdbcConnection.Create(AOwner: TComponent);
var
  cfg: TJdbcConfig;
begin
  inherited Create(AOwner);
  cfg := TJdbcConfig.Default;
  try
    FDriverId := 'sqlite';
    FHost := '';
    FPort := 0;
    FDatabase := '';
    FUser := '';
    FPassword := '';
    FMaxPool := cfg.Pool_MaxPool;
    FMinIdle := cfg.Pool_MinIdle;
    FLoginTimeoutSecs := 15;
  finally
    cfg.Free;
  end;
end;

function TJdbcConnection.BuiltUrl(UrlFor: TUrlForFunc): string;
begin
  if not Assigned(UrlFor) then
    raise Exception.Create('url builder required');
  Result := UrlFor(FDriverId, FHost, FPort, FDatabase);
end;

end.
