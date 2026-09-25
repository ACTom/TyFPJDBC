unit TyFPJDBC.StoredProc;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, TyFPJDBC.Handles, TyFPJDBC.JNI.Bridge, TyFPJDBC.Engine;

type
  { Stored procedure: CallableStatement via Bridge. In params bind by
    index, out params register by JDBC type, execute, then read outs. }
  TJDBCStoredProc = class
  private
    FEngine: TJdbcEngine;
    FConn: Int64;
    FStmt: Int64;
  public
    constructor Create(AEngine: TJdbcEngine; AConn: Int64);
    destructor Destroy; override;
    procedure PrepareCall(const SQL: string);
    procedure BindString(Idx: Integer; const V: UTF8String);
    procedure BindLong(Idx: Integer; V: Int64);
    procedure RegisterOut(Idx, SqlType: Integer);
    function Exec: Boolean;
    function OutValue(Idx: Integer): UTF8String;
  end;

implementation

constructor TJDBCStoredProc.Create(AEngine: TJdbcEngine; AConn: Int64);
begin
  inherited Create;
  if AEngine = nil then
    raise EJDBCError.CreateChain('engine required', 'HY000', 99, 'nil');
  CheckHandle('conn', AConn);
  FEngine := AEngine;
  FConn := AConn;
  FStmt := 0;
end;

destructor TJDBCStoredProc.Destroy;
begin
  if FStmt > 0 then
    try
      FEngine.Bridge.CloseStmt(FStmt);
    except
    end;
  inherited;
end;

procedure TJDBCStoredProc.PrepareCall(const SQL: string);
begin
  if FStmt > 0 then
    raise EJDBCError.CreateChain('already prepared', 'HY000', 99, 'call');
  FStmt := FEngine.Bridge.PrepareCall(FConn, UTF8String(SQL));
  CheckHandle('stmt', FStmt);
end;

procedure TJDBCStoredProc.BindString(Idx: Integer; const V: UTF8String);
begin
  CheckHandle('stmt', FStmt);
  FEngine.Bridge.BindString(FStmt, Idx, V);
end;

procedure TJDBCStoredProc.BindLong(Idx: Integer; V: Int64);
begin
  CheckHandle('stmt', FStmt);
  FEngine.Bridge.BindLong(FStmt, Idx, V);
end;

procedure TJDBCStoredProc.RegisterOut(Idx, SqlType: Integer);
begin
  CheckHandle('stmt', FStmt);
  FEngine.Bridge.RegisterOut(FStmt, Idx, SqlType);
end;

function TJDBCStoredProc.Exec: Boolean;
begin
  CheckHandle('stmt', FStmt);
  Result := FEngine.Bridge.ExecProc(FStmt);
end;

function TJDBCStoredProc.OutValue(Idx: Integer): UTF8String;
begin
  CheckHandle('stmt', FStmt);
  Result := FEngine.Bridge.OutValue(FStmt, Idx);
end;

end.
