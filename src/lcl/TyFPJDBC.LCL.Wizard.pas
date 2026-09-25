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
  FTestedOk := False;
end;

procedure TJdbcDriverWizard.SetDriverId(const V: string);
begin
  if FDriverId <> V then
  begin
    FDriverId := V;
    FTestedOk := False;
  end;
end;

function TJdbcDriverWizard.DriverIds: TDriverIdArray;
begin
  Result := TDriverRegistry.BuiltinIds;
end;

function TJdbcDriverWizard.JarTarget(const Id: string): string;
var
  e: TDriverEntry;
  grp, art, ver, dir: string;
begin
  e := TDriverRegistry.Find(Id);
  TDriverFetch.MavenPath(e.Maven, grp, art, ver);
  dir := FRoot;
  if dir = '' then
    dir := ExtractFilePath(ParamStr(0));
  Result := IncludeTrailingPathDelimiter(dir) + 'drivers' + PathDelim +
    art + '-' + ver + '.jar';
end;

function TJdbcDriverWizard.JarState(const Id: string): TJarState;
var
  target, expect, side: string;
  sl: TStringList;
begin
  target := JarTarget(Id);
  if not FileExists(target) then
    Exit(jsMissing);
  expect := TDriverRegistry.Find(Id).Sha;
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
  rel := TDriverFetch.MavenPath(e.Maven, grp, art, ver);
  if rel = '' then
    Exit(False);
  url := TDriverFetch.MavenURL(rel);
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

end.
