unit Unit1;

{$mode objfpc}{$H+}
{$codepage UTF8}

{ ex09: DBGrid + DBEdit + DBNavigator bound to TJDBCQuery.
  All visual layout lives in unit1.lfm (drawn form, no code-built UI).
  FormCreate loads REAL rows via GridData.TryLoadLive (Pascal -> JNI ->
  Bridge -> sqlite file DB); if the JVM/jars are unavailable it falls
  back to bundled rows and says so in the status line. Edit/append goes
  through CachedUpdates + ApplyUpdates; on the live path ApplyUpdates
  writes to the same real table. }

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, DBGrids, DBCtrls,
  StdCtrls, DB, TyFPJDBC.Query, TyFPJDBC.Options, GridData;

type
  TForm1 = class(TForm)
    Q: TJDBCQuery;
    DS: TDataSource;
    Grid: TDBGrid;
    Nav: TDBNavigator;
    NameEdit: TDBEdit;
    NameLabel: TLabel;
    AddBtn: TButton;
    ApplyBtn: TButton;
    StatusLabel: TLabel;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure AddBtnClick(Sender: TObject);
    procedure ApplyBtnClick(Sender: TObject);
    procedure RefreshStatus;
  private
    FLive: TObject;
    FPool: Int64;
    FConn: Int64;
    FLiveNote: string;
  end;

var
  Form1: TForm1;

implementation

{$R *.lfm}

function ClassesDir: string;
begin
  Result := GetEnvironmentVariable('TYFPJDBC_CLASSES');
  if Result = '' then
    Result := ExtractFilePath(ParamStr(0)) + '..' + PathDelim + 'jmain';
end;

procedure TForm1.FormCreate(Sender: TObject);
var
  rows: TStringList;
begin
  FLive := nil;
  FPool := 0;
  FConn := 0;
  if TryLoadLive(Q, ClassesDir, GetTempDir(False), FLive, FPool, FConn,
    FLiveNote) then
    StatusLabel.Caption := 'live OK; ' + FLiveNote
  else
  begin
    rows := GridSeedRows;
    try
      Q.LoadRowsBuffered(['id', 'name'], ['INTEGER', 'NVARCHAR'], rows);
      Q.CachedUpdates := True;
      Q.UpdateOptions.ReadOnly := False;
      Q.UpdateOptions.AutoIncField := 'id';
    finally
      rows.Free;
    end;
    StatusLabel.Caption := 'fallback rows; ' + FLiveNote;
  end;
  RefreshStatus;
end;

procedure TForm1.FormDestroy(Sender: TObject);
begin
  FreeLive(FLive, FPool);
  FLive := nil;
end;

procedure TForm1.AddBtnClick(Sender: TObject);
begin
  Q.Append;
  Q.FieldFromUTF8(Q.Fields[1], UTF8String('新增-中文测试'));
  Q.Post;
  RefreshStatus;
end;

procedure TForm1.ApplyBtnClick(Sender: TObject);
begin
  Q.ApplyUpdates;
  StatusLabel.Caption := '已应用 applied=' + IntToStr(Q.AppliedInserts) +
    ' 主键回取=' + IntToStr(Q.GetGeneratedKeys);
end;

procedure TForm1.RefreshStatus;
begin
  StatusLabel.Caption := StatusLabel.Caption + ' | 共 ' +
    IntToStr(Q.RecordCount) + ' 行 待提交=' + IntToStr(Q.PendingInserts);
end;

end.
