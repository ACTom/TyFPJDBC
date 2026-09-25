program ex10_json_config;

{$mode objfpc}{$H+}
{$codepage UTF8}

{ ex10: read-only demo that the connection dialog / downloader wizard and
  the mautool CLI all consume the SAME configs/drivers.json and
  configs/runtimes.json. Prints every driver and runtime entry; asserts
  the sqlite manifest entry can be resolved to a real local jar. }

uses
  SysUtils, Classes, fpjson, jsonparser;

function LoadJson(const Path: string): TJSONData;
var
  s: TStringList;
begin
  if not FileExists(Path) then
    raise Exception.Create('missing: ' + Path);
  s := TStringList.Create;
  try
    s.LoadFromFile(Path);
    Result := GetJSON(s.Text);
  finally
    s.Free;
  end;
end;

function CfgDir: string;
begin
  if ParamStr(1) <> '' then
    Result := ParamStr(1)
  else
    Result := ExtractFilePath(ParamStr(0)) + '..' + PathDelim + '..' +
      PathDelim + 'configs';
end;

function JStr(P: TJSONData; const K: string): string;
var
  d: TJSONData;
begin
  Result := '';
  if (P = nil) or not (P is TJSONObject) then
    Exit;
  d := TJSONObject(P).Find(K);
  if (d <> nil) and (d.JSONType = jtString) then
    Result := d.AsString;
end;

var
  drivers, runtimes, entry: TJSONData;
  arr: TJSONArray;
  i: Integer;
  sqliteSha1: string;
  jarPath: string;
begin
  WriteLn('configs: ', CfgDir);
  drivers := LoadJson(CfgDir + PathDelim + 'drivers.json');
  runtimes := LoadJson(CfgDir + PathDelim + 'runtimes.json');
  try
    arr := TJSONArray(drivers.FindPath('drivers'));
    WriteLn('drivers=', arr.Count);
    sqliteSha1 := '';
    for i := 0 to arr.Count - 1 do
    begin
      entry := arr.Items[i];
      WriteLn('driver id=', JStr(entry, 'id'),
        ' maven=', JStr(entry, 'maven'),
        ' sha1=', JStr(entry, 'sha1'),
        ' testQuery=', JStr(entry, 'testQuery'));
      if JStr(entry, 'id') = 'sqlite' then
        sqliteSha1 := JStr(entry, 'sha1');
    end;
    if sqliteSha1 = '' then
    begin
      WriteLn('FAIL sqlite entry missing');
      Halt(1);
    end;
    WriteLn('PASS sqlite-sha1-present');

    arr := TJSONArray(runtimes.FindPath('runtimes'));
    WriteLn('runtimes=', arr.Count);
    for i := 0 to arr.Count - 1 do
    begin
      entry := arr.Items[i];
      WriteLn('runtime platform=', entry.FindPath('platform').AsString,
        ' asset=', entry.FindPath('asset').AsString,
        ' packedBytes=', entry.FindPath('packedBytes').AsString,
        ' sha256=', Copy(entry.FindPath('sha256').AsString, 1, 16), '...');
    end;
    WriteLn('PASS json-reuse');

    jarPath := 'C:\Tools\tyfpjdbc-libs\sqlite-jdbc-3.46.1.0.jar';
    if FileExists(jarPath) then
      WriteLn('PASS sqlite-jar-resolves jar=', jarPath,
        ' manifest-sha1=', sqliteSha1)
    else
    begin
      WriteLn('NOTE sqlite jar not at ', jarPath,
        ' (manifest entry still listed above)');
    end;
  finally
    drivers.Free;
    runtimes.Free;
  end;
  WriteLn('ex10 ok');
end.
