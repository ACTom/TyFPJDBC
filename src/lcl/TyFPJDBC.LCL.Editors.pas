unit TyFPJDBC.LCL.Editors;
{$mode objfpc}{$H+}
interface
uses
  Classes, SysUtils, ComponentEditors, TyFPJDBC.LCL.Conn,
  TyFPJDBC.LCL.ConnDialog;
type
  { Right-click "Test connection..." on TJdbcConnection: opens the driver
    wizard dialog (jar check + download + live test) and writes the result
    back into the component. Design-time only; the IDE calls this. }
  TJdbcConnectionEditor = class(TComponentEditor)
  public
    procedure ExecuteVerb(Index: Integer); override;
    function GetVerb(Index: Integer): string; override;
    function GetVerbCount: Integer; override;
  end;

procedure Register;

implementation

procedure Register;
begin
  RegisterComponentEditor(TJdbcConnection, TJdbcConnectionEditor);
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
    Result := 'Test connection...'
  else
    Result := '';
end;

function TJdbcConnectionEditor.GetVerbCount: Integer;
begin
  Result := 1;
end;

end.
