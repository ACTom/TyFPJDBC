program mautool;
{$mode objfpc}{$H+}
uses
  SysUtils, Classes, fpjson, jsonparser, sha1;

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

function MavenPath(const Maven: string; out Group, Artifact, Ver: string): string;
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
    Fail('bad maven coordinate ' + Maven);
  Group := Copy(Maven, 1, p1 - 1);
  Artifact := Copy(Maven, p1 + 1, p2 - p1 - 1);
  Ver := Copy(Maven, p2 + 1, MaxInt);
  Result := StringReplace(Group, '.', '/', [rfReplaceAll]) + '/' + Artifact +
    '/' + Ver + '/' + Artifact + '-' + Ver + '.jar';
end;

function MavenURL(const Rel: string): string;
begin
  Result := 'https://repo1.maven.org/maven2/' + Rel;
end;

function Downloader: string;
begin
  Result := 'curl.exe';
end;

function RunGet(const Exe, Args, OutFile: string): Boolean;
var
  code: Integer;
begin
  if OutFile = '' then
    code := ExecuteProcess(Exe, Args, [])
  else
    code := ExecuteProcess(Exe, Args + ' -o "' + OutFile + '"', []);
  Result := code = 0;
end;

function FetchText(const URL: string): string;
var
  tmp: string;
  sl: TStringList;
begin
  Result := '';
  tmp := GetTempFileName('', 'mau');
  try
    if not RunGet(Downloader, '-sL "' + URL + '"', tmp) then
      Fail('download failed: ' + URL);
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

procedure CmdDriver(const Cfg, Id, OutDir: string);
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
    maven := ReqStr(o, 'maven');
    rel := MavenPath(maven, grp, art, ver);
    url := MavenURL(rel);
    target := IncludeTrailingPathDelimiter(OutDir) + art + '-' + ver + '.jar';
    WriteLn('driver: ', ReqStr(o, 'id'));
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
      expectSha := FetchText(url + '.sha1');
      WriteLn('upstream-sha1: ', expectSha);
    end
    else
      WriteLn('manifest-sha1: ', expectSha);
    if FileExists(target) then
    begin
      gotSha := LowerCase(SHA1Print(SHA1File(target)));
      WriteLn('local-sha1: ', gotSha);
      if gotSha = LowerCase(Trim(expectSha)) then
        WriteLn('checksum: VERIFIED')
      else
        Fail('checksum MISMATCH for ' + target);
    end
    else
      WriteLn('checksum: PENDING (file not present, expected sha1 ' + Trim(expectSha) + ')');
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
    rel := MavenPath(maven, grp, art, ver);
    target := IncludeTrailingPathDelimiter(OutDir) + art + '-' + ver + '.jar';
    if not FileExists(target) then
      Fail('file not present: ' + target);
    gotSha := LowerCase(SHA1Print(SHA1File(target)));
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
  need: array[0..7] of string = ('id', 'displayName', 'maven', 'driverClass',
    'urlTemplate', 'testQuery', 'license', 'upstreamSyncVersion');
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
    end;
    WriteLn('drivers ok: ', arr.Count);
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
begin
  j := LoadJSON(Cfg);
  try
    arr := TJSONObject(j).Arrays['runtimes'];
    if arr.Count <> 5 then Fail('want 5 runtimes');
    for i := 0 to arr.Count - 1 do
    begin
      o := arr.Objects[i];
      ReqStr(o, 'platform');
      ReqStr(o, 'temurinVersion');
      if o.Strings['bridgeVersion'] <> '1.0.0' then
        Fail('bridgeVersion mismatch');
      ReqStr(o, 'url');
      ReqStr(o, 'sha256');
    end;
    WriteLn('runtimes ok: ', arr.Count);
  finally
    j.Free;
  end;
end;

var
  mode, cfg, id, outd, rcfg, sha: string;
  i: Integer;
begin
  mode := '';
  cfg := 'configs/drivers.json';
  rcfg := 'configs/runtimes.json';
  id := '';
  outd := 'drivers';
  sha := '';
  i := 1;
  while i <= ParamCount do
  begin
    if ParamStr(i) = '--list' then mode := 'list'
    else if ParamStr(i) = '--driver' then begin Inc(i); id := ParamStr(i); if mode = '' then mode := 'driver'; end
    else if ParamStr(i) = '--out' then begin Inc(i); outd := ParamStr(i); end
    else if ParamStr(i) = '--sha1' then begin Inc(i); sha := ParamStr(i); end
    else if ParamStr(i) = '--config' then begin Inc(i); cfg := ParamStr(i); end
    else if ParamStr(i) = '--verify-manifests' then mode := 'verify'
    else if ParamStr(i) = '--verify-file' then mode := 'verifyfile';
    Inc(i);
  end;
  if mode = 'list' then CmdList(cfg)
  else if mode = 'driver' then begin if id = '' then Fail('--driver needs id'); CmdDriver(cfg, id, outd); end
  else if mode = 'verify' then begin CheckDrivers(cfg); CheckRuntimes(rcfg); WriteLn('manifests verified'); end
  else if mode = 'verifyfile' then
  begin
    if (id = '') or (sha = '') then Fail('--verify-file needs --driver <id> --sha1 <hex>');
    CmdVerifyFile(cfg, id, outd, sha);
  end
  else begin WriteLn('usage: mautool --list | --driver <id> --out <dir> | --verify-file --driver <id> --sha1 <hex> --out <dir> | --verify-manifests'); Halt(2); end;
end.
