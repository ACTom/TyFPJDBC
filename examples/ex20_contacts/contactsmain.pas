unit ContactsMain;

{$mode objfpc}{$H+}
{$codepage UTF8}

{ 通讯录主窗体：DBGrid 只读浏览，增/改/删走 TJdbcCommand 命名参数，
  搜索按姓名/电话/邮箱 LIKE 重查。字段读写一律 UTF-8（AsUTF8String 纪律）。 }

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls,
  ExtCtrls, Grids, DBGrids, DB, LResources, TyFPJDBC.Handles, TyFPJDBC.JVM.Manager,
  TyFPJDBC.JNI.Bridge, TyFPJDBC.Engine, TyFPJDBC.Command, TyFPJDBC.Query,
  TyFPJDBC.LCL.Conn, TyFPJDBC.LCL.Query;

type
  TMainForm = class(TForm)
    Grid: TDBGrid;
    PanelBar: TPanel;
    LabFind: TLabel;
    EdSearch: TEdit;
    BtnSearch: TButton;
    BtnRefresh: TButton;
    BtnAdd: TButton;
    BtnEdit: TButton;
    BtnDel: TButton;
    LabStatus: TLabel;
    DbConn: TJdbcConnection;
    DbQuery: TJdbcConnQuery;
    Src: TDataSource;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure BtnSearchClick(Sender: TObject);
    procedure BtnRefreshClick(Sender: TObject);
    procedure BtnAddClick(Sender: TObject);
    procedure BtnEditClick(Sender: TObject);
    procedure BtnDelClick(Sender: TObject);
  private
    FDbPath: string;
    procedure RefreshGrid(const Filter: string);
    procedure EnsureContactsTable;
    procedure SeedContacts;
    procedure UpdateStatus;
    function QuoteLike(const S: string): string;
    function EditDialog(const Title: string; var AName, APhone, AEmail,
      ANote: string): Boolean;
  public
    function DebugState: string;
  end;

var
  MainForm: TMainForm;
  { 无界面校验模式（--verifyform）跳过错误弹窗，只记日志，避免无人值守时卡住。 }
  QuietStart: Boolean = False;
  { FormCreate 异常文本（QuietStart 下由 --verifyform 写入日志）。 }
  StartError: string = '';

implementation

procedure TMainForm.FormCreate(Sender: TObject);
begin
  Grid.Options := Grid.Options - [dgEditing];
  Grid.DataSource := Src;
  try
    DbConn.Database := ExtractFilePath(ParamStr(0)) + 'contacts.db';
    DbConn.Connected := True;
    FDbPath := DbConn.Database;
    EnsureContactsTable;
    DbQuery.Active := True;
    if DbQuery.RecordCount = 0 then
    begin
      SeedContacts;
      DbQuery.Refresh;
    end;
    RefreshGrid('');
  except
    on E: Exception do
    begin
      StartError := E.ClassName + ': ' + E.Message;
      if not QuietStart then
        MessageDlg('启动失败', '数据库打不开：' + E.Message, mtError, [mbOK], 0);
      Application.Terminate;
    end;
  end;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  DbQuery.Active := False;
  DbConn.Connected := False;
end;

procedure TMainForm.RefreshGrid(const Filter: string);
var
  sql: string;
begin
  sql := 'SELECT id,name,phone,email,note FROM contacts';
  if Trim(Filter) <> '' then
    sql := sql + ' WHERE name LIKE ' + QuoteLike(Filter) +
      ' OR phone LIKE ' + QuoteLike(Filter) +
      ' OR email LIKE ' + QuoteLike(Filter);
  sql := sql + ' ORDER BY id';
  DbQuery.SQLText := sql;
  DbQuery.Refresh;
  DbQuery.Fields[0].DisplayLabel := '编号';
  DbQuery.Fields[1].DisplayLabel := '姓名';
  DbQuery.Fields[2].DisplayLabel := '电话';
  DbQuery.Fields[3].DisplayLabel := '邮箱';
  DbQuery.Fields[4].DisplayLabel := '备注';
  UpdateStatus;
end;

procedure TMainForm.UpdateStatus;
begin
  LabStatus.Caption := '共 ' + IntToStr(DbQuery.RecordCount) + ' 条记录  |  ' + FDbPath;
end;

{ 首跑自动建表：库文件由 SQLite 连接时创建，表结构在这里补。 }
procedure TMainForm.EnsureContactsTable;
begin
  DbQuery.SQLText :=
    'CREATE TABLE IF NOT EXISTS contacts(' +
    'id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
    'name VARCHAR(50) NOT NULL, phone VARCHAR(30), ' +
    'email VARCHAR(80), note VARCHAR(200))';
  DbQuery.ExecSQL;
  DbQuery.SQLText :=
    'SELECT id,name,phone,email,note FROM contacts ORDER BY id';
end;

{ 首跑空表时写入 3 条示例，打开就能看到数据和中文。 }
procedure TMainForm.SeedContacts;
begin
  DbQuery.SQLText :=
    'INSERT INTO contacts(name,phone,email,note) VALUES(''张三'',' +
    '''13800001111'',''zhangsan@example.com'',''示例：中文原样存取'')';
  DbQuery.ExecSQL;
  DbQuery.SQLText :=
    'INSERT INTO contacts(name,phone,email,note) VALUES(''李四'',' +
    '''13900002222'',''lisi@example.com'',''示例：搜索姓名/电话/邮箱'')';
  DbQuery.ExecSQL;
  DbQuery.SQLText :=
    'INSERT INTO contacts(name,phone,email,note) VALUES(''王五'',' +
    '''13700003333'',''wangwu@example.com'',''示例：新增/修改/删除'')';
  DbQuery.ExecSQL;
  DbQuery.SQLText := 'SELECT id,name,phone,email,note FROM contacts ORDER BY id';
end;

function TMainForm.QuoteLike(const S: string): string;
begin
  Result := '''%' +
    StringReplace(Trim(S), '''', '''''', [rfReplaceAll]) + '%''';
end;

procedure TMainForm.BtnSearchClick(Sender: TObject);
begin
  RefreshGrid(EdSearch.Text);
end;

procedure TMainForm.BtnRefreshClick(Sender: TObject);
begin
  EdSearch.Text := '';
  RefreshGrid('');
end;

procedure TMainForm.BtnAddClick(Sender: TObject);
var
  nm, ph, em, nt: string;
begin
  nm := '';
  ph := '';
  em := '';
  nt := '';
  if not EditDialog('新增联系人', nm, ph, em, nt) then
    Exit;
  if Trim(nm) = '' then
  begin
    MessageDlg('提示', '姓名不能为空', mtWarning, [mbOK], 0);
    Exit;
  end;
  DbQuery.SetParam('name', nm);
  DbQuery.SetParam('phone', ph);
  DbQuery.SetParam('email', em);
  DbQuery.SetParam('note', nt);
  DbQuery.SQLText := 'INSERT INTO contacts(name,phone,email,note)' +
    ' VALUES(:name,:phone,:email,:note)';
  DbQuery.ExecSQL;
  RefreshGrid(EdSearch.Text);
end;

procedure TMainForm.BtnEditClick(Sender: TObject);
var
  id: Int64;
  nm, ph, em, nt: string;
begin
  if DbQuery.RecordCount = 0 then
    Exit;
  id := DbQuery.Fields[0].AsLargeInt;
  nm := DbQuery.Fields[1].AsUTF8String;
  ph := DbQuery.Fields[2].AsUTF8String;
  em := DbQuery.Fields[3].AsUTF8String;
  nt := DbQuery.Fields[4].AsUTF8String;
  if not EditDialog('修改联系人', nm, ph, em, nt) then
    Exit;
  if Trim(nm) = '' then
  begin
    MessageDlg('提示', '姓名不能为空', mtWarning, [mbOK], 0);
    Exit;
  end;
  DbQuery.SetParam('name', nm);
  DbQuery.SetParam('phone', ph);
  DbQuery.SetParam('email', em);
  DbQuery.SetParam('note', nt);
  DbQuery.SetParam('id', IntToStr(id));
  DbQuery.SQLText := 'UPDATE contacts SET name=:name,phone=:phone,' +
    'email=:email,note=:note WHERE id=:id';
  DbQuery.ExecSQL;
  RefreshGrid(EdSearch.Text);
end;

procedure TMainForm.BtnDelClick(Sender: TObject);
var
  id: Int64;
  nm: string;
begin
  if DbQuery.RecordCount = 0 then
    Exit;
  id := DbQuery.Fields[0].AsLargeInt;
  nm := DbQuery.Fields[1].AsUTF8String;
  if MessageDlg('确认删除', '删除联系人“' + nm + '”吗？',
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  DbQuery.SetParam('id', IntToStr(id));
  DbQuery.SQLText := 'DELETE FROM contacts WHERE id=:id';
  DbQuery.ExecSQL;
  RefreshGrid(EdSearch.Text);
end;

{ 供 --verifyform 取数：不抛异常，只拼状态串。 }
function TMainForm.DebugState: string;
var
  ds: TDataSet;
begin
  ds := Src.DataSet;
  Result := 'dataset-nil=' + BoolToStr(ds = nil, True) +
    ' starterror=' + StartError +
    ' status=' + LabStatus.Caption +
    ' conn-active=' + BoolToStr(DbConn.Connected, True) +
    ' query-active=' + BoolToStr(DbQuery.Active, True);
  if ds <> nil then
    Result := Result + ' count=' + IntToStr(ds.RecordCount);
end;

function TMainForm.EditDialog(const Title: string; var AName, APhone,
  AEmail, ANote: string): Boolean;
var
  d: TForm;
  labN, labP, labE, labNt: TLabel;
  edN, edP, edE, edNt: TEdit;
  okB, cancelB: TButton;

  procedure Place(L: TLabel; E: TEdit; Top: Integer; const Cap: string);
  begin
    L.Parent := d;
    L.Caption := Cap;
    L.Left := 16;
    L.Top := Top + 4;
    E.Parent := d;
    E.Left := 80;
    E.Top := Top;
    E.Width := 280;
  end;

begin
  d := TForm.Create(Self);
  try
    d.Caption := Title;
    d.Width := 392;
    d.Height := 264;
    d.Position := poMainFormCenter;
    d.BorderStyle := bsDialog;
    labN := TLabel.Create(d);
    labP := TLabel.Create(d);
    labE := TLabel.Create(d);
    labNt := TLabel.Create(d);
    edN := TEdit.Create(d);
    edP := TEdit.Create(d);
    edE := TEdit.Create(d);
    edNt := TEdit.Create(d);
    Place(labN, edN, 16, '姓名');
    Place(labP, edP, 52, '电话');
    Place(labE, edE, 88, '邮箱');
    Place(labNt, edNt, 124, '备注');
    edN.Text := AName;
    edP.Text := APhone;
    edE.Text := AEmail;
    edNt.Text := ANote;
    okB := TButton.Create(d);
    okB.Parent := d;
    okB.Caption := '确定';
    okB.ModalResult := mrOk;
    okB.Default := True;
    okB.Left := 184;
    okB.Top := 176;
    cancelB := TButton.Create(d);
    cancelB.Parent := d;
    cancelB.Caption := '取消';
    cancelB.ModalResult := mrCancel;
    cancelB.Cancel := True;
    cancelB.Left := 280;
    cancelB.Top := 176;
    Result := d.ShowModal = mrOk;
    if Result then
    begin
      AName := edN.Text;
      APhone := edP.Text;
      AEmail := edE.Text;
      ANote := edNt.Text;
    end;
  finally
    d.Free;
  end;
end;

initialization
{$I contactsmain.lrs}

end.
