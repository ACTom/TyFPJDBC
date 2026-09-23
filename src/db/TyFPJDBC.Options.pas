unit TyFPJDBC.Options;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes;
type
  TFetchMode = (fmAll, fmOnDemand);
  TFetchOptions = class
    RowsetSize: Integer;
    Mode: TFetchMode;
    Unidirectional: Boolean;
    FetchSize: Integer;
    constructor Create;
  end;
  TFormatOptions = class
    StrictNull: Boolean;
    constructor Create;
  end;
  TUpdateOptions = class
    ReadOnly: Boolean;
    KeyFields: string;
    AutoIncField: string;
    constructor Create;
  end;
implementation
constructor TFetchOptions.Create;
begin
  RowsetSize := 1000;
  Mode := fmAll;
  Unidirectional := False;
  FetchSize := 1000;
end;
constructor TFormatOptions.Create;
begin
  StrictNull := True;
end;
constructor TUpdateOptions.Create;
begin
  ReadOnly := False;
  KeyFields := '';
  AutoIncField := '';
end;
end.
