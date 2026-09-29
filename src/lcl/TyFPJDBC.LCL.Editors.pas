unit TyFPJDBC.LCL.Editors;
{$mode objfpc}{$H+}
interface
uses
  Classes, SysUtils, ComponentEditors, PropEdits, TyFPJDBC.LCL.Conn,
  TyFPJDBC.LCL.ConnDialog, TyFPJDBC.LCL.Query, TyFPJDBC.Driver.Registry;
type
  { Right-click "Connection setup..." on TJdbcConnection: opens the driver
    wizard dialog (pick driver incl. custom, jar check + download + live
    test) and writes the result back. Design-time only; the IDE calls this. }
  TJdbcConnectionEditor = class(TComponentEditor)
  public
    procedure ExecuteVerb(Index: Integer); override;
    function GetVerb(Index: Integer): string; override;
    function GetVerbCount: Integer; override;
  end;

  { DriverId: dropdown of builtin + session-registered ids (free typing
    still allowed, the list never restricts); "..." opens the wizard. }
  TDriverIdProperty = class(TStringPropertyEditor)
  public
    function GetAttributes: TPropertyAttributes; override;
    procedure GetValues(Proc: TGetStrProc); override;
    procedure Edit; override;
  end;

  { Database: "..." file picker for embedded drivers; plain text otherwise. }
  TDatabaseProperty = class(TStringPropertyEditor)
  public
    function GetAttributes: TPropertyAttributes; override;
    procedure Edit; override;
  end;

  { Password: masked in the Object Inspector, real value untouched. }
  TPasswordProperty = class(TStringPropertyEditor)
  public
    function GetVisualValue: string; override;
  end;

  { SQLText: "..." opens a memo editor. }
  TSQLTextProperty = class(TStringPropertyEditor)
  public
    function GetAttributes: TPropertyAttributes; override;
    procedure Edit; override;
  end;

procedure Register;

implementation

uses
  Forms, Controls, StdCtrls, Dialogs;

procedure Register;
begin
  RegisterComponentEditor(TJdbcConnection, TJdbcConnectionEditor);
  RegisterPropertyEditor(TypeInfo(string), TJdbcConnection, 'DriverId',
    TDriverIdProperty);
  RegisterPropertyEditor(TypeInfo(string), TJdbcConnection, 'Database',
    TDatabaseProperty);
  RegisterPropertyEditor(TypeInfo(string), TJdbcConnection, 'Password',
    TPasswordProperty);
  RegisterPropertyEditor(TypeInfo(string), TJdbcConnQuery, 'SQLText',
    TSQLTextProperty);
end;

procedure TJdbcConnectionEditor.ExecuteVerb(Index: Integer);
var
  dlg: TJdbcConnDialog;
  conn: TJdbcConnection;
begin
  if Index <> 0 then
    Exit;
  if not (GetComponent is TJdbcConnection) then
    Exit;
  conn := TJdbcConnection(GetComponent);
  dlg := TJdbcConnDialog.Create(nil);
  try
    if dlg.Execute(conn) then
      Modified;
  finally
    dlg.Free;
  end;
end;

function TJdbcConnectionEditor.GetVerb(Index: Integer): string;
begin
  if Index = 0 then
    Result := 'Connection setup...'
  else
    Result := '';
end;

function TJdbcConnectionEditor.GetVerbCount: Integer;
begin
  Result := 1;
end;

function TDriverIdProperty.GetAttributes: TPropertyAttributes;
begin
  Result := [paValueList, paDialog, paRevertable];
end;

procedure TDriverIdProperty.GetValues(Proc: TGetStrProc);
var
  id: string;
begin
  for id in TDriverRegistry.BuiltinIds do
    Proc(id);
end;

procedure TDriverIdProperty.Edit;
var
  dlg: TJdbcConnDialog;
begin
  if not (GetComponent(0) is TJdbcConnection) then
    Exit;
  dlg := TJdbcConnDialog.Create(nil);
  try
    if dlg.Execute(TJdbcConnection(GetComponent(0))) then
      Modified;
  finally
    dlg.Free;
  end;
end;

function TDatabaseProperty.GetAttributes: TPropertyAttributes;
var
  conn: TJdbcConnection;
begin
  Result := [paRevertable];
  if not (GetComponent(0) is TJdbcConnection) then
    Exit;
  conn := TJdbcConnection(GetComponent(0));
  if TDriverRegistry.IsEmbedded(conn.DriverId) then
    Result := [paDialog, paRevertable];
end;

procedure TDatabaseProperty.Edit;
var
  conn: TJdbcConnection;
begin
  if not (GetComponent(0) is TJdbcConnection) then
    Exit;
  conn := TJdbcConnection(GetComponent(0));
  if not TDriverRegistry.IsEmbedded(conn.DriverId) then
    Exit;
  with TOpenDialog.Create(nil) do
  try
    Title := 'Database file (' + conn.DriverId + ')';
    Filter := 'Database|*.db;*.sqlite;*.sqlite3;*.db3|All files|*.*';
    FileName := GetValue;
    if Execute then
      SetValue(FileName);
  finally
    Free;
  end;
end;

function TPasswordProperty.GetVisualValue: string;
begin
  if GetValue <> '' then
    Result := '******'
  else
    Result := '';
end;

function TSQLTextProperty.GetAttributes: TPropertyAttributes;
begin
  Result := [paDialog, paRevertable];
end;

procedure TSQLTextProperty.Edit;
var
  f: TForm;
  m: TMemo;
  okB, cancelB: TButton;
begin
  f := TForm.Create(nil);
  try
    f.Caption := 'SQLText';
    f.Width := 560;
    f.Height := 400;
    f.Position := poScreenCenter;
    m := TMemo.Create(f);
    m.Parent := f;
    m.Align := alClient;
    m.ScrollBars := ssBoth;
    m.Text := GetValue;
    okB := TButton.Create(f);
    okB.Parent := f;
    okB.Align := alBottom;
    okB.Caption := 'OK';
    okB.ModalResult := mrOk;
    cancelB := TButton.Create(f);
    cancelB.Parent := f;
    cancelB.Align := alBottom;
    cancelB.Caption := 'Cancel';
    cancelB.ModalResult := mrCancel;
    if f.ShowModal = mrOk then
      SetValue(m.Text);
  finally
    f.Free;
  end;
end;

end.
