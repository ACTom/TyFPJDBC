unit TyFPJDBC.LCL.ConnDialog;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Forms, Controls, Graphics, StdCtrls, ComCtrls, Dialogs,
  LazIDEIntf, ProjectIntf,
  TyFPJDBC.Handles, TyFPJDBC.JVM.Manager, TyFPJDBC.JNI.Bridge,
  TyFPJDBC.Engine, TyFPJDBC.Driver.Registry, TyFPJDBC.Driver.Fetch,
  TyFPJDBC.LCL.Conn, TyFPJDBC.LCL.Wizard, TyFPJDBC.LCL.CustomDriver;

var
  { Session-picked design JVM dir (this IDE session only). }
  GDesignJvmDir: string = '';

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
    MavenEdit, MaxPoolEdit, UrlEdit: TEdit;
    ClassLbl, StatusLbl: TLabel;
    TestBtn, OkBtn, CancelBtn: TButton;
    function SelectedId: string;
    procedure FillDrivers(const KeepId: string);
    procedure UpdatePreview;
    procedure InputChanged(Sender: TObject);
    procedure MavenChanged(Sender: TObject);
    function ResolveDesignJvm: string;
    function ProjectDir: string;
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
  drvGroup, connGroup: TGroupBox;

  function MkGroup(const Cap: string; Y, H: Integer): TGroupBox;
  begin
    Result := TGroupBox.Create(Self);
    Result.Parent := Self;
    Result.Caption := Cap;
    Result.Left := 12;
    Result.Top := Y;
    Result.Width := 496;
    Result.Height := H;
  end;

  function MkLab(P: TWinControl; const Cap: string; Y: Integer): TLabel;
  begin
    Result := TLabel.Create(Self);
    Result.Parent := P;
    Result.Caption := Cap;
    Result.Left := 12;
    Result.Top := Y;
    Result.Width := 90;
  end;

  function MkEdit(P: TWinControl; Y, W: Integer): TEdit;
  begin
    Result := TEdit.Create(Self);
    Result.Parent := P;
    Result.Left := 108;
    Result.Top := Y - 3;
    Result.Width := W;
  end;

begin
  inherited CreateNew(AOwner);
  Caption := 'TyFPJDBC Connection';
  ClientWidth := 520;
  ClientHeight := 548;
  Position := poScreenCenter;
  BorderStyle := bsDialog;
  FWizard := TJdbcDriverWizard.Create;
  FWizard.OnTest := @DefaultTest;

  drvGroup := MkGroup('Driver', 8, 172);
  MkLab(drvGroup, 'Driver', 20);
  DriverBox := TComboBox.Create(Self);
  DriverBox.Parent := drvGroup;
  DriverBox.Left := 108;
  DriverBox.Top := 17;
  DriverBox.Width := 376;
  DriverBox.Style := csDropDownList;
  DriverBox.OnChange := @DriverBoxChange;
  DriverBox.TabOrder := 0;
  MkLab(drvGroup, 'Class', 48);
  ClassLbl := TLabel.Create(Self);
  ClassLbl.Parent := drvGroup;
  ClassLbl.Left := 108;
  ClassLbl.Top := 48;
  ClassLbl.Width := 376;
  ClassLbl.ShowHint := True;
  MkLab(drvGroup, 'Jar', 76);
  StateLbl := TLabel.Create(Self);
  StateLbl.Parent := drvGroup;
  StateLbl.Left := 108;
  StateLbl.Top := 76;
  StateLbl.Width := 180;
  DownloadBtn := TButton.Create(Self);
  DownloadBtn.Parent := drvGroup;
  DownloadBtn.Caption := 'Download...';
  DownloadBtn.Left := 292;
  DownloadBtn.Top := 73;
  DownloadBtn.Width := 100;
  DownloadBtn.OnClick := @DownloadBtnClick;
  Progress := TProgressBar.Create(Self);
  Progress.Parent := drvGroup;
  Progress.Left := 398;
  Progress.Top := 77;
  Progress.Width := 86;
  Progress.Style := pbstMarquee;
  Progress.Visible := False;
  MkLab(drvGroup, 'Maven', 104);
  MavenEdit := MkEdit(drvGroup, 104, 376);
  MavenEdit.TextHint := 'group:artifact:version (custom drivers)';
  MavenEdit.OnChange := @MavenChanged;
  LicenseCheck := TCheckBox.Create(Self);
  LicenseCheck.Parent := drvGroup;
  LicenseCheck.Left := 12;
  LicenseCheck.Top := 132;
  LicenseCheck.Width := 472;
  LicenseCheck.Caption := 'Accept GPL license';

  connGroup := MkGroup('Connection', 188, 228);
  t := 20;
  MkLab(connGroup, 'Host', t);
  HostEdit := MkEdit(connGroup, t, 376);
  HostEdit.OnChange := @InputChanged;
  Inc(t, 28);
  MkLab(connGroup, 'Port', t);
  PortEdit := MkEdit(connGroup, t, 120);
  PortEdit.NumbersOnly := True;
  PortEdit.OnChange := @InputChanged;
  Inc(t, 28);
  MkLab(connGroup, 'Database', t);
  DbEdit := MkEdit(connGroup, t, 376);
  DbEdit.OnChange := @InputChanged;
  Inc(t, 28);
  MkLab(connGroup, 'User', t);
  UserEdit := MkEdit(connGroup, t, 376);
  Inc(t, 28);
  MkLab(connGroup, 'Password', t);
  PassEdit := MkEdit(connGroup, t, 376);
  PassEdit.PasswordChar := '*';
  Inc(t, 28);
  MkLab(connGroup, 'Timeout(s)', t);
  TimeoutEdit := MkEdit(connGroup, t, 120);
  TimeoutEdit.NumbersOnly := True;
  Inc(t, 28);
  MkLab(connGroup, 'MaxPool', t);
  MaxPoolEdit := MkEdit(connGroup, t, 120);
  MaxPoolEdit.NumbersOnly := True;

  MkLab(Self, 'URL', 427);
  UrlEdit := MkEdit(Self, 427, 400);
  UrlEdit.ReadOnly := True;
  UrlEdit.TabStop := False;

  StatusLbl := TLabel.Create(Self);
  StatusLbl.Parent := Self;
  StatusLbl.Left := 12;
  StatusLbl.Top := 459;
  StatusLbl.Width := 496;
  StatusLbl.Height := 32;
  StatusLbl.WordWrap := True;

  TestBtn := TButton.Create(Self);
  TestBtn.Parent := Self;
  TestBtn.Caption := 'Test';
  TestBtn.Left := 240;
  TestBtn.Top := 502;
  TestBtn.Width := 84;
  TestBtn.OnClick := @TestBtnClick;
  OkBtn := TButton.Create(Self);
  OkBtn.Parent := Self;
  OkBtn.Caption := 'OK';
  OkBtn.Left := 332;
  OkBtn.Top := 502;
  OkBtn.Width := 84;
  OkBtn.ModalResult := mrOk;
  OkBtn.Default := True;
  CancelBtn := TButton.Create(Self);
  CancelBtn.Parent := Self;
  CancelBtn.Caption := 'Cancel';
  CancelBtn.Left := 424;
  CancelBtn.Top := 502;
  CancelBtn.Width := 84;
  CancelBtn.ModalResult := mrCancel;
  CancelBtn.Cancel := True;
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
begin
  FWizard.DriverId := SelectedId;
  FWizard.Host := Trim(HostEdit.Text);
  FWizard.Port := StrToIntDef(Trim(PortEdit.Text), 0);
  FWizard.Database := Trim(DbEdit.Text);
  FWizard.User := Trim(UserEdit.Text);
  FWizard.Password := PassEdit.Text;
  FWizard.LoginTimeoutSecs := StrToIntDef(Trim(TimeoutEdit.Text), 15);
  FWizard.MaxPool := StrToIntDef(Trim(MaxPoolEdit.Text), FWizard.MaxPool);
  { NOTE: MavenOverride is maintained by MavenChanged (real user typing)
    and cleared by SetDriverId on driver switch — never reaped from the
    (possibly stale) edit text here. }
end;

procedure TJdbcConnDialog.MavenChanged(Sender: TObject);
var
  e: TDriverEntry;
begin
  try
    e := TDriverRegistry.Find(SelectedId);
  except
    Exit;
  end;
  if Trim(MavenEdit.Text) = e.Maven then
    FWizard.MavenOverride := ''
  else
    FWizard.MavenOverride := Trim(MavenEdit.Text);
  if FWizard.MavenOverrideValid then
    MavenEdit.Color := clWindow
  else
    MavenEdit.Color := clCream;
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
  ClassLbl.Caption := e.DriverClass;
  ClassLbl.Hint := e.DriverClass;
  if TDriverFetch.IsGplLicense(e.License) and
    not TDriverFetch.LicenseAccepted(id) then
  begin
    LicenseCheck.Caption := 'Accept GPL license (' + e.License + ')';
    LicenseCheck.Enabled := True;
    LicenseCheck.Checked := False;
  end
  else
  begin
    LicenseCheck.Caption := 'License: ' + e.License;
    LicenseCheck.Enabled := False;
    LicenseCheck.Checked := True;
  end;
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
  DownloadBtn.Enabled := True;
  OkBtn.Enabled := FWizard.CanConfirm;
  UpdatePreview;
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
  if Trim(PortEdit.Text) = '' then
  try
    if TDriverRegistry.DefaultPort(SelectedId) > 0 then
      PortEdit.Text := IntToStr(TDriverRegistry.DefaultPort(SelectedId));
  except
  end;
  PullFromEdits;
  RefreshState;
end;

procedure TJdbcConnDialog.InputChanged(Sender: TObject);
begin
  UpdatePreview;
end;

procedure TJdbcConnDialog.UpdatePreview;
begin
  try
    UrlEdit.Text := TDriverRegistry.BuildUrlNil(SelectedId,
      Trim(HostEdit.Text), StrToIntDef(Trim(PortEdit.Text), 0),
      Trim(DbEdit.Text));
    UrlEdit.Font.Color := clWindowText;
  except
    on E: Exception do
    begin
      UrlEdit.Text := E.Message;
      UrlEdit.Font.Color := clRed;
    end;
  end;
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
  id: string;
begin
  PullFromEdits;
  id := SelectedId;
  if (id <> '') and (FWizard.JarState(id) <> jsReady) then
  begin
    if not FWizard.MavenOverrideValid then
    begin
      StatusLbl.Caption := 'bad maven coordinates, fix them first';
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
  if FWizard.Test then
    StatusLbl.Caption := 'Connection OK'
  else if StatusLbl.Caption = '' then
    StatusLbl.Caption := 'Test failed.';
  RefreshState;
end;

function TJdbcConnDialog.ProjectDir: string;
begin
  { Active Lazarus project directory (where the exe-side layout lives).
    Empty when no project is open — callers fall back gracefully. }
  Result := '';
  if not Assigned(LazarusIDE) then
    Exit;
  if not Assigned(LazarusIDE.ActiveProject) then
    Exit;
  Result := ExtractFilePath(LazarusIDE.ActiveProject.ProjectInfoFile);
end;

function TJdbcConnDialog.ResolveDesignJvm: string;
var
  proj: TLazProject;
  pdir: string;
begin
  { Design-time JVM search (NOT the runtime FindLibJvm: at design time the
    "exe" is the IDE itself, so look where the user's program lives):
    session pick -> project dir -> IDE dir -> ask. }
  Result := TJdbcDriverWizard.JvmDllInDir(GDesignJvmDir);
  if Result <> '' then
    Exit;
  if Assigned(LazarusIDE) then
  begin
    proj := LazarusIDE.ActiveProject;
    if Assigned(proj) then
    begin
      pdir := ExtractFilePath(proj.ProjectInfoFile);
      Result := TJdbcDriverWizard.JvmDllInDir(pdir);
      if Result <> '' then
        Exit;
    end;
  end;
  Result := TJdbcDriverWizard.JvmDllInDir(ExtractFilePath(ParamStr(0)));
  if Result <> '' then
    Exit;
  Result := '';
  if MessageDlg('JVM not found',
    'No jre/ next to the project or the IDE. Get ' +
    'jre-25-tyfpjdbc-<platform>.zip from TyFPJDBC-Runtimes releases, ' +
    'unpack it, rename the inner directory to "jre/" beside your exe. ' +
    'Select the folder containing jre/ now?',
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  with TSelectDirectoryDialog.Create(nil) do
  try
    Title := 'Select the folder containing jre/';
    if Execute then
    begin
      Result := TJdbcDriverWizard.JvmDllInDir(FileName);
      if Result <> '' then
        GDesignJvmDir := FileName
      else
        StatusLbl.Caption := 'no jvm under ' + FileName;
    end;
  finally
    Free;
  end;
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
  cp, root: string;
begin
  Result := False;
  try
    jvm := ResolveDesignJvm;
    if jvm = '' then
    begin
      if StatusLbl.Caption = '' then
        StatusLbl.Caption := 'jvm not found: bundle jre/ next to the project';
      Exit;
    end;
    { Test classpath comes from the jars deployed beside the project
      (bridge/*.jar + drivers/*.jar), NOT the IDE directory. NOTE: once
      started, a JVM keeps its first classpath for the IDE session. }
    root := FWizard.Root;
    if root = '' then
      root := ProjectDir;
    cp := TJdbcDriverWizard.DriverTestClassPath(root);
    if cp = '' then
    begin
      StatusLbl.Caption := 'no jars under ' + root +
        '/bridge|drivers — download the driver first';
      Exit;
    end;
    TJVMManager.SetClassPath(cp);
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
      StatusLbl.Caption := 'test: ' + Ex.Message;
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
  if ProjectDir <> '' then
    FWizard.Root := ProjectDir; { downloads + test share the project layout }
  PullFromEdits;
  MavenEdit.Text := FWizard.EffectiveMaven(FWizard.DriverId);
  StatusLbl.Caption := '';
  RefreshState;
  Result := ShowModal = mrOk;
  if Result then
    FWizard.ApplyTo(FTarget);
end;

end.
