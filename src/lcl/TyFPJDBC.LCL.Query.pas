unit TyFPJDBC.LCL.Query;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, DB, BufDataset, TyFPJDBC.Config;
type
  { Design-time query component: SQL text + key field + window size, plus
    a live Connection link. At design time it is config only (never opens
    sockets); at runtime Active=True opens the shared TJdbcQuery against
    the connection, ExecSQL runs named-param DML, ApplyUpdates posts the
    pending grid edits, and the dataset base stays bindable to
    DBGrid/DBEdit. }
  TJdbcConnQuery = class(TBufDataset)
  private
    FSQLText: string;
    FKeyField: string;
    FWindowSize: Integer;
    FConnection: TComponent;
    FActive: Boolean;
    FQuery: TObject;
    FParams: TStrings;
    function Designing: Boolean;
    procedure SetConnection(V: TComponent);
    procedure SetActive(V: Boolean);
    procedure SetParams(V: TStrings);
    procedure CheckBound;
    procedure CloseLive;
  protected
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Open;
    procedure Close;
    procedure Refresh;
    function ExecSQL: Integer;
    procedure ApplyUpdates;
    function ParamValue(const ParamName: string): string;
    procedure SetParam(const ParamName, Value: string);
  published
    property SQLText: string read FSQLText write FSQLText;
    property KeyField: string read FKeyField write FKeyField;
    property WindowSize: Integer read FWindowSize write FWindowSize;
    property Connection: TComponent read FConnection write SetConnection;
    property Active: Boolean read FActive write SetActive default False;
    property Params: TStrings read FParams write SetParams;
  end;

implementation

uses
  TyFPJDBC.Handles, TyFPJDBC.JNI.Bridge, TyFPJDBC.Engine,
  TyFPJDBC.Command, TyFPJDBC.Query, TyFPJDBC.LCL.Conn;

constructor TJdbcConnQuery.Create(AOwner: TComponent);
var
  cfg: TJdbcConfig;
begin
  inherited Create(AOwner);
  FSQLText := '';
  FKeyField := '';
  cfg := TJdbcConfig.Default;
  try
    FWindowSize := cfg.Exec_WindowSize;
  finally
    cfg.Free;
  end;
  FConnection := nil;
  FActive := False;
  FQuery := nil;
  FParams := TStringList.Create;
end;

destructor TJdbcConnQuery.Destroy;
begin
  if not Designing then
    CloseLive;
  FreeAndNil(FParams);
  inherited;
end;

function TJdbcConnQuery.Designing: Boolean;
begin
  Result := (csDesigning in ComponentState) or (csLoading in ComponentState);
end;

procedure TJdbcConnQuery.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if (Operation = opRemove) and (AComponent = FConnection) then
  begin
    if not Designing then
      CloseLive;
    FConnection := nil;
    FActive := False;
  end;
end;

procedure TJdbcConnQuery.SetConnection(V: TComponent);
begin
  if V = FConnection then
    Exit;
  if (V <> nil) and not (V is TJdbcConnection) then
    raise Exception.Create('connection must be TJdbcConnection');
  if not Designing then
    CloseLive;
  FConnection := V;
  FActive := False;
end;

procedure TJdbcConnQuery.SetActive(V: Boolean);
begin
  if Designing then
  begin
    FActive := False;
    Exit;
  end;
  if V = FActive then
    Exit;
  if V then
    Open
  else
    Close;
end;

procedure TJdbcConnQuery.SetParams(V: TStrings);
begin
  FParams.Assign(V);
end;

procedure TJdbcConnQuery.CheckBound;
begin
  if (FConnection = nil) or not (FConnection is TJdbcConnection) then
    raise EJDBCError.CreateChain('connection required', '08000', 48, 'query');
  if not TJdbcConnection(FConnection).Connected then
    raise EJDBCError.CreateChain('connect first', '08000', 49, 'query');
end;

procedure TJdbcConnQuery.CloseLive;
begin
  if FQuery <> nil then
  begin
    try
      TJdbcQuery(FQuery).CloseQuery;
    except
    end;
    FreeAndNil(FQuery);
  end;
  inherited Close;
  FActive := False;
end;

procedure TJdbcConnQuery.Open;
var
  eng: TJdbcEngine;
  cmd: TJdbcCommand;
  onames: TStringArray;
  bound: TBoundRow;
  i, k: Integer;
  nm: string;
begin
  if Designing then
    Exit;
  CheckBound;
  CloseLive;
  if Trim(FSQLText) = '' then
    raise EJDBCError.CreateChain('sql required', 'HY000', 50, 'query');
  eng := TJdbcEngine(TJdbcConnection(FConnection).EnginePtr);
  cmd := TJdbcCommand.Create(eng, TJdbcConnection(FConnection).LiveConn);
  try
    cmd.SetSQL(FSQLText);
    onames := cmd.ParamOrder;
    SetLength(bound, Length(onames));
    for i := 0 to High(onames) do
    begin
      nm := onames[i];
      k := FParams.IndexOfName(nm);
      if k < 0 then
        raise EJDBCError.CreateChain('param missing: ' + nm, 'HY092', 51, nm);
      bound[i].Kind := bvStr;
      bound[i].S := UTF8String(FParams.ValueFromIndex[k]);
      bound[i].I64 := 0;
      bound[i].F64 := 0;
      SetLength(bound[i].Bytes, 0);
      bound[i].SqlType := 0;
    end;
    if Length(onames) > 0 then
      cmd.BindRow(bound);
    FQuery := TJdbcQuery.Create(nil);
    try
      TJdbcQuery(FQuery).KeyField := UTF8String(FKeyField);
      TJdbcQuery(FQuery).OpenQuery(eng,
        TJdbcConnection(FConnection).LiveConn, '', FSQLText, FWindowSize);
      TJdbcQuery(FQuery).First;
      FActive := True;
    except
      FreeAndNil(FQuery);
      raise;
    end;
  finally
    cmd.Free;
  end;
end;

procedure TJdbcConnQuery.Close;
begin
  if Designing then
    Exit;
  if FActive or (FQuery <> nil) then
    CloseLive
  else
    inherited Close;
end;

procedure TJdbcConnQuery.Refresh;
var
  was: Boolean;
begin
  if Designing then
    Exit;
  was := FActive;
  if was then
    Open
  else
    raise EJDBCError.CreateChain('not active', 'HY000', 52, 'query');
end;

function TJdbcConnQuery.ExecSQL: Integer;
var
  eng: TJdbcEngine;
  cmd: TJdbcCommand;
  onames: TStringArray;
  bound: TBoundRow;
  i, k: Integer;
  nm: string;
begin
  if Designing then
    raise Exception.Create('exec at runtime only');
  CheckBound;
  if Trim(FSQLText) = '' then
    raise EJDBCError.CreateChain('sql required', 'HY000', 50, 'query');
  eng := TJdbcEngine(TJdbcConnection(FConnection).EnginePtr);
  cmd := TJdbcCommand.Create(eng, TJdbcConnection(FConnection).LiveConn);
  try
    cmd.SetSQL(FSQLText);
    onames := cmd.ParamOrder;
    SetLength(bound, Length(onames));
    for i := 0 to High(onames) do
    begin
      nm := onames[i];
      k := FParams.IndexOfName(nm);
      if k < 0 then
        raise EJDBCError.CreateChain('param missing: ' + nm, 'HY092', 51, nm);
      bound[i].Kind := bvStr;
      bound[i].S := UTF8String(FParams.ValueFromIndex[k]);
      bound[i].I64 := 0;
      bound[i].F64 := 0;
      SetLength(bound[i].Bytes, 0);
      bound[i].SqlType := 0;
    end;
    Result := cmd.ExecUpdate(bound);
  finally
    cmd.Free;
  end;
end;

procedure TJdbcConnQuery.ApplyUpdates;
begin
  if Designing then
    Exit;
  if FQuery = nil then
    raise EJDBCError.CreateChain('not active', 'HY000', 52, 'query');
  TJdbcQuery(FQuery).ApplyUpdates2;
end;

function TJdbcConnQuery.ParamValue(const ParamName: string): string;
begin
  Result := FParams.Values[ParamName];
end;

procedure TJdbcConnQuery.SetParam(const ParamName, Value: string);
begin
  FParams.Values[ParamName] := Value;
end;

end.
