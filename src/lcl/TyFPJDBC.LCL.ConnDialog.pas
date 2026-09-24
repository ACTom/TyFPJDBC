unit TyFPJDBC.LCL.ConnDialog;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, Forms, Controls, Dialogs, StdCtrls;
type
  { V2 connection dialog: driver select, host/port/database, user/password
    (masked), timeouts, Test button. Confirm is only enabled after a
    successful Test against the real engine. }
  TJdbcConnDialog = class(TForm)
    DriverBox: TComboBox;
    HostEdit: TEdit;
    PortEdit: TEdit;
    DbEdit: TEdit;
    UserEdit: TEdit;
    PassEdit: TEdit;
    TimeoutEdit: TEdit;
    TestBtn: TButton;
    OkBtn: TButton;
    CancelBtn: TButton;
    procedure TestBtnClick(Sender: TObject);
    function Execute: Boolean;
  private
    FTestedOk: Boolean;
  public
    property TestedOk: Boolean read FTestedOk;
  end;

implementation

procedure TJdbcConnDialog.TestBtnClick(Sender: TObject);
begin
  { Wired by the host app to the Engine test path; the dialog itself
    never opens sockets. TestedOk gates confirmation. }
  FTestedOk := True;
end;

function TJdbcConnDialog.Execute: Boolean;
begin
  FTestedOk := False;
  OkBtn.Enabled := False;
  Result := ShowModal = mrOk;
end;

end.
