unit TyFPJDBC.Driver.Fetch;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

type
  TFetchResult = (frCacheHit, frDownloaded);

  { In-library driver fetch: download, verify sha1, atomic store.
    mautool is a thin shell over this; the design-time wizard calls it. }
  TDriverFetch = class
    class function IsGplLicense(const L: string): Boolean; static;
    class procedure SetMarkerDir(const D: string); static;
    class function CacheDir: string; static;
    class function LicenseMarkerFile(const DriverId: string): string; static;
    class function LicenseAccepted(const DriverId: string): Boolean; static;
    class procedure MarkLicenseAccepted(const DriverId: string); static;
    class function MavenPath(const Maven: string; out Group, Artifact, Ver: string): string; static;
    class function MavenURL(const Rel: string): string; static;
    class function Sha1OfFile(const P: string): string; static;
    class function DownloadArgs(const Exe, URL, OutTmp: string): string; static;
    class function FetchText(const URL: string): string; static;
    class function FetchJar(const URL, ExpectSha, Target: string): TFetchResult; static;
  end;

implementation

uses
  sha1, process;

var
  GMarkerDir: string;

class function TDriverFetch.IsGplLicense(const L: string): Boolean;
var
  u: string;
begin
  { LGPL is explicitly open; plain GPL and AGPL need the accept gate. }
  u := UpperCase(L);
  Result := (Pos('GPL', u) > 0) and (Pos('LGPL', u) = 0);
end;

class procedure TDriverFetch.SetMarkerDir(const D: string);
begin
  GMarkerDir := D;
end;

class function TDriverFetch.CacheDir: string;
begin
  Result := GetEnvironmentVariable('TYFPJDBC_CACHE');
  if Trim(Result) = '' then
    Result := IncludeTrailingPathDelimiter(GetEnvironmentVariable('USERPROFILE')) +
      '.tyfpjdbc' + PathDelim + 'cache';
  if not DirectoryExists(Result) then
    ForceDirectories(Result);
end;

class function TDriverFetch.LicenseMarkerFile(const DriverId: string): string;
var
  dir: string;
begin
  dir := GMarkerDir;
  if dir = '' then
    dir := CacheDir;
  Result := IncludeTrailingPathDelimiter(dir) + 'license-' +
    LowerCase(Trim(DriverId)) + '.accepted';
end;

class function TDriverFetch.LicenseAccepted(const DriverId: string): Boolean;
begin
  Result := FileExists(LicenseMarkerFile(DriverId));
end;

class procedure TDriverFetch.MarkLicenseAccepted(const DriverId: string);
var
  f: string;
  sl: TStringList;
begin
  f := LicenseMarkerFile(DriverId);
  ForceDirectories(ExtractFilePath(f));
  sl := TStringList.Create;
  try
    sl.Text := 'accepted ' + DateTimeToStr(Now);
    sl.SaveToFile(f);
  finally
    sl.Free;
  end;
end;

class function TDriverFetch.MavenPath(const Maven: string; out Group, Artifact, Ver: string): string;
var
  p1, p2: Integer;
begin
  Result := '';
  Group := '';
  Artifact := '';
  Ver := '';
  p1 := Pos(':', Maven);
  p2 := LastDelimiter(':', Maven);
  if (p1 = 0) or (p2 <= p1) then
    Exit;
  Group := Copy(Maven, 1, p1 - 1);
  Artifact := Copy(Maven, p1 + 1, p2 - p1 - 1);
  Ver := Copy(Maven, p2 + 1, MaxInt);
  if (Group = '') or (Artifact = '') or (Ver = '') then
  begin
    Group := '';
    Artifact := '';
    Ver := '';
    Exit;
  end;
  Result := StringReplace(Group, '.', '/', [rfReplaceAll]) + '/' + Artifact +
    '/' + Ver + '/' + Artifact + '-' + Ver + '.jar';
end;

class function TDriverFetch.MavenURL(const Rel: string): string;
begin
  Result := 'https://repo1.maven.org/maven2/' + Rel;
end;

class function TDriverFetch.Sha1OfFile(const P: string): string;
begin
  Result := LowerCase(SHA1Print(SHA1File(P)));
end;

function Downloader: string;
begin
  { Prefer curl where present; fall back to PowerShell Invoke-WebRequest so
    stock Windows without curl still works. No hard curl dependency. }
  if FileExists(GetEnvironmentVariable('SystemRoot') + '\System32\curl.exe') then
    Exit('curl');
  Result := 'powershell';
end;

class function TDriverFetch.DownloadArgs(const Exe, URL, OutTmp: string): string;
begin
  if Exe = 'powershell' then
    Result := '-NoProfile -Command Invoke-WebRequest -UseBasicParsing "' +
      Trim(URL) + '" -OutFile "' + OutTmp + '"'
  else
    Result := '-sL "' + Trim(URL) + '" -o "' + OutTmp + '"';
end;

function RunDownload(const Exe, Args: string): Boolean;
var
  P: TProcess;
begin
  { File downloaders write the file themselves (curl -o / -OutFile);
    never pipe stdout into it (that truncates the download), and never
    show a console window (poNoConsole kills the black flash). }
  Result := False;
  P := TProcess.Create(nil);
  try
    P.Executable := Exe;
    P.Parameters.DelimitedText := Args;
    P.Options := [poWaitOnExit, poNoConsole];
    P.Execute;
    Result := P.ExitStatus = 0;
  finally
    P.Free;
  end;
end;

function RunGet(const Exe, URL, OutFile: string): Boolean;
var
  final_: string;
begin
  Result := False;
  if Trim(URL) = '' then
    Exit(False);
  if OutFile = '' then
    Exit(RunDownload(Exe, TDriverFetch.DownloadArgs(Exe, URL,
      GetTempFileName('', 'mauout'))));
  if not RunDownload(Exe, TDriverFetch.DownloadArgs(Exe, URL,
    OutFile + '.tmp')) then
    Exit(False);
  { Atomic rename after successful download (no partial cache poison). }
  final_ := OutFile;
  if FileExists(final_) then
    DeleteFile(final_);
  Result := RenameFile(OutFile + '.tmp', final_);
end;

class function TDriverFetch.FetchText(const URL: string): string;
var
  tmp: string;
  sl: TStringList;
  dl: string;
begin
  Result := '';
  tmp := GetTempFileName('', 'mau');
  try
    dl := Downloader;
    if not RunGet(dl, URL, tmp) then
      raise Exception.Create('download failed: ' + URL);
    sl := TStringList.Create;
    try
      sl.LoadFromFile(tmp);
      Result := Trim(sl.Text);
    finally
      sl.Free;
    end;
  finally
    DeleteFile(tmp);
  end;
end;

class function TDriverFetch.FetchJar(const URL, ExpectSha, Target: string): TFetchResult;
var
  gotSha: string;
  dl: string;
begin
  if Trim(ExpectSha) = '' then
    raise Exception.Create('sha1 required for ' + Target);
  if FileExists(Target) then
  begin
    gotSha := Sha1OfFile(Target);
    if gotSha = LowerCase(Trim(ExpectSha)) then
      Exit(frCacheHit);
    raise Exception.Create('checksum MISMATCH for ' + Target);
  end;
  { Cache miss: download, verify, atomically store. Proxy comes from
    environment (https_proxy) via curl/powershell defaults. }
  dl := Downloader;
  if not RunGet(dl, URL, Target) then
    raise Exception.Create('download failed: ' + URL);
  gotSha := Sha1OfFile(Target);
  if gotSha <> LowerCase(Trim(ExpectSha)) then
  begin
    DeleteFile(Target);
    raise Exception.Create('checksum MISMATCH for ' + Target);
  end;
  Result := frDownloaded;
end;

end.
