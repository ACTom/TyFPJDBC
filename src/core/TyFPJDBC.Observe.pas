unit TyFPJDBC.Observe;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes;

type
  TLogLevel = (llDebug, llInfo, llWarn, llError);
  TLogProc = procedure(Level: TLogLevel; const Msg: string) of object;

  { Observability: explicit log sink, slow-query timing at the call site,
    structured pool/exec snapshots. No globals: one instance per engine. }
  TJdbcLogger = class
  private
    FOnLog: TLogProc;
  public
    procedure SetSink(P: TLogProc);
    procedure Log(Level: TLogLevel; const Msg: string);
  end;

  TExecStat = record
    Name: UTF8String;
    ElapsedMs: Int64;
    Slow: Boolean;
    Level: Integer;
  end;

  TJdbcObserve = class
  private
    FLogger: TJdbcLogger;
    FSlowWarnMs: Int64;
    FSlowErrorMs: Int64;
    FSampleEvery: Integer;
    FSampled: Integer;
    FExecs: array of TExecStat;
    function LevelOf(ElapsedMs: Int64): Integer;
  public
    constructor Create(ALogger: TJdbcLogger);
    property SlowThresholdMs: Int64 read FSlowWarnMs write FSlowWarnMs;
    property SlowWarnMs: Int64 read FSlowWarnMs write FSlowWarnMs;
    property SlowErrorMs: Int64 read FSlowErrorMs write FSlowErrorMs;
    property SampleEvery: Integer read FSampleEvery write FSampleEvery;
    function Timed(const Name: UTF8String; ElapsedMs: Int64): Boolean;
    function SlowCount: Integer;
    function ErrorCount: Integer;
    function ExecCount: Integer;
    function P95Ms: Int64;
    property Logger: TJdbcLogger read FLogger;
  end;

implementation

uses
  TyFPJDBC.Config;

procedure TJdbcLogger.SetSink(P: TLogProc);
begin
  FOnLog := P;
end;

procedure TJdbcLogger.Log(Level: TLogLevel; const Msg: string);
begin
  if Assigned(FOnLog) then
    FOnLog(Level, Msg);
end;

constructor TJdbcObserve.Create(ALogger: TJdbcLogger);
var
  cfg: TJdbcConfig;
begin
  inherited Create;
  FLogger := ALogger;
  cfg := TJdbcConfig.Default;
  try
    FSlowWarnMs := cfg.Obs_SlowWarnMs;
    FSlowErrorMs := cfg.Obs_SlowErrorMs;
    FSampleEvery := cfg.Obs_SampleEvery;
  finally
    cfg.Free;
  end;
  FSampled := 0;
  SetLength(FExecs, 0);
end;

function TJdbcObserve.LevelOf(ElapsedMs: Int64): Integer;
begin
  if (FSlowErrorMs > 0) and (ElapsedMs >= FSlowErrorMs) then
    Exit(2);
  if (FSlowWarnMs > 0) and (ElapsedMs >= FSlowWarnMs) then
    Exit(1);
  Result := 0;
end;

function TJdbcObserve.Timed(const Name: UTF8String; ElapsedMs: Int64): Boolean;
var
  n: Integer;
begin
  Inc(FSampled);
  if (FSampleEvery > 1) and (FSampled mod FSampleEvery <> 1) then
  begin
    Result := LevelOf(ElapsedMs) > 0;
    Exit;
  end;
  n := Length(FExecs);
  SetLength(FExecs, n + 1);
  FExecs[n].Name := Name;
  FExecs[n].ElapsedMs := ElapsedMs;
  FExecs[n].Level := LevelOf(ElapsedMs);
  FExecs[n].Slow := FExecs[n].Level > 0;
  Result := FExecs[n].Slow;
  if FExecs[n].Slow and (FLogger <> nil) then
    FLogger.Log(llWarn, 'slow: ' + string(Name) + ' ms=' + IntToStr(ElapsedMs));
end;

function TJdbcObserve.SlowCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FExecs) do
    if FExecs[i].Slow then
      Inc(Result);
end;

function TJdbcObserve.ExecCount: Integer;
begin
  Result := Length(FExecs);
end;

function TJdbcObserve.ErrorCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FExecs) do
    if FExecs[i].Level >= 2 then
      Inc(Result);
end;

function TJdbcObserve.P95Ms: Int64;
var
  vals: array of Int64;
  i, j: Integer;
  tmp: Int64;
begin
  if Length(FExecs) = 0 then
    Exit(0);
  SetLength(vals, Length(FExecs));
  for i := 0 to High(FExecs) do
    vals[i] := FExecs[i].ElapsedMs;
  for i := 1 to High(vals) do
    for j := i downto 1 do
    begin
      if vals[j] >= vals[j - 1] then
        Break;
      tmp := vals[j];
      vals[j] := vals[j - 1];
      vals[j - 1] := tmp;
    end;
  Result := vals[(95 * Length(vals)) div 100];
  if Result < 0 then
    Result := 0;
end;

end.
