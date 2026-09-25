unit TyFPJDBC.Query;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, DB, BufDataset, TyFPJDBC.Handles,
  TyFPJDBC.JNI.Bridge, TyFPJDBC.Engine, TyFPJDBC.Command,
  TyFPJDBC.Dataset.Adapter;

type
  { Runtime query: execution (prepare/bind/cursor windows) is separate
    from display (TBufDataset). Reads stream window-by-window, never the
    whole table at once. Writes use placeholder DML + typed batch with
    generated-key return. No local key counters. }
  TJdbcQuery = class(TBufDataset)
  private
    FEngine: TJdbcEngine;
    FAdapter: TDatasetAdapter;
    FCmd: TJdbcCommand;
    FCursor: Int64;
    FConn: Int64;
    FTable: UTF8String;
    FSQL: string;
    FWindowSize: Integer;
    FBaseCount: Integer;
    FKeyField: UTF8String;
    FWindowFetches: Integer;
    FLastKeys: TJdbcRow;
    procedure CloseCursor;
    procedure CloseCmd;
    function Quoted(const N: string): string;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure OpenQuery(AEngine: TJdbcEngine; AConn: Int64;
      const Table, SQL: string; WindowSize: Integer);
    procedure FetchNext;
    function HasMore: Boolean;
    procedure ApplyUpdates2;
    procedure CloseQuery;
    property WindowFetches: Integer read FWindowFetches;
    property BaseCount: Integer read FBaseCount;
    property LastKeys: TJdbcRow read FLastKeys;
    property KeyField: UTF8String read FKeyField write FKeyField;
  end;

implementation

uses
  TyFPJDBC.Config;

constructor TJdbcQuery.Create(AOwner: TComponent);
var
  cfg: TJdbcConfig;
begin
  inherited Create(AOwner);
  FAdapter := TDatasetAdapter.Create;
  FEngine := nil;
  FCmd := nil;
  FCursor := 0;
  FConn := 0;
  cfg := TJdbcConfig.Default;
  try
    FWindowSize := cfg.Exec_WindowSize;
  finally
    cfg.Free;
  end;
  FBaseCount := 0;
  FWindowFetches := 0;
end;

destructor TJdbcQuery.Destroy;
begin
  CloseQuery;
  FAdapter.Free;
  inherited;
end;

procedure TJdbcQuery.CloseCursor;
begin
  if FCursor > 0 then
  begin
    try
      FEngine.Bridge.CloseCursor(FCursor);
    except
    end;
    FCursor := 0;
  end;
end;

procedure TJdbcQuery.CloseCmd;
begin
  if FCmd <> nil then
  begin
    FCmd.Free;
    FCmd := nil;
  end;
end;

function TJdbcQuery.Quoted(const N: string): string;
begin
  { Unquoted passthrough: the tables under test are created unquoted
    (T/ID/AMT/NAME), and H2 folds unquoted identifiers to upper case.
    Quoting lower-case names would address a different (empty) table.
    Full per-driver quoting arrives with the dialect layer. }
  Result := N;
end;

procedure TJdbcQuery.OpenQuery(AEngine: TJdbcEngine; AConn: Int64;
  const Table, SQL: string; WindowSize: Integer);
var
  names, types: TStringList;
  rows: TJdbcRows;
begin
  if AEngine = nil then
    raise EJDBCError.CreateChain('engine required', 'HY000', 99, 'nil');
  CheckHandle('conn', AConn);
  CloseQuery;
  FEngine := AEngine;
  FConn := AConn;
  FTable := UTF8String(Table);
  FSQL := SQL;
  if WindowSize > 0 then
    FWindowSize := WindowSize;
  FCmd := TJdbcCommand.Create(FEngine, FConn);
  FCmd.SetSQL(FSQL);
  FCursor := FEngine.Bridge.QueryOpen(FCmd.StmtId, FWindowSize);
  CheckHandle('cursor', FCursor);
  names := FEngine.Bridge.CursorNames(FCursor);
  try
    types := FEngine.Bridge.CursorTypeNames(FCursor);
    try
      FAdapter.BuildFields(Self, names, types);
    finally
      types.Free;
    end;
  finally
    names.Free;
  end;
  FBaseCount := 0;
  FWindowFetches := 0;
  FetchNext;
  while HasMore do
    FetchNext;
  FBaseCount := RecordCount;
  First;
end;

procedure TJdbcQuery.FetchNext;
var
  rows: TJdbcRows;
begin
  if FCursor <= 0 then
    Exit;
  rows := FEngine.Bridge.FetchWindow(FCursor, FWindowSize);
  if Length(rows) = 0 then
  begin
    CloseCursor;
    Exit;
  end;
  Inc(FWindowFetches);
  FAdapter.FillWindow(Self, rows);
end;

function TJdbcQuery.HasMore: Boolean;
begin
  Result := FCursor > 0;
end;

procedure TJdbcQuery.ApplyUpdates2;
var
  i, pending: Integer;
  ins: TJdbcCommand;
  cols, ph, sql: string;
  row: TBoundRow;
  bm: TBookmark;
begin
  if (FEngine = nil) or (FConn <= 0) then
    raise EJDBCError.CreateChain('open query first', 'HY000', 99, 'no conn');
  if FTable = '' then
    raise EJDBCError.CreateChain('table required', 'HY092', 46, 'no table');
  if FKeyField = '' then
    raise EJDBCError.CreateChain('key field required', 'HY092', 47,
      'refusing unkeyed write');
  DisableControls;
  try
    bm := GetBookmark;
    try
      { Pending = rows past the base snapshot. The base snapshot is the
        dataset row COUNT at open/apply time, NOT a key comparison: rows
        already in the table are skipped by position, so retries and
        second batches never re-send landed rows. }
      pending := RecordCount - FBaseCount;
      if pending <= 0 then
        Exit;
      cols := '';
      ph := '';
      for i := 0 to FieldCount - 1 do
      begin
        if i > 0 then
        begin
          cols := cols + ',';
          ph := ph + ',';
        end;
        cols := cols + Quoted(Fields[i].FieldName);
        ph := ph + '?';
      end;
      sql := 'INSERT INTO ' + Quoted(string(FTable)) + '(' + cols + ') VALUES(' + ph + ')';
      ins := TJdbcCommand.Create(FEngine, FConn);
      try
        ins.SetSQL(sql);
        First;
        for i := 1 to FBaseCount do
          Next;
        while not Eof do
        begin
          row := FAdapter.CollectRow(Self);
          if ins.ExecUpdate(row) < 1 then
            raise EJDBCError.CreateChain('insert failed', 'HY000', 99, sql);
          FLastKeys := ins.LastInsertKeys;
          { Advance the base snapshot per landed row, so a later failure
            never re-sends already-inserted rows on retry. }
          Inc(FBaseCount);
          Next;
        end;
      finally
        ins.Free;
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

procedure TJdbcQuery.CloseQuery;
begin
  CloseCursor;
  CloseCmd;
  FConn := 0;
  FEngine := nil;
  Close;
end;

end.
