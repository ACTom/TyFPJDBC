program mautool;
{$mode objfpc}{$H+}
uses
  SysUtils, Classes, fpjson, jsonparser;

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

procedure CmdDriver(const Cfg, Id, OutDir: string);
var
  j: TJSONData;
  arr: TJSONArray;
  i: Integer;
  o: TJSONObject;
  maven, ver, art: string;
  p: Integer;
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
    p := LastDelimiter(':', maven);
    ver := Copy(maven, p + 1, MaxInt);
    art := Copy(maven, Pos(':', maven) + 1, p - Pos(':', maven) - 1);
    WriteLn('driver: ', ReqStr(o, 'id'));
    WriteLn('maven: ', maven);
    WriteLn('artifact: ', art + '-' + ver + '.jar');
    WriteLn('expected-path: ', IncludeTrailingPathDelimiter(OutDir) + art + '-' + ver + '.jar');
    WriteLn('driverClass: ', ReqStr(o, 'driverClass'));
    WriteLn('urlTemplate: ', ReqStr(o, 'urlTemplate'));
    WriteLn('testQuery: ', ReqStr(o, 'testQuery'));
    WriteLn('checksum: see Maven Central .sha1 for ' + maven);
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
  mode, cfg, id, outd, rcfg: string;
  i: Integer;
begin
  mode := '';
  cfg := 'configs/drivers.json';
  rcfg := 'configs/runtimes.json';
  id := '';
  outd := 'drivers';
  i := 1;
  while i <= ParamCount do
  begin
    if ParamStr(i) = '--list' then mode := 'list'
    else if ParamStr(i) = '--driver' then begin Inc(i); id := ParamStr(i); if mode = '' then mode := 'driver'; end
    else if ParamStr(i) = '--out' then begin Inc(i); outd := ParamStr(i); end
    else if ParamStr(i) = '--config' then begin Inc(i); cfg := ParamStr(i); end
    else if ParamStr(i) = '--verify-manifests' then mode := 'verify';
    Inc(i);
  end;
  if mode = 'list' then CmdList(cfg)
  else if mode = 'driver' then begin if id = '' then Fail('--driver needs id'); CmdDriver(cfg, id, outd); end
  else if mode = 'verify' then begin CheckDrivers(cfg); CheckRuntimes(rcfg); WriteLn('manifests verified'); end
  else begin WriteLn('usage: mautool --list | --driver <id> --out <dir> | --verify-manifests'); Halt(2); end;
end.
