unit TyFPJDBC.JVM.Manager;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, syncobjs;
type
  TJVMLogProc = procedure(const Msg: string) of object;

  TJVMManager = class
  private
    class var FLock: TCriticalSection;
    class var FStarted: Boolean;
    class var FLibJvm: string;
    class var FArgs: string;
    class var FAttachCount: Integer;
    class var FOnLog: TJVMLogProc;
    class procedure DoLog(const Msg: string); static;
  public
    class constructor Create;
    class destructor Destroy;
    class function IsHeadlessArg(const S: string): Boolean; static;
    class function BuildDesktopArgs: string; static;
    class function BuildServerArgs: string; static;
    class function FindLibJvm(const CustomPath: string): string; static;
    class procedure EnsureStarted(const LibJvm, ExtraArgs: string); static;
    class procedure ResetForTests; static;
    class procedure AttachThread; static;
    class procedure DetachThread; static;
    class function IsStarted: Boolean; static;
    class function AttachedCount: Integer; static;
    class property OnLog: TJVMLogProc read FOnLog write FOnLog;
  end;

implementation

class constructor TJVMManager.Create;
begin
  FLock := TCriticalSection.Create;
end;

class destructor TJVMManager.Destroy;
begin
  FLock.Free;
end;

class procedure TJVMManager.DoLog(const Msg: string);
begin
  if Assigned(FOnLog) then
    FOnLog(Msg);
end;

class function TJVMManager.IsHeadlessArg(const S: string): Boolean;
begin
  Result := Pos('headless=true', S) > 0;
end;

class function TJVMManager.BuildDesktopArgs: string;
begin
  Result := '-Xmx512m -Dfile.encoding=UTF-8 -Djava.awt.headless=true';
end;

class function TJVMManager.BuildServerArgs: string;
begin
  Result := '-XX:MaxRAMPercentage=60.0 -Xrs -Dfile.encoding=UTF-8 -Djava.awt.headless=true';
end;

class function TJVMManager.FindLibJvm(const CustomPath: string): string;
var
  h: string;
begin
  if (CustomPath <> '') and FileExists(CustomPath) then
    Exit(CustomPath);
  h := GetEnvironmentVariable('JAVA_HOME');
  if h <> '' then
  begin
    Result := IncludeTrailingPathDelimiter(h) + 'bin' + PathDelim + 'server' +
      PathDelim + 'jvm.dll';
    if FileExists(Result) then
      Exit;
    Result := IncludeTrailingPathDelimiter(h) + 'lib' + PathDelim + 'server' +
      PathDelim + 'libjvm.so';
    if FileExists(Result) then
      Exit;
  end;
  raise Exception.Create('libjvm not found, set JAVA_HOME or bundle jre/');
end;

class procedure TJVMManager.EnsureStarted(const LibJvm, ExtraArgs: string);
begin
  FLock.Enter;
  try
    if FStarted then
      Exit;
    if not IsHeadlessArg(ExtraArgs) then
      raise Exception.Create('must pass headless=true');
    if Pos('file.encoding=UTF-8', ExtraArgs) = 0 then
      raise Exception.Create('must pass file.encoding=UTF-8');
    if not FileExists(LibJvm) then
      raise Exception.Create('libjvm not found: ' + LibJvm);
    FLibJvm := LibJvm;
    FArgs := ExtraArgs;
    FStarted := True;
    DoLog('JVM started: ' + LibJvm);
  finally
    FLock.Leave;
  end;
end;

class procedure TJVMManager.ResetForTests;
begin
  FLock.Enter;
  try
    FStarted := False;
    FLibJvm := '';
    FArgs := '';
    FAttachCount := 0;
  finally
    FLock.Leave;
  end;
end;

class procedure TJVMManager.AttachThread;
begin
  FLock.Enter;
  try
    if not FStarted then
      raise Exception.Create('JVM not started');
    Inc(FAttachCount);
  finally
    FLock.Leave;
  end;
end;

class procedure TJVMManager.DetachThread;
begin
  FLock.Enter;
  try
    if FAttachCount > 0 then
      Dec(FAttachCount);
  finally
    FLock.Leave;
  end;
end;

class function TJVMManager.IsStarted: Boolean;
begin
  FLock.Enter;
  try
    Result := FStarted;
  finally
    FLock.Leave;
  end;
end;

class function TJVMManager.AttachedCount: Integer;
begin
  FLock.Enter;
  try
    Result := FAttachCount;
  finally
    FLock.Leave;
  end;
end;

end.
