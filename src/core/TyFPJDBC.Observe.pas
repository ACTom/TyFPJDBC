unit TyFPJDBC.Observe;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes;

type
  TLogLevel = (llDebug, llInfo, llWarn, llError);
  TLogProc = procedure(Level: TLogLevel; const Msg: string) of object;

  { V2 observability: explicit log sink, slow-query timing at the call site,
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
  end;

  TJdbcObserve = class
  private
    FLogger: TJdbcLogger;
    FSlowThresholdMs: Int64;
    FExecs: array of TExecStat;
  public
    constructor Create(ALogger: TJdbcLogger);
    property SlowThresholdMs: Int64 read FSlowThresholdMs write FSlowThresholdMs;
    function Timed(const Name: UTF8String; ElapsedMs: Int64): Boolean;
    function SlowCount: Integer;
    function ExecCount: Integer;
    property Logger: TJdbcLogger read FLogger;
  end;

implementation

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
begin
  inherited Create;
  FLogger := ALogger;
  FSlowThresholdMs := 1000;
  SetLength(FExecs, 0);
end;

function TJdbcObserve.Timed(const Name: UTF8String; ElapsedMs: Int64): Boolean;
var
  n: Integer;
begin
  n := Length(FExecs);
  SetLength(FExecs, n + 1);
  FExecs[n].Name := Name;
  FExecs[n].ElapsedMs := ElapsedMs;
  FExecs[n].Slow := (FSlowThresholdMs > 0) and (ElapsedMs >= FSlowThresholdMs);
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

end.
