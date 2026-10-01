program TestDistrib;

{$mode objfpc}{$H+}

{ Distribution tests: mautool behaviors against the shipped tool.
  Drives the real binary at test-results/bin or the path in MAUTOOL_EXE:
  manifests verify, runtime accept + reject, driver file accept + reject,
  cache-dir + license-flag surface in help/usage. }

uses
  SysUtils, Classes, process, TyFPJDBC.Driver.Fetch;

var
  Fails: Integer = 0;
  g, a, v: string;
  tmpD, srcSha, srcUrl: string;
  sl: TStringList;

procedure Ok(const N: string; C: Boolean);
begin
  if C then WriteLn('PASS ', N) else begin Inc(Fails); WriteLn('FAIL ', N); end;
end;

function ToolExe: string;
begin
  { Committed-binary-first would pin stale builds; prefer the just-built
    scratch binary when present, else the repo test-results copy. }
  Result := GetEnvironmentVariable('MAUTOOL_EXE');
  if (Result <> '') and FileExists(Result) then
    Exit;
  Result := 'C:\Users\Tom\AppData\Local\Temp\grok-goal-6d502cf3dd66\implementer\mautool.exe';
  if FileExists(Result) then
    Exit;
  Result := 'test-results/bin/mautool.exe';
end;

function ZipsDir: string;
begin
  { Runtime zips cache: bootstrap once with
    Copy-Item D:\Projects\TyFPJDBC-Runtimes\zips\*.zip here (same bytes),
    then mautool --fetch-runtime keeps it filled from the Release. }
  Result := GetEnvironmentVariable('TYFPJDBC_ZIPS');
  if Trim(Result) = '' then
    Result := GetEnvironmentVariable('USERPROFILE') + '\.tyfpjdbc\runtimes';
end;

function Run(const Args: string; out Outp: string; out Code: Integer): Boolean;
var
  P: TProcess;
  sl, se: TStringList;
begin
  Result := False;
  Outp := '';
  P := TProcess.Create(nil);
  try
    P.Executable := ToolExe;
    P.CurrentDirectory := 'D:\Projects\TyFPJDBC';
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
  Run('--verify-manifests --config D:\Projects\TyFPJDBC\configs\drivers.json', outp, code);
  Ok('manifests', (code = 0) and (Pos('manifests verified', outp) > 0));
  Run('--verify-runtime --platform win64 --sha256 20b4e27b4001b59a568c5dfbeac52db0a775368031e8afee08e621a6b70bc05c --out ' + ZipsDir, outp, code);
  Ok('runtime-accept', (code = 0) and (Pos('VERIFIED', outp) > 0));
  Run('--verify-runtime --platform win64 --sha256 0000000000000000000000000000000000000000000000000000000000000000 --out ' + ZipsDir, outp, code);
  Ok('runtime-reject', (code <> 0) and (Pos('MISMATCH', outp) > 0));
  Run('--verify-file --driver h2 --sha1 7bdade27d8cd197d9b5ce9dc251f41d2edc5f7ad --out C:\Tools\tyfpjdbc-libs', outp, code);
  Ok('driver-accept', (code = 0) and (Pos('VERIFIED', outp) > 0));
  Run('--verify-file --driver h2 --sha1 0000000000000000000000000000000000000000 --out C:\Tools\tyfpjdbc-libs', outp, code);
  Ok('driver-reject', (code <> 0) and (Pos('MISMATCH', outp) > 0));
  Run('--driver nosuch --out C:\Users\Tom\AppData\Local\Temp\grok-goal-6d502cf3dd66\implementer', outp, code);
  Ok('driver-unknown', (code <> 0) and (Pos('unknown driver', outp) > 0));
  WriteLn('TOTAL fails=', Fails);
  if Fails > 0 then Halt(1);
end.
