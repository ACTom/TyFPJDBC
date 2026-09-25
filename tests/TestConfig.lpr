program TestConfig;

{$mode objfpc}{$H+}

uses SysUtils, TyFPJDBC.JNI.Bridge, TyFPJDBC.Config;

var Fails: Integer = 0;

procedure Ok(const N: string; C: Boolean);
begin
  if C then WriteLn('PASS ', N) else begin Inc(Fails); WriteLn('FAIL ', N); end;
end;

var
  c: TJdbcConfig;
  p: TPoolCfgRec;
begin
  c := TJdbcConfig.Default;
  try
    Ok('jvm-defaults', (c.JVM_Xmx = '512m') and (c.JVM_MaxRAMPercentage = 60.0) and c.JVM_Headless and (c.JVM_FileEncoding = 'UTF-8'));
    Ok('pool-defaults', (c.Pool_MaxPool = 10) and (c.Pool_MinIdle = 2) and (c.Pool_TestQuery = 'SELECT 1'));
    Ok('exec-defaults', (c.Exec_WindowSize = 1000) and (c.Exec_BatchLimit = 10000));
    c.Pool_MaxPool := 0;
    try
      c.Validate;
      Ok('zero-pool-rejected', False);
    except
      on E: Exception do Ok('zero-pool-rejected', True);
    end;
    c.Free;
    c := TJdbcConfig.Default;
    c.Pool_MaxPool := 4;
    c.Pool_MinIdle := 1;
    c.ApplyToPoolCfg(p);
    Ok('apply-pool', (p.MaximumPoolSize = 4) and (p.MinimumIdle = 1));
    Ok('jvm-args', Pos('-Xmx', c.BuildJvmArgs) = 1);
  finally
    c.Free;
  end;
  WriteLn('TOTAL fails=', Fails);
  if Fails > 0 then Halt(1);
end.
