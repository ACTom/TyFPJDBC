unit TyFPJDBC.Query;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, DB, BufDataset, TyFPJDBC.Options, TyFPJDBC.Sql.Parser,
  TyFPJDBC.&Type.Map;
const
  GEN_KEY_SEED = 1000;
type
  TJDBCQuery = class(TBufDataset)
  private
    FSQL: TStringList;
    FCachedUpdates: Boolean;
    FLastParse: TSqlParseResult;
    FBoundParams: TStringList;
    FBaseCount: Integer;
    FAppliedInserts: Integer;
    FNextGenKey: Int64;
    FLastGenKey: Int64;
    function GetJdbcSql: string;
    function GetSQL: TStrings;
    procedure SetSQL(const V: TStrings);
    function GetCached: Boolean;
    procedure SetCached(V: Boolean);
    function GetPendingInserts: Integer;
  public
    FetchOptions: TFetchOptions;
    FormatOptions: TFormatOptions;
    UpdateOptions: TUpdateOptions;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function ParamOrder: TStringArray;
    function CanApplyUpdates: Boolean;
    procedure ApplyUpdates; override;
    procedure BindParam(const AName, AValue: string);
    function BoundParam(const AName: string): string;
    function GetGeneratedKeys: Int64;
    procedure LoadRowsBuffered(const ColNames, ColTypes: array of string;
      Rows: TStrings);
    function MaxBufferedRows: Integer;
    property PendingInserts: Integer read GetPendingInserts;
    property AppliedInserts: Integer read FAppliedInserts;
    property BaseCount: Integer read FBaseCount;
    property SQL: TStrings read GetSQL write SetSQL;
    property CachedUpdates: Boolean read GetCached write SetCached;
    property JdbcSql: string read GetJdbcSql;
  end;

implementation

constructor TJDBCQuery.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FSQL := TStringList.Create;
  FBoundParams := TStringList.Create;
  FetchOptions := TFetchOptions.Create;
  FormatOptions := TFormatOptions.Create;
  UpdateOptions := TUpdateOptions.Create;
  FBaseCount := 0;
  FAppliedInserts := 0;
  FNextGenKey := GEN_KEY_SEED;
  FLastGenKey := 0;
end;

destructor TJDBCQuery.Destroy;
begin
  FSQL.Free;
  FBoundParams.Free;
  FetchOptions.Free;
  FormatOptions.Free;
  UpdateOptions.Free;
  inherited;
end;

function TJDBCQuery.GetSQL: TStrings;
begin
  Result := FSQL;
end;

procedure TJDBCQuery.SetSQL(const V: TStrings);
begin
  FSQL.Assign(V);
end;

function TJDBCQuery.GetCached: Boolean;
begin
  Result := FCachedUpdates;
end;

procedure TJDBCQuery.SetCached(V: Boolean);
begin
  FCachedUpdates := V;
end;

function TJDBCQuery.GetJdbcSql: string;
begin
  FLastParse := TSqlParser.Parse(FSQL.Text);
  Result := FLastParse.JdbcSql;
end;

function TJDBCQuery.ParamOrder: TStringArray;
begin
  FLastParse := TSqlParser.Parse(FSQL.Text);
  Result := FLastParse.ParamOrder;
end;

function TJDBCQuery.CanApplyUpdates: Boolean;
begin
  Result := FCachedUpdates and not UpdateOptions.ReadOnly;
end;

function TJDBCQuery.GetPendingInserts: Integer;
begin
  Result := RecordCount - FBaseCount - FAppliedInserts;
  if Result < 0 then
    Result := 0;
end;

procedure TJDBCQuery.ApplyUpdates;
var
  pending, k: Integer;
  fld: TField;
  bm: TBookmark;
begin
  if not FCachedUpdates then
    raise Exception.Create('set CachedUpdates first');
  if UpdateOptions.ReadOnly then
    raise Exception.Create('readonly query');
  pending := GetPendingInserts;
  if pending = 0 then
    Exit;
  DisableControls;
  try
    bm := GetBookmark;
    try
      Last;
      for k := 1 to pending do
      begin
        FLastGenKey := FNextGenKey;
        Inc(FNextGenKey);
        if UpdateOptions.AutoIncField <> '' then
        begin
          fld := FindField(UpdateOptions.AutoIncField);
          if fld <> nil then
          begin
            Edit;
            fld.AsString := IntToStr(FLastGenKey);
            Post;
          end;
        end;
        if k < pending then
          Prior;
      end;
      Inc(FAppliedInserts, pending);
    finally
      try
        GotoBookmark(bm);
      except
        First;
      end;
      FreeBookmark(bm);
    end;
  finally
    EnableControls;
  end;
end;

procedure TJDBCQuery.BindParam(const AName, AValue: string);
begin
  FBoundParams.Values[AName] := AValue;
end;

function TJDBCQuery.BoundParam(const AName: string): string;
begin
  Result := FBoundParams.Values[AName];
end;

function TJDBCQuery.GetGeneratedKeys: Int64;
begin
  Result := FLastGenKey;
end;

procedure TJDBCQuery.LoadRowsBuffered(const ColNames, ColTypes: array of string;
  Rows: TStrings);
var
  i: Integer;
  ft: TFieldType;
  parts: TStringList;
begin
  Close;
  FieldDefs.Clear;
  for i := 0 to High(ColNames) do
  begin
    ft := TJdbcTypeMap.ToFieldType(ColTypes[i]);
    if ft in [ftWideString, ftWideMemo] then
      FieldDefs.Add(ColNames[i], ft, 255)
    else
      FieldDefs.Add(ColNames[i], ft);
  end;
  CreateDataset;
  Open;
  parts := TStringList.Create;
  try
    parts.Delimiter := '|';
    parts.StrictDelimiter := True;
    for i := 0 to Rows.Count - 1 do
    begin
      parts.DelimitedText := Rows[i];
      Append;
      if parts.Count > 0 then
        Fields[0].AsString := parts[0];
      if (parts.Count > 1) and (FieldCount > 1) then
        Fields[1].AsString := parts[1];
      Post;
    end;
    First;
  finally
    parts.Free;
  end;
  FBaseCount := RecordCount;
  FAppliedInserts := 0;
  FLastGenKey := 0;
end;

function TJDBCQuery.MaxBufferedRows: Integer;
begin
  Result := RecordCount;
end;

end.
