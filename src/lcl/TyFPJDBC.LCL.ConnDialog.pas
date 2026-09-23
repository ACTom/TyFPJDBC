unit TyFPJDBC.LCL.ConnDialog;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, Forms, Dialogs, StdCtrls;
type
  TJdbcConnDialog = class(TForm)
    UrlEdit: TEdit;
    UserEdit: TEdit;
    PassEdit: TEdit;
    OkBtn: TButton;
    CancelBtn: TButton;
    function Execute: Boolean;
  end;

implementation

function TJdbcConnDialog.Execute: Boolean;
begin
  Result := ShowModal = mrOk;
end;

end.
