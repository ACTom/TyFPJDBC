unit TyFPJDBC.LCL.Query;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, DB, BufDataset, TyFPJDBC.Config;
type
  { Design-time query component: SQL text + key field + window size. At
    runtime pair it with TJdbcQuery (src/db) against a live connection;
    the dataset base is the design surface shared with DBGrid/DBEdit. }
  TJdbcConnQuery = class(TBufDataset)
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

constructor TJdbcConnQuery.Create(AOwner: TComponent);
var
  cfg: TJdbcConfig;
begin
  inherited Create(AOwner);
  FSQLText := '';
  FKeyField := '';
  cfg := TJdbcConfig.Default;
  try
    FWindowSize := cfg.Exec_WindowSize;
  finally
    cfg.Free;
  end;
end;

end.
