program contacts;

{$mode objfpc}{$H+}
{$codepage UTF8}

{ 通讯录 Demo：LCL 图形界面 + TyFPJDBC + SQLite。
  双击 contacts.exe 直接运行（jre/bridge/drivers 随 exe 分发）。
  contacts.exe --selftest 做无界面自检，结果写 selftest.log。
  contacts.exe --verifyform 做窗体装配校验，结果写 verifyform.log。 }

uses
  Interfaces, Forms, ContactsMain,
  SysUtils, Classes, TyFPJDBC.Handles, TyFPJDBC.JVM.Manager,
  TyFPJDBC.JNI.Bridge, TyFPJDBC.Engine, TyFPJDBC.Command, TyFPJDBC.Query;

{$R *.res}

function RunSelfTest: Integer;
var
  log: TStringList;
  root, db: string;
  bridge: TBridge;
  eng: TJdbcEngine;
  cfg: TPoolCfgRec;
  pool, conn: Int64;
  cmd: TJdbcCommand;
  q: TJdbcQuery;
  r: TBoundRow;
  fails: Integer;

  procedure Ok(const N: string; C: Boolean);
  begin
    if C then
      log.Add('PASS ' + N)
    else
    begin
      Inc(fails);
      log.Add('FAIL ' + N);
    end;
  end;

begin
  fails := 0;
  log := TStringList.Create;
  try
    root := ExtractFilePath(ParamStr(0));
    db := root + 'selftest.db';
    if FileExists(db) then
      DeleteFile(db);
    try
      { 不调 SetClassPath：默认走 exe 旁 bridge/* + drivers/*，正好验证分发布局。 }
      TJVMManager.EnsureStarted(TJVMManager.FindLibJvm(''),
        TJVMManager.BuildDesktopArgs);
      Ok('jvm-started', TJVMManager.IsStarted);
      log.Add('classpath=' + TJVMManager.GetClassPath);
      bridge := TBridge.Create;
      try
        eng := TJdbcEngine.Create(bridge);
        try
          cfg := DefaultPoolCfg('jdbc:sqlite:' + UTF8String(db), 'org.sqlite.JDBC');
          pool := eng.OpenPool(cfg);
          conn := eng.Borrow(pool);
          bridge.ExecDirect(conn,
            'CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT, name VARCHAR(50))');
          cmd := TJdbcCommand.Create(eng, conn);
          try
            cmd.SetSQL('INSERT INTO t(name) VALUES(:n)');
            SetLength(r, 1);
            r[0] := BStr('张三-中文');
            Ok('insert1', cmd.ExecUpdate(r) = 1);
          finally
            cmd.Free;
          end;
          q := TJdbcQuery.Create(nil);
          try
            q.OpenQuery(eng, conn, 't', 'SELECT id,name FROM t ORDER BY id', 100);
            Ok('rows1', q.RecordCount = 1);
            q.First;
            Ok('cjk', q.Fields[1].AsUTF8String = UTF8String('张三-中文'));
            q.CloseQuery;
          finally
            q.Free;
          end;
          eng.Release(conn);
          eng.ClosePool(pool);
          Ok('handles-zero', eng.HandleCount = 0);
          Ok('audit-zero', eng.AuditReport = 'pools=0 conns=0 stmts=0 cursors=0');
        finally
          eng.Free;
        end;
      finally
        bridge.Free;
      end;
      TJVMManager.ShutdownJvm;
    except
      on E: Exception do
      begin
        Inc(fails);
        log.Add('EXCEPTION ' + E.ClassName + ': ' + E.Message);
      end;
    end;
    log.Add('TOTAL fails=' + IntToStr(fails));
    log.SaveToFile(root + 'selftest.log');
    Result := Ord(fails > 0);
  finally
    log.Free;
  end;
end;

{ 窗体装配校验：实例化主窗体（会走完整 FormCreate/DB/种子链路），
  断言 lfm 控件全部装上、数据集已绑且有种子行。 }
function RunVerifyForm: Integer;
var
  log: TStringList;
  root: string;
  fails: Integer;

  procedure Ok(const N: string; C: Boolean);
  begin
    if C then
      log.Add('PASS ' + N)
    else
    begin
      Inc(fails);
      log.Add('FAIL ' + N);
    end;
  end;

begin
  fails := 0;
  log := TStringList.Create;
  try
    root := ExtractFilePath(ParamStr(0));
    QuietStart := True;
    try
      Application.Initialize;
      Application.CreateForm(TMainForm, MainForm);
      Ok('form-created', Assigned(MainForm));
      Ok('grid', Assigned(MainForm.Grid));
      Ok('panel', Assigned(MainForm.PanelBar));
      Ok('search-edit', Assigned(MainForm.EdSearch));
      Ok('btn-search', Assigned(MainForm.BtnSearch));
      Ok('btn-refresh', Assigned(MainForm.BtnRefresh));
      Ok('btn-add', Assigned(MainForm.BtnAdd));
      Ok('btn-edit', Assigned(MainForm.BtnEdit));
      Ok('btn-del', Assigned(MainForm.BtnDel));
      Ok('status-label', Assigned(MainForm.LabStatus));
      Ok('datasource', Assigned(MainForm.Src));
      Ok('dbconn-comp', Assigned(MainForm.DbConn));
      Ok('dbquery-comp', Assigned(MainForm.DbQuery));
      Ok('dataset-bound', Assigned(MainForm.Src.DataSet));
      Ok('conn-active', MainForm.DbConn.Connected);
      Ok('query-active', MainForm.DbQuery.Active);
      Ok('seed-rows', Assigned(MainForm.Src.DataSet) and
        (MainForm.Src.DataSet.RecordCount >= 3));
      Ok('status-text', Pos('条记录', MainForm.LabStatus.Caption) > 0);
      Ok('grid-datasource', MainForm.Grid.DataSource = MainForm.Src);
      log.Add('DEBUG ' + MainForm.DebugState);
      if StartError <> '' then
        log.Add('STARTERROR ' + StartError);
    except
      on E: Exception do
      begin
        Inc(fails);
        log.Add('EXCEPTION ' + E.ClassName + ': ' + E.Message);
      end;
    end;
    log.Add('TOTAL fails=' + IntToStr(fails));
    log.SaveToFile(root + 'verifyform.log');
    Result := Ord(fails > 0);
  finally
    log.Free;
  end;
end;

begin
  if (ParamCount >= 1) and (ParamStr(1) = '--selftest') then
    Halt(RunSelfTest);
  if (ParamCount >= 1) and (ParamStr(1) = '--verifyform') then
    Halt(RunVerifyForm);
  Application.Title := '通讯录';
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
