unit Unit1;

{$mode objfpc}{$H+}

{ ex09: DBGrid + DBEdit + DBNavigator bound to TJDBCQuery.
  All visual layout lives in unit1.lfm (drawn form, no code-built UI).
  Data is loaded via LoadRowsBuffered; edit/append goes through
  CachedUpdates + ApplyUpdates with generated-keys回取. }

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, DBGrids, DBCtrls,
  StdCtrls, DB, TyFPJDBC.Query, TyFPJDBC.Options;

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
    procedure AddBtnClick(Sender: TObject);
    procedure ApplyBtnClick(Sender: TObject);
    procedure RefreshStatus;
  end;

var
  Form1: TForm1;

implementation

{$R *.lfm}

procedure TForm1.FormCreate(Sender: TObject);
var
  rows: TStringList;
begin
  rows := TStringList.Create;
  try
    rows.Add('1|hello');
    rows.Add('2|中文测试');
    rows.Add('3|jdbc-bridge');
    Q.LoadRowsBuffered(['id', 'name'], ['INTEGER', 'NVARCHAR'], rows);
    Q.CachedUpdates := True;
    Q.UpdateOptions.ReadOnly := False;
    Q.UpdateOptions.AutoIncField := 'id';
  finally
    rows.Free;
  end;
  RefreshStatus;
end;

procedure TForm1.AddBtnClick(Sender: TObject);
begin
  Q.Append;
  Q.Fields[1].AsString := '新增-中文测试';
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
  StatusLabel.Caption := '共 ' + IntToStr(Q.RecordCount) + ' 行 待提交=' +
    IntToStr(Q.PendingInserts);
end;

end.
