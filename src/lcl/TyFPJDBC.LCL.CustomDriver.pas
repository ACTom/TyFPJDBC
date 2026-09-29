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
  idGroup, distGroup, diaGroup: TGroupBox;

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
    Result.Width := 110;
  end;

  function MkEdit(P: TWinControl; Y, W: Integer): TEdit;
  begin
    Result := TEdit.Create(Self);
    Result.Parent := P;
    Result.Left := 128;
    Result.Top := Y - 3;
    Result.Width := W;
  end;

  function MkCombo(P: TWinControl; const Cap: string; Y: Integer;
    const Items: array of string): TComboBox;
  var
    s: string;
  begin
    MkLab(P, Cap, Y);
    Result := TComboBox.Create(Self);
    Result.Parent := P;
    Result.Left := 128;
    Result.Top := Y - 3;
    Result.Width := 356;
    Result.Style := csDropDownList;
    for s in Items do
      Result.Items.Add(s);
    if Result.Items.Count > 0 then
      Result.ItemIndex := 0;
  end;

begin
  inherited CreateNew(AOwner);
  Caption := 'TyFPJDBC Custom Driver';
  ClientWidth := 520;
  ClientHeight := 574;
  Position := poScreenCenter;
  BorderStyle := bsDialog;

  idGroup := MkGroup('Identity', 8, 172);
  MkLab(idGroup, 'Id', 20);
  IdEdit := MkEdit(idGroup, 20, 356);
  MkLab(idGroup, 'Driver class', 48);
  ClassEdit := MkEdit(idGroup, 48, 356);
  MkLab(idGroup, 'URL template', 76);
  UrlEdit := MkEdit(idGroup, 76, 356);
  UrlEdit.TextHint := 'jdbc:mydb://{host}:{port}/{database}';
  MkLab(idGroup, 'Default port', 104);
  PortEdit := MkEdit(idGroup, 104, 120);
  PortEdit.NumbersOnly := True;
  MkLab(idGroup, 'Test query', 132);
  TestEdit := MkEdit(idGroup, 132, 356);

  distGroup := MkGroup('Distribution (jar download)', 188, 116);
  MkLab(distGroup, 'License', 20);
  LicenseEdit := MkEdit(distGroup, 20, 356);
  MkLab(distGroup, 'Maven', 48);
  MavenEdit := MkEdit(distGroup, 48, 356);
  MavenEdit.TextHint := 'group:artifact:version (optional, enables Download)';
  MkLab(distGroup, 'Sha1', 76);
  ShaEdit := MkEdit(distGroup, 76, 356);
  ShaEdit.TextHint := 'optional';

  diaGroup := MkGroup('Dialect & options', 312, 172);
  EmbeddedCheck := TCheckBox.Create(Self);
  EmbeddedCheck.Parent := diaGroup;
  EmbeddedCheck.Left := 128;
  EmbeddedCheck.Top := 20;
  EmbeddedCheck.Width := 356;
  EmbeddedCheck.Caption := 'Embedded (file database)';
  PagingBox := MkCombo(diaGroup, 'Paging', 48,
    ['limit-offset', 'offset-fetch-next', 'offset-fetch-first']);
  QuoteBox := MkCombo(diaGroup, 'Quoting', 76,
    ['double', 'backtick', 'bracket']);
  KeyBox := MkCombo(diaGroup, 'Key return', 104, ['none', 'returning']);
  MkLab(diaGroup, 'Param separator', 132);
  SepEdit := MkEdit(diaGroup, 132, 120);

  HintLbl := TLabel.Create(Self);
  HintLbl.Parent := Self;
  HintLbl.Left := 12;
  HintLbl.Top := 492;
  HintLbl.Width := 496;
  HintLbl.Height := 32;
  HintLbl.Caption := 'Register works for this IDE session only. ' +
    'For runtimes, Copy code and paste it into the project.';
  HintLbl.WordWrap := True;
  with TButton.Create(Self) do
  begin
    Parent := Self;
    Caption := 'Register for session';
    Left := 12;
    Top := 532;
    Width := 150;
    OnClick := @RegBtnClick;
  end;
  with TButton.Create(Self) do
  begin
    Parent := Self;
    Caption := 'Copy code';
    Left := 170;
    Top := 532;
    Width := 120;
    OnClick := @CopyBtnClick;
  end;
  with TButton.Create(Self) do
  begin
    Parent := Self;
    Caption := 'Close';
    Left := 388;
    Top := 532;
    Width := 120;
    ModalResult := mrCancel;
    Cancel := True;
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
