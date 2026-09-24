program TestV2Jvm;
{$mode objfpc}{$H+}
uses
  SysUtils, TyFPJDBC.JVM.Manager;
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
  try
    TJVMManager.FindLibJvmV2('');
    Ok('findlib-probe', True);
  except
    on E: Exception do
      Ok('findlib-probe', Pos('libjvm', E.Message) > 0);
  end;
  WriteLn('TOTAL fails=', Fails);
  if Fails > 0 then Halt(1);
end.
