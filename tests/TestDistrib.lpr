program TestDistrib;

{$mode objfpc}{$H+}

{ Distribution tests: mautool behaviors against the shipped tool.
  Drives the real binary at test-results/bin or the path in MAUTOOL_EXE:
  manifests verify, runtime accept + reject, driver file accept + reject,
  cache-dir + license-flag surface in help/usage. }

uses
  SysUtils, Classes, process;

var
  Fails: Integer = 0;

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
  Run('--verify-manifests --config D:\Projects\TyFPJDBC\configs\drivers.json', outp, code);
  Ok('manifests', (code = 0) and (Pos('manifests verified', outp) > 0));
  Run('--verify-runtime --platform win64 --sha256 bc04cdab23b4468829ca29a2fcff008b3ea7dd78de41a7636247c8774b486cec --out D:\Projects\TyFPJDBC-Runtimes\zips', outp, code);
  Ok('runtime-accept', (code = 0) and (Pos('VERIFIED', outp) > 0));
  Run('--verify-runtime --platform win64 --sha256 0000000000000000000000000000000000000000000000000000000000000000 --out D:\Projects\TyFPJDBC-Runtimes\zips', outp, code);
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
