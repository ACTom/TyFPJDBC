unit TyFPJDBC.LCL.Conn;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, DB, TyFPJDBC.Config;
type
  TUrlForFunc = function(const DriverId, Host: string; Port: Integer;
    const Database: string): string;

  { Design-time connection component: configuration only at design time
    (driver, url parts, credentials, pool sizes, timeouts). At runtime it
    owns JVM + Engine + pool + one live connection; the component never
    opens sockets while csDesigning is set. CloseQuery on the query side
    does not touch this handle. }
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
    FConnected: Boolean;
    FBridge: TObject;
    FEngine: TObject;
    FPool: Int64;
    FConn: Int64;
    FLastError: string;
    function GetConnected: Boolean;
    procedure SetConnected(V: Boolean);
    function Designing: Boolean;
    procedure Shutdown;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function BuiltUrl(UrlFor: TUrlForFunc): string;
    function BuiltUrlDefault: string;
    procedure Connect;
    procedure Disconnect;
    function TestConnection(out Msg: string): Boolean;
    function EnginePtr: TObject;
    function LiveConn: Int64;
    property LastError: string read FLastError;
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
    property Connected: Boolean read GetConnected write SetConnected default False;
    property ConnectionTimeoutSecs: Integer read FLoginTimeoutSecs write FLoginTimeoutSecs;
  end;

implementation

uses
  TyFPJDBC.Handles, TyFPJDBC.JVM.Manager, TyFPJDBC.JNI.Bridge,
  TyFPJDBC.Engine, TyFPJDBC.Driver.Registry;

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
  FConnected := False;
  FBridge := nil;
  FEngine := nil;
  FPool := 0;
  FConn := 0;
  FLastError := '';
end;

destructor TJdbcConnection.Destroy;
begin
  if not Designing then
    Shutdown;
  inherited;
end;

function TJdbcConnection.Designing: Boolean;
begin
  Result := (csDesigning in ComponentState) or (csLoading in ComponentState);
end;

function TJdbcConnection.GetConnected: Boolean;
begin
  Result := FConnected and (FEngine <> nil) and (FConn > 0);
end;

procedure TJdbcConnection.SetConnected(V: Boolean);
begin
  if V then
    Connect
  else
    Disconnect;
end;

procedure TJdbcConnection.Shutdown;
begin
  if FConn > 0 then
  begin
    try
      TJdbcEngine(FEngine).Release(FConn);
    except
    end;
    FConn := 0;
  end;
  if FPool > 0 then
  begin
    try
      TJdbcEngine(FEngine).ClosePool(FPool);
    except
    end;
    FPool := 0;
  end;
  FreeAndNil(FEngine);
  FreeAndNil(FBridge);
  FConnected := False;
end;

function TJdbcConnection.BuiltUrl(UrlFor: TUrlForFunc): string;
begin
  if not Assigned(UrlFor) then
    raise Exception.Create('url builder required');
  Result := UrlFor(FDriverId, FHost, FPort, FDatabase);
end;

function TJdbcConnection.BuiltUrlDefault: string;
var
  e: TDriverEntry;
  p: Integer;
begin
  e := TDriverRegistry.Find(FDriverId);
  if FDatabase = '' then
    raise EJDBCError.CreateChain('database required', '08000', 42, FDriverId);
  if TDriverRegistry.IsEmbedded(FDriverId) then
    Exit(TDriverRegistry.BuildUrl(FDriverId, '', 0, FDatabase, nil));
  if Trim(FHost) = '' then
    raise EJDBCError.CreateChain('host required', '08000', 41, FDriverId);
  p := FPort;
  if p <= 0 then
    p := e.DefaultPort;
  Result := TDriverRegistry.BuildUrl(FDriverId, FHost, p, FDatabase, nil);
end;

function TJdbcConnection.EnginePtr: TObject;
begin
  Result := FEngine;
end;

function TJdbcConnection.LiveConn: Int64;
begin
  if not GetConnected then
    raise EJDBCError.CreateChain('not connected', '08000', 44, FDriverId);
  Result := FConn;
end;

procedure TJdbcConnection.Connect;
var
  e: TDriverEntry;
  url: string;
  cfg: TPoolCfgRec;
  stmt, cur: Int64;
begin
  if Designing then
    raise Exception.Create('connect at runtime only');
  if GetConnected then
    Exit;
  Shutdown;
  FLastError := '';
  try
    TJVMManager.EnsureStarted(TJVMManager.FindLibJvm(''),
      TJVMManager.BuildDesktopArgs);
    FBridge := TBridge.Create;
    try
      FEngine := TJdbcEngine.Create(TBridge(FBridge));
      e := TDriverRegistry.Find(FDriverId);
      url := BuiltUrlDefault;
      cfg := DefaultPoolCfg(UTF8String(url), UTF8String(e.DriverClass));
      cfg.User := UTF8String(FUser);
      cfg.Password := UTF8String(FPassword);
      cfg.MaximumPoolSize := FMaxPool;
      cfg.MinimumIdle := FMinIdle;
      cfg.ConnectionTimeoutMs := Int64(FLoginTimeoutSecs) * 1000;
      FPool := TJdbcEngine(FEngine).OpenPool(cfg);
      FConn := TJdbcEngine(FEngine).Borrow(FPool);
      stmt := TBridge(FBridge).Prepare(FConn, UTF8String(e.TestQuery));
      try
        cur := TBridge(FBridge).QueryOpen(stmt, 1);
        try
          TBridge(FBridge).FetchWindow(cur, 1);
        finally
          TBridge(FBridge).CloseCursor(cur);
        end;
      finally
        TBridge(FBridge).CloseStmt(stmt);
      end;
      FConnected := True;
    except
      Shutdown;
      raise;
    end;
  except
    on Ex: Exception do
    begin
      if Ex is EJDBCError then
        FLastError := EJDBCError(Ex).SQLState + ': ' + Ex.Message
      else
        FLastError := Ex.Message;
      raise;
    end;
  end;
end;

procedure TJdbcConnection.Disconnect;
begin
  if Designing then
    Exit;
  Shutdown;
end;

function TJdbcConnection.TestConnection(out Msg: string): Boolean;
begin
  try
    Connect;
    Msg := 'connection ok';
    Result := True;
  except
    on Ex: Exception do
    begin
      Msg := FLastError;
      if Msg = '' then
        Msg := Ex.Message;
      Result := False;
    end;
  end;
end;

end.
