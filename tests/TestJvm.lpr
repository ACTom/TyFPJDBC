program TestJvm;
{$mode objfpc}{$H+}
uses
  SysUtils, Classes,
  {$IFDEF MSWINDOWS}Windows,{$ENDIF}
  TyFPJDBC.JVM.Manager;
var
  Fails: Integer = 0;
procedure Ok(const N: string; C: Boolean);
begin
  if C then WriteLn('PASS ', N) else begin Inc(Fails); WriteLn('FAIL ', N); end;
end;
var
  Cfg: TJVMOptions;
  arr: TStringArray;
  joined: string;
  tmpJvm: string;
  {$IFDEF MSWINDOWS}
  jhName, jhVal: AnsiString;
  {$ENDIF}
begin
  Cfg := TJVMOptions.Create;
  try
    Cfg.Validate;
    Ok('default-valid', True);
    arr := Cfg.BuildArgArray;
    Ok('arg-array', (Length(arr) >= 3) and (Pos('-Xmx', arr[0]) = 1));
    Cfg.ExtraArgs.Add('-Dpath=C:\Program Files\x');
    joined := TJVMManager.JoinArgs(Cfg.BuildArgArray);
    Ok('join-quotes-space', Pos('"', joined) > 0);
    arr := TJVMManager.SplitArgs(joined);
    Ok('split-roundtrip', (Length(arr) > 0) and (Pos('Program Files', arr[High(arr)]) > 0));
  finally
    Cfg.Free;
  end;
  Cfg := TJVMOptions.Create;
  try
    Cfg.Headless := False;
    try
      Cfg.Validate;
      Ok('headless-rejected', False);
    except
      on E: Exception do Ok('headless-rejected', True);
    end;
  finally
    Cfg.Free;
  end;
  try
    TJVMManager.EnsureStartedWithOptions('C:/nonexistent-jvm.dll', nil);
    Ok('nil-opts-rejected', False);
  except
    on E: Exception do Ok('nil-opts-rejected', True);
  end;
  try
    TJVMManager.EnsureStartedArgs('C:/nonexistent-jvm.dll',
      ['-Dfile.encoding=UTF-8', '-Djava.awt.headless=true']);
    Ok('missing-jvm-fails', False);
  except
    on E: Exception do
      Ok('missing-jvm-fails', Pos('libjvm', E.Message) > 0);
  end;
  TJVMManager.ShutdownJvm;
  Ok('shutdown-ok', True);
  Ok('jni-version', TJVMManager.JniVersionUsed = $00010006);
  tmpJvm := IncludeTrailingPathDelimiter(GetTempDir) + 'fake-jvm.dll';
  with TFileStream.Create(tmpJvm, fmCreate) do Free;
  try
    Ok('explicit-path', TJVMManager.FindLibJvm(tmpJvm) = tmpJvm);
  finally
    SysUtils.DeleteFile(tmpJvm);
  end;
  { Root 钉死到不存在的目录后，JAVA_HOME 必须被无视：系统 JRE 不再是来源。 }
  TJVMManager.SetRuntimeConfig('C:\nonexistent-root-xyz', '');
  {$IFDEF MSWINDOWS}
  jhName := 'JAVA_HOME';
  jhVal := 'C:\nonexistent-java-home-xyz';
  Windows.SetEnvironmentVariable(PChar(jhName), PChar(jhVal));
  {$ENDIF}
  try
    TJVMManager.FindLibJvm('');
    Ok('no-system-jre', False);
  except
    on E: Exception do
      Ok('no-system-jre', Pos('libjvm', E.Message) > 0);
  end;
  TJVMManager.SetRuntimeConfig('', '');
  Ok('default-cp-shape', (Pos('bridge', TJVMManager.DefaultClassPath) > 0) and
    (Pos('drivers', TJVMManager.DefaultClassPath) > 0));
  { JNI 下 -Djava.class.path 的 '*' 不会被虚拟机展开（只有 java 启动器
    展开 -cp），默认 classpath 里不许出现通配符，必须是显式 jar 列表。 }
  Ok('default-cp-no-wildcard', Pos('*', TJVMManager.DefaultClassPath) = 0);
  WriteLn('TOTAL fails=', Fails);
  if Fails > 0 then Halt(1);
end.
