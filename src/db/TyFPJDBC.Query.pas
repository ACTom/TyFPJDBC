unit TyFPJDBC.Query;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, DB, BufDataset, TyFPJDBC.Options, TyFPJDBC.Sql.Parser,
  TyFPJDBC.&Type.Map, TyFPJDBC.Connection, TyFPJDBC.JNI.Bridge;
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
    FLiveBridge: TBridgeClient;
    FLiveConn: Int64;
    FLiveTable: UTF8String;
    FLiveSnap: array of UTF8String;
    FLiveConnProps: TJDBCConnection;
    function GetJdbcSql: string;
    function GetSQL: TStrings;
    procedure SetSQL(const V: TStrings);
    function GetCached: Boolean;
    procedure SetCached(V: Boolean);
    function GetPendingInserts: Integer;
    function RowImage: UTF8String;
    procedure TakeSnapshot;
    function KeyFieldName: string;
    function SqlQuote(const V: UTF8String; IsNull: Boolean): UTF8String;
    procedure ApplyInsertsLive(Pending: Integer);
    procedure ApplyEditsLive;
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
    procedure LoadJavaRows(const ColNames, ColTypes: array of string;
      const Rows: TJavaRows);
    procedure LoadRowsLive(ABridge: TBridgeClient; AConn: Int64;
      const Table: UTF8String; const SQL: UTF8String;
      const ColNames, ColTypes: array of string);
    function MaxBufferedRows: Integer;
    function BufferedRowLimit: Integer;
    { Unicode-correct field access: the bridge carries UTF-8 bytes, while
      ftWideString/ftWideMemo fields store UTF-16. Going through AsString
      would run the bytes through the ANSI codepage and corrupt non-ASCII
      text on e.g. GBK systems. These helpers keep the transfer exact. }
    function FieldToUTF8(F: TField): UTF8String;
    procedure FieldFromUTF8(F: TField; const U: UTF8String);
    property PendingInserts: Integer read GetPendingInserts;
    property AppliedInserts: Integer read FAppliedInserts;
    property BaseCount: Integer read FBaseCount;
    property LiveBridge: TBridgeClient read FLiveBridge write FLiveBridge;
    property LiveConn: Int64 read FLiveConn write FLiveConn;
    property LiveTable: UTF8String read FLiveTable write FLiveTable;
    { Optional live-connection settings (Catalog/Schema/ValidationQuery):
      when assigned, identifiers resolve through QualifiedTable so schema
      changes reach the SQL below, and ApplyUpdates validates first. }
    property LiveConnProps: TJDBCConnection read FLiveConnProps write FLiveConnProps;
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
  SetLength(FLiveSnap, 0);
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

function TJDBCQuery.FieldToUTF8(F: TField): UTF8String;
begin
  { Dedicated UTF8 accessors: plain AsString/AsWideString route through
    the ANSI codepage on this FPC build and corrupt CJK on GBK systems. }
  Result := F.AsUTF8String;
end;

procedure TJDBCQuery.FieldFromUTF8(F: TField; const U: UTF8String);
begin
  F.AsUTF8String := U;
end;

procedure TJDBCQuery.ApplyUpdates;
var
  pending, k, batchN: Integer;
  fld: TField;
  bm: TBookmark;
  live: Boolean;
begin
  if not FCachedUpdates then
    raise Exception.Create('set CachedUpdates first');
  if UpdateOptions.ReadOnly then
    raise Exception.Create('readonly query');
  FetchOptions.Validate;
  UpdateOptions.Validate;
  pending := GetPendingInserts;
  live := (FLiveBridge <> nil) and (FLiveTable <> '');
  if live then
  begin
    { BatchApplySize caps each ExecBatch round trip: a 2500-row pending set
      with BatchApplySize=1000 ships as 1000+1000+500. Edits to base rows
      go out first so a re-read sees both. }
    if FLiveConnProps <> nil then
      FLiveConnProps.Validate;
    ApplyEditsLive;
    while pending > 0 do
    begin
      batchN := pending;
      if batchN > UpdateOptions.BatchApplySize then
        batchN := UpdateOptions.BatchApplySize;
      ApplyInsertsLive(batchN);
      pending := GetPendingInserts;
    end;
    TakeSnapshot;
    Exit;
  end;
  if pending = 0 then
    Exit;
  DisableControls;
  try
    bm := GetBookmark;
    try
      { Ascending row order: first appended row takes the lowest key, so
        key order matches physical row order and re-reads line up. }
      First;
      for k := 1 to FBaseCount + FAppliedInserts do
        Next;
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
            FieldFromUTF8(fld, UTF8String(IntToStr(FLastGenKey)));
            Post;
          end;
        end;
        if k < pending then
          Next;
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

function TJDBCQuery.RowImage: UTF8String;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to FieldCount - 1 do
  begin
    if i > 0 then
      Result := Result + UTF8String(#31);
    if Fields[i].IsNull then
      Result := Result + UTF8String(#0)
    else
      Result := Result + FieldToUTF8(Fields[i]);
  end;
end;

procedure TJDBCQuery.TakeSnapshot;
var
  bm: TBookmark;
  i: Integer;
begin
  SetLength(FLiveSnap, 0);
  if RecordCount = 0 then
    Exit;
  DisableControls;
  try
    bm := GetBookmark;
    try
      First;
      for i := 1 to FBaseCount do
      begin
        if Eof then
          Break;
        SetLength(FLiveSnap, Length(FLiveSnap) + 1);
        FLiveSnap[High(FLiveSnap)] := RowImage;
        Next;
      end;
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

function TJDBCQuery.KeyFieldName: string;
var
  p: Integer;
begin
  Result := Trim(UpdateOptions.KeyFields);
  p := Pos(',', Result);
  if p > 0 then
    Result := Trim(Copy(Result, 1, p - 1));
  if Result = '' then
    Result := Trim(UpdateOptions.AutoIncField);
  if (Result = '') and (FieldCount > 0) then
    Result := Fields[0].FieldName;
end;

function TJDBCQuery.SqlQuote(const V: UTF8String; IsNull: Boolean): UTF8String;
begin
  if IsNull then
    Exit('NULL');
  Result := '''' + StringReplace(V, '''', '''''', [rfReplaceAll]) + '''';
end;

procedure TJDBCQuery.ApplyInsertsLive(Pending: Integer);
var
  cols, ph, target: UTF8String;
  i, r: Integer;
  batch: TJavaRows;
  nulls: TJavaNulls;
  bm: TBookmark;
  fld: TField;
begin
  cols := '';
  ph := '';
  for i := 0 to FieldCount - 1 do
  begin
    if i > 0 then
    begin
      cols := cols + ',';
      ph := ph + ',';
    end;
    cols := cols + Fields[i].FieldName;
    ph := ph + '?';
  end;
  SetLength(batch, Pending);
  SetLength(nulls, Pending);
  { Genkeys first, in ascending row order: first appended row takes the
    lowest key. Ids are inserted explicitly so a re-read sees the same
    keys the dataset holds (same sequence as the offline path). }
  DisableControls;
  try
    bm := GetBookmark;
    try
      First;
      for r := 1 to FBaseCount + FAppliedInserts do
        Next;
      for r := 1 to Pending do
      begin
        FLastGenKey := FNextGenKey;
        Inc(FNextGenKey);
        if UpdateOptions.AutoIncField <> '' then
        begin
          fld := FindField(UpdateOptions.AutoIncField);
          if fld <> nil then
          begin
            Edit;
            FieldFromUTF8(fld, UTF8String(IntToStr(FLastGenKey)));
            Post;
          end;
        end;
        if r < Pending then
          Next;
      end;
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
  DisableControls;
  try
    bm := GetBookmark;
    try
      First;
      { Same skip as the genkey loop above: rows applied by earlier
        ApplyUpdates calls are already in the table and must not be
        collected again, or the second batch would re-insert them. }
      for r := 1 to FBaseCount + FAppliedInserts do
        Next;
      for r := 0 to Pending - 1 do
      begin
        SetLength(batch[r], FieldCount);
        SetLength(nulls[r], FieldCount);
        for i := 0 to FieldCount - 1 do
        begin
          nulls[r][i] := Fields[i].IsNull;
          if Fields[i].IsNull then
            batch[r][i] := ''
          else
            batch[r][i] := FieldToUTF8(Fields[i]);
        end;
        Next;
      end;
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
  { BatchApplySize is enforced here (not just documented): oversized single
    batches are rejected, and ApplyUpdates pre-splits so a large pending
    set ships as several BatchApplySize-sized round trips. The target
    honors LiveConnProps Schema/Catalog via QualifiedTable. }
  UpdateOptions.Validate;
  if Pending > UpdateOptions.BatchApplySize then
    raise Exception.Create('ApplyInsertsLive batch over BatchApplySize: ' +
      IntToStr(Pending) + '>' + IntToStr(UpdateOptions.BatchApplySize));
  if FLiveConnProps <> nil then
    target := UTF8String(FLiveConnProps.QualifiedTable(string(FLiveTable)))
  else
    target := FLiveTable;
  if FLiveBridge.ExecBatch(FLiveConn,
    'INSERT INTO ' + target + '(' + cols + ') VALUES(' + ph + ')',
    batch, nulls) < Pending then
    raise Exception.Create('live insert short write');
  Inc(FAppliedInserts, Pending);
end;

procedure TJDBCQuery.ApplyEditsLive;
var
  bm: TBookmark;
  i, row: Integer;
  img, key, setList, upd, target: UTF8String;
  fi: Integer;
begin
  if (Length(FLiveSnap) = 0) or (FBaseCount = 0) then
    Exit;
  key := UTF8String(KeyFieldName);
  if FLiveConnProps <> nil then
    target := UTF8String(FLiveConnProps.QualifiedTable(string(FLiveTable)))
  else
    target := FLiveTable;
  DisableControls;
  try
    bm := GetBookmark;
    try
      First;
      for row := 0 to FBaseCount - 1 do
      begin
        if Eof then
          Break;
        img := RowImage;
        if (row < Length(FLiveSnap)) and (img <> FLiveSnap[row]) then
        begin
          setList := '';
          for i := 0 to FieldCount - 1 do
            if Fields[i].FieldName <> key then
            begin
              if setList <> '' then
                setList := setList + ',';
              setList := setList + Fields[i].FieldName + '=' +
                SqlQuote(FieldToUTF8(Fields[i]), Fields[i].IsNull);
            end;
          fi := FieldByName(key).Index;
          upd := 'UPDATE ' + target + ' SET ' + setList + ' WHERE ' +
            key + '=' + SqlQuote(FieldToUTF8(Fields[fi]), Fields[fi].IsNull);
          if FLiveBridge.ExecUpdate(FLiveConn, upd) < 1 then
            raise Exception.Create('live update affected 0 rows');
        end;
        Next;
      end;
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
  FetchOptions.Validate;
  if Rows.Count > FetchOptions.MaxBufferedRows then
    raise EJDBCError.CreateChain('buffer over MaxBufferedRows', 'HY001', 60,
      'rows=' + IntToStr(Rows.Count) + ' max=' +
      IntToStr(FetchOptions.MaxBufferedRows) + '; switch to fmOnDemand');
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
        FieldFromUTF8(Fields[0], parts[0]);
      if (parts.Count > 1) and (FieldCount > 1) then
        FieldFromUTF8(Fields[1], parts[1]);
      Post;
    end;
    First;
  finally
    parts.Free;
  end;
  FBaseCount := RecordCount;
  FAppliedInserts := 0;
  FLastGenKey := 0;
  TakeSnapshot;
end;

procedure TJDBCQuery.LoadJavaRows(const ColNames, ColTypes: array of string;
  const Rows: TJavaRows);
var
  i, r, c: Integer;
  ft: TFieldType;
begin
  { MaxBufferedRows caps fmAll buffering: callers that lower the option get
    a HY001 refusal instead of silently buffering past the budget. }
  FetchOptions.Validate;
  if Length(Rows) > FetchOptions.MaxBufferedRows then
    raise EJDBCError.CreateChain('buffer over MaxBufferedRows', 'HY001', 60,
      'rows=' + IntToStr(Length(Rows)) + ' max=' +
      IntToStr(FetchOptions.MaxBufferedRows) + '; switch to fmOnDemand');
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
  for r := 0 to High(Rows) do
  begin
    Append;
    for c := 0 to FieldCount - 1 do
      if c <= High(Rows[r]) then
        FieldFromUTF8(Fields[c], Rows[r][c]);
    Post;
  end;
  First;
  FBaseCount := RecordCount;
  FAppliedInserts := 0;
  FLastGenKey := 0;
  TakeSnapshot;
end;

procedure TJDBCQuery.LoadRowsLive(ABridge: TBridgeClient; AConn: Int64;
  const Table: UTF8String; const SQL: UTF8String;
  const ColNames, ColTypes: array of string);
var
  all: TJavaRows;
  page: TJavaRows;
  off, r, base, pageSize: Integer;
begin
  { Live paging honors FetchOptions.RowsetSize (validated >= 1): shrinking
    it multiplies the FetchBatch round trips for the same row total, and
    total buffered rows still respect MaxBufferedRows via LoadJavaRows. }
  FetchOptions.Validate;
  pageSize := FetchOptions.RowsetSize;
  FLiveBridge := ABridge;
  FLiveConn := AConn;
  FLiveTable := Table;
  SetLength(all, 0);
  off := 0;
  repeat
    page := ABridge.FetchBatch(AConn, SQL + ' LIMIT ' + IntToStr(pageSize) +
      ' OFFSET ' + IntToStr(off), 0, pageSize, FetchOptions.FetchSize);
    if Length(page) = 0 then
      Break;
    base := Length(all);
    SetLength(all, base + Length(page));
    for r := 0 to High(page) do
      all[base + r] := page[r];
    off := off + Length(page);
  until Length(page) < pageSize;
  LoadJavaRows(ColNames, ColTypes, all);
end;

function TJDBCQuery.MaxBufferedRows: Integer;
begin
  { Effective buffered-row budget: the FetchOptions setting caps how many
    rows fmAll load paths accept, while the function result reports how
    many are currently buffered. }
  Result := RecordCount;
end;

function TJDBCQuery.BufferedRowLimit: Integer;
begin
  Result := FetchOptions.MaxBufferedRows;
end;

end.
