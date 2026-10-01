program TestDistrib;

{$mode objfpc}{$H+}

{ Distribution tests: mautool behaviors against the shipped tool.
  Drives the real binary at test-results/bin or the path in MAUTOOL_EXE:
  manifests verify, runtime accept + reject, driver file accept + reject,
  fetch-driver deploy copy, cache-dir + license-flag surface in help/usage.
  Portable: repo paths derive from RepoRoot (walk-up from ParamStr(0));
  the third-party jars cache honors TYFPJDBC_LIBS; the runtime-accept sha
  comes from configs/runtimes.json, not a literal. No network calls. }

uses
  SysUtils, Classes, process, fpjson, jsonparser, TyFPJDBC.Driver.Fetch;

var
  Fails: Integer = 0;
  g, a, v: string;
  tmpD, srcSha, srcUrl: string;
  sl: TStringList;

procedure Ok(const N: string; C: Boolean);
begin
  if C then WriteLn('PASS ', N) else begin Inc(Fails); WriteLn('FAIL ', N); end;
end;

function RepoRoot: string;
var
  D, Prev: string;
  I: Integer;
begin
  { Walk up from the test binary (max 6 levels) for the repo anchor
    configs/runtimes.json; '' when not found (caller falls back). }
  Result := '';
  D := ExpandFileName(ExtractFileDir(ParamStr(0)));
  for I := 0 to 6 do
  begin
    if FileExists(IncludeTrailingPathDelimiter(D) + 'configs' + PathDelim + 'runtimes.json') then
      Exit(D);
    Prev := D;
    D := ExpandFileName(ExtractFileDir(Prev));
    if (D = '') or (D = Prev) then
      Exit('');
  end;
end;

function DriversConfig: string;
var
  R: string;
begin
  R := RepoRoot;
  if R <> '' then
    Result := IncludeTrailingPathDelimiter(R) + 'configs' + PathDelim + 'drivers.json'
  else
    Result := 'configs' + PathDelim + 'drivers.json';
end;

function RuntimesConfig: string;
var
  R: string;
begin
  R := RepoRoot;
  if R <> '' then
    Result := IncludeTrailingPathDelimiter(R) + 'configs' + PathDelim + 'runtimes.json'
  else
    Result := 'configs' + PathDelim + 'runtimes.json';
end;

function LibsDir: string;
begin
  { Third-party jars cache: per-machine/CI override via TYFPJDBC_LIBS,
    default is this host's cache dir. }
  Result := GetEnvironmentVariable('TYFPJDBC_LIBS');
  if Trim(Result) = '' then
    Result := 'C:\Tools\tyfpjdbc-libs';
end;

function Win64Sha256: string;
var
  j: TJSONData;
  arr: TJSONArray;
  i: Integer;
  s: TStringList;
begin
  { Expected win64 sha256 read from the runtimes manifest (the same JSON
    --verify-manifests checks), so rebuilds never rot this test. }
  Result := '';
  if not FileExists(RuntimesConfig) then
    Exit;
  s := TStringList.Create;
  try
    s.LoadFromFile(RuntimesConfig);
    j := GetJSON(s.Text);
  finally
    s.Free;
  end;
  try
    arr := TJSONObject(j).Arrays['runtimes'];
    for i := 0 to arr.Count - 1 do
      if arr.Objects[i].Strings['platform'] = 'win64' then
        Exit(LowerCase(Trim(arr.Objects[i].Strings['sha256'])));
  finally
    j.Free;
  end;
end;

function ToolExe: string;
var
  R: string;
begin
  { Committed-binary-first would pin stale builds; prefer the just-built
    scratch binary when present, else the repo test-results copy. }
  Result := GetEnvironmentVariable('MAUTOOL_EXE');
  if (Result <> '') and FileExists(Result) then
    Exit;
  R := RepoRoot;
  if R <> '' then
  begin
    Result := IncludeTrailingPathDelimiter(R) + 'test-results' + PathDelim +
      'bin' + PathDelim + 'mautool.exe';
    if FileExists(Result) then
      Exit;
  end;
  Result := 'test-results/bin/mautool.exe';
end;

function ZipsDir: string;
begin
  { Runtime zips cache: bootstrap once with
    Copy-Item <runtimes>\zips\*.zip here (same bytes),
    then mautool --fetch-runtime keeps it filled from the Release. }
  Result := GetEnvironmentVariable('TYFPJDBC_ZIPS');
  if Trim(Result) = '' then
    Result := GetEnvironmentVariable('USERPROFILE') + '\.tyfpjdbc\runtimes';
end;

function Run(const Args: string; out Outp: string; out Code: Integer): Boolean;
var
  P: TProcess;
  sl: TStringList;
  R: string;
begin
  Result := False;
  Outp := '';
  P := TProcess.Create(nil);
  try
    P.Executable := ToolExe;
    R := RepoRoot;
    if (R <> '') and DirectoryExists(R) then
      P.CurrentDirectory := R;
    P.Parameters.DelimitedText := Args;
    P.Options := [poWaitOnExit, poUsePipes, poStderrToOutPut];
    P.Execute;
    sl := TStringList.Create;
    try
      sl.LoadFromStream(P.Output);
      Outp := sl.Text;
    finally
      sl.Free;
    end;
    Code := P.ExitStatus;
    Result := True;
  finally
    P.Free;
  end;
end;

var
  outp: string;
  code: Integer;
  winSha: string;
begin
  Ok('gpl-gate', TDriverFetch.IsGplLicense('GPL-2'));
  Ok('lgpl-open', not TDriverFetch.IsGplLicense('LGPL-2.1'));
  Ok('bsd-open', not TDriverFetch.IsGplLicense('BSD-2-Clause'));
  Ok('maven-path', TDriverFetch.MavenPath('com.h2database:h2:2.2.224', g, a, v) =
    'com/h2database/h2/2.2.224/h2-2.2.224.jar');
  Ok('fetch-url', TDriverFetch.RuntimeAssetUrl('win64', 'runtime/jre25.0.4.1-bridge0.9.0') = 'https://github.com/ACTom/TyFPJDBC/releases/download/runtime/jre25.0.4.1-bridge0.9.0/jre-25-tyfpjdbc-win64.zip');
  Ok('dlargs-curl', TDriverFetch.DownloadArgs('curl', 'https://x/y.jar',
    'C:\t\f.tmp') = '-sL "https://x/y.jar" -o "C:\t\f.tmp"');
  Ok('dlargs-ps', TDriverFetch.DownloadArgs('powershell', 'https://x/y.jar',
    'C:\t\f.tmp') = '-NoProfile -Command Invoke-WebRequest ' +
    '-UseBasicParsing "https://x/y.jar" -OutFile "C:\t\f.tmp"');
  tmpD := IncludeTrailingPathDelimiter(GetTempDir) + 'tjfetchjar';
  ForceDirectories(tmpD);
  sl := TStringList.Create;
  try
    sl.Text := 'fetch-jar-fixture';
    sl.SaveToFile(tmpD + PathDelim + 'src.txt');
    srcSha := TDriverFetch.Sha1OfFile(tmpD + PathDelim + 'src.txt');
    srcUrl := 'file:///' + StringReplace(tmpD + PathDelim + 'src.txt',
      '\', '/', [rfReplaceAll]);
    try
      Ok('dl-mkdir', TDriverFetch.FetchJar(srcUrl, srcSha,
        tmpD + PathDelim + 'missing' + PathDelim + 'dst.txt') = frDownloaded);
    except
      on E: Exception do
        Ok('dl-mkdir(' + E.Message + ')', False);
    end;
    sl.LoadFromFile(tmpD + PathDelim + 'missing' + PathDelim + 'dst.txt');
    Ok('dl-mkdir-content', Trim(sl.Text) = 'fetch-jar-fixture');
  finally
    sl.Free;
  end;
  DeleteFile(tmpD + PathDelim + 'missing' + PathDelim + 'dst.txt');
  DeleteFile(tmpD + PathDelim + 'src.txt');
  RemoveDir(tmpD + PathDelim + 'missing');
  RemoveDir(tmpD);
  Run('--verify-manifests --config "' + DriversConfig + '"', outp, code);
  Ok('manifests', (code = 0) and (Pos('manifests verified', outp) > 0));
  winSha := Win64Sha256;
  Run('--verify-runtime --platform win64 --sha256 ' + winSha + ' --out "' + ZipsDir + '"', outp, code);
  Ok('runtime-accept', (winSha <> '') and (code = 0) and (Pos('VERIFIED', outp) > 0));
  Run('--verify-runtime --platform win64 --sha256 0000000000000000000000000000000000000000000000000000000000000000 --out "' + ZipsDir + '"', outp, code);
  Ok('runtime-reject', (code <> 0) and (Pos('MISMATCH', outp) > 0));
  Run('--verify-file --driver h2 --sha1 7bdade27d8cd197d9b5ce9dc251f41d2edc5f7ad --out "' + LibsDir + '"', outp, code);
  Ok('driver-accept', (code = 0) and (Pos('VERIFIED', outp) > 0));
  Run('--verify-file --driver h2 --sha1 0000000000000000000000000000000000000000 --out "' + LibsDir + '"', outp, code);
  Ok('driver-reject', (code <> 0) and (Pos('MISMATCH', outp) > 0));
  Run('--driver nosuch --out "' + IncludeTrailingPathDelimiter(GetTempDir) + 'tjnosuch"', outp, code);
  Ok('driver-unknown', (code <> 0) and (Pos('unknown driver', outp) > 0));
  Run('--fetch-driver h2 --out "' + tmpD + PathDelim + 'deploy"', outp, code);
  Ok('driver-deploy', (code = 0) and (Pos('deployed:', outp) > 0) and
    FileExists(tmpD + PathDelim + 'deploy' + PathDelim + 'h2-2.2.224.jar'));
  DeleteFile(tmpD + PathDelim + 'deploy' + PathDelim + 'h2-2.2.224.jar');
  RemoveDir(tmpD + PathDelim + 'deploy');
  WriteLn('TOTAL fails=', Fails);
  if Fails > 0 then Halt(1);
end.
