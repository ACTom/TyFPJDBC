unit GridData;

{$mode objfpc}{$H+}
{$codepage UTF8}

{ Shared data path for ex09 (LCL DBGrid demo) and TestLiveGrid.
  TryLoadLive drives the SHIPPED units on the real path:
  TJVMManager (real JNI_CreateJavaVM) -> TBridgeClient (real JNI into
  tyfpjdbc.Bridge) -> HikariCP -> sqlite-jdbc file DB, then LoadRowsLive
  into the given TJDBCQuery. Returns False (no exception) when the JVM
  or jars are unavailable so the GUI can fall back to bundled rows. }

interface

uses
  SysUtils, Classes, TyFPJDBC.JVM.Manager, TyFPJDBC.JNI.Bridge,
  TyFPJDBC.Query;

function GridSeedRows: TStringList;
function FindJvmDll(out Dll: string): Boolean;
function TryLoadLive(Q: TJDBCQuery; const ClassesDir, WorkDir: string;
  out Owned: TObject; out PoolId, ConnId: Int64; out Note: string): Boolean;
procedure FreeLive(Owned: TObject; PoolId: Int64);

implementation

function GridSeedRows: TStringList;
begin
  Result := TStringList.Create;
  Result.Add('1|hello');
  Result.Add('2|中文测试');
  Result.Add('3|jdbc-bridge');
end;

function FindJvmDll(out Dll: string): Boolean;
const
  Cands: array[0..1] of string = (
    'C:\Tools\ms-jdks\win64\jdk-25.0.4.1+1\bin\server\jvm.dll',
    'C:\Tools\jdk25\jdk-25.0.4.1+1\bin\server\jvm.dll');
var
  i: Integer;
begin
  for i := 0 to High(Cands) do
    if FileExists(Cands[i]) then
    begin
      Dll := Cands[i];
      Exit(True);
    end;
  Dll := '';
  Result := False;
end;

function LibJar(const Name: string): string;
begin
  Result := 'C:\Tools\tyfpjdbc-libs\' + Name;
end;

function TryLoadLive(Q: TJDBCQuery; const ClassesDir, WorkDir: string;
  out Owned: TObject; out PoolId, ConnId: Int64; out Note: string): Boolean;
var
  bridge: TBridgeClient;
  dll, db: string;
  batch: TJavaRows;
  nulls: TJavaNulls;
begin
  Result := False;
  Owned := nil;
  PoolId := 0;
  ConnId := 0;
  Note := '';
  try
    if not DirectoryExists(ClassesDir + PathDelim + 'tyfpjdbc') then
    begin
      Note := 'bridge classes missing: ' + ClassesDir;
      Exit;
    end;
    if not FindJvmDll(dll) then
    begin
      Note := 'jvm.dll not found';
      Exit;
    end;
    if not FileExists(LibJar('sqlite-jdbc-3.46.1.0.jar')) then
    begin
      Note := 'sqlite-jdbc jar missing';
      Exit;
    end;
    ForceDirectories(WorkDir);
    TJVMManager.ResetForTests;
    TJVMManager.SetClassPath(ClassesDir + ';' + LibJar('HikariCP-5.1.0.jar') +
      ';' + LibJar('slf4j-api-2.0.9.jar') + ';' + LibJar('h2-2.2.224.jar') +
      ';' + LibJar('sqlite-jdbc-3.46.1.0.jar'));
    TJVMManager.EnsureStarted(dll, TJVMManager.BuildDesktopArgs);
    TJVMManager.AttachThread;
    bridge := TBridgeClient.Create;
    Owned := bridge;
    if bridge.GetVersion <> '1.0.0' then
    begin
      Note := 'bridge version mismatch';
      Exit;
    end;
    db := WorkDir + PathDelim + 'grid-' + IntToStr(GetProcessID) + '.db';
    if FileExists(db) then
      DeleteFile(db);
    PoolId := bridge.CreatePool('jdbc:sqlite:' + db, '', '', 4, 1);
    ConnId := bridge.BorrowConnection(PoolId);
    bridge.ExecUpdate(ConnId,
      'CREATE TABLE grid_t(id INTEGER PRIMARY KEY, name TEXT)');
    SetLength(batch, 3);
    SetLength(nulls, 3);
    batch[0] := TJavaRow.Create('1', 'hello');
    batch[1] := TJavaRow.Create('2', UTF8String('中文测试'));
    batch[2] := TJavaRow.Create('3', 'jdbc-bridge');
    nulls[0] := TJavaNullRow.Create(False, False);
    nulls[1] := TJavaNullRow.Create(False, False);
    nulls[2] := TJavaNullRow.Create(False, False);
    if bridge.ExecBatch(ConnId, 'INSERT INTO grid_t VALUES(?,?)',
      batch, nulls) <> 3 then
    begin
      Note := 'seed write failed';
      Exit;
    end;
    Q.LoadRowsLive(bridge, ConnId, 'grid_t',
      'SELECT id,name FROM grid_t ORDER BY id',
      ['id', 'name'], ['INTEGER', 'NVARCHAR']);
    Q.CachedUpdates := True;
    Q.UpdateOptions.ReadOnly := False;
    Q.UpdateOptions.KeyFields := 'id';
    Q.UpdateOptions.AutoIncField := 'id';
    Note := 'live: ' + db;
    Result := True;
  except
    on E: Exception do
      Note := 'live unavailable: ' + E.Message;
  end;
end;

procedure FreeLive(Owned: TObject; PoolId: Int64);
var
  bridge: TBridgeClient;
begin
  if Owned = nil then
    Exit;
  bridge := TBridgeClient(Owned);
  try
    try
      bridge.DestroyPool(PoolId);
    except
    end;
  finally
    bridge.Free;
  end;
  try
    TJVMManager.DetachThread;
  except
  end;
end;

end.
