unit TyFPJDBC.JNI.Utils;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

type
  TJniUtils = class
    class function IsWhiteIdent(const S: string): Boolean; static;
  end;

implementation

class function TJniUtils.IsWhiteIdent(const S: string): Boolean;
var
  i: Integer;
begin
  Result := S <> '';
  if not Result then
    Exit;
  for i := 1 to Length(S) do
    if not (S[i] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '.', '$']) then
      Exit(False);
  Result := True;
end;

end.
