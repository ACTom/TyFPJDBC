unit TyFPJDBC.LCL.ConnDialog;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Forms, Controls, Graphics, StdCtrls, ComCtrls, Dialogs,
  TyFPJDBC.Handles, TyFPJDBC.JVM.Manager, TyFPJDBC.JNI.Bridge,
  TyFPJDBC.Engine, TyFPJDBC.Driver.Registry, TyFPJDBC.Driver.Fetch,
  TyFPJDBC.LCL.Conn, TyFPJDBC.LCL.Wizard, TyFPJDBC.LCL.CustomDriver;

type
  { Driver wizard dialog: pick driver, check jar, one-click fetch
    (GPL needs the checkbox), Test live connectivity, OK writes back.
    OK stays disabled until TestedOk and jar ready (CanConfirm). }
  TJdbcConnDialog = class(TForm)
  private
    FWizard: TJdbcDriverWizard;
    FTarget: TJdbcConnection;
    DriverBox: TComboBox;
    StateLbl: TLabel;
    DownloadBtn: TButton;
    Progress: TProgressBar;
    LicenseCheck: TCheckBox;
    HostEdit, PortEdit, DbEdit, UserEdit, PassEdit, TimeoutEdit,
    MavenEdit, MaxPoolEdit: TEdit;
    TestBtn, OkBtn, CancelBtn: TButton;
    function SelectedId: string;
    procedure FillDrivers(const KeepId: string);
    function GetTestedOk: Boolean;
    function GetOnTest: TTestFunc;
    procedure SetOnTest(V: TTestFunc);
    procedure PullFromEdits;
    procedure RefreshState;
    procedure DriverBoxChange(Sender: TObject);
    procedure DownloadBtnClick(Sender: TObject);
    procedure TestBtnClick(Sender: TObject);
    function DefaultTest(const DriverId, Url: string): Boolean;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function Execute(AConn: TJdbcConnection): Boolean;
    property TestedOk: Boolean read GetTestedOk;
    property OnTest: TTestFunc read GetOnTest write SetOnTest;
  end;

implementation

constructor TJdbcConnDialog.Create(AOwner: TComponent);
var
  t: Integer;

  function MkEdit(const Cap: string; Y: Integer): TEdit;
  begin
    with TLabel.Create(Self) do
    begin
      Parent := Self;
      Left := 12;
      Top := Y;
      Caption := Cap;
    end;
    Result := TEdit.Create(Self);
    Result.Parent := Self;
    Result.Left := 120;
    Result.Top := Y - 3;
    Result.Width := 160;
  end;

begin
  inherited CreateNew(AOwner);
  Caption := 'TyFPJDBC Connection';
  ClientWidth := 300;
  ClientHeight := 480;
  Position := poScreenCenter;
  FWizard := TJdbcDriverWizard.Create;
  FWizard.OnTest := @DefaultTest;
  t := 12;
  DriverBox := TComboBox.Create(Self);
  DriverBox.Parent := Self;
  DriverBox.Left := 12;
  DriverBox.Top := t;
  DriverBox.Width := 160;
  DriverBox.Style := csDropDownList;
  DriverBox.OnChange := @DriverBoxChange;
  Inc(t, 28);
  StateLbl := TLabel.Create(Self);
  StateLbl.Parent := Self;
  StateLbl.Left := 12;
  StateLbl.Top := t;
  StateLbl.Width := 276;
  Inc(t, 24);
  DownloadBtn := TButton.Create(Self);
  DownloadBtn.Parent := Self;
  DownloadBtn.Caption := 'Download driver';
  DownloadBtn.Left := 12;
  DownloadBtn.Top := t;
  DownloadBtn.Width := 130;
  DownloadBtn.OnClick := @DownloadBtnClick;
  Progress := TProgressBar.Create(Self);
  Progress.Parent := Self;
  Progress.Left := 150;
  Progress.Top := t + 4;
  Progress.Width := 130;
  Progress.Style := pbstMarquee;
  Progress.Visible := False;
  Inc(t, 32);
  LicenseCheck := TCheckBox.Create(Self);
  LicenseCheck.Parent := Self;
  LicenseCheck.Left := 12;
  LicenseCheck.Top := t;
  LicenseCheck.Width := 276;
  LicenseCheck.Caption := 'Accept GPL license';
  Inc(t, 28);
  HostEdit := MkEdit('Host', t);
  Inc(t, 28);
  PortEdit := MkEdit('Port', t);
  Inc(t, 28);
  DbEdit := MkEdit('Database', t);
  Inc(t, 28);
  UserEdit := MkEdit('User', t);
  Inc(t, 28);
  PassEdit := MkEdit('Password', t);
  PassEdit.PasswordChar := '*';
  Inc(t, 28);
  TimeoutEdit := MkEdit('Timeout(s)', t);
  Inc(t, 28);
  MavenEdit := MkEdit('Maven', t);
  MavenEdit.TextHint := 'group:artifact:version (custom drivers)';
  Inc(t, 28);
  MaxPoolEdit := MkEdit('MaxPool', t);
  Inc(t, 32);
  TestBtn := TButton.Create(Self);
  TestBtn.Parent := Self;
  TestBtn.Caption := 'Test';
  TestBtn.Left := 12;
  TestBtn.Top := t;
  TestBtn.Width := 130;
  TestBtn.OnClick := @TestBtnClick;
  OkBtn := TButton.Create(Self);
  OkBtn.Parent := Self;
  OkBtn.Caption := 'OK';
  OkBtn.Left := 104;
  OkBtn.Top := 440;
  OkBtn.Width := 84;
  OkBtn.ModalResult := mrOk;
  CancelBtn := TButton.Create(Self);
  CancelBtn.Parent := Self;
  CancelBtn.Caption := 'Cancel';
  CancelBtn.Left := 196;
  CancelBtn.Top := 440;
  CancelBtn.Width := 84;
  CancelBtn.ModalResult := mrCancel;
  FillDrivers('');
  RefreshState;
end;

procedure TJdbcConnDialog.FillDrivers(const KeepId: string);
var
  i: Integer;
  ids: TDriverIdArray;
begin
  ids := FWizard.DriverIds;
  DriverBox.Items.BeginUpdate;
  try
    DriverBox.Items.Clear;
    for i := 0 to High(ids) do
      DriverBox.Items.Add(ids[i]);
    DriverBox.Items.Add(CustomItem);
    if KeepId <> '' then
      DriverBox.ItemIndex := DriverBox.Items.IndexOf(KeepId);
    if DriverBox.ItemIndex < 0 then
      DriverBox.ItemIndex := 0;
  finally
    DriverBox.Items.EndUpdate;
  end;
end;

destructor TJdbcConnDialog.Destroy;
begin
  FWizard.Free;
  inherited;
end;

function TJdbcConnDialog.SelectedId: string;
begin
  if (DriverBox.ItemIndex >= 0) and
    (DriverBox.Items[DriverBox.ItemIndex] <> CustomItem) then
    Result := DriverBox.Items[DriverBox.ItemIndex]
  else
    Result := '';
end;

function TJdbcConnDialog.GetTestedOk: Boolean;
begin
  Result := FWizard.TestedOk;
end;

function TJdbcConnDialog.GetOnTest: TTestFunc;
begin
  Result := FWizard.OnTest;
end;

procedure TJdbcConnDialog.SetOnTest(V: TTestFunc);
begin
  FWizard.OnTest := V;
end;

procedure TJdbcConnDialog.PullFromEdits;
var
  e: TDriverEntry;
begin
  FWizard.DriverId := SelectedId;
  FWizard.Host := Trim(HostEdit.Text);
  FWizard.Port := StrToIntDef(Trim(PortEdit.Text), 0);
  FWizard.Database := Trim(DbEdit.Text);
  FWizard.User := Trim(UserEdit.Text);
  FWizard.Password := PassEdit.Text;
  FWizard.LoginTimeoutSecs := StrToIntDef(Trim(TimeoutEdit.Text), 15);
  FWizard.MaxPool := StrToIntDef(Trim(MaxPoolEdit.Text), FWizard.MaxPool);
  FWizard.MavenOverride := '';
  if SelectedId <> '' then
  try
    e := TDriverRegistry.Find(SelectedId);
    if (Trim(MavenEdit.Text) <> '') and (Trim(MavenEdit.Text) <> e.Maven) then
      FWizard.MavenOverride := Trim(MavenEdit.Text);
  except
  end;
end;

procedure TJdbcConnDialog.RefreshState;
var
  id: string;
  e: TDriverEntry;
begin
  id := SelectedId;
  if id = '' then
  begin
    StateLbl.Caption := 'no driver selected';
    DownloadBtn.Enabled := False;
    OkBtn.Enabled := False;
    Exit;
  end;
  e := TDriverRegistry.Find(id);
  LicenseCheck.Visible := TDriverFetch.IsGplLicense(e.License) and
    not TDriverFetch.LicenseAccepted(id);
  MavenEdit.Text := FWizard.EffectiveMaven(id);
  if FWizard.MavenOverrideValid then
    MavenEdit.Color := clWindow
  else
    MavenEdit.Color := clCream;
  case FWizard.JarState(id) of
    jsReady: StateLbl.Caption := 'driver jar ready';
    jsMismatch: StateLbl.Caption := 'driver jar MISMATCH, re-download';
    jsMissing: StateLbl.Caption := 'driver jar missing';
  end;
  if FWizard.TestedOk and (FWizard.JarState(id) = jsReady) then
    StateLbl.Caption := StateLbl.Caption + ' + connection ok';
  DownloadBtn.Enabled := True;
  OkBtn.Enabled := FWizard.CanConfirm;
end;

procedure TJdbcConnDialog.DriverBoxChange(Sender: TObject);
var
  id: string;
begin
  if (DriverBox.ItemIndex >= 0) and
    (DriverBox.Items[DriverBox.ItemIndex] = CustomItem) then
  begin
    id := EditCustomDriver(FWizard.DriverId);
    if id <> '' then
    begin
      FillDrivers(id);
      FWizard.DriverId := id;
    end
    else
      FillDrivers(FWizard.DriverId);
  end;
  PullFromEdits;
  RefreshState;
end;

procedure TJdbcConnDialog.DownloadBtnClick(Sender: TObject);
begin
  PullFromEdits;
  Progress.Visible := True;
  try
    Application.ProcessMessages;
    if FWizard.Fetch(SelectedId, LicenseCheck.Checked) then
      StateLbl.Caption := 'driver downloaded and verified'
    else
      StateLbl.Caption := 'download failed (see log)';
  finally
    Progress.Visible := False;
  end;
  RefreshState;
end;

procedure TJdbcConnDialog.TestBtnClick(Sender: TObject);
var
  id, keep: string;
begin
  PullFromEdits;
  id := SelectedId;
  if (id <> '') and (FWizard.JarState(id) <> jsReady) then
  begin
    if not FWizard.MavenOverrideValid then
    begin
      StateLbl.Caption := 'bad maven coordinates, fix them first';
      RefreshState;
      Exit;
    end;
    if MessageDlg('Download driver?',
      'Driver jar is missing or mismatched. Download it now?',
      mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    begin
      RefreshState;
      Exit;
    end;
    DownloadBtnClick(Sender);
    if FWizard.JarState(id) <> jsReady then
      Exit;
  end;
  keep := '';
  if FWizard.Test then
    keep := 'connection ok'
  else
    keep := StateLbl.Caption;
  RefreshState;
  if keep <> '' then
    StateLbl.Caption := keep;
end;

function TJdbcConnDialog.DefaultTest(const DriverId, Url: string): Boolean;
var
  jvm: string;
  eng: TJdbcEngine;
  bridge: TBridge;
  cfg: TPoolCfgRec;
  pool, conn, stmt, cur: Int64;
  rows: TJdbcRows;
  e: TDriverEntry;
begin
  Result := False;
  try
    jvm := TJVMManager.FindLibJvm('');
    TJVMManager.EnsureStarted(jvm, TJVMManager.BuildDesktopArgs);
    bridge := TBridge.Create;
    try
      eng := TJdbcEngine.Create(bridge);
      try
        e := TDriverRegistry.Find(DriverId);
        cfg := DefaultPoolCfg(Url, e.DriverClass);
        pool := eng.OpenPool(cfg);
        try
          conn := eng.Borrow(pool);
          try
            stmt := bridge.Prepare(conn, e.TestQuery);
            try
              cur := bridge.QueryOpen(stmt, 10);
              try
                rows := bridge.FetchWindow(cur, 10);
                Result := Length(rows) >= 1;
              finally
                bridge.CloseCursor(cur);
              end;
            finally
              bridge.CloseStmt(stmt);
            end;
          finally
            eng.Release(conn);
          end;
        finally
          eng.ClosePool(pool);
        end;
      finally
        eng.Free;
      end;
    finally
      bridge.Free;
    end;
  except
    on Ex: Exception do
      StateLbl.Caption := 'test: ' + Ex.Message;
  end;
end;

function TJdbcConnDialog.Execute(AConn: TJdbcConnection): Boolean;
begin
  FTarget := AConn;
  FWizard.DriverId := AConn.DriverId;
  FWizard.Host := AConn.Host;
  FWizard.Port := AConn.Port;
  FWizard.Database := AConn.Database;
  FWizard.User := AConn.User;
  FWizard.Password := AConn.Password;
  FWizard.MaxPool := AConn.MaxPool;
  FWizard.LoginTimeoutSecs := AConn.LoginTimeoutSecs;
  DriverBox.ItemIndex := DriverBox.Items.IndexOf(AConn.DriverId);
  if DriverBox.ItemIndex < 0 then
    DriverBox.ItemIndex := 0; { unknown (unregistered custom) id: fall back }
  HostEdit.Text := AConn.Host;
  if AConn.Port > 0 then
    PortEdit.Text := IntToStr(AConn.Port);
  DbEdit.Text := AConn.Database;
  UserEdit.Text := AConn.User;
  PassEdit.Text := AConn.Password;
  TimeoutEdit.Text := IntToStr(AConn.LoginTimeoutSecs);
  MaxPoolEdit.Text := IntToStr(AConn.MaxPool);
  PullFromEdits;
  MavenEdit.Text := FWizard.EffectiveMaven(FWizard.DriverId);
  RefreshState;
  Result := ShowModal = mrOk;
  if Result then
    FWizard.ApplyTo(FTarget);
end;

end.
