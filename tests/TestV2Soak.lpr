program TestV2Soak;

{$mode objfpc}{$H+}

{ V2 soak: 4 threads x 50 borrow/exec/query/release iterations against one
  shared pool. Each iteration writes a thread-keyed row and reads it back;
  any cross-talk (wrong tag on own id) counts as misroute. Leak assert:
  every per-thread engine ends at HandleCount=0 and the main engine is zero
  after ClosePool. Usage: TestV2Soak <classesDir>. }

uses
  SysUtils, Classes, syncobjs, TyFPJDBC.Handles, TyFPJDBC.JVM.Manager,
  TyFPJDBC.JNI.BridgeV2, TyFPJDBC.Engine;

const
  THREADS = 4;
  ITERS = 50;

var
  Fails: Integer = 0;
  Misroute: Integer = 0;
  ThreadFails: Integer = 0;
  Lock: TCriticalSection;
  SharedBridge: TBridgeV2;
  SharedPool: Int64;

procedure Ok(const N: string; C: Boolean);
begin
  if C then WriteLn('PASS ', N) else begin Inc(Fails); WriteLn('FAIL ', N); end;
end;

function LibJar(const Name: string): string;
begin
  Result := 'C:\Tools\tyfpjdbc-libs\' + Name;
  if not FileExists(Result) then
    raise Exception.Create('missing jar: ' + Result);
end;

function FindJvmDll: string;
const
  Cands: array[0..1] of string = (
    'C:\Tools\ms-jdks\win64\jdk-25.0.4.1+1\bin\server\jvm.dll',
    'C:\Tools\jdk25\jdk-25.0.4.1+1\bin\server\jvm.dll');
var
  i: Integer;
begin
  for i := 0 to High(Cands) do
    if FileExists(Cands[i]) then
      Exit(Cands[i]);
  raise Exception.Create('no jvm.dll found');
end;

type
  TSoakThread = class(TThread)
  private
    FSlot: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(ASlot: Integer);
  end;

constructor TSoakThread.Create(ASlot: Integer);
begin
  inherited Create(True);
  FSlot := ASlot;
  FreeOnTerminate := False;
end;

procedure TSoakThread.Execute;
var
  eng: TJdbcEngine;
  conn, stmt, cur: Int64;
  rows: TV2Rows;
  i, id: Integer;
  tag: string;
  localBad: Integer;
begin
  localBad := 0;
  eng := TJdbcEngine.Create(SharedBridge);
  try
    for i := 1 to ITERS do
    begin
      id := FSlot * 100000 + i;
      tag := 't' + IntToStr(FSlot) + 'r' + IntToStr(i);
      conn := 0; stmt := 0; cur := 0;
      try
        conn := eng.Borrow(SharedPool);
        stmt := SharedBridge.Prepare(conn,
          'INSERT INTO soak(id, tag) VALUES(?,?)');
        SharedBridge.BindLong(stmt, 1, id);
        SharedBridge.BindString(stmt, 2, tag);
        if SharedBridge.ExecUpdate(stmt) <> 1 then
          Inc(localBad);
        SharedBridge.CloseStmt(stmt);
        stmt := 0;
        stmt := SharedBridge.Prepare(conn,
          'SELECT tag FROM soak WHERE id=?');
        SharedBridge.BindLong(stmt, 1, id);
        cur := SharedBridge.QueryOpen(stmt, 10);
        rows := SharedBridge.FetchWindow(cur, 10);
        { No misroute: own id must come back with own tag. }
        if (Length(rows) <> 1) or (rows[0][0] <> tag) then
        begin
          Inc(localBad);
          Lock.Enter;
          try
            Inc(Misroute);
          finally
            Lock.Leave;
          end;
        end;
        SharedBridge.CloseCursor(cur);
        cur := 0;
        SharedBridge.CloseStmt(stmt);
        stmt := 0;
        eng.Release(conn);
        conn := 0;
      except
        Inc(localBad);
        try
          if cur > 0 then SharedBridge.CloseCursor(cur);
        except
        end;
        try
          if stmt > 0 then SharedBridge.CloseStmt(stmt);
        except
        end;
        try
          if conn > 0 then eng.Release(conn);
        except
        end;
      end;
    end;
    if eng.HandleCount <> 0 then
      Inc(localBad);
  finally
    eng.Free;
  end;
  TJVMManager.DetachThread;
  if localBad <> 0 then
  begin
    Lock.Enter;
    try
      Inc(ThreadFails, localBad);
    finally
      Lock.Leave;
    end;
  end;
end;

var
  classesDir: string;
  mainEng: TJdbcEngine;
  cfg: TPoolCfgRec;
  conn, stmt, cur: Int64;
  rows: TV2Rows;
  workers: array[0..THREADS - 1] of TSoakThread;
  t: Integer;
  attachBase: Integer;
begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: TestV2Soak <classesDir>');
    Halt(2);
  end;
  classesDir := ParamStr(1);
  Lock := TCriticalSection.Create;
  try
    TJVMManager.ResetForTests;
    TJVMManager.SetClassPath(classesDir + ';' + LibJar('HikariCP-5.1.0.jar') +
      ';' + LibJar('slf4j-api-2.0.9.jar') + ';' + LibJar('h2-2.2.224.jar') +
      ';' + LibJar('sqlite-jdbc-3.46.1.0.jar'));
    TJVMManager.EnsureStarted(FindJvmDll, TJVMManager.BuildDesktopArgs);
    attachBase := TJVMManager.AttachedCount;
    SharedBridge := TBridgeV2.Create;
    try
      Ok('bridge-version-2', SharedBridge.GetVersion = '2.0.0');
      mainEng := TJdbcEngine.Create(SharedBridge);
      try
        cfg := DefaultPoolCfg('jdbc:h2:mem:v2soak;DB_CLOSE_DELAY=-1',
          'org.h2.Driver');
        cfg.MaximumPoolSize := 10;
        SharedPool := mainEng.OpenPool(cfg);
        conn := mainEng.Borrow(SharedPool);
        SharedBridge.ExecDirect(conn, 'DROP TABLE IF EXISTS soak');
        Ok('ddl', SharedBridge.ExecDirect(conn,
          'CREATE TABLE soak(id BIGINT PRIMARY KEY, tag VARCHAR(50))') = 0);
        mainEng.Release(conn);
        for t := 0 to THREADS - 1 do
        begin
          workers[t] := TSoakThread.Create(t + 1);
          workers[t].Start;
        end;
        for t := 0 to THREADS - 1 do
        begin
          workers[t].WaitFor;
          workers[t].Free;
        end;
        Ok('no-misroute', Misroute = 0);
        Ok('no-thread-fails', ThreadFails = 0);
        conn := mainEng.Borrow(SharedPool);
        stmt := SharedBridge.Prepare(conn, 'SELECT COUNT(*) FROM soak');
        try
          cur := SharedBridge.QueryOpen(stmt, 10);
          try
            rows := SharedBridge.FetchWindow(cur, 10);
            Ok('soak-total', (Length(rows) = 1) and
              (rows[0][0] = IntToStr(THREADS * ITERS)));
          finally
            SharedBridge.CloseCursor(cur);
          end;
        finally
          SharedBridge.CloseStmt(stmt);
        end;
        mainEng.Release(conn);
        mainEng.ClosePool(SharedPool);
        Ok('handles-zero', mainEng.HandleCount = 0);
        Ok('threads-detached', TJVMManager.AttachedCount = attachBase);
      finally
        mainEng.Free;
      end;
    finally
      SharedBridge.Free;
    end;
    TJVMManager.ShutdownJvm;
  finally
    Lock.Free;
  end;
  WriteLn('TOTAL fails=', Fails);
  if Fails > 0 then Halt(1);
end.
