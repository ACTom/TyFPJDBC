program mautool;
{$mode objfpc}{$H+}
uses
  SysUtils, Classes, process, fpjson, jsonparser, TyFPJDBC.Driver.Fetch;

procedure Fail(const M: string);
begin
  WriteLn(StdErr, 'ERROR ', M);
  Halt(1);
end;

function LoadJSON(const P: string): TJSONData;
var
  s: TStringList;
begin
  if not FileExists(P) then
    Fail('missing ' + P);
  s := TStringList.Create;
  try
    s.LoadFromFile(P);
    Result := GetJSON(s.Text);
  finally
    s.Free;
  end;
end;

function ReqStr(O: TJSONObject; const K: string): string;
var
  d: TJSONData;
begin
  d := O.Find(K);
  if (d = nil) or (d.JSONType <> jtString) then
    Fail('missing string field ' + K);
  Result := d.AsString;
end;

procedure CmdList(const Cfg: string);
var
  j: TJSONData;
  arr: TJSONArray;
  i: Integer;
  o: TJSONObject;
begin
  j := LoadJSON(Cfg);
  try
    arr := TJSONObject(j).Arrays['drivers'];
    for i := 0 to arr.Count - 1 do
    begin
      o := arr.Objects[i];
      WriteLn(o.Strings['id'], ' | ', o.Strings['maven'], ' | ', o.Strings['driverClass']);
    end;
  finally
    j.Free;
  end;
end;

procedure NeedLicense(const DriverId, License: string; var AcceptFlag: Boolean);
var
  ans: string;
begin
  if not TDriverFetch.IsGplLicense(License) then
    Exit;
  if AcceptFlag then
    Exit;
  if TDriverFetch.LicenseAccepted(DriverId) then
    Exit;
  Write('Driver ', DriverId, ' is ', License,
    '. Type ACCEPT to download: ');
  ReadLn(ans);
  if UpperCase(Trim(ans)) <> 'ACCEPT' then
    Fail('license not accepted for ' + DriverId);
  TDriverFetch.MarkLicenseAccepted(DriverId);
end;

function RunCapture(const Exe, Args: string; out Output: string): Boolean;
var
  P: TProcess;
  sl: TStringList;
begin
  Result := False;
  Output := '';
  P := TProcess.Create(nil);
  try
    P.Executable := Exe;
    P.Parameters.DelimitedText := Args;
    P.Options := [poWaitOnExit, poUsePipes];
    P.Execute;
    sl := TStringList.Create;
    try
      sl.LoadFromStream(P.Output);
      Output := sl.Text;
    finally
      sl.Free;
    end;
    Result := P.ExitStatus = 0;
  finally
    P.Free;
  end;
end;

procedure CmdDriver(const Cfg, Id, OutDir: string; AcceptLicense: Boolean);
var
  j: TJSONData;
  arr: TJSONArray;
  i: Integer;
  o: TJSONObject;
  maven, grp, art, ver, rel, url, target, expectSha, gotSha: string;
begin
  j := LoadJSON(Cfg);
  try
    arr := TJSONObject(j).Arrays['drivers'];
    o := nil;
    for i := 0 to arr.Count - 1 do
      if arr.Objects[i].Strings['id'] = Id then
        o := arr.Objects[i];
    if o = nil then
      Fail('unknown driver ' + Id);
    NeedLicense(Id, o.Strings['license'], AcceptLicense);
    maven := ReqStr(o, 'maven');
    rel := TDriverFetch.MavenPath(maven, grp, art, ver);
    if rel = '' then
      Fail('bad maven coordinate ' + maven);
    url := TDriverFetch.MavenURL(rel);
    target := IncludeTrailingPathDelimiter(OutDir) + art + '-' + ver + '.jar';
    if (OutDir = 'drivers') or (Trim(OutDir) = '') then
      target := TDriverFetch.CacheDir + PathDelim + art + '-' + ver + '.jar';
    WriteLn('driver: ', ReqStr(o, 'id'));
    WriteLn('cache: ', target);
    WriteLn('maven: ', maven);
    WriteLn('url: ', url);
    WriteLn('expected-path: ', target);
    WriteLn('driverClass: ', ReqStr(o, 'driverClass'));
    WriteLn('urlTemplate: ', ReqStr(o, 'urlTemplate'));
    WriteLn('testQuery: ', ReqStr(o, 'testQuery'));
    expectSha := '';
    if o.Find('sha1') <> nil then
      expectSha := o.Strings['sha1'];
    if expectSha = '' then
    begin
      expectSha := TDriverFetch.FetchText(url + '.sha1');
      WriteLn('upstream-sha1: ', expectSha);
    end
    else
      WriteLn('manifest-sha1: ', expectSha);
    if FileExists(target) then
    begin
      gotSha := TDriverFetch.Sha1OfFile(target);
      WriteLn('local-sha1: ', gotSha);
      if gotSha = LowerCase(Trim(expectSha)) then
        WriteLn('checksum: VERIFIED (cache hit)')
      else
        Fail('checksum MISMATCH for ' + target);
    end
    else
    begin
      { Cache miss: download, verify, atomically store. Proxy comes from
        environment (https_proxy) via curl/powershell defaults. }
      WriteLn('cache: MISS, downloading...');
      try
        if TDriverFetch.FetchJar(url, expectSha, target) = frDownloaded then
          WriteLn('checksum: VERIFIED (downloaded)')
        else
          WriteLn('checksum: VERIFIED (cache hit)');
      except
        on E: Exception do
          Fail(E.Message);
      end;
      gotSha := TDriverFetch.Sha1OfFile(target);
      WriteLn('local-sha1: ', gotSha);
    end;
  finally
    j.Free;
  end;
end;

procedure CmdVerifyFile(const Cfg, Id, OutDir, ExpectSha: string);
var
  j: TJSONData;
  arr: TJSONArray;
  i: Integer;
  o: TJSONObject;
  maven, grp, art, ver, rel, target, gotSha: string;
begin
  j := LoadJSON(Cfg);
  try
    arr := TJSONObject(j).Arrays['drivers'];
    o := nil;
    for i := 0 to arr.Count - 1 do
      if arr.Objects[i].Strings['id'] = Id then
        o := arr.Objects[i];
    if o = nil then
      Fail('unknown driver ' + Id);
    maven := ReqStr(o, 'maven');
    rel := TDriverFetch.MavenPath(maven, grp, art, ver);
    if rel = '' then
      Fail('bad maven coordinate ' + maven);
    target := IncludeTrailingPathDelimiter(OutDir) + art + '-' + ver + '.jar';
    if not FileExists(target) then
      Fail('file not present: ' + target);
    gotSha := TDriverFetch.Sha1OfFile(target);
    WriteLn('file: ', target);
    WriteLn('expected-sha1: ', LowerCase(Trim(ExpectSha)));
    WriteLn('actual-sha1: ', gotSha);
    if gotSha <> LowerCase(Trim(ExpectSha)) then
      Fail('checksum MISMATCH');
    WriteLn('checksum: VERIFIED');
  finally
    j.Free;
  end;
end;

procedure CheckDrivers(const Cfg: string);
var
  j: TJSONData;
  arr: TJSONArray;
  i: Integer;
  o: TJSONObject;
  need: array[0..13] of string = ('id', 'displayName', 'maven', 'driverClass',
    'urlTemplate', 'testQuery', 'license', 'upstreamSyncVersion',
    'embedded', 'paging', 'quote', 'keyReturn', 'paramSep', 'typeAliases');
  k: Integer;
begin
  j := LoadJSON(Cfg);
  try
    arr := TJSONObject(j).Arrays['drivers'];
    if arr.Count = 0 then Fail('no drivers');
    for i := 0 to arr.Count - 1 do
    begin
      o := arr.Objects[i];
      for k := 0 to High(need) do
        if o.Find(need[k]) = nil then
          Fail('driver[' + IntToStr(i) + '] missing ' + need[k]);
      if (o.Strings['paging'] <> 'limit-offset') and
        (o.Strings['paging'] <> 'offset-fetch-next') and
        (o.Strings['paging'] <> 'offset-fetch-first') then
        Fail('driver[' + IntToStr(i) + '] bad paging');
      if (o.Strings['quote'] <> 'double') and
        (o.Strings['quote'] <> 'backtick') and
        (o.Strings['quote'] <> 'bracket') then
        Fail('driver[' + IntToStr(i) + '] bad quote');
      if (o.Strings['keyReturn'] <> 'none') and
        (o.Strings['keyReturn'] <> 'returning') then
        Fail('driver[' + IntToStr(i) + '] bad keyReturn');
      if (o.Strings['paramSep'] <> '&') and
        (o.Strings['paramSep'] <> ';') then
        Fail('driver[' + IntToStr(i) + '] bad paramSep');
    end;
    WriteLn('drivers ok: ', arr.Count);
  finally
    j.Free;
  end;
end;

function CertHashLine(const P: string): string;
var
  outp: string;
  sl: TStringList;
  i: Integer;
  line: string;
begin
  Result := '';
  if not RunCapture('certutil', '-hashfile "' + P + '" SHA256', outp) then
    Exit;
  sl := TStringList.Create;
  try
    sl.Text := outp;
    for i := 0 to sl.Count - 1 do
    begin
      line := LowerCase(StringReplace(Trim(sl[i]), ' ', '', [rfReplaceAll]));
      if (Length(line) = 64) then
      begin
        Result := line;
        Exit;
      end;
    end;
  finally
    sl.Free;
  end;
end;

function PowerShellHashLine(const Shell, P: string): string;
var
  outp: string;
begin
  Result := '';
  if not RunCapture(Shell,
    '-NoProfile -Command "(Get-FileHash -LiteralPath ''' + P +
    ''' -Algorithm SHA256).Hash.ToLower()"', outp) then
    Exit;
  Result := LowerCase(Trim(outp));
end;

function Sha256OfFile(const P: string): string;
begin
  Result := CertHashLine(P);
  if Length(Result) = 64 then
    Exit;
  Result := PowerShellHashLine(
    'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe', P);
  if Length(Result) = 64 then
    Exit;
  Result := PowerShellHashLine('pwsh', P);
  if Length(Result) = 64 then
    Exit;
  Fail('sha256 failed for ' + P);
end;

procedure CmdVerifyRuntime(const Cfg, Platform, Dir, ExpectSha: string);
var
  j: TJSONData;
  arr: TJSONArray;
  i: Integer;
  o: TJSONObject;
  asset, target, gotSha: string;
begin
  j := LoadJSON(Cfg);
  try
    arr := TJSONObject(j).Arrays['runtimes'];
    o := nil;
    for i := 0 to arr.Count - 1 do
      if arr.Objects[i].Strings['platform'] = Platform then
        o := arr.Objects[i];
    if o = nil then
      Fail('unknown platform ' + Platform);
    asset := 'jre-25-tyfpjdbc-' + Platform + '.zip';
    target := IncludeTrailingPathDelimiter(Dir) + asset;
    if not FileExists(target) then
      Fail('runtime zip not present: ' + target);
    gotSha := Sha256OfFile(target);
    WriteLn('runtime: ', asset);
    WriteLn('file: ', target);
    WriteLn('manifest-sha256: ', LowerCase(Trim(ExpectSha)));
    WriteLn('actual-sha256: ', gotSha);
    if gotSha <> LowerCase(Trim(ExpectSha)) then
      Fail('checksum MISMATCH');
    WriteLn('checksum: VERIFIED');
  finally
    j.Free;
  end;
end;

procedure CheckRuntimes(const Cfg: string);
var
  j: TJSONData;
  arr: TJSONArray;
  i: Integer;
  o: TJSONObject;
  hx, c: Integer;
  s, b: string;
  up, pk: Int64;
begin
  j := LoadJSON(Cfg);
  try
    arr := TJSONObject(j).Arrays['runtimes'];
    if arr.Count <> 5 then Fail('want 5 runtimes');
    for i := 0 to arr.Count - 1 do
    begin
      o := arr.Objects[i];
      ReqStr(o, 'platform');
      ReqStr(o, 'jdkVersion');
      if o.Strings['bridgeVersion'] <> '0.9.0' then
        Fail('bridgeVersion mismatch');
      ReqStr(o, 'url');
      s := ReqStr(o, 'sha256');
      if (Length(s) = 64) then
      begin
        s := LowerCase(Trim(s));
        for hx := 1 to Length(s) do
        begin
          c := Ord(s[hx]);
          if not (((c >= Ord('0')) and (c <= Ord('9'))) or ((c >= Ord('a')) and (c <= Ord('f')))) then
            Fail('runtime[' + o.Strings['platform'] + '] sha256 must be hex');
        end;
      end
      else if (Pos('_SHA256_FROM_RELEASE', UpperCase(s)) > 0) then
      begin
        if o.Find('verifiedNote') = nil then
          Fail('runtime[' + o.Strings['platform'] + '] pending sha256 needs verifiedNote');
        WriteLn('runtime[' + o.Strings['platform'] + '] sha256 pending CI build (token kept)');
      end
      else
        Fail('runtime[' + o.Strings['platform'] + '] sha256 must be 64 hex chars or a _SHA256_FROM_RELEASE token: ' + s);
      b := ReqStr(o, 'build');
      if o.Find('unpackedBytes') = nil then
        Fail('runtime[' + o.Strings['platform'] + '] missing unpackedBytes');
      if o.Find('packedBytes') = nil then
        Fail('runtime[' + o.Strings['platform'] + '] missing packedBytes');
      up := o.Int64s['unpackedBytes'];
      pk := o.Int64s['packedBytes'];
      if b <> 'jlink-trimmed-9-modules' then
        Fail('runtime[' + o.Strings['platform'] + '] build must be jlink-trimmed-9-modules, got: ' + b);
      if up > 83886080 then
        Fail('runtime[' + o.Strings['platform'] + '] trimmed unpackedBytes over 80MB budget');
      if pk > 52428800 then
        Fail('runtime[' + o.Strings['platform'] + '] trimmed packedBytes over 50MB budget');
      ReqStr(o, 'verifiedNote');
    end;
    WriteLn('runtimes ok: ', arr.Count);
  finally
    j.Free;
  end;
end;

var
  mode, cfg, id, outd, rcfg, sha, plat: string;
  acceptLicense: Boolean;
  i: Integer;
begin
  mode := '';
  cfg := 'configs/drivers.json';
  rcfg := 'configs/runtimes.json';
  id := '';
  outd := 'drivers';
  sha := '';
  plat := '';
  acceptLicense := False;
  i := 1;
  while i <= ParamCount do
  begin
    if ParamStr(i) = '--list' then mode := 'list'
    else if ParamStr(i) = '--driver' then begin Inc(i); id := ParamStr(i); if mode = '' then mode := 'driver'; end
    else if ParamStr(i) = '--fetch-driver' then begin Inc(i); id := ParamStr(i); mode := 'driver'; end
    else if ParamStr(i) = '--resolve-runtime' then mode := 'verifyruntime'
    else if ParamStr(i) = '--accept-license' then acceptLicense := True
    else if ParamStr(i) = '--out' then begin Inc(i); outd := ParamStr(i); end
    else if ParamStr(i) = '--sha1' then begin Inc(i); sha := ParamStr(i); end
    else if ParamStr(i) = '--sha256' then begin Inc(i); sha := ParamStr(i); end
    else if ParamStr(i) = '--config' then begin Inc(i); cfg := ParamStr(i);
      rcfg := IncludeTrailingPathDelimiter(ExtractFilePath(cfg)) + 'runtimes.json'; end
    else if ParamStr(i) = '--verify-manifests' then mode := 'verify'
    else if ParamStr(i) = '--verify-file' then mode := 'verifyfile'
    else if ParamStr(i) = '--verify-runtime' then mode := 'verifyruntime'
    else if ParamStr(i) = '--platform' then begin Inc(i); plat := ParamStr(i); end;
    Inc(i);
  end;
  if mode = 'list' then CmdList(cfg)
  else if mode = 'driver' then begin if id = '' then Fail('--driver needs id'); CmdDriver(cfg, id, outd, acceptLicense); end
  else if mode = 'verify' then begin CheckDrivers(cfg); CheckRuntimes(rcfg); WriteLn('manifests verified'); end
  else if mode = 'verifyfile' then
  begin
    if (id = '') or (sha = '') then Fail('--verify-file needs --driver <id> --sha1 <hex>');
    CmdVerifyFile(cfg, id, outd, sha);
  end
  else if mode = 'verifyruntime' then
  begin
    if (plat = '') or (sha = '') then Fail('--verify-runtime needs --platform <p> --sha256 <hex> [--out <dir>]');
    CmdVerifyRuntime(rcfg, plat, outd, sha);
  end
  else begin WriteLn('usage: mautool --list | --driver <id> --out <dir> | --fetch-driver <id> [--accept-license] | --verify-file --driver <id> --sha1 <hex> --out <dir> | --resolve-runtime --platform <p> --sha256 <hex> --out <dir> | --verify-runtime --platform <p> --sha256 <hex> --out <dir> | --verify-manifests'); Halt(2); end;
end.
