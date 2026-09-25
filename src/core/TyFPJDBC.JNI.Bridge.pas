unit TyFPJDBC.JNI.Bridge;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, jni, TyFPJDBC.JVM.Manager, TyFPJDBC.Handles;

type
  TJdbcRow = array of UTF8String;
  TJdbcRows = array of TJdbcRow;
  TIntArray = array of LongInt;
  TNullMatrix = array of array of Boolean;

  { Window page: strings plus the NULL bitmap from fetchLastNulls.
    Rows[i][j] = '' with Nulls[i][j] = False means a real empty string;
    Nulls[i][j] = True means SQL NULL regardless of the string cell. }
  TFetchPage = record
    Rows: TJdbcRows;
    Nulls: TNullMatrix;
  end;

  { Config mirror of tyfpjdbc.PoolCfg: shipped to Java via createPoolFlat so
    Pascal never builds Java objects field-by-field over JNI. }
  TPoolCfgRec = record
    Url, User, Password, DriverClass: UTF8String;
    MaximumPoolSize, MinimumIdle: Integer;
    ConnectionTimeoutMs, MaxLifetimeMs, KeepaliveTimeMs: Int64;
    LeakDetectionThresholdMs: Int64;
    ConnectionTestQuery: UTF8String;
    ValidationTimeoutMs: Int64;
    ReadOnly, AutoCommit: Boolean;
    IsolationName, Catalog, Schema: UTF8String;
  end;

  TPoolStatRec = record
    Active, Idle, Waiting, Leak: Integer;
  end;

function DefaultPoolCfg(const Url, DriverClass: UTF8String): TPoolCfgRec;

type
  { Thin JNI client over tyfpjdbc.Bridge (VERSION 0.9.0). Every call first
    validates handles locally (HY000/99); driver errors surface with the
    ThreadLocal chain from getErrorChain. }
  TBridge = class
  private
    FObj: jobject;
    FClass: jclass;
    FMGetVersion, FMCreatePoolFlat, FMDestroyPool, FMBorrow, FMCloseConn: jmethodID;
    FMSetAutoCommit, FMCommit, FMRollback, FMSavepoint, FMRollbackTo, FMReleaseSp: jmethodID;
    FMSetReadOnly, FMSetCatalog, FMSetSchema, FMSetIsolation, FMIsValid, FMDbMeta: jmethodID;
    FMPrepare, FMPrepareCall, FMSetTimeout: jmethodID;
    FMBindLong, FMBindDouble, FMBindBD, FMBindStr, FMBindDate, FMBindTime: jmethodID;
    FMBindTS, FMBindBytes, FMBindNull, FMAddBatch, FMExecUpdate, FMExecBatch: jmethodID;
    FMGenKeys, FMExecDirect, FMExecDirectTimeout: jmethodID;
    FMRegisterOut, FMExecProc, FMGetOut: jmethodID;
    FMCancel, FMCloseStmt: jmethodID;
    FMQueryOpen, FMCursorCols, FMCursorNames, FMCursorTypeNames, FMCursorTypeCodes: jmethodID;
    FMFetchWindow, FMFetchNulls, FMCloseCursor: jmethodID;
    FMGetTables, FMGetColumns, FMGetPKs: jmethodID;
    FMWriteBlob, FMFetchBlob: jmethodID;
    FMPoolActive, FMPoolIdle, FMPoolWaiting, FMPoolLeak: jmethodID;
    FMHeapUsed, FMHeapMax, FMErrorChain: jmethodID;
    function Env: PJNIEnv;
    function Mid(const Name, Sig: string): jmethodID;
    procedure CheckJ(const What: string);
    function JStr(const S: UTF8String): jstring;
    function FromJStr(JS: jstring): UTF8String;
    function SafeErrorChain: UTF8String;
    function CallJString0(M: jmethodID): UTF8String;
    function CallLong1(M: jmethodID; A: jlong): jlong;
    function CallLongStr(M: jmethodID; A: jlong; const S: UTF8String): jlong;
    function CallInt1(M: jmethodID; A: jlong): Integer;
    function CallBool2(M: jmethodID; A: jlong; B: Boolean): Boolean;
    procedure CallVoid1J(M: jmethodID; A: jlong);
    procedure CallVoidJZ(M: jmethodID; A: jlong; B: Boolean);
    procedure CallVoidJS(M: jmethodID; A: jlong; const S: UTF8String);
    function CallIntStr(M: jmethodID; A: jlong; const S: UTF8String): Integer;
    function CallStrArray1(M: jmethodID; A: jlong): TStringList;
    function CallStrMatrix(M: jmethodID; A: jlong; const S: UTF8String): TJdbcRows;
    function CallWindow(M: jmethodID; A: jlong; Size: Integer): TJdbcRows;
    function CallBoolMatrix(M: jmethodID; A: jlong): TNullMatrix;
    function CallBytes(M: jmethodID; A: jlong; const S: UTF8String): TBytes;
  public
    constructor Create;
    destructor Destroy; override;
    function GetVersion: UTF8String;
    function CreatePool(const Cfg: TPoolCfgRec): Int64;
    procedure DestroyPool(PoolId: Int64);
    function BorrowConn(PoolId: Int64): Int64;
    procedure CloseConn(ConnId: Int64);
    procedure SetAutoCommit(ConnId: Int64; Auto: Boolean);
    procedure Commit(ConnId: Int64);
    procedure Rollback(ConnId: Int64);
    procedure Savepoint(ConnId: Int64; const Name: UTF8String);
    procedure RollbackTo(ConnId: Int64; const Name: UTF8String);
    procedure ReleaseSavepoint(ConnId: Int64; const Name: UTF8String);
    procedure SetReadOnly(ConnId: Int64; Ro: Boolean);
    procedure SetCatalog(ConnId: Int64; const V: UTF8String);
    procedure SetSchema(ConnId: Int64; const V: UTF8String);
    procedure SetIsolation(ConnId: Int64; const Name: UTF8String);
    function IsValid(ConnId: Int64; TimeoutSecs: Integer): Boolean;
    function DatabaseMeta(ConnId: Int64): UTF8String;
    function Prepare(ConnId: Int64; const SQL: UTF8String): Int64;
    function PrepareCall(ConnId: Int64; const SQL: UTF8String): Int64;
    procedure SetTimeout(StmtId: Int64; Secs: Integer);
    procedure BindLong(StmtId: Int64; Idx: Integer; V: Int64);
    procedure BindDouble(StmtId: Int64; Idx: Integer; V: Double);
    procedure BindBigDecimal(StmtId: Int64; Idx: Integer; const V: UTF8String);
    procedure BindString(StmtId: Int64; Idx: Integer; const V: UTF8String);
    procedure BindDate(StmtId: Int64; Idx: Integer; const Iso: UTF8String);
    procedure BindTime(StmtId: Int64; Idx: Integer; const Iso: UTF8String);
    procedure BindTimestamp(StmtId: Int64; Idx: Integer; const Iso: UTF8String);
    procedure BindBytes(StmtId: Int64; Idx: Integer; const V: TBytes);
    procedure BindNull(StmtId: Int64; Idx: Integer; SqlType: Integer);
    procedure AddBatch(StmtId: Int64);
    function ExecUpdate(StmtId: Int64): Integer;
    function ExecBatch(StmtId: Int64): Integer;
    function GeneratedKeys(StmtId: Int64): TJdbcRow;
    function ExecDirect(ConnId: Int64; const SQL: UTF8String): Integer;
    function ExecDirectTimeout(ConnId: Int64; const SQL: UTF8String; Secs: Integer): Integer;
    procedure RegisterOut(StmtId: Int64; Idx, SqlType: Integer);
    function ExecProc(StmtId: Int64): Boolean;
    function OutValue(StmtId: Int64; Idx: Integer): UTF8String;
    procedure Cancel(StmtId: Int64);
    procedure CloseStmt(StmtId: Int64);
    function QueryOpen(StmtId: Int64; FetchSize: Integer): Int64;
    function CursorCols(CursorId: Int64): Integer;
    function CursorNames(CursorId: Int64): TStringList;
    function CursorTypeNames(CursorId: Int64): TStringList;
    function CursorTypeCodes(CursorId: Int64): TIntArray;
    function FetchWindow(CursorId: Int64; Size: Integer): TJdbcRows;
    function FetchLastNulls(CursorId: Int64): TNullMatrix;
    function FetchPage(CursorId: Int64; Size: Integer): TFetchPage;
    procedure CloseCursor(CursorId: Int64);
    function GetTables(ConnId: Int64; const Table: UTF8String): TJdbcRows;
    function GetColumns(ConnId: Int64; const Table: UTF8String): TJdbcRows;
    function GetPrimaryKeys(ConnId: Int64; const Table: UTF8String): TStringList;
    function WriteBlob(ConnId: Int64; const SQL: UTF8String; const Data: TBytes): Integer;
    function FetchBlob(ConnId: Int64; const SQL: UTF8String): TBytes;
    function PoolStats(PoolId: Int64): TPoolStatRec;
    function HeapUsed: Int64;
    function HeapMax: Int64;
    function ErrorChain: UTF8String;
  end;

implementation

uses
  TyFPJDBC.Config, TyFPJDBC.Errors;

function DefaultPoolCfg(const Url, DriverClass: UTF8String): TPoolCfgRec;
var
  cfg: TJdbcConfig;
begin
  cfg := TJdbcConfig.Default;
  try
    Result.Url := Url;
    Result.User := '';
    Result.Password := '';
    Result.DriverClass := DriverClass;
    Result.MaximumPoolSize := cfg.Pool_MaxPool;
    Result.MinimumIdle := cfg.Pool_MinIdle;
    Result.ConnectionTimeoutMs := cfg.Pool_ConnTimeoutMs;
    Result.MaxLifetimeMs := cfg.Pool_MaxLifetimeMs;
    Result.KeepaliveTimeMs := cfg.Pool_KeepaliveMs;
    Result.LeakDetectionThresholdMs := cfg.Pool_LeakMs;
    Result.ConnectionTestQuery := UTF8String(cfg.Pool_TestQuery);
    Result.ValidationTimeoutMs := cfg.Pool_ValidTimeoutMs;
    Result.ReadOnly := False;
    Result.AutoCommit := True;
    Result.IsolationName := 'READ_COMMITTED';
    Result.Catalog := '';
    Result.Schema := '';
  finally
    cfg.Free;
  end;
end;

function TBridge.Env: PJNIEnv;
begin
  Result := TJVMManager.GetJNIEnv;
end;

procedure TBridge.CheckJ(const What: string);
var
  e: PJNIEnv;
  chain: UTF8String;
  st: string;
  code: Integer;
  p, q, r: Integer;
  codeStr: string;
begin
  e := TJVMManager.GetJNIEnv;
  if e^^.ExceptionOccurred(e) <> nil then
  begin
    e^^.ExceptionClear(e);
    chain := SafeErrorChain;
    if chain = '' then
      chain := 'jni exception';
    { Preserve the driver SQLState/code from the ThreadLocal chain
      (format SQLState=XXXXX;code=N;msg=...). Without this every driver
      error flattens to HY000/99 and breaks HY092/43 + constraint
      classification. }
    st := 'HY000';
    code := 99;
    p := Pos('SQLState=', string(chain));
    if p > 0 then
    begin
      st := Copy(string(chain), p + 9, 5);
      if Length(st) <> 5 then
        st := 'HY000';
    end;
    q := Pos(';code=', string(chain));
    if q > 0 then
    begin
      r := q + 6;
      codeStr := '';
      while (r <= Length(chain)) and (chain[r] in ['0'..'9']) do
      begin
        codeStr := codeStr + string(chain[r]);
        Inc(r);
      end;
      if codeStr <> '' then
        code := StrToIntDef(codeStr, 99);
    end;
    raise EJDBCError.CreateChain('bridge.' + What + ' failed', st, code, chain);
  end;
end;

function TBridge.JStr(const S: UTF8String): jstring;
var
  e: PJNIEnv;
begin
  e := TJVMManager.GetJNIEnv;
  if S = '' then
    Result := e^^.NewStringUTF(e, '')
  else
    Result := e^^.NewStringUTF(e, PChar(S));
  CheckJ('newstring');
  if Result = nil then
    raise EJDBCError.CreateChain('bridge.newstring failed', 'HY000', 99, 'null jstring');
end;

function TBridge.FromJStr(JS: jstring): UTF8String;
var
  e: PJNIEnv;
  p: PChar;
  n: jsize;
  u: UTF8String;
begin
  if JS = nil then
    Exit('');
  e := TJVMManager.GetJNIEnv;
  p := e^^.GetStringUTFChars(e, JS, nil);
  CheckJ('getutf');
  if p = nil then
    Exit('');
  try
    n := e^^.GetStringUTFLength(e, JS);
    SetLength(u, n);
    if n > 0 then
      Move(p^, u[1], n);
    Result := u;
  finally
    e^^.ReleaseStringUTFChars(e, JS, p);
  end;
end;

function TBridge.SafeErrorChain: UTF8String;
var
  e: PJNIEnv;
  js: jstring;
  args: array[0..0] of jvalue;
begin
  Result := '';
  try
    if (FObj = nil) or (FMErrorChain = nil) then
      Exit;
    e := TJVMManager.GetJNIEnv;
    FillChar(args, SizeOf(args), 0);
    js := jstring(e^^.CallObjectMethodA(e, FObj, FMErrorChain, @args[0]));
    if e^^.ExceptionOccurred(e) <> nil then
    begin
      e^^.ExceptionClear(e);
      Exit;
    end;
    if js = nil then
      Exit;
    try
      Result := FromJStr(js);
    finally
      e^^.DeleteLocalRef(e, js);
    end;
  except
    Result := '';
  end;
end;

function TBridge.Mid(const Name, Sig: string): jmethodID;
var
  e: PJNIEnv;
begin
  e := TJVMManager.GetJNIEnv;
  Result := e^^.GetMethodID(e, FClass, PChar(Name), PChar(Sig));
  CheckJ('method ' + Name);
  if Result = nil then
    raise EJDBCError.CreateChain('bridge.method missing', 'HY000', 99, Name);
end;

function TBridge.CallJString0(M: jmethodID): UTF8String;
var
  e: PJNIEnv;
  js: jstring;
begin
  e := TJVMManager.GetJNIEnv;
  js := jstring(e^^.CallObjectMethod(e, FObj, M));
  CheckJ('callstring');
  if js = nil then
    Exit('');
  try
    Result := FromJStr(js);
  finally
    e^^.DeleteLocalRef(e, js);
  end;
end;

function TBridge.CallLong1(M: jmethodID; A: jlong): jlong;
var
  e: PJNIEnv;
  args: array[0..0] of jvalue;
begin
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  args[0].j := A;
  Result := e^^.CallLongMethodA(e, FObj, M, @args[0]);
  CheckJ('calllong');
end;

function TBridge.CallLongStr(M: jmethodID; A: jlong; const S: UTF8String): jlong;
var
  e: PJNIEnv;
  args: array[0..1] of jvalue;
  js: jstring;
begin
  CheckHandle('arg', A);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  js := JStr(S);
  try
    args[0].j := A;
    args[1].l := js;
    Result := e^^.CallLongMethodA(e, FObj, M, @args[0]);
    CheckJ('calllongstr');
  finally
    e^^.DeleteLocalRef(e, js);
  end;
end;

function TBridge.CallInt1(M: jmethodID; A: jlong): Integer;
var
  e: PJNIEnv;
  args: array[0..0] of jvalue;
begin
  CheckHandle('arg', A);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  args[0].j := A;
  Result := e^^.CallIntMethodA(e, FObj, M, @args[0]);
  CheckJ('callint');
end;

function TBridge.CallBool2(M: jmethodID; A: jlong; B: Boolean): Boolean;
var
  e: PJNIEnv;
  args: array[0..1] of jvalue;
begin
  CheckHandle('arg', A);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  args[0].j := A;
  args[1].i := Ord(B);
  Result := e^^.CallBooleanMethodA(e, FObj, M, @args[0]) <> 0;
  CheckJ('callbool');
end;

procedure TBridge.CallVoid1J(M: jmethodID; A: jlong);
var
  e: PJNIEnv;
  args: array[0..0] of jvalue;
begin
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  args[0].j := A;
  e^^.CallVoidMethodA(e, FObj, M, @args[0]);
  CheckJ('callvoid');
end;

procedure TBridge.CallVoidJZ(M: jmethodID; A: jlong; B: Boolean);
var
  e: PJNIEnv;
  args: array[0..1] of jvalue;
begin
  CheckHandle('arg', A);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  args[0].j := A;
  args[1].z := Byte(Ord(B));
  e^^.CallVoidMethodA(e, FObj, M, @args[0]);
  CheckJ('callvoidz');
end;

procedure TBridge.CallVoidJS(M: jmethodID; A: jlong; const S: UTF8String);
var
  e: PJNIEnv;
  args: array[0..1] of jvalue;
  js: jstring;
begin
  CheckHandle('arg', A);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  js := JStr(S);
  try
    args[0].j := A;
    args[1].l := js;
    e^^.CallVoidMethodA(e, FObj, M, @args[0]);
    CheckJ('callvoids');
  finally
    e^^.DeleteLocalRef(e, js);
  end;
end;

function TBridge.CallIntStr(M: jmethodID; A: jlong; const S: UTF8String): Integer;
var
  e: PJNIEnv;
  args: array[0..1] of jvalue;
  js: jstring;
begin
  CheckHandle('arg', A);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  js := JStr(S);
  try
    args[0].j := A;
    args[1].l := js;
    Result := e^^.CallIntMethodA(e, FObj, M, @args[0]);
    CheckJ('callints');
  finally
    e^^.DeleteLocalRef(e, js);
  end;
end;

function TBridge.CallStrArray1(M: jmethodID; A: jlong): TStringList;
var
  e: PJNIEnv;
  args: array[0..0] of jvalue;
  arr: jobjectArray;
  n, i: Integer;
  cell: jobject;
begin
  Result := TStringList.Create;
  CheckHandle('arg', A);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  args[0].j := A;
  arr := jobjectArray(e^^.CallObjectMethodA(e, FObj, M, @args[0]));
  CheckJ('callstrarr');
  if arr = nil then
    Exit;
  try
    n := e^^.GetArrayLength(e, arr);
    CheckJ('arrlen');
    for i := 0 to n - 1 do
    begin
      cell := e^^.GetObjectArrayElement(e, arr, i);
      CheckJ('arrcell');
      try
        if cell = nil then
          Result.Add('')
        else
          Result.Add(string(FromJStr(jstring(cell))));
      finally
        if cell <> nil then
          e^^.DeleteLocalRef(e, cell);
      end;
    end;
  finally
    e^^.DeleteLocalRef(e, arr);
  end;
end;

function TBridge.CallStrMatrix(M: jmethodID; A: jlong; const S: UTF8String): TJdbcRows;
var
  e: PJNIEnv;
  args: array[0..1] of jvalue;
  js: jstring;
  outer, inner: jobjectArray;
  nr, nc, i, j: Integer;
  cell: jobject;
begin
  SetLength(Result, 0);
  CheckHandle('arg', A);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  js := JStr(S);
  try
    args[0].j := A;
    args[1].l := js;
    outer := jobjectArray(e^^.CallObjectMethodA(e, FObj, M, @args[0]));
    CheckJ('callmatrix');
    if outer = nil then
      Exit;
    try
      nr := e^^.GetArrayLength(e, outer);
      CheckJ('matrixlen');
      SetLength(Result, nr);
      for i := 0 to nr - 1 do
      begin
        inner := jobjectArray(e^^.GetObjectArrayElement(e, outer, i));
        CheckJ('matrixrow');
        try
          if inner = nil then
          begin
            SetLength(Result[i], 0);
            Continue;
          end;
          nc := e^^.GetArrayLength(e, inner);
          SetLength(Result[i], nc);
          for j := 0 to nc - 1 do
          begin
            cell := e^^.GetObjectArrayElement(e, inner, j);
            CheckJ('matrixcell');
            try
              Result[i][j] := FromJStr(jstring(cell));
            finally
              if cell <> nil then
                e^^.DeleteLocalRef(e, cell);
            end;
          end;
        finally
          e^^.DeleteLocalRef(e, inner);
        end;
      end;
    finally
      e^^.DeleteLocalRef(e, outer);
    end;
  finally
    e^^.DeleteLocalRef(e, js);
  end;
end;

function TBridge.CallWindow(M: jmethodID; A: jlong; Size: Integer): TJdbcRows;
var
  e: PJNIEnv;
  args: array[0..1] of jvalue;
  outer, inner: jobjectArray;
  nr, nc, i, j: Integer;
  cell: jobject;
begin
  SetLength(Result, 0);
  CheckHandle('cursor', A);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  args[0].j := A;
  args[1].i := Size;
  outer := jobjectArray(e^^.CallObjectMethodA(e, FObj, M, @args[0]));
  CheckJ('fetchwindow');
  if outer = nil then
    Exit;
  try
    nr := e^^.GetArrayLength(e, outer);
    CheckJ('winlen');
    SetLength(Result, nr);
    for i := 0 to nr - 1 do
    begin
      inner := jobjectArray(e^^.GetObjectArrayElement(e, outer, i));
      CheckJ('winrow');
      try
        if inner = nil then
        begin
          SetLength(Result[i], 0);
          Continue;
        end;
        nc := e^^.GetArrayLength(e, inner);
        SetLength(Result[i], nc);
        for j := 0 to nc - 1 do
        begin
          cell := e^^.GetObjectArrayElement(e, inner, j);
          CheckJ('wincell');
          try
            Result[i][j] := FromJStr(jstring(cell));
          finally
            if cell <> nil then
              e^^.DeleteLocalRef(e, cell);
          end;
        end;
      finally
        e^^.DeleteLocalRef(e, inner);
      end;
    end;
  finally
    e^^.DeleteLocalRef(e, outer);
  end;
end;

function TBridge.CallBytes(M: jmethodID; A: jlong; const S: UTF8String): TBytes;
var
  e: PJNIEnv;
  args: array[0..1] of jvalue;
  js: jstring;
  arr: jbyteArray;
  n: jsize;
  elems: PJByte;
  isCopy: jboolean;
begin
  SetLength(Result, 0);
  CheckHandle('arg', A);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  js := JStr(S);
  try
    args[0].j := A;
    args[1].l := js;
    arr := jbyteArray(e^^.CallObjectMethodA(e, FObj, M, @args[0]));
    CheckJ('callbytes');
    if arr = nil then
      Exit;
    try
      n := e^^.GetArrayLength(e, arr);
      SetLength(Result, n);
      if n > 0 then
      begin
        isCopy := 0;
        elems := e^^.GetByteArrayElements(e, arr, isCopy);
        CheckJ('byteselems');
        try
          Move(elems^, Result[0], n);
        finally
          e^^.ReleaseByteArrayElements(e, arr, elems, JNI_ABORT);
        end;
      end;
    finally
      e^^.DeleteLocalRef(e, arr);
    end;
  finally
    e^^.DeleteLocalRef(e, js);
  end;
end;

constructor TBridge.Create;
var
  e: PJNIEnv;
  cls: jclass;
  ctor: jmethodID;
  obj, g, gc: jobject;
begin
  inherited Create;
  e := TJVMManager.GetJNIEnv;
  cls := e^^.FindClass(e, 'tyfpjdbc/Bridge');
  if (e^^.ExceptionOccurred(e) <> nil) or (cls = nil) then
  begin
    e^^.ExceptionClear(e);
    raise EJDBCError.CreateChain('bridge class missing', 'HY000', 99,
      'tyfpjdbc/Bridge not found; check -Djava.class.path');
  end;
  try
    ctor := e^^.GetMethodID(e, cls, '<init>', '()V');
    if (e^^.ExceptionOccurred(e) <> nil) or (ctor = nil) then
    begin
      e^^.ExceptionClear(e);
      raise EJDBCError.CreateChain('bridge ctor missing', 'HY000', 99,
        'tyfpjdbc/Bridge.<init>');
    end;
    obj := e^^.NewObjectA(e, cls, ctor, nil);
    if (e^^.ExceptionOccurred(e) <> nil) or (obj = nil) then
    begin
      e^^.ExceptionClear(e);
      raise EJDBCError.CreateChain('bridge ctor failed', 'HY000', 99,
        'NewObject tyfpjdbc/Bridge');
    end;
    g := e^^.NewGlobalRef(e, obj);
    e^^.DeleteLocalRef(e, obj);
    if g = nil then
      raise EJDBCError.CreateChain('bridge ref failed', 'HY000', 99, 'NewGlobalRef');
    FObj := g;
    gc := jclass(e^^.NewGlobalRef(e, cls));
    if gc = nil then
    begin
      e^^.DeleteGlobalRef(e, FObj);
      FObj := nil;
      raise EJDBCError.CreateChain('bridge class ref failed', 'HY000', 99, 'NewGlobalRef class');
    end;
    FClass := gc;
  finally
    e^^.DeleteLocalRef(e, cls);
  end;
  FMGetVersion := Mid('getVersion', '()Ljava/lang/String;');
  FMCreatePoolFlat := Mid('createPoolFlat',
    '(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;IIJJJJLjava/lang/String;JZZLjava/lang/String;Ljava/lang/String;Ljava/lang/String;)J');
  FMDestroyPool := Mid('destroyPool', '(J)V');
  FMBorrow := Mid('borrowConn', '(J)J');
  FMCloseConn := Mid('closeConn', '(J)V');
  FMSetAutoCommit := Mid('setAutoCommit', '(JZ)V');
  FMCommit := Mid('commit', '(J)V');
  FMRollback := Mid('rollback', '(J)V');
  FMSavepoint := Mid('savepoint', '(JLjava/lang/String;)V');
  FMRollbackTo := Mid('rollbackTo', '(JLjava/lang/String;)V');
  FMReleaseSp := Mid('releaseSavepoint', '(JLjava/lang/String;)V');
  FMSetReadOnly := Mid('setReadOnly', '(JZ)V');
  FMSetCatalog := Mid('setCatalog', '(JLjava/lang/String;)V');
  FMSetSchema := Mid('setSchema', '(JLjava/lang/String;)V');
  FMSetIsolation := Mid('setIsolation', '(JLjava/lang/String;)V');
  FMIsValid := Mid('isValid', '(JI)Z');
  FMDbMeta := Mid('getDatabaseMeta', '(J)Ljava/lang/String;');
  FMPrepare := Mid('prepare', '(JLjava/lang/String;)J');
  FMPrepareCall := Mid('prepareCall', '(JLjava/lang/String;)J');
  FMSetTimeout := Mid('setTimeout', '(JI)V');
  FMBindLong := Mid('bindLong', '(JIJ)V');
  FMBindDouble := Mid('bindDouble', '(JID)V');
  FMBindBD := Mid('bindBigDecimal', '(JILjava/lang/String;)V');
  FMBindStr := Mid('bindString', '(JILjava/lang/String;)V');
  FMBindDate := Mid('bindDate', '(JILjava/lang/String;)V');
  FMBindTime := Mid('bindTime', '(JILjava/lang/String;)V');
  FMBindTS := Mid('bindTimestamp', '(JILjava/lang/String;)V');
  FMBindBytes := Mid('bindBytes', '(JI[B)V');
  FMBindNull := Mid('bindNull', '(JII)V');
  FMAddBatch := Mid('addBatch', '(J)V');
  FMExecUpdate := Mid('execUpdate', '(J)I');
  FMExecBatch := Mid('execBatch', '(J)I');
  FMGenKeys := Mid('getGeneratedKeys', '(J)[Ljava/lang/String;');
  FMExecDirect := Mid('execDirect', '(JLjava/lang/String;)I');
  FMExecDirectTimeout := Mid('execDirectTimeout', '(JLjava/lang/String;I)I');
  FMRegisterOut := Mid('registerOut', '(JII)V');
  FMExecProc := Mid('execProc', '(J)Z');
  FMGetOut := Mid('getOutValue', '(JI)Ljava/lang/String;');
  FMCancel := Mid('cancel', '(J)V');
  FMCloseStmt := Mid('closeStmt', '(J)V');
  FMQueryOpen := Mid('queryOpen', '(JI)J');
  FMCursorCols := Mid('cursorCols', '(J)I');
  FMCursorNames := Mid('cursorNames', '(J)[Ljava/lang/String;');
  FMCursorTypeNames := Mid('cursorTypeNames', '(J)[Ljava/lang/String;');
  FMCursorTypeCodes := Mid('cursorTypeCodes', '(J)[I');
  FMFetchWindow := Mid('fetchWindow', '(JI)[[Ljava/lang/String;');
  FMFetchNulls := Mid('fetchLastNulls', '(J)[[Z');
  FMCloseCursor := Mid('closeCursor', '(J)V');
  FMGetTables := Mid('getTables', '(JLjava/lang/String;)[[Ljava/lang/String;');
  FMGetColumns := Mid('getColumns', '(JLjava/lang/String;)[[Ljava/lang/String;');
  FMGetPKs := Mid('getPrimaryKeys', '(JLjava/lang/String;)[Ljava/lang/String;');
  FMWriteBlob := Mid('writeBlob', '(JLjava/lang/String;[B)I');
  FMFetchBlob := Mid('fetchBlob', '(JLjava/lang/String;)[B');
  FMPoolActive := Mid('poolActive', '(J)I');
  FMPoolIdle := Mid('poolIdle', '(J)I');
  FMPoolWaiting := Mid('poolWaiting', '(J)I');
  FMPoolLeak := Mid('poolLeak', '(J)I');
  FMHeapUsed := Mid('heapUsedBytes', '()J');
  FMHeapMax := Mid('heapMaxBytes', '()J');
  FMErrorChain := Mid('getErrorChain', '()Ljava/lang/String;');
  if GetVersion <> '0.9.0' then
    raise EJDBCError.CreateChain('bridge version mismatch', 'HY000', 99,
      'expected 0.9.0 got ' + string(GetVersion) + '; ' + ErrAdvice(ecConfig));
end;

destructor TBridge.Destroy;
var
  e: PJNIEnv;
begin
  try
    e := TJVMManager.GetJNIEnv;
    if FObj <> nil then
      e^^.DeleteGlobalRef(e, FObj);
    if FClass <> nil then
      e^^.DeleteGlobalRef(e, FClass);
  except
  end;
  inherited;
end;

function TBridge.GetVersion: UTF8String;
begin
  Result := CallJString0(FMGetVersion);
end;

function TBridge.CreatePool(const Cfg: TPoolCfgRec): Int64;
var
  e: PJNIEnv;
  args: array[0..16] of jvalue;
  su, ss, sp, sd, stq, sis, sc, ssch: jstring;
begin
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  su := JStr(Cfg.Url); ss := JStr(Cfg.User); sp := JStr(Cfg.Password);
  sd := JStr(Cfg.DriverClass); stq := JStr(Cfg.ConnectionTestQuery);
  sis := JStr(Cfg.IsolationName); sc := JStr(Cfg.Catalog); ssch := JStr(Cfg.Schema);
  try
    args[0].l := su; args[1].l := ss; args[2].l := sp; args[3].l := sd;
    args[4].i := Cfg.MaximumPoolSize; args[5].i := Cfg.MinimumIdle;
    args[6].j := Cfg.ConnectionTimeoutMs; args[7].j := Cfg.MaxLifetimeMs;
    args[8].j := Cfg.KeepaliveTimeMs; args[9].j := Cfg.LeakDetectionThresholdMs;
    args[10].l := stq; args[11].j := Cfg.ValidationTimeoutMs;
    args[12].z := Byte(Ord(Cfg.ReadOnly)); args[13].z := Byte(Ord(Cfg.AutoCommit));
    args[14].l := sis; args[15].l := sc; args[16].l := ssch;
    Result := e^^.CallLongMethodA(e, FObj, FMCreatePoolFlat, @args[0]);
    CheckJ('createPoolFlat');
  finally
    e^^.DeleteLocalRef(e, su); e^^.DeleteLocalRef(e, ss);
    e^^.DeleteLocalRef(e, sp); e^^.DeleteLocalRef(e, sd);
    e^^.DeleteLocalRef(e, stq); e^^.DeleteLocalRef(e, sis);
    e^^.DeleteLocalRef(e, sc); e^^.DeleteLocalRef(e, ssch);
  end;
end;

procedure TBridge.DestroyPool(PoolId: Int64);
begin
  CallVoid1J(FMDestroyPool, PoolId);
end;

function TBridge.BorrowConn(PoolId: Int64): Int64;
begin
  CheckHandle('pool', PoolId);
  Result := CallLong1(FMBorrow, PoolId);
  CheckHandle('conn', Result);
end;

procedure TBridge.CloseConn(ConnId: Int64);
begin
  CheckHandle('conn', ConnId);
  CallVoid1J(FMCloseConn, ConnId);
end;

procedure TBridge.SetAutoCommit(ConnId: Int64; Auto: Boolean);
begin
  CallVoidJZ(FMSetAutoCommit, ConnId, Auto);
end;

procedure TBridge.Commit(ConnId: Int64);
begin
  CheckHandle('conn', ConnId);
  CallVoid1J(FMCommit, ConnId);
end;

procedure TBridge.Rollback(ConnId: Int64);
begin
  CheckHandle('conn', ConnId);
  CallVoid1J(FMRollback, ConnId);
end;

procedure TBridge.Savepoint(ConnId: Int64; const Name: UTF8String);
begin
  CallVoidJS(FMSavepoint, ConnId, Name);
end;

procedure TBridge.RollbackTo(ConnId: Int64; const Name: UTF8String);
begin
  CallVoidJS(FMRollbackTo, ConnId, Name);
end;

procedure TBridge.ReleaseSavepoint(ConnId: Int64; const Name: UTF8String);
begin
  CallVoidJS(FMReleaseSp, ConnId, Name);
end;

procedure TBridge.SetReadOnly(ConnId: Int64; Ro: Boolean);
begin
  CallVoidJZ(FMSetReadOnly, ConnId, Ro);
end;

procedure TBridge.SetCatalog(ConnId: Int64; const V: UTF8String);
begin
  CallVoidJS(FMSetCatalog, ConnId, V);
end;

procedure TBridge.SetSchema(ConnId: Int64; const V: UTF8String);
begin
  CallVoidJS(FMSetSchema, ConnId, V);
end;

procedure TBridge.SetIsolation(ConnId: Int64; const Name: UTF8String);
begin
  CallVoidJS(FMSetIsolation, ConnId, Name);
end;

function TBridge.IsValid(ConnId: Int64; TimeoutSecs: Integer): Boolean;
var
  e: PJNIEnv;
  args: array[0..1] of jvalue;
begin
  CheckHandle('conn', ConnId);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  args[0].j := ConnId;
  args[1].i := TimeoutSecs;
  Result := e^^.CallBooleanMethodA(e, FObj, FMIsValid, @args[0]) <> 0;
  CheckJ('isValid');
end;

function TBridge.DatabaseMeta(ConnId: Int64): UTF8String;
var
  e: PJNIEnv;
  args: array[0..0] of jvalue;
  js: jstring;
begin
  CheckHandle('conn', ConnId);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  args[0].j := ConnId;
  js := jstring(e^^.CallObjectMethodA(e, FObj, FMDbMeta, @args[0]));
  CheckJ('dbmeta');
  if js = nil then
    Exit('');
  try
    Result := FromJStr(js);
  finally
    e^^.DeleteLocalRef(e, js);
  end;
end;

function TBridge.Prepare(ConnId: Int64; const SQL: UTF8String): Int64;
begin
  Result := CallLongStr(FMPrepare, ConnId, SQL);
  CheckHandle('stmt', Result);
end;

function TBridge.PrepareCall(ConnId: Int64; const SQL: UTF8String): Int64;
begin
  Result := CallLongStr(FMPrepareCall, ConnId, SQL);
  CheckHandle('stmt', Result);
end;

procedure TBridge.SetTimeout(StmtId: Int64; Secs: Integer);
var
  e: PJNIEnv;
  args: array[0..1] of jvalue;
begin
  CheckHandle('stmt', StmtId);
  if Secs < 0 then
    raise EJDBCError.CreateChain('bad timeout', 'HY092', 20, 'timeout<0');
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  args[0].j := StmtId;
  args[1].i := Secs;
  e^^.CallVoidMethodA(e, FObj, FMSetTimeout, @args[0]);
  CheckJ('setTimeout');
end;

procedure TBridge.BindLong(StmtId: Int64; Idx: Integer; V: Int64);
var
  e: PJNIEnv;
  args: array[0..2] of jvalue;
begin
  CheckHandle('stmt', StmtId);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  args[0].j := StmtId; args[1].i := Idx; args[2].j := V;
  e^^.CallVoidMethodA(e, FObj, FMBindLong, @args[0]);
  CheckJ('bindLong');
end;

procedure TBridge.BindDouble(StmtId: Int64; Idx: Integer; V: Double);
var
  e: PJNIEnv;
  args: array[0..2] of jvalue;
begin
  CheckHandle('stmt', StmtId);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  args[0].j := StmtId; args[1].i := Idx; args[2].d := V;
  e^^.CallVoidMethodA(e, FObj, FMBindDouble, @args[0]);
  CheckJ('bindDouble');
end;

procedure TBridge.BindBigDecimal(StmtId: Int64; Idx: Integer; const V: UTF8String);
var
  e: PJNIEnv;
  args: array[0..2] of jvalue;
  js: jstring;
begin
  CheckHandle('stmt', StmtId);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  js := JStr(V);
  try
    args[0].j := StmtId; args[1].i := Idx; args[2].l := js;
    e^^.CallVoidMethodA(e, FObj, FMBindBD, @args[0]);
    CheckJ('bindBigDecimal');
  finally
    e^^.DeleteLocalRef(e, js);
  end;
end;

procedure TBridge.BindString(StmtId: Int64; Idx: Integer; const V: UTF8String);
var
  e: PJNIEnv;
  args: array[0..2] of jvalue;
  js: jstring;
begin
  CheckHandle('stmt', StmtId);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  js := JStr(V);
  try
    args[0].j := StmtId; args[1].i := Idx; args[2].l := js;
    e^^.CallVoidMethodA(e, FObj, FMBindStr, @args[0]);
    CheckJ('bindString');
  finally
    e^^.DeleteLocalRef(e, js);
  end;
end;

procedure TBridge.BindDate(StmtId: Int64; Idx: Integer; const Iso: UTF8String);
var
  e: PJNIEnv;
  args: array[0..2] of jvalue;
  js: jstring;
begin
  CheckHandle('stmt', StmtId);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  js := JStr(Iso);
  try
    args[0].j := StmtId; args[1].i := Idx; args[2].l := js;
    e^^.CallVoidMethodA(e, FObj, FMBindDate, @args[0]);
    CheckJ('bindDate');
  finally
    e^^.DeleteLocalRef(e, js);
  end;
end;

procedure TBridge.BindTime(StmtId: Int64; Idx: Integer; const Iso: UTF8String);
var
  e: PJNIEnv;
  args: array[0..2] of jvalue;
  js: jstring;
begin
  CheckHandle('stmt', StmtId);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  js := JStr(Iso);
  try
    args[0].j := StmtId; args[1].i := Idx; args[2].l := js;
    e^^.CallVoidMethodA(e, FObj, FMBindTime, @args[0]);
    CheckJ('bindTime');
  finally
    e^^.DeleteLocalRef(e, js);
  end;
end;

procedure TBridge.BindTimestamp(StmtId: Int64; Idx: Integer; const Iso: UTF8String);
var
  e: PJNIEnv;
  args: array[0..2] of jvalue;
  js: jstring;
begin
  CheckHandle('stmt', StmtId);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  js := JStr(Iso);
  try
    args[0].j := StmtId; args[1].i := Idx; args[2].l := js;
    e^^.CallVoidMethodA(e, FObj, FMBindTS, @args[0]);
    CheckJ('bindTimestamp');
  finally
    e^^.DeleteLocalRef(e, js);
  end;
end;

procedure TBridge.BindBytes(StmtId: Int64; Idx: Integer; const V: TBytes);
var
  e: PJNIEnv;
  args: array[0..2] of jvalue;
  arr: jbyteArray;
begin
  CheckHandle('stmt', StmtId);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  arr := e^^.NewByteArray(e, Length(V));
  CheckJ('newbytes');
  try
    if Length(V) > 0 then
      e^^.SetByteArrayRegion(e, arr, 0, Length(V), PJByte(@V[0]));
    CheckJ('fillbytes');
    args[0].j := StmtId; args[1].i := Idx; args[2].l := arr;
    e^^.CallVoidMethodA(e, FObj, FMBindBytes, @args[0]);
    CheckJ('bindBytes');
  finally
    e^^.DeleteLocalRef(e, arr);
  end;
end;

procedure TBridge.BindNull(StmtId: Int64; Idx: Integer; SqlType: Integer);
var
  e: PJNIEnv;
  args: array[0..2] of jvalue;
begin
  CheckHandle('stmt', StmtId);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  args[0].j := StmtId; args[1].i := Idx; args[2].i := SqlType;
  e^^.CallVoidMethodA(e, FObj, FMBindNull, @args[0]);
  CheckJ('bindNull');
end;

procedure TBridge.AddBatch(StmtId: Int64);
begin
  CheckHandle('stmt', StmtId);
  CallVoid1J(FMAddBatch, StmtId);
end;

function TBridge.ExecUpdate(StmtId: Int64): Integer;
begin
  Result := CallInt1(FMExecUpdate, StmtId);
end;

function TBridge.ExecBatch(StmtId: Int64): Integer;
begin
  Result := CallInt1(FMExecBatch, StmtId);
end;

function TBridge.GeneratedKeys(StmtId: Int64): TJdbcRow;
var
  e: PJNIEnv;
  args: array[0..0] of jvalue;
  arr: jobjectArray;
  n, i: Integer;
  cell: jobject;
begin
  SetLength(Result, 0);
  CheckHandle('stmt', StmtId);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  args[0].j := StmtId;
  arr := jobjectArray(e^^.CallObjectMethodA(e, FObj, FMGenKeys, @args[0]));
  CheckJ('genkeys');
  if arr = nil then
    Exit;
  try
    n := e^^.GetArrayLength(e, arr);
    SetLength(Result, n);
    for i := 0 to n - 1 do
    begin
      cell := e^^.GetObjectArrayElement(e, arr, i);
      CheckJ('genkeycell');
      try
        Result[i] := FromJStr(jstring(cell));
      finally
        if cell <> nil then
          e^^.DeleteLocalRef(e, cell);
      end;
    end;
  finally
    e^^.DeleteLocalRef(e, arr);
  end;
end;

function TBridge.ExecDirect(ConnId: Int64; const SQL: UTF8String): Integer;
begin
  Result := CallIntStr(FMExecDirect, ConnId, SQL);
end;

function TBridge.ExecDirectTimeout(ConnId: Int64; const SQL: UTF8String; Secs: Integer): Integer;
var
  e: PJNIEnv;
  args: array[0..2] of jvalue;
  js: jstring;
begin
  CheckHandle('conn', ConnId);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  js := JStr(SQL);
  try
    args[0].j := ConnId; args[1].l := js; args[2].i := Secs;
    Result := e^^.CallIntMethodA(e, FObj, FMExecDirectTimeout, @args[0]);
    CheckJ('execDirectTimeout');
  finally
    e^^.DeleteLocalRef(e, js);
  end;
end;

procedure TBridge.RegisterOut(StmtId: Int64; Idx, SqlType: Integer);
var
  e: PJNIEnv;
  args: array[0..2] of jvalue;
begin
  CheckHandle('stmt', StmtId);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  args[0].j := StmtId; args[1].i := Idx; args[2].i := SqlType;
  e^^.CallVoidMethodA(e, FObj, FMRegisterOut, @args[0]);
  CheckJ('registerOut');
end;

function TBridge.ExecProc(StmtId: Int64): Boolean;
var
  e: PJNIEnv;
  args: array[0..0] of jvalue;
begin
  CheckHandle('stmt', StmtId);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  args[0].j := StmtId;
  Result := e^^.CallBooleanMethodA(e, FObj, FMExecProc, @args[0]) <> 0;
  CheckJ('execProc');
end;

function TBridge.OutValue(StmtId: Int64; Idx: Integer): UTF8String;
var
  e: PJNIEnv;
  args: array[0..1] of jvalue;
  js: jstring;
begin
  CheckHandle('stmt', StmtId);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  args[0].j := StmtId; args[1].i := Idx;
  js := jstring(e^^.CallObjectMethodA(e, FObj, FMGetOut, @args[0]));
  CheckJ('getOut');
  if js = nil then
    Exit('');
  try
    Result := FromJStr(js);
  finally
    e^^.DeleteLocalRef(e, js);
  end;
end;

procedure TBridge.Cancel(StmtId: Int64);
begin
  CheckHandle('stmt', StmtId);
  CallVoid1J(FMCancel, StmtId);
end;

procedure TBridge.CloseStmt(StmtId: Int64);
begin
  CheckHandle('stmt', StmtId);
  CallVoid1J(FMCloseStmt, StmtId);
end;

function TBridge.QueryOpen(StmtId: Int64; FetchSize: Integer): Int64;
var
  e: PJNIEnv;
  args: array[0..1] of jvalue;
begin
  CheckHandle('stmt', StmtId);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  args[0].j := StmtId; args[1].i := FetchSize;
  Result := e^^.CallLongMethodA(e, FObj, FMQueryOpen, @args[0]);
  CheckJ('queryOpen');
  CheckHandle('cursor', Result);
end;

function TBridge.CursorCols(CursorId: Int64): Integer;
begin
  Result := CallInt1(FMCursorCols, CursorId);
end;

function TBridge.CursorNames(CursorId: Int64): TStringList;
begin
  Result := CallStrArray1(FMCursorNames, CursorId);
end;

function TBridge.CursorTypeNames(CursorId: Int64): TStringList;
begin
  Result := CallStrArray1(FMCursorTypeNames, CursorId);
end;

function TBridge.CursorTypeCodes(CursorId: Int64): TIntArray;
var
  e: PJNIEnv;
  args: array[0..0] of jvalue;
  arr: jintArray;
  n: jsize;
  elems: PJInt;
  isCopy: jboolean;
  i: Integer;
begin
  SetLength(Result, 0);
  CheckHandle('cursor', CursorId);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  args[0].j := CursorId;
  arr := jintArray(e^^.CallObjectMethodA(e, FObj, FMCursorTypeCodes, @args[0]));
  CheckJ('typecodes');
  if arr = nil then
    Exit;
  try
    n := e^^.GetArrayLength(e, arr);
    SetLength(Result, n);
    if n > 0 then
    begin
      isCopy := 0;
      elems := e^^.GetIntArrayElements(e, arr, isCopy);
      CheckJ('typeelems');
      try
        for i := 0 to n - 1 do
          Result[i] := elems[i];
      finally
        e^^.ReleaseIntArrayElements(e, arr, elems, JNI_ABORT);
      end;
    end;
  finally
    e^^.DeleteLocalRef(e, arr);
  end;
end;

function TBridge.CallBoolMatrix(M: jmethodID; A: jlong): TNullMatrix;
var
  e: PJNIEnv;
  args: array[0..0] of jvalue;
  outer, inner: jobjectArray;
  nr, nc, i, j: Integer;
  elems: PByte;
  isCopy: jboolean;
begin
  SetLength(Result, 0);
  CheckHandle('cursor', A);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  args[0].j := A;
  outer := jobjectArray(e^^.CallObjectMethodA(e, FObj, M, @args[0]));
  CheckJ('fetchnulls');
  if outer = nil then
    Exit;
  try
    nr := e^^.GetArrayLength(e, outer);
    CheckJ('nulllen');
    SetLength(Result, nr);
    for i := 0 to nr - 1 do
    begin
      inner := jobjectArray(e^^.GetObjectArrayElement(e, outer, i));
      CheckJ('nullrow');
      try
        if inner = nil then
        begin
          SetLength(Result[i], 0);
          Continue;
        end;
        nc := e^^.GetArrayLength(e, inner);
        SetLength(Result[i], nc);
        isCopy := 0;
        elems := PByte(e^^.GetBooleanArrayElements(e, jbooleanArray(inner), isCopy));
        CheckJ('nullelems');
        try
          for j := 0 to nc - 1 do
            Result[i][j] := elems[j] <> 0;
        finally
          e^^.ReleaseBooleanArrayElements(e, jbooleanArray(inner), elems, JNI_ABORT);
        end;
      finally
        e^^.DeleteLocalRef(e, inner);
      end;
    end;
  finally
    e^^.DeleteLocalRef(e, outer);
  end;
end;

function TBridge.FetchWindow(CursorId: Int64; Size: Integer): TJdbcRows;
begin
  Result := CallWindow(FMFetchWindow, CursorId, Size);
end;

function TBridge.FetchLastNulls(CursorId: Int64): TNullMatrix;
begin
  Result := CallBoolMatrix(FMFetchNulls, CursorId);
end;

function TBridge.FetchPage(CursorId: Int64; Size: Integer): TFetchPage;
begin
  Result.Rows := CallWindow(FMFetchWindow, CursorId, Size);
  Result.Nulls := CallBoolMatrix(FMFetchNulls, CursorId);
end;

procedure TBridge.CloseCursor(CursorId: Int64);
begin
  CheckHandle('cursor', CursorId);
  CallVoid1J(FMCloseCursor, CursorId);
end;

function TBridge.GetTables(ConnId: Int64; const Table: UTF8String): TJdbcRows;
begin
  Result := CallStrMatrix(FMGetTables, ConnId, Table);
end;

function TBridge.GetColumns(ConnId: Int64; const Table: UTF8String): TJdbcRows;
begin
  Result := CallStrMatrix(FMGetColumns, ConnId, Table);
end;

function TBridge.GetPrimaryKeys(ConnId: Int64; const Table: UTF8String): TStringList;
var
  e: PJNIEnv;
  args: array[0..1] of jvalue;
  js: jstring;
  arr: jobjectArray;
  n, i: Integer;
  cell: jobject;
begin
  Result := TStringList.Create;
  CheckHandle('conn', ConnId);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  js := JStr(Table);
  try
    args[0].j := ConnId; args[1].l := js;
    arr := jobjectArray(e^^.CallObjectMethodA(e, FObj, FMGetPKs, @args[0]));
    CheckJ('getpks');
    if arr = nil then
      Exit;
    try
      n := e^^.GetArrayLength(e, arr);
      for i := 0 to n - 1 do
      begin
        cell := e^^.GetObjectArrayElement(e, arr, i);
        CheckJ('pkcell');
        try
          if cell = nil then
            Result.Add('')
          else
            Result.Add(string(FromJStr(jstring(cell))));
        finally
          if cell <> nil then
            e^^.DeleteLocalRef(e, cell);
        end;
      end;
    finally
      e^^.DeleteLocalRef(e, arr);
    end;
  finally
    e^^.DeleteLocalRef(e, js);
  end;
end;

function TBridge.WriteBlob(ConnId: Int64; const SQL: UTF8String; const Data: TBytes): Integer;
var
  e: PJNIEnv;
  args: array[0..2] of jvalue;
  js: jstring;
  arr: jbyteArray;
begin
  CheckHandle('conn', ConnId);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  js := JStr(SQL);
  arr := e^^.NewByteArray(e, Length(Data));
  CheckJ('newbytes');
  try
    if Length(Data) > 0 then
      e^^.SetByteArrayRegion(e, arr, 0, Length(Data), PJByte(@Data[0]));
    CheckJ('fillbytes');
    args[0].j := ConnId; args[1].l := js; args[2].l := arr;
    Result := e^^.CallIntMethodA(e, FObj, FMWriteBlob, @args[0]);
    CheckJ('writeBlob');
  finally
    e^^.DeleteLocalRef(e, arr);
    e^^.DeleteLocalRef(e, js);
  end;
end;

function TBridge.FetchBlob(ConnId: Int64; const SQL: UTF8String): TBytes;
begin
  Result := CallBytes(FMFetchBlob, ConnId, SQL);
end;

function TBridge.PoolStats(PoolId: Int64): TPoolStatRec;
begin
  CheckHandle('pool', PoolId);
  Result.Active := CallInt1(FMPoolActive, PoolId);
  Result.Idle := CallInt1(FMPoolIdle, PoolId);
  Result.Waiting := CallInt1(FMPoolWaiting, PoolId);
  Result.Leak := CallInt1(FMPoolLeak, PoolId);
end;

function TBridge.HeapUsed: Int64;
var
  e: PJNIEnv;
begin
  e := TJVMManager.GetJNIEnv;
  Result := e^^.CallLongMethod(e, FObj, FMHeapUsed);
  CheckJ('heapUsed');
end;

function TBridge.HeapMax: Int64;
var
  e: PJNIEnv;
begin
  e := TJVMManager.GetJNIEnv;
  Result := e^^.CallLongMethod(e, FObj, FMHeapMax);
  CheckJ('heapMax');
end;

function TBridge.ErrorChain: UTF8String;
begin
  Result := CallJString0(FMErrorChain);
end;

end.
