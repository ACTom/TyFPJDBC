unit TyFPJDBC.Mock.Engine;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes;
type
  TMockEngine = class
  private
    FLargeTotal: Integer;
  public
    constructor Create(ALargeTotal: Integer = 20000);
    function SmallTotal: Integer;
    function LargeTotal: Integer;
    function SmallRow(I: Integer): string;
    function SmallName(I: Integer): string;
    function LargeRow(I: Integer): string;
    function FetchSmall(Offset, Limit: Integer; out Total: Integer): TStringList;
    function FetchLarge(Offset, Limit: Integer; out Total: Integer): TStringList;
  end;

implementation

constructor TMockEngine.Create(ALargeTotal: Integer);
begin
  FLargeTotal := ALargeTotal;
end;

function TMockEngine.SmallTotal: Integer;
begin
  Result := 3;
end;

function TMockEngine.LargeTotal: Integer;
begin
  Result := FLargeTotal;
end;

function TMockEngine.SmallRow(I: Integer): string;
begin
  case I of
    0: Result := '1|hello';
    1: Result := '2|中文测试';
    2: Result := '3|jdbc-bridge';
  else
    Result := '';
  end;
end;

function TMockEngine.SmallName(I: Integer): string;
begin
  Result := SmallRow(I);
end;

function TMockEngine.LargeRow(I: Integer): string;
begin
  Result := IntToStr(I + 1) + '|row-' + IntToStr(I + 1);
end;

function TMockEngine.FetchSmall(Offset, Limit: Integer; out Total: Integer): TStringList;
var
  i, last: Integer;
begin
  Total := SmallTotal;
  Result := TStringList.Create;
  last := Offset + Limit - 1;
  if last > Total - 1 then
    last := Total - 1;
  for i := Offset to last do
    if i >= 0 then
      Result.Add(SmallRow(i));
end;

function TMockEngine.FetchLarge(Offset, Limit: Integer; out Total: Integer): TStringList;
var
  i, last: Integer;
begin
  Total := LargeTotal;
  Result := TStringList.Create;
  last := Offset + Limit - 1;
  if last > Total - 1 then
    last := Total - 1;
  for i := Offset to last do
    if i >= 0 then
      Result.Add(LargeRow(i));
end;

end.
