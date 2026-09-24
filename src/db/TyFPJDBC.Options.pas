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
    MaxBufferedRows: Integer;
    constructor Create;
    procedure Validate;
  end;
  TFormatOptions = class
    StrictNull: Boolean;
    constructor Create;
  end;
  TUpdateOptions = class
    ReadOnly: Boolean;
    KeyFields: string;
    AutoIncField: string;
    BatchApplySize: Integer;
    constructor Create;
    procedure Validate;
  end;
implementation
constructor TFetchOptions.Create;
begin
  RowsetSize := 1000;
  Mode := fmAll;
  Unidirectional := False;
  FetchSize := 1000;
  MaxBufferedRows := 100000;
end;
procedure TFetchOptions.Validate;
begin
  if (Mode = fmOnDemand) and not Unidirectional then
    raise Exception.Create('fmOnDemand requires Unidirectional=True');
  if RowsetSize < 1 then
    raise Exception.Create('RowsetSize must be >= 1');
  if MaxBufferedRows < 1 then
    raise Exception.Create('MaxBufferedRows must be >= 1');
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
  BatchApplySize := 1000;
end;
procedure TUpdateOptions.Validate;
begin
  if (BatchApplySize < 1) or (BatchApplySize > 10000) then
    raise Exception.Create('BatchApplySize out of range 1..10000');
end;
end.
