unit TyFPJDBC.JVM.Manager;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, syncobjs, dynlibs, jni;
type
  TJVMLogProc = procedure(const Msg: string) of object;
  TJVMMode = (jvmAuto, jvmDesktop, jvmServer);

  TJVMOptions = class
  public
    Mode: TJVMMode;
    Xmx: string;
    MaxRAMPercentage: Double;
    Headless: Boolean;
    FileEncoding: string;
    EnableCheckJNI: Boolean;
    ExtraArgs: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure Validate;
    function BuildArgs: string;
    function BuildArgArray: TStringArray;
  end;

  TJVMManager = class
  private
    class var FLock: TCriticalSection;
    class var FStarted: Boolean;
    class var FLibJvm: string;
    class var FArgs: string;
    class var FClassPath: string;
    class var FAttachCount: Integer;
    class var FOnLog: TJVMLogProc;
    class var FLibHandle: TLibHandle;
    class var FJavaVM: PJavaVM;
    class var FMainEnv: PJNIEnv;
    class var FRuntimeRoot: string;
    class var FRuntimeJvmPath: string;
    class procedure DoLog(const Msg: string); static;
    class function ExpandDirJars(const Dir: string): string; static;
  public
    class constructor Create;
    class destructor Destroy;
    class function IsHeadlessArg(const S: string): Boolean; static;
    class function BuildDesktopArgs: string; static;
    class function BuildServerArgs: string; static;
    class function FindLibJvm(const CustomPath: string): string; static;
    class procedure SetRuntimeConfig(const Root, JvmPath: string); static;
    class function DefaultClassPath: string; static;
    class procedure SetClassPath(const CP: string); static;
    class function GetClassPath: string; static;
    class procedure EnsureStarted(const LibJvm, ExtraArgs: string); static;
    class procedure EnsureStartedWithOptions(const LibJvm: string;
      Opts: TJVMOptions); static;
    class procedure EnsureStartedArgs(const LibJvm: string;
      const Args: array of string); static;
    class function JoinArgs(const Args: array of string): string; static;
    class function SplitArgs(const S: string): TStringArray; static;
    class procedure ShutdownJvm; static;
    class function JniVersionUsed: LongInt; static;
    class function LastStartArgs: string; static;
    class procedure ResetForTests; static;
    class procedure AttachThread; static;
    class procedure DetachThread; static;
    class function IsStarted: Boolean; static;
    class function AttachedCount: Integer; static;
    class function GetJNIEnv: PJNIEnv; static;
    class function GetJavaVM: PJavaVM; static;
  end;

type
  T_JNI_CreateJavaVM = function(vm: PPJavaVM; penv: PPJNIEnv;
    args: pointer): jint; stdcall;
  T_JNI_GetCreatedJavaVMs = function(vm: PPJavaVM; size: jsize;
    n: Pjsize): jint; stdcall;

implementation

uses
  TyFPJDBC.Config;

class constructor TJVMManager.Create;
begin
  FLock := TCriticalSection.Create;
  FLibHandle := NilHandle;
  FJavaVM := nil;
  FMainEnv := nil;
end;

class destructor TJVMManager.Destroy;
begin
  FLock.Free;
end;

constructor TJVMOptions.Create;
var
  cfg: TJdbcConfig;
begin
  inherited Create;
  cfg := TJdbcConfig.Default;
  try
    Mode := jvmAuto;
    Xmx := cfg.JVM_Xmx;
    MaxRAMPercentage := cfg.JVM_MaxRAMPercentage;
    Headless := cfg.JVM_Headless;
    FileEncoding := cfg.JVM_FileEncoding;
  finally
    cfg.Free;
  end;
  EnableCheckJNI := False;
  ExtraArgs := TStringList.Create;
end;

destructor TJVMOptions.Destroy;
begin
  ExtraArgs.Free;
  inherited;
end;

procedure TJVMOptions.Validate;
begin
  if not Headless then
    raise Exception.Create('JVM must run headless=true');
  if FileEncoding <> 'UTF-8' then
    raise Exception.Create('JVM FileEncoding must be UTF-8, got ' +
      FileEncoding);
  if (MaxRAMPercentage < 50.0) or (MaxRAMPercentage > 75.0) then
    raise Exception.Create('MaxRAMPercentage out of range 50..75');
  if Trim(Xmx) = '' then
    raise Exception.Create('Xmx must not be empty');
end;

function TJVMOptions.BuildArgs: string;
begin
  Result := TJVMManager.JoinArgs(BuildArgArray);
end;

function TJVMOptions.BuildArgArray: TStringArray;

  procedure Add(const S: string);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := S;
  end;

var
  i: Integer;
begin
  Validate;
  SetLength(Result, 0);
  case Mode of
    jvmServer:
      Add('-XX:MaxRAMPercentage=' +
        StringReplace(FloatToStr(MaxRAMPercentage), ',', '.',
          [rfReplaceAll]));
    else
      Add('-Xmx' + Xmx);
  end;
  if Mode = jvmServer then
    Add('-Xrs');
  Add('-Dfile.encoding=' + FileEncoding);
  Add('-Djava.awt.headless=true');
  if EnableCheckJNI then
    Add('-Xcheck:jni');
  for i := 0 to ExtraArgs.Count - 1 do
    if Trim(ExtraArgs[i]) <> '' then
      Add(Trim(ExtraArgs[i]));
end;

class procedure TJVMManager.DoLog(const Msg: string);
begin
  if Assigned(FOnLog) then
    FOnLog(Msg);
end;

class function TJVMManager.SplitArgs(const S: string): TStringArray;
var
  i: Integer;
  cur: string;
  quoted: Boolean;

  procedure Flush;
  begin
    if cur <> '' then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := cur;
      cur := '';
    end;
  end;

begin
  { Quote-aware splitter: "C:\Program Files\x" stays one arg. Old callers
    passing unquoted args behave exactly as before. }
  SetLength(Result, 0);
  cur := '';
  quoted := False;
  i := 1;
  while i <= Length(S) do
  begin
    if S[i] = '"' then
      quoted := not quoted
    else if (S[i] = ' ') and not quoted then
      Flush
    else
      cur := cur + S[i];
    Inc(i);
  end;
  Flush;
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
  root, cand: string;

  function TryPath(const P: string): Boolean;
  begin
    Result := (P <> '') and FileExists(P);
    if Result then
      FindLibJvm := P;
  end;

begin
  { Only three sources: explicit path, configured root, exe-side jre/.
    System JRE (JAVA_HOME/registry/PATH) is deliberately unsupported. }
  if TryPath(CustomPath) then
  begin
    DoLog('WARNING: explicit libjvm used, version not verified: ' + CustomPath);
    Exit;
  end;
  if TryPath(FRuntimeJvmPath) then
  begin
    DoLog('WARNING: configured libjvm used, version not verified: ' + FRuntimeJvmPath);
    Exit;
  end;
  root := FRuntimeRoot;
  if root = '' then
    root := ExtractFilePath(ParamStr(0));
  cand := IncludeTrailingPathDelimiter(root) + 'jre' + PathDelim + 'bin' +
    PathDelim + 'server' + PathDelim + 'jvm.dll';
  if TryPath(cand) then
    Exit;
  cand := IncludeTrailingPathDelimiter(root) + 'jre' + PathDelim + 'lib' +
    PathDelim + 'server' + PathDelim + 'libjvm.so';
  if TryPath(cand) then
    Exit;
  cand := IncludeTrailingPathDelimiter(root) + 'jre' + PathDelim + 'lib' +
    PathDelim + 'server' + PathDelim + 'libjvm.dylib';
  if TryPath(cand) then
    Exit;
  raise Exception.Create('libjvm not found: bundle jre/ next to the exe or set ' +
    'Runtime_Root/Runtime_JvmPath (system JRE is not supported)');
end;

class procedure TJVMManager.SetRuntimeConfig(const Root, JvmPath: string);
begin
  FLock.Enter;
  try
    FRuntimeRoot := Root;
    FRuntimeJvmPath := JvmPath;
  finally
    FLock.Leave;
  end;
end;

class function TJVMManager.DefaultClassPath: string;
var
  root, bdir, ddir, bj, dj: string;
begin
  root := FRuntimeRoot;
  if root = '' then
    root := ExtractFilePath(ParamStr(0));
  { JNI only gets -Djava.class.path, whose trailing '*' is NOT expanded by
    the VM (only the java launcher expands -cp wildcards, verified red).
    Enumerate jars explicitly; keep the bare dirs for loose dev classes. }
  bdir := IncludeTrailingPathDelimiter(root) + 'bridge';
  ddir := IncludeTrailingPathDelimiter(root) + 'drivers';
  Result := bdir + PathSeparator + ddir;
  bj := ExpandDirJars(bdir);
  if bj <> '' then
    Result := Result + PathSeparator + bj;
  dj := ExpandDirJars(ddir);
  if dj <> '' then
    Result := Result + PathSeparator + dj;
end;

class function TJVMManager.ExpandDirJars(const Dir: string): string;
var
  sr: TSearchRec;
  jars: TStringList;
  i: Integer;
begin
  Result := '';
  jars := TStringList.Create;
  try
    jars.Sorted := True;
    if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*.jar',
      faAnyFile, sr) = 0 then
    try
      repeat
        if (sr.Attr and faDirectory) = 0 then
          jars.Add(IncludeTrailingPathDelimiter(Dir) + sr.Name);
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
    for i := 0 to jars.Count - 1 do
    begin
      if Result <> '' then
        Result := Result + PathSeparator;
      Result := Result + jars[i];
    end;
  finally
    jars.Free;
  end;
end;

class procedure TJVMManager.SetClassPath(const CP: string);
begin
  FLock.Enter;
  try
    FClassPath := CP;
  finally
    FLock.Leave;
  end;
end;

class function TJVMManager.GetClassPath: string;
begin
  FLock.Enter;
  try
    Result := FClassPath;
    if Result = '' then
      Result := DefaultClassPath;
  finally
    FLock.Leave;
  end;
end;

class procedure TJVMManager.EnsureStarted(const LibJvm, ExtraArgs: string);
type
  PAnsi = PChar;
var
  createVM: T_JNI_CreateJavaVM;
  getVMs: T_JNI_GetCreatedJavaVMs;
  vm: PJavaVM;
  env: PJNIEnv;
  n: jsize;
  rc: jint;
  argList: TStringArray;
  opts: array of JavaVMOption;
  optStrs: array of AnsiString;
  args: JavaVMInitArgs;
  i, nopt: Integer;
  cpOpt: AnsiString;
  effCP: string;
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
    if FLibHandle = NilHandle then
    begin
      FLibHandle := LoadLibrary(LibJvm);
      if FLibHandle = NilHandle then
        raise Exception.Create('LoadLibrary failed: ' + LibJvm);
    end;
    Pointer(createVM) := GetProcedureAddress(FLibHandle, 'JNI_CreateJavaVM');
    Pointer(getVMs) := GetProcedureAddress(FLibHandle, 'JNI_GetCreatedJavaVMs');
    if not Assigned(createVM) then
      raise Exception.Create('JNI_CreateJavaVM not exported by ' + LibJvm);
    if Assigned(getVMs) then
    begin
      vm := nil;
      n := 0;
      rc := getVMs(@vm, 1, @n);
      if (rc = JNI_OK) and (n > 0) and (vm <> nil) then
      begin
        FJavaVM := vm;
        env := nil;
        rc := FJavaVM^^.GetEnv(FJavaVM, @env, JNI_VERSION_1_6);
        if rc = JNI_EDETACHED then
          rc := FJavaVM^^.AttachCurrentThread(FJavaVM, @env, nil);
        if rc <> JNI_OK then
          raise Exception.Create('GetEnv/Attach failed, rc=' + IntToStr(rc));
        FMainEnv := env;
        FLibJvm := LibJvm;
        FArgs := ExtraArgs;
        FStarted := True;
        DoLog('JVM reused: ' + LibJvm);
        Exit;
      end;
    end;
    argList := SplitArgs(ExtraArgs);
    effCP := FClassPath;
    if effCP = '' then
      effCP := DefaultClassPath;
    nopt := Length(argList);
    if effCP <> '' then
      Inc(nopt);
    SetLength(opts, nopt);
    SetLength(optStrs, nopt);
    for i := 0 to High(argList) do
    begin
      optStrs[i] := AnsiString(argList[i]);
      opts[i].optionString := PAnsi(optStrs[i]);
      opts[i].extraInfo := nil;
    end;
    if effCP <> '' then
    begin
      cpOpt := AnsiString('-Djava.class.path=' + effCP);
      optStrs[High(optStrs)] := cpOpt;
      opts[High(opts)].optionString := PAnsi(optStrs[High(optStrs)]);
      opts[High(opts)].extraInfo := nil;
    end;
    args.version := JNI_VERSION_1_6;
    args.nOptions := nopt;
    if nopt > 0 then
      args.options := @opts[0]
    else
      args.options := nil;
    args.ignoreUnrecognized := nil;
    vm := nil;
    env := nil;
    rc := createVM(@vm, @env, @args);
    if rc <> JNI_OK then
      raise Exception.Create('JNI_CreateJavaVM failed, rc=' + IntToStr(rc));
    FJavaVM := vm;
    FMainEnv := env;
    FLibJvm := LibJvm;
    FArgs := ExtraArgs;
    FStarted := True;
    DoLog('JVM started: ' + LibJvm);
  finally
    FLock.Leave;
  end;
end;

class procedure TJVMManager.EnsureStartedWithOptions(const LibJvm: string;
  Opts: TJVMOptions);
begin
  if Opts = nil then
    raise Exception.Create('JVM options required');
  EnsureStarted(LibJvm, Opts.BuildArgs);
end;

class function TJVMManager.JoinArgs(const Args: array of string): string;
var
  i: Integer;
  a: string;
begin
  { Array-based entry: args containing spaces are double-quoted; the
    quote-aware SplitArgs on the creation path strips them back, so
    '-Dpath=C:\Program Files\x' arrives as ONE option. }
  Result := '';
  for i := 0 to High(Args) do
  begin
    a := Args[i];
    if (Pos(' ', a) > 0) and ((a = '') or (a[1] <> '"')) then
      a := '"' + a + '"';
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + a;
  end;
end;

class procedure TJVMManager.EnsureStartedArgs(const LibJvm: string;
  const Args: array of string);
begin
  { JoinArgs quotes space-bearing args; the quote-aware SplitArgs below
    strips them back, so paths with spaces arrive as single options. }
  EnsureStarted(LibJvm, JoinArgs(Args));
end;

class procedure TJVMManager.ShutdownJvm;
begin
  { HotSpot supports exactly one VM per process and DestroyJavaVM rarely
    unloads cleanly, so shutdown only releases thread accounting; the VM
    itself is retained. Callers must close all pools/cursors first. }
  FLock.Enter;
  try
    FAttachCount := 0;
    DoLog('JVM shutdown (VM retained by HotSpot)');
  finally
    FLock.Leave;
  end;
end;

class function TJVMManager.JniVersionUsed: LongInt;
begin
  { FPC 3.2.2's jni unit caps at JNI_VERSION_1_6; HotSpot 25 still accepts
    it for the CreateVM/GetEnv version field. No negotiation possible. }
  Result := JNI_VERSION_1_6;
end;
class function TJVMManager.LastStartArgs: string;
begin
  FLock.Enter;
  try
    Result := FArgs;
  finally
    FLock.Leave;
  end;
end;

class procedure TJVMManager.ResetForTests;
begin
  FLock.Enter;
  try
    { Keep a live VM: HotSpot allows exactly one VM per process, so tests
      must reuse it instead of recreating. Only accounting resets here. }
    FAttachCount := 0;
    FRuntimeRoot := '';
    FRuntimeJvmPath := '';
    if FJavaVM = nil then
    begin
      FStarted := False;
      FLibJvm := '';
      FArgs := '';
      if FLibHandle <> NilHandle then
      begin
        UnloadLibrary(FLibHandle);
        FLibHandle := NilHandle;
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

class function TJVMManager.GetJNIEnv: PJNIEnv;
var
  env: PJNIEnv;
  rc: jint;
begin
  FLock.Enter;
  try
    if not FStarted or (FJavaVM = nil) then
      raise Exception.Create('JVM not started');
    env := nil;
    rc := FJavaVM^^.GetEnv(FJavaVM, @env, JNI_VERSION_1_6);
    if rc = JNI_EDETACHED then
    begin
      rc := FJavaVM^^.AttachCurrentThread(FJavaVM, @env, nil);
      if rc <> JNI_OK then
        raise Exception.Create('AttachCurrentThread failed, rc=' + IntToStr(rc));
    end
    else if rc <> JNI_OK then
      raise Exception.Create('GetEnv failed, rc=' + IntToStr(rc));
    Result := env;
  finally
    FLock.Leave;
  end;
end;

class function TJVMManager.GetJavaVM: PJavaVM;
begin
  FLock.Enter;
  try
    if not FStarted or (FJavaVM = nil) then
      raise Exception.Create('JVM not started');
    Result := FJavaVM;
  finally
    FLock.Leave;
  end;
end;

class procedure TJVMManager.AttachThread;
begin
  GetJNIEnv;
  FLock.Enter;
  try
    Inc(FAttachCount);
  finally
    FLock.Leave;
  end;
end;

class procedure TJVMManager.DetachThread;
var
  vm: PJavaVM;
  doDetach: Boolean;
begin
  FLock.Enter;
  try
    if FAttachCount > 0 then
      Dec(FAttachCount);
    doDetach := (FAttachCount = 0) and (FJavaVM <> nil);
    vm := FJavaVM;
  finally
    FLock.Leave;
  end;
  if doDetach and (vm <> nil) then
    vm^^.DetachCurrentThread(vm);
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
