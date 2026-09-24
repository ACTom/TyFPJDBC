unit TyFPJDBC.LCL.Query;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, DB, BufDataset;
type
  { Design-time query component: SQL text + key field + window size. At
    runtime the Engine prepares it against a live connection; the dataset
    base is the design surface shared with DBGrid/DBEdit. }
  TJdbcQuery = class(TBufDataset)
  private
    FSQLText: string;
    FKeyField: string;
    FWindowSize: Integer;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property SQLText: string read FSQLText write FSQLText;
    property KeyField: string read FKeyField write FKeyField;
    property WindowSize: Integer read FWindowSize write FWindowSize;
  end;

implementation

constructor TJdbcQuery.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FSQLText := '';
  FKeyField := '';
  FWindowSize := 1000;
end;

end.
