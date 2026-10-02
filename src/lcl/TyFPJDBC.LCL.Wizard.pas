unit TyFPJDBC.LCL.Wizard;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, TyFPJDBC.Driver.Registry, TyFPJDBC.Driver.Fetch,
  TyFPJDBC.Config, TyFPJDBC.LCL.Conn;

type
  TJarState = (jsMissing, jsMismatch, jsReady);
  TFetchFunc = function(const URL, ExpectSha, Target: string): Boolean of object;
  TTestFunc = function(const DriverId, Url: string): Boolean of object;

  { Headless-capable wizard logic: the form is a thin view over this.
    Fetch/Test are injectable so tests run without network or IDE. }
  TJdbcDriverWizard = class
  private
    FDriverId, FHost, FDatabase, FUser, FPassword: string;
    FPort, FMaxPool, FLoginTimeoutSecs: Integer;
    FRoot: string;
    FMavenOverride: string;
    FTestedOk: Boolean;
    FOnFetch: TFetchFunc;
    FOnTest: TTestFunc;
    function DefaultFetch(const URL, ExpectSha, Target: string): Boolean;
    procedure SetDriverId(const V: string);
  public
    constructor Create;
    property DriverId: string read FDriverId write SetDriverId;
    property Host: string read FHost write FHost;
    property Port: Integer read FPort write FPort;
    property Database: string read FDatabase write FDatabase;
    property User: string read FUser write FUser;
    property Password: string read FPassword write FPassword;
    property MaxPool: Integer read FMaxPool write FMaxPool;
    property LoginTimeoutSecs: Integer read FLoginTimeoutSecs write FLoginTimeoutSecs;
    property Root: string read FRoot write FRoot;
    { Manual maven coordinates for the download dialog (custom drivers).
      Empty (default) uses the registry entry's Maven. }
    property MavenOverride: string read FMavenOverride write FMavenOverride;
    function MavenOverrideValid: Boolean;
    function EffectiveMaven(const Id: string): string;
    class function JvmDllInDir(const Dir: string): string; static;
    class function DriverTestClassPath(const ProjectDir: string): string; static;
    property OnFetch: TFetchFunc read FOnFetch write FOnFetch;
    property OnTest: TTestFunc read FOnTest write FOnTest;
    property TestedOk: Boolean read FTestedOk;
    function DriverIds: TDriverIdArray;
    function JarTarget(const Id: string): string;
    function JarState(const Id: string): TJarState;
    function Fetch(const Id: string; AcceptGpl: Boolean): Boolean;
    function Test: Boolean;
    function CanConfirm: Boolean;
    procedure ApplyTo(Conn: TJdbcConnection);
    class function BuildRegisterCode(const E: TDriverEntry): string; static;
  end;

implementation

constructor TJdbcDriverWizard.Create;
var
  cfg: TJdbcConfig;
begin
  inherited Create;
  cfg := TJdbcConfig.Default;
  try
    FDriverId := 'sqlite';
    FHost := '';
    FPort := 0;
    FDatabase := '';
    FUser := '';
    FPassword := '';
    FMaxPool := cfg.Pool_MaxPool;
    FLoginTimeoutSecs := 15;
  finally
    cfg.Free;
  end;
  FRoot := '';
  FMavenOverride := '';
  FTestedOk := False;
end;

procedure TJdbcDriverWizard.SetDriverId(const V: string);
begin
  if FDriverId <> V then
  begin
    FDriverId := V;
    FTestedOk := False;
    { A manual maven override belongs to the previous selection; never let
      a stale edit box poison the new driver (designer bug 2026-10-01). }
    FMavenOverride := '';
  end;
end;

function TJdbcDriverWizard.DriverIds: TDriverIdArray;
begin
  Result := TDriverRegistry.BuiltinIds;
end;

function TJdbcDriverWizard.JarTarget(const Id: string): string;
var
  e: TDriverEntry;
  grp, art, ver, dir, maven: string;
begin
  maven := EffectiveMaven(Id);
  dir := FRoot;
  if dir = '' then
    dir := ExtractFilePath(ParamStr(0));
  dir := IncludeTrailingPathDelimiter(dir) + 'drivers' + PathDelim;
  if maven = '' then
  begin
    { Custom driver without maven coordinates (or a malformed override):
      local jar named by id. Find still validates the id is known. }
    e := TDriverRegistry.Find(Id);
    Result := dir + e.Id + '.jar';
    Exit;
  end;
  TDriverFetch.MavenPath(maven, grp, art, ver);
  Result := dir + art + '-' + ver + '.jar';
end;

class function TJdbcDriverWizard.DriverTestClassPath(const ProjectDir: string): string;

  function JarList(const Sub: string): string;
  var
    base: string;
    sr: TSearchRec;
  begin
    Result := '';
    if Trim(ProjectDir) = '' then
      Exit;
    base := IncludeTrailingPathDelimiter(Trim(ProjectDir)) + Sub + PathDelim;
    if FindFirst(base + '*.jar', faAnyFile, sr) <> 0 then
      Exit;
    try
      repeat
        if (sr.Attr and faDirectory) = 0 then
        begin
          if Result <> '' then
            Result := Result + ';';
          Result := Result + base + sr.Name;
        end;
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
  end;

var
  b, d: string;
begin
  { Design-time Test classpath: the jars deployed beside the project
    (bridge/*.jar + drivers/*.jar). Order within a dir is filesystem
    order; callers needing determinism keep one jar per dir in tests. }
  Result := '';
  b := JarList('bridge');
  d := JarList('drivers');
  if b <> '' then
    Result := b;
  if d <> '' then
  begin
    if Result <> '' then
      Result := Result + ';';
    Result := Result + d;
  end;
end;

class function TJdbcDriverWizard.JvmDllInDir(const Dir: string): string;
var
  base, cand: string;
begin
  { Same three layouts as TJVMManager.FindLibJvm, rooted at an explicit
    directory (design-time search: picked dir, project dir, IDE dir). }
  Result := '';
  if Trim(Dir) = '' then
    Exit;
  base := IncludeTrailingPathDelimiter(Trim(Dir));
  cand := base + 'jre' + PathDelim + 'bin' + PathDelim + 'server' +
    PathDelim + 'jvm.dll';
  if FileExists(cand) then
    Exit(cand);
  cand := base + 'jre' + PathDelim + 'lib' + PathDelim + 'server' +
    PathDelim + 'libjvm.so';
  if FileExists(cand) then
    Exit(cand);
  cand := base + 'jre' + PathDelim + 'lib' + PathDelim + 'server' +
    PathDelim + 'libjvm.dylib';
  if FileExists(cand) then
    Exit(cand);
end;

function TJdbcDriverWizard.MavenOverrideValid: Boolean;
var
  grp, art, ver: string;
begin
  if Trim(FMavenOverride) = '' then
    Exit(True);
  Result := TDriverFetch.MavenPath(Trim(FMavenOverride), grp, art, ver) <> '';
end;

function TJdbcDriverWizard.EffectiveMaven(const Id: string): string;
var
  grp, art, ver: string;
begin
  Result := '';
  if Trim(FMavenOverride) <> '' then
  begin
    if TDriverFetch.MavenPath(Trim(FMavenOverride), grp, art, ver) = '' then
      Exit('');
    Exit(Trim(FMavenOverride));
  end;
  Result := TDriverRegistry.Find(Id).Maven;
end;

function TJdbcDriverWizard.JarState(const Id: string): TJarState;
var
  e: TDriverEntry;
  target, expect, side: string;
  sl: TStringList;
begin
  target := JarTarget(Id);
  if not FileExists(target) then
    Exit(jsMissing);
  e := TDriverRegistry.Find(Id);
  { The pinned Sha only applies to the entry's own coordinates; an
    override (or no maven at all) falls back to the sidecar file. }
  expect := '';
  if EffectiveMaven(Id) = e.Maven then
    expect := e.Sha;
  if expect = '' then
  begin
    side := target + '.sha1';
    if FileExists(side) then
    begin
      sl := TStringList.Create;
      try
        sl.LoadFromFile(side);
        expect := Trim(sl.Text);
      finally
        sl.Free;
      end;
    end;
  end;
  if expect = '' then
    Exit(jsReady);
  if LowerCase(TDriverFetch.Sha1OfFile(target)) = LowerCase(Trim(expect)) then
    Exit(jsReady);
  Result := jsMismatch;
end;

function TJdbcDriverWizard.DefaultFetch(const URL, ExpectSha, Target: string): Boolean;
begin
  try
    TDriverFetch.FetchJar(URL, ExpectSha, Target);
    Result := True;
  except
    Result := False;
  end;
end;

function TJdbcDriverWizard.Fetch(const Id: string; AcceptGpl: Boolean): Boolean;
var
  e: TDriverEntry;
  rel, grp, art, ver, url, sha, target: string;
  sl: TStringList;
begin
  Result := False;
  e := TDriverRegistry.Find(Id);
  if TDriverFetch.IsGplLicense(e.License) then
  begin
    if AcceptGpl then
      TDriverFetch.MarkLicenseAccepted(Id);
    if not TDriverFetch.LicenseAccepted(Id) then
      Exit(False);
  end;
  rel := TDriverFetch.MavenPath(EffectiveMaven(Id), grp, art, ver);
  if rel = '' then
    Exit(False);
  url := TDriverFetch.MavenURL(rel);
  sha := '';
  if EffectiveMaven(Id) = e.Maven then
    sha := e.Sha;
  if sha = '' then
    try
      sha := Trim(TDriverFetch.FetchText(url + '.sha1'));
    except
      sha := '';
    end;
  target := JarTarget(Id);
  ForceDirectories(ExtractFilePath(target));
  if Assigned(FOnFetch) then
    Result := FOnFetch(url, sha, target)
  else
    Result := DefaultFetch(url, sha, target);
  if Result then
  begin
    FTestedOk := False;
    if sha <> '' then
    begin
      sl := TStringList.Create;
      try
        sl.Text := LowerCase(sha);
        sl.SaveToFile(target + '.sha1');
      finally
        sl.Free;
      end;
    end;
  end;
end;

function TJdbcDriverWizard.Test: Boolean;
var
  url: string;
begin
  FTestedOk := False;
  if not Assigned(FOnTest) then
    Exit(False);
  try
    url := TDriverRegistry.BuildUrlNil(FDriverId, FHost, FPort, FDatabase);
  except
    Exit(False);
  end;
  FTestedOk := FOnTest(FDriverId, url);
  Result := FTestedOk;
end;

function TJdbcDriverWizard.CanConfirm: Boolean;
begin
  Result := FTestedOk and (JarState(FDriverId) = jsReady);
end;

procedure TJdbcDriverWizard.ApplyTo(Conn: TJdbcConnection);
begin
  Conn.DriverId := FDriverId;
  Conn.Host := FHost;
  Conn.Port := FPort;
  Conn.Database := FDatabase;
  Conn.User := FUser;
  Conn.Password := FPassword;
  Conn.MaxPool := FMaxPool;
  Conn.LoginTimeoutSecs := FLoginTimeoutSecs;
end;

class function TJdbcDriverWizard.BuildRegisterCode(const E: TDriverEntry): string;

  function Q(const S: string): string;
  begin
    Result := '''' + StringReplace(S, '''', '''''', [rfReplaceAll]) + '''';
  end;

  function PagingName(P: TPagingStyle): string;
  begin
    case P of
      psOffsetFetchNext: Result := 'psOffsetFetchNext';
      psOffsetFetchFirst: Result := 'psOffsetFetchFirst';
    else
      Result := 'psLimitOffset';
    end;
  end;

  function QuoteName(QS: TQuoteStyle): string;
  begin
    case QS of
      qsBacktick: Result := 'qsBacktick';
      qsBracket: Result := 'qsBracket';
    else
      Result := 'qsDouble';
    end;
  end;

  function KeyName(K: TKeyReturnStyle): string;
  begin
    if K = krReturning then
      Result := 'krReturning'
    else
      Result := 'krNone';
  end;

var
  L: TStringList;
begin
  { Paste-ready registration: call once at startup before Connect.
    Session registration inside the IDE does not survive restart. }
  L := TStringList.Create;
  try
    L.Add('{ Custom driver for TyFPJDBC: call once at startup before Connect. }');
    L.Add('uses TyFPJDBC.Driver.Registry;');
    L.Add('var');
    L.Add('  e: TDriverEntry;');
    L.Add('begin');
    L.Add('  e.Id := ' + Q(E.Id) + ';');
    L.Add('  e.DriverClass := ' + Q(E.DriverClass) + ';');
    L.Add('  e.UrlTemplate := ' + Q(E.UrlTemplate) + ';');
    L.Add('  e.DefaultPort := ' + IntToStr(E.DefaultPort) + ';');
    L.Add('  e.TestQuery := ' + Q(E.TestQuery) + ';');
    L.Add('  e.License := ' + Q(E.License) + ';');
    L.Add('  e.Maven := ' + Q(E.Maven) + ';');
    L.Add('  e.Sha := ' + Q(E.Sha) + ';');
    L.Add('  e.Embedded := ' + BoolToStr(E.Embedded, True) + ';');
    L.Add('  e.Paging := ' + PagingName(E.Paging) + ';');
    L.Add('  e.Quote := ' + QuoteName(E.Quote) + ';');
    L.Add('  e.KeyReturn := ' + KeyName(E.KeyReturn) + ';');
    L.Add('  e.ParamSep := ' + Q(E.ParamSep) + ';');
    L.Add('  SetLength(e.TypeAliases, 0);');
    L.Add('  TDriverRegistry.Register(e);');
    L.Add('end;');
    Result := L.Text;
  finally
    L.Free;
  end;
end;

end.
