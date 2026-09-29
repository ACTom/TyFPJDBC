unit TyFPJDBC.LCL.CustomDriver;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Forms, Controls, StdCtrls,
  TyFPJDBC.Driver.Registry, TyFPJDBC.LCL.Wizard;

type
  { Custom driver dialog (shared by the property editor and the wizard):
    fill the TDriverEntry fields, [Register] for this IDE session,
    [Copy code] for the durable path (paste into the project; session
    registration does not survive IDE restart). Design-time only. }
  TCustomDriverDialog = class(TForm)
  private
    FResultId: string;
    IdEdit, ClassEdit, UrlEdit, PortEdit, TestEdit, LicenseEdit,
    MavenEdit, ShaEdit, SepEdit: TEdit;
    EmbeddedCheck: TCheckBox;
    PagingBox, QuoteBox, KeyBox: TComboBox;
    HintLbl: TLabel;
    function Pull(var E: TDriverEntry; Silent: Boolean): Boolean;
    procedure Push(const E: TDriverEntry);
    procedure RegBtnClick(Sender: TObject);
    procedure CopyBtnClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    function Execute(const InitialId: string): string;
  end;

function EditCustomDriver(const InitialId: string): string;

const
  CustomItem = '(Custom...)';

implementation

uses
  Clipbrd, Dialogs;

function EditCustomDriver(const InitialId: string): string;
var
  d: TCustomDriverDialog;
begin
  Result := '';
  d := TCustomDriverDialog.Create(nil);
  try
    Result := d.Execute(InitialId);
  finally
    d.Free;
  end;
end;

constructor TCustomDriverDialog.Create(AOwner: TComponent);
var
  t: Integer;

  function MkEdit(const Cap: string; Y: Integer): TEdit;
  begin
    with TLabel.Create(Self) do
    begin
      Parent := Self;
      Left := 12;
      Top := Y;
      Width := 130;
      Caption := Cap;
    end;
    Result := TEdit.Create(Self);
    Result.Parent := Self;
    Result.Left := 150;
    Result.Top := Y - 3;
    Result.Width := 278;
  end;

  function MkCombo(const Cap: string; Y: Integer;
    const Items: array of string): TComboBox;
  var
    s: string;
  begin
    with TLabel.Create(Self) do
    begin
      Parent := Self;
      Left := 12;
      Top := Y;
      Width := 130;
      Caption := Cap;
    end;
    Result := TComboBox.Create(Self);
    Result.Parent := Self;
    Result.Left := 150;
    Result.Top := Y - 3;
    Result.Width := 278;
    Result.Style := csDropDownList;
    for s in Items do
      Result.Items.Add(s);
    if Result.Items.Count > 0 then
      Result.ItemIndex := 0;
  end;

begin
  inherited CreateNew(AOwner);
  Caption := 'TyFPJDBC Custom Driver';
  ClientWidth := 440;
  ClientHeight := 520;
  Position := poScreenCenter;
  t := 12;
  IdEdit := MkEdit('Id', t); Inc(t, 28);
  ClassEdit := MkEdit('Driver class', t); Inc(t, 28);
  UrlEdit := MkEdit('URL template', t); Inc(t, 28);
  UrlEdit.TextHint := 'jdbc:mydb://{host}:{port}/{database}';
  PortEdit := MkEdit('Default port', t); Inc(t, 28);
  TestEdit := MkEdit('Test query', t); Inc(t, 28);
  LicenseEdit := MkEdit('License', t); Inc(t, 28);
  MavenEdit := MkEdit('Maven (optional)', t); Inc(t, 28);
  MavenEdit.TextHint := 'group:artifact:version (enables Download)';
  ShaEdit := MkEdit('Sha1 (optional)', t); Inc(t, 28);
  SepEdit := MkEdit('Param separator', t); Inc(t, 28);
  EmbeddedCheck := TCheckBox.Create(Self);
  EmbeddedCheck.Parent := Self;
  EmbeddedCheck.Left := 150;
  EmbeddedCheck.Top := t;
  EmbeddedCheck.Caption := 'Embedded (file database)';
  Inc(t, 28);
  PagingBox := MkCombo('Paging', t,
    ['limit-offset', 'offset-fetch-next', 'offset-fetch-first']); Inc(t, 28);
  QuoteBox := MkCombo('Quoting', t,
    ['double', 'backtick', 'bracket']); Inc(t, 28);
  KeyBox := MkCombo('Key return', t, ['none', 'returning']); Inc(t, 28);
  HintLbl := TLabel.Create(Self);
  HintLbl.Parent := Self;
  HintLbl.Left := 12;
  HintLbl.Top := t;
  HintLbl.Width := 416;
  HintLbl.Height := 32;
  HintLbl.Caption := 'Register works for this IDE session only. ' +
    'For runtimes, Copy code and paste it into the project.';
  HintLbl.WordWrap := True;
  Inc(t, 40);
  with TButton.Create(Self) do
  begin
    Parent := Self;
    Caption := 'Register';
    Left := 12;
    Top := t;
    Width := 120;
    OnClick := @RegBtnClick;
  end;
  with TButton.Create(Self) do
  begin
    Parent := Self;
    Caption := 'Copy code';
    Left := 140;
    Top := t;
    Width := 120;
    OnClick := @CopyBtnClick;
  end;
  with TButton.Create(Self) do
  begin
    Parent := Self;
    Caption := 'Close';
    Left := 308;
    Top := t;
    Width := 120;
    ModalResult := mrCancel;
  end;
end;

function TCustomDriverDialog.Pull(var E: TDriverEntry; Silent: Boolean): Boolean;

  function Bad(const What: string): Boolean;
  begin
    Result := False;
    if not Silent then
      HintLbl.Caption := What + ' is required.';
  end;

begin
  Result := False;
  E.Id := Trim(IdEdit.Text);
  if E.Id = '' then Exit(Bad('Id'));
  if E.Id = CustomItem then Exit(Bad('Id'));
  E.DriverClass := Trim(ClassEdit.Text);
  if E.DriverClass = '' then Exit(Bad('Driver class'));
  E.UrlTemplate := Trim(UrlEdit.Text);
  if E.UrlTemplate = '' then Exit(Bad('URL template'));
  E.DefaultPort := StrToIntDef(Trim(PortEdit.Text), 0);
  E.TestQuery := Trim(TestEdit.Text);
  if E.TestQuery = '' then
    E.TestQuery := 'SELECT 1';
  E.License := Trim(LicenseEdit.Text);
  E.Maven := Trim(MavenEdit.Text);
  E.Sha := Trim(ShaEdit.Text);
  E.Embedded := EmbeddedCheck.Checked;
  case PagingBox.ItemIndex of
    1: E.Paging := psOffsetFetchNext;
    2: E.Paging := psOffsetFetchFirst;
  else
    E.Paging := psLimitOffset;
  end;
  case QuoteBox.ItemIndex of
    1: E.Quote := qsBacktick;
    2: E.Quote := qsBracket;
  else
    E.Quote := qsDouble;
  end;
  if KeyBox.ItemIndex = 1 then
    E.KeyReturn := krReturning
  else
    E.KeyReturn := krNone;
  E.ParamSep := Trim(SepEdit.Text);
  if E.ParamSep = '' then
    E.ParamSep := '&';
  SetLength(E.TypeAliases, 0);
  Result := True;
end;

procedure TCustomDriverDialog.Push(const E: TDriverEntry);
begin
  IdEdit.Text := E.Id;
  ClassEdit.Text := E.DriverClass;
  UrlEdit.Text := E.UrlTemplate;
  PortEdit.Text := IntToStr(E.DefaultPort);
  TestEdit.Text := E.TestQuery;
  LicenseEdit.Text := E.License;
  MavenEdit.Text := E.Maven;
  ShaEdit.Text := E.Sha;
  if E.ParamSep <> '' then
    SepEdit.Text := E.ParamSep
  else
    SepEdit.Text := '&';
  EmbeddedCheck.Checked := E.Embedded;
  case E.Paging of
    psOffsetFetchNext: PagingBox.ItemIndex := 1;
    psOffsetFetchFirst: PagingBox.ItemIndex := 2;
  else
    PagingBox.ItemIndex := 0;
  end;
  case E.Quote of
    qsBacktick: QuoteBox.ItemIndex := 1;
    qsBracket: QuoteBox.ItemIndex := 2;
  else
    QuoteBox.ItemIndex := 0;
  end;
  if E.KeyReturn = krReturning then
    KeyBox.ItemIndex := 1
  else
    KeyBox.ItemIndex := 0;
end;

procedure TCustomDriverDialog.RegBtnClick(Sender: TObject);
var
  e: TDriverEntry;
begin
  if not Pull(e, False) then
    Exit;
  TDriverRegistry.Register(e);
  FResultId := e.Id;
  ModalResult := mrOk;
end;

procedure TCustomDriverDialog.CopyBtnClick(Sender: TObject);
var
  e: TDriverEntry;
begin
  if not Pull(e, False) then
    Exit;
  Clipboard.AsText := TJdbcDriverWizard.BuildRegisterCode(e);
  HintLbl.Caption := 'Register code copied to clipboard.';
end;

function TCustomDriverDialog.Execute(const InitialId: string): string;
var
  e: TDriverEntry;
begin
  Result := '';
  FResultId := '';
  try
    e := TDriverRegistry.Find(InitialId);
    Push(e);
  except
    IdEdit.Text := InitialId;
    if (InitialId = '') or (InitialId = CustomItem) then
      IdEdit.Text := '';
    TestEdit.Text := 'SELECT 1';
    SepEdit.Text := '&';
  end;
  if ShowModal = mrOk then
    Result := FResultId
  else
    Result := '';
end;

end.
