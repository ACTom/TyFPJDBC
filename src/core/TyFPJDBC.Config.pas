unit TyFPJDBC.Config;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, TyFPJDBC.JNI.Bridge;

type
  { Single source of truth for every tunable in the library. Exactly one
    place holds defaults; all units (pool, JVM, exec window/batch, field
    width, savepoint length, observability) read from here. }
  TJdbcConfig = class
  public
    JVM_Xmx: string;
    JVM_MaxRAMPercentage: Double;
    JVM_Headless: Boolean;
    JVM_FileEncoding: string;
    Pool_MaxPool, Pool_MinIdle: Integer;
    Pool_ConnTimeoutMs, Pool_MaxLifetimeMs, Pool_KeepaliveMs: Int64;
    Pool_LeakMs, Pool_ValidTimeoutMs: Int64;
    Pool_TestQuery: string;
    Exec_WindowSize, Exec_BatchLimit, Exec_TimeoutSecs: Integer;
    Field_WideWidth, Savepoint_MaxLen: Integer;
    Obs_SlowWarnMs, Obs_SlowErrorMs: Int64;
    Obs_SampleEvery: Integer;
    constructor Create;
    class function Default: TJdbcConfig;
    procedure Validate;
    procedure ApplyToPoolCfg(var Cfg: TPoolCfgRec);
    function BuildJvmArgs: string;
  end;

implementation

constructor TJdbcConfig.Create;
begin
  inherited Create;
  JVM_Xmx := '512m';
  JVM_MaxRAMPercentage := 60.0;
  JVM_Headless := True;
  JVM_FileEncoding := 'UTF-8';
  Pool_MaxPool := 10;
  Pool_MinIdle := 2;
  Pool_ConnTimeoutMs := 30000;
  Pool_MaxLifetimeMs := 1800000;
  Pool_KeepaliveMs := 30000;
  Pool_LeakMs := 0;
  Pool_TestQuery := 'SELECT 1';
  Pool_ValidTimeoutMs := 5000;
  Exec_WindowSize := 1000;
  Exec_BatchLimit := 10000;
  Exec_TimeoutSecs := 0;
  Field_WideWidth := 255;
  Savepoint_MaxLen := 64;
  Obs_SlowWarnMs := 1000;
  Obs_SlowErrorMs := 5000;
  Obs_SampleEvery := 1;
end;

class function TJdbcConfig.Default: TJdbcConfig;
begin
  Result := TJdbcConfig.Create;
end;

procedure TJdbcConfig.Validate;
begin
  if Pool_MaxPool < 1 then
    raise Exception.Create('Pool_MaxPool must be >= 1');
  if Pool_MinIdle < 0 then
    raise Exception.Create('Pool_MinIdle must be >= 0');
  if Pool_MinIdle > Pool_MaxPool then
    raise Exception.Create('Pool_MinIdle cannot exceed Pool_MaxPool');
  if Exec_WindowSize < 1 then
    raise Exception.Create('Exec_WindowSize must be >= 1');
  if (Exec_BatchLimit < 1) or (Exec_BatchLimit > 100000) then
    raise Exception.Create('Exec_BatchLimit out of range 1..100000');
  if JVM_MaxRAMPercentage < 50.0 then
    raise Exception.Create('JVM_MaxRAMPercentage too small');
  if not JVM_Headless then
    raise Exception.Create('JVM must run headless=true');
  if JVM_FileEncoding <> 'UTF-8' then
    raise Exception.Create('JVM FileEncoding must be UTF-8');
end;

procedure TJdbcConfig.ApplyToPoolCfg(var Cfg: TPoolCfgRec);
begin
  Cfg.MaximumPoolSize := Pool_MaxPool;
  Cfg.MinimumIdle := Pool_MinIdle;
  Cfg.ConnectionTimeoutMs := Pool_ConnTimeoutMs;
  Cfg.MaxLifetimeMs := Pool_MaxLifetimeMs;
  Cfg.KeepaliveTimeMs := Pool_KeepaliveMs;
  Cfg.LeakDetectionThresholdMs := Pool_LeakMs;
  Cfg.ConnectionTestQuery := UTF8String(Pool_TestQuery);
  Cfg.ValidationTimeoutMs := Pool_ValidTimeoutMs;
end;

function TJdbcConfig.BuildJvmArgs: string;
begin
  Result := '-Xmx' + JVM_Xmx + ' -Dfile.encoding=UTF-8 -Djava.awt.headless=true';
end;

end.
