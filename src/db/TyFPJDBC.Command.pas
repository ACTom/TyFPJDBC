unit TyFPJDBC.Command;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, TyFPJDBC.Handles, TyFPJDBC.JNI.Bridge, TyFPJDBC.Engine;

type
  { Bound value kinds mirror the typed Bridge setters. Values stay in
    canonical string form on the Pascal side; JDBC uses the typed setter. }
  TBVKind = (bvInt, bvInt64, bvDouble, bvBigDec, bvStr, bvDate, bvTime,
    bvStamp, bvBytes, bvNull);

  TBoundValue = record
    Kind: TBVKind;
    S: UTF8String;
    I64: Int64;
    F64: Double;
    Bytes: TBytes;
    SqlType: Integer;
  end;

  TBoundRow = array of TBoundValue;

function BInt(V: Integer): TBoundValue;
function BInt64(V: Int64): TBoundValue;
function BDouble(V: Double): TBoundValue;
function BBigDec(const V: string): TBoundValue;
function BStr(const V: string): TBoundValue;
function BDate(const Iso: string): TBoundValue;
function BTime(const Iso: string): TBoundValue;
function BStamp(const Iso: string): TBoundValue;
function BBytes(const V: TBytes): TBoundValue;
function BNull(SqlType: Integer): TBoundValue;

type
  TRewriteResult = record
    JdbcSql: string;
    ParamOrder: TStringArray;
  end;

function RewriteNamedParams(const S: string): TRewriteResult;

type
  { Named-parameter command: converts :name to ? (: casts, :=, strings,
    quoted idents, comments, $$  bodies, ?|/?&  and lone ? untouched),
    binds typed values positionally, executes via Engine stmt handles
    with timeout/cancel support. }
  TJdbcCommand = class
  private
    FEngine: TJdbcEngine;
    FConn: Int64;
    FStmt: Int64;
    FSql: string;
    FOrder: TStringArray;
    FTimeoutSecs: Integer;
    procedure CloseStmt;
  public
    constructor Create(AEngine: TJdbcEngine; AConn: Int64);
    destructor Destroy; override;
    procedure SetSQL(const S: string);
    function ParamOrder: TStringArray;
    function JdbcSQL: string;
    procedure BindRow(const Row: TBoundRow);
    function ExecUpdate(const Row: TBoundRow): Integer;
    function ExecBatch(const Rows: array of TBoundRow; BatchSize: Integer): Integer;
    function LastInsertKeys: TJdbcRow;
    procedure SetTimeout(Secs: Integer);
    procedure Cancel;
    property StmtId: Int64 read FStmt;
  end;

const
  SQL_VARCHAR = 12;
  SQL_BIGINT = -5;
  SQL_DOUBLE = 8;
  SQL_DECIMAL = 3;
  SQL_DATE = 91;
  SQL_BLOB = 2004;

implementation

uses
  TyFPJDBC.Config;

function IsRewriteNameStart(C: Char): Boolean;
begin
  Result := C in ['A'..'Z', 'a'..'z', '_'];
end;

function IsRewriteNameChar(C: Char): Boolean;
begin
  Result := C in ['A'..'Z', 'a'..'z', '0'..'9', '_'];
end;

{ Pure rewrite shared by TJdbcCommand.SetSQL and unit tests: no JNI, no
  engine state, output feeds directly into Prepare. }
function RewriteNamedParams(const S: string): TRewriteResult;
var
  i, n, k: Integer;
  ch, q: Char;
  inStr: Boolean;
  outSql, name: string;
  names: TStringList;
begin
  names := TStringList.Create;
  try
    outSql := '';
    i := 1;
    n := Length(S);
    inStr := False;
    q := #0;
    while i <= n do
    begin
      ch := S[i];
      if inStr then
      begin
        outSql := outSql + ch;
        { Standard SQL strings end only on a lone quote ('' doubles).
          Backslash stays literal so ESCAPE '\' never swallows the
          closing quote. }
        if ch = q then
        begin
          if (i < n) and (S[i + 1] = q) then
          begin
            outSql := outSql + S[i + 1];
            Inc(i, 2);
            Continue;
          end;
          inStr := False;
        end;
        Inc(i);
        Continue;
      end;
      if (ch = '$') and (i < n) and (S[i + 1] = '$') then
      begin
        outSql := outSql + '$$';
        Inc(i, 2);
        while i <= n do
        begin
          if (S[i] = '$') and (i < n) and (S[i + 1] = '$') then
          begin
            outSql := outSql + '$$';
            Inc(i, 2);
            Break;
          end;
          outSql := outSql + S[i];
          Inc(i);
        end;
        Continue;
      end;
      if (ch = '''') or (ch = '"') or (ch = '`') then
      begin
        inStr := True;
        q := ch;
        outSql := outSql + ch;
        Inc(i);
        Continue;
      end;
      if (ch = '-') and (i < n) and (S[i + 1] = '-') then
      begin
        while (i <= n) and (S[i] <> #10) do
        begin
          outSql := outSql + S[i];
          Inc(i);
        end;
        Continue;
      end;
      if (ch = '/') and (i < n) and (S[i + 1] = '*') then
      begin
        outSql := outSql + '/*';
        Inc(i, 2);
        while i <= n do
        begin
          if (S[i] = '*') and (i < n) and (S[i + 1] = '/') then
          begin
            outSql := outSql + '*/';
            Inc(i, 2);
            Break;
          end;
          outSql := outSql + S[i];
          Inc(i);
        end;
        Continue;
      end;
      if (ch = ':') and (i < n) and (S[i + 1] = ':') then
      begin
        outSql := outSql + '::';
        Inc(i, 2);
        Continue;
      end;
      if (ch = ':') and (i < n) and (S[i + 1] = '=') then
      begin
        outSql := outSql + ':=';
        Inc(i, 2);
        Continue;
      end;
      { :/ (host-style) and :digit (time literals, array slices) are not
        named params: keep the colon, the tail copies verbatim below. }
      if (ch = ':') and (i < n) and (S[i + 1] = '/') then
      begin
        outSql := outSql + ':';
        Inc(i);
        Continue;
      end;
      if (ch = ':') and (i < n) and IsRewriteNameStart(S[i + 1]) then
      begin
        name := '';
        Inc(i);
        while (i <= n) and IsRewriteNameChar(S[i]) do
        begin
          name := name + S[i];
          Inc(i);
        end;
        names.Add(name);
        outSql := outSql + '?';
        Continue;
      end;
      { JSON ?| / ?& operators and an already-? placeholder stay literal. }
      if ch = '?' then
      begin
        if (i < n) and (S[i + 1] in ['|', '&']) then
        begin
          outSql := outSql + '?' + S[i + 1];
          Inc(i, 2);
          Continue;
        end;
        outSql := outSql + '?';
        Inc(i);
        Continue;
      end;
      outSql := outSql + ch;
      Inc(i);
    end;
    Result.JdbcSql := outSql;
    SetLength(Result.ParamOrder, names.Count);
    for k := 0 to names.Count - 1 do
      Result.ParamOrder[k] := names[k];
  finally
    names.Free;
  end;
end;

function BInt(V: Integer): TBoundValue;
begin
  Result.Kind := bvInt; Result.I64 := V; Result.F64 := 0;
  Result.S := ''; SetLength(Result.Bytes, 0); Result.SqlType := 0;
end;

function BInt64(V: Int64): TBoundValue;
begin
  Result.Kind := bvInt64; Result.I64 := V; Result.F64 := 0;
  Result.S := ''; SetLength(Result.Bytes, 0); Result.SqlType := 0;
end;

function BDouble(V: Double): TBoundValue;
begin
  Result.Kind := bvDouble; Result.F64 := V; Result.I64 := 0;
  Result.S := ''; SetLength(Result.Bytes, 0); Result.SqlType := 0;
end;

function BBigDec(const V: string): TBoundValue;
begin
  Result.Kind := bvBigDec; Result.S := UTF8String(V);
  Result.I64 := 0; Result.F64 := 0; SetLength(Result.Bytes, 0); Result.SqlType := 0;
end;

function BStr(const V: string): TBoundValue;
begin
  Result.Kind := bvStr; Result.S := UTF8String(V);
  Result.I64 := 0; Result.F64 := 0; SetLength(Result.Bytes, 0); Result.SqlType := 0;
end;

function BDate(const Iso: string): TBoundValue;
begin
  Result.Kind := bvDate; Result.S := UTF8String(Iso);
  Result.I64 := 0; Result.F64 := 0; SetLength(Result.Bytes, 0); Result.SqlType := 0;
end;

function BTime(const Iso: string): TBoundValue;
begin
  Result.Kind := bvTime; Result.S := UTF8String(Iso);
  Result.I64 := 0; Result.F64 := 0; SetLength(Result.Bytes, 0); Result.SqlType := 0;
end;

function BStamp(const Iso: string): TBoundValue;
begin
  Result.Kind := bvStamp; Result.S := UTF8String(Iso);
  Result.I64 := 0; Result.F64 := 0; SetLength(Result.Bytes, 0); Result.SqlType := 0;
end;

function BBytes(const V: TBytes): TBoundValue;
var
  i: Integer;
begin
  Result.Kind := bvBytes; Result.S := '';
  Result.I64 := 0; Result.F64 := 0; Result.SqlType := 0;
  SetLength(Result.Bytes, Length(V));
  for i := 0 to High(V) do
    Result.Bytes[i] := V[i];
end;

function BNull(SqlType: Integer): TBoundValue;
begin
  Result.Kind := bvNull; Result.SqlType := SqlType;
  Result.S := ''; Result.I64 := 0; Result.F64 := 0; SetLength(Result.Bytes, 0);
end;

constructor TJdbcCommand.Create(AEngine: TJdbcEngine; AConn: Int64);
begin
  inherited Create;
  if AEngine = nil then
    raise EJDBCError.CreateChain('engine required', 'HY000', 99, 'nil');
  CheckHandle('conn', AConn);
  FEngine := AEngine;
  FConn := AConn;
  FStmt := 0;
  FTimeoutSecs := 0;
end;

destructor TJdbcCommand.Destroy;
begin
  CloseStmt;
  inherited;
end;

procedure TJdbcCommand.CloseStmt;
begin
  if FStmt > 0 then
  begin
    try
      FEngine.Bridge.CloseStmt(FStmt);
    except
    end;
    FStmt := 0;
  end;
end;

procedure TJdbcCommand.SetSQL(const S: string);
var
  i: Integer;
  rw: TRewriteResult;
begin
  CloseStmt;
  FSql := S;
  rw := RewriteNamedParams(S);
  SetLength(FOrder, Length(rw.ParamOrder));
  for i := 0 to High(rw.ParamOrder) do
    FOrder[i] := rw.ParamOrder[i];
  FStmt := FEngine.Bridge.Prepare(FConn, UTF8String(rw.JdbcSql));
  CheckHandle('stmt', FStmt);
  if FTimeoutSecs > 0 then
    FEngine.Bridge.SetTimeout(FStmt, FTimeoutSecs);
end;

function TJdbcCommand.ParamOrder: TStringArray;
begin
  Result := Copy(FOrder, 0, Length(FOrder));
end;

function TJdbcCommand.JdbcSQL: string;
begin
  { Reserved for the prepared shape; use ParamOrder for binding order.
    Kept minimal on purpose: the rewrite result lives server-side in the
    prepared statement, Pascal never re-sends SQL strings per row. }
  Result := FSql;
end;

procedure TJdbcCommand.BindRow(const Row: TBoundRow);
var
  i: Integer;
  b: TBridge;
begin
  CheckHandle('stmt', FStmt);
  b := FEngine.Bridge;
  for i := 0 to High(Row) do
    case Row[i].Kind of
      bvInt: b.BindLong(FStmt, i + 1, Row[i].I64); // ftBoolean arrives as BInt(0/1) by CollectRow contract
      bvInt64: b.BindLong(FStmt, i + 1, Row[i].I64);
      bvDouble: b.BindDouble(FStmt, i + 1, Row[i].F64);
      bvBigDec: b.BindBigDecimal(FStmt, i + 1, Row[i].S);
      bvStr: b.BindString(FStmt, i + 1, Row[i].S);
      bvDate: b.BindDate(FStmt, i + 1, Row[i].S);
      bvTime: b.BindTime(FStmt, i + 1, Row[i].S);
      bvStamp: b.BindTimestamp(FStmt, i + 1, Row[i].S);
      bvBytes: b.BindBytes(FStmt, i + 1, Row[i].Bytes);
      bvNull: b.BindNull(FStmt, i + 1, Row[i].SqlType);
    end;
end;

function TJdbcCommand.ExecUpdate(const Row: TBoundRow): Integer;
begin
  CheckHandle('stmt', FStmt);
  BindRow(Row);
  Result := FEngine.Bridge.ExecUpdate(FStmt);
end;

function TJdbcCommand.ExecBatch(const Rows: array of TBoundRow; BatchSize: Integer): Integer;
var
  i, total, n, limit: Integer;
  cfg: TJdbcConfig;
begin
  CheckHandle('stmt', FStmt);
  cfg := TJdbcConfig.Default;
  try
    limit := cfg.Exec_BatchLimit;
  finally
    cfg.Free;
  end;
  if BatchSize < 1 then
    raise EJDBCError.CreateChain('bad batch size', 'HY092', 44, IntToStr(BatchSize));
  if BatchSize > limit then
    raise EJDBCError.CreateChain('bad batch size', 'HY092', 44, IntToStr(BatchSize));
  { BatchSize caps driver round trips: ExecBatch ships the whole addBatch
    set at once, so pre-split into BatchSize chunks. }
  Result := 0;
  i := 0;
  while i <= High(Rows) do
  begin
    total := 0;
    for n := i to i + BatchSize - 1 do
    begin
      if n > High(Rows) then
        Break;
      BindRow(Rows[n]);
      FEngine.Bridge.AddBatch(FStmt);
      Inc(total);
    end;
    Result := Result + FEngine.Bridge.ExecBatch(FStmt);
    i := i + total;
  end;
end;

function TJdbcCommand.LastInsertKeys: TJdbcRow;
begin
  CheckHandle('stmt', FStmt);
  Result := FEngine.Bridge.GeneratedKeys(FStmt);
end;

procedure TJdbcCommand.SetTimeout(Secs: Integer);
begin
  if Secs < 0 then
    raise EJDBCError.CreateChain('bad timeout', 'HY092', 20, 'timeout<0');
  FTimeoutSecs := Secs;
  if FStmt > 0 then
    FEngine.Bridge.SetTimeout(FStmt, Secs);
end;

procedure TJdbcCommand.Cancel;
begin
  CheckHandle('stmt', FStmt);
  FEngine.Bridge.Cancel(FStmt);
end;

end.
