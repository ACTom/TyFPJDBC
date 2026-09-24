unit TyFPJDBC.JNI.Bridge;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, jni, TyFPJDBC.JVM.Manager, TyFPJDBC.Connection;

type
  TJavaRow = array of UTF8String;
  TJavaRows = array of TJavaRow;
  TJavaNullRow = array of Boolean;
  TJavaNulls = array of TJavaNullRow;

  { Thin JNI wrapper over the shipped tyfpjdbc.Bridge facade jar.
    Every value crosses as a bound string (setString); Java null maps to
    Pascal '' on fetch (null-sensitive counts go through SQL IS NULL). }
  TBridgeClient = class
  private
    FObj: jobject;
    FClass: jclass;
    FMGetVersion: jmethodID;
    FMCreatePool: jmethodID;
    FMDestroyPool: jmethodID;
    FMBorrow: jmethodID;
    FMRelease: jmethodID;
    FMExecUpdate: jmethodID;
    FMExecUpdateTimeout: jmethodID;
    FMExecBatch: jmethodID;
    FMFetchBatch: jmethodID;
    FMCancel: jmethodID;
    FMPoolStats: jmethodID;
    FMErrorChain: jmethodID;
    FMSetAutoCommit: jmethodID;
    FMCommit: jmethodID;
    FMRollback: jmethodID;
    FMSavepoint: jmethodID;
    FMRollbackTo: jmethodID;
    FMReleaseSp: jmethodID;
    FMWriteBlob: jmethodID;
    FMFetchBlob: jmethodID;
    FMHeapUsed: jmethodID;
    FMHeapMax: jmethodID;
    function Env: PJNIEnv;
    function Mid(const Name, Sig: string): jmethodID;
    procedure CheckJ(const What: string);
    function JStr(const S: UTF8String): jstring;
    function FromJStr(JS: jstring): UTF8String;
    function SafeErrorChain: UTF8String;
    function CallJString0(M: jmethodID): UTF8String;
    function CallLong1(M: jmethodID; A: jlong): jlong;
    procedure CallVoid1J(M: jmethodID; A: jlong);
  public
    constructor Create;
    destructor Destroy; override;
    function GetVersion: UTF8String;
    function CreatePool(const Url, User, Pw: UTF8String;
      MaxPool, MinIdle: Integer): Int64;
    procedure DestroyPool(PoolId: Int64);
    function BorrowConnection(PoolId: Int64): Int64;
    procedure ReleaseConnection(ConnId: Int64);
    function ExecUpdate(ConnId: Int64; const SQL: UTF8String): Integer;
    function ExecUpdateTimeout(ConnId: Int64; const SQL: UTF8String;
      TimeoutSecs: Integer): Integer;
    function ExecBatch(ConnId: Int64; const SQL: UTF8String;
      const Rows: TJavaRows; const Nulls: TJavaNulls): Integer;
    function FetchBatch(ConnId: Int64; const SQL: UTF8String;
      Offset, Limit, FetchSize: Integer): TJavaRows;
    procedure Cancel(ConnId: Int64);
    function PoolStats(PoolId: Int64): UTF8String;
    function GetErrorChain: UTF8String;
    procedure SetAutoCommit(ConnId: Int64; Auto: Boolean);
    procedure Commit(ConnId: Int64);
    procedure Rollback(ConnId: Int64);
    procedure Savepoint(ConnId: Int64; const Name: UTF8String);
    procedure RollbackToSavepoint(ConnId: Int64; const Name: UTF8String);
    procedure ReleaseSavepoint(ConnId: Int64; const Name: UTF8String);
    function WriteBlob(ConnId: Int64; const SQL: UTF8String;
      const Data: TBytes): Integer;
    function FetchBlob(ConnId: Int64; const SQL: UTF8String): TBytes;
    function HeapUsedBytes: Int64;
    function HeapMaxBytes: Int64;
  end;

implementation

function TBridgeClient.Env: PJNIEnv;
begin
  Result := TJVMManager.GetJNIEnv;
end;

procedure TBridgeClient.CheckJ(const What: string);
var
  e: PJNIEnv;
  chain: UTF8String;
begin
  e := TJVMManager.GetJNIEnv;
  if e^^.ExceptionOccurred(e) <> nil then
  begin
    e^^.ExceptionClear(e);
    chain := SafeErrorChain;
    if chain = '' then
      chain := 'jni exception';
    raise EJDBCError.CreateChain('bridge.' + What + ' failed',
      'HY000', 99, chain);
  end;
end;

function TBridgeClient.SafeErrorChain: UTF8String;
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

function TBridgeClient.JStr(const S: UTF8String): jstring;
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
    raise EJDBCError.CreateChain('bridge.newstring failed',
      'HY000', 99, 'null jstring');
end;

function TBridgeClient.FromJStr(JS: jstring): UTF8String;
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

function TBridgeClient.Mid(const Name, Sig: string): jmethodID;
var
  e: PJNIEnv;
begin
  e := TJVMManager.GetJNIEnv;
  Result := e^^.GetMethodID(e, FClass, PChar(Name), PChar(Sig));
  CheckJ('method ' + Name);
  if Result = nil then
    raise EJDBCError.CreateChain('bridge.method missing', 'HY000', 99, Name);
end;

function TBridgeClient.CallJString0(M: jmethodID): UTF8String;
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

function TBridgeClient.CallLong1(M: jmethodID; A: jlong): jlong;
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

procedure TBridgeClient.CallVoid1J(M: jmethodID; A: jlong);
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

constructor TBridgeClient.Create;
var
  e: PJNIEnv;
  cls, scls, arrCls: jclass;
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
      raise EJDBCError.CreateChain('bridge ref failed', 'HY000', 99,
        'NewGlobalRef');
    FObj := g;
    gc := jclass(e^^.NewGlobalRef(e, cls));
    if gc = nil then
    begin
      e^^.DeleteGlobalRef(e, FObj);
      FObj := nil;
      raise EJDBCError.CreateChain('bridge class ref failed', 'HY000', 99,
        'NewGlobalRef class');
    end;
    FClass := gc;
  finally
    e^^.DeleteLocalRef(e, cls);
  end;
  FMGetVersion := Mid('getVersion', '()Ljava/lang/String;');
  FMCreatePool := Mid('createPool',
    '(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;II)J');
  FMDestroyPool := Mid('destroyPool', '(J)V');
  FMBorrow := Mid('borrowConnection', '(J)J');
  FMRelease := Mid('releaseConnection', '(J)V');
  FMExecUpdate := Mid('execUpdate', '(JLjava/lang/String;)I');
  FMExecUpdateTimeout := Mid('execUpdateTimeout', '(JLjava/lang/String;I)I');
  FMExecBatch := Mid('execBatch', '(JLjava/lang/String;[[Ljava/lang/String;)I');
  FMFetchBatch := Mid('fetchBatch', '(JLjava/lang/String;III)[[Ljava/lang/String;');
  FMCancel := Mid('cancel', '(J)V');
  FMPoolStats := Mid('poolStats', '(J)Ljava/lang/String;');
  FMErrorChain := Mid('getErrorChain', '()Ljava/lang/String;');
  FMSetAutoCommit := Mid('setAutoCommit', '(JZ)V');
  FMCommit := Mid('commit', '(J)V');
  FMRollback := Mid('rollback', '(J)V');
  FMSavepoint := Mid('savepoint', '(JLjava/lang/String;)V');
  FMRollbackTo := Mid('rollbackToSavepoint', '(JLjava/lang/String;)V');
  FMReleaseSp := Mid('releaseSavepoint', '(JLjava/lang/String;)V');
  FMWriteBlob := Mid('writeBlob', '(JLjava/lang/String;[B)I');
  FMFetchBlob := Mid('fetchBlob', '(JLjava/lang/String;)[B');
  FMHeapUsed := Mid('heapUsedBytes', '()J');
  FMHeapMax := Mid('heapMaxBytes', '()J');
  scls := e^^.FindClass(e, 'java/lang/String');
  CheckJ('string class');
  e^^.DeleteLocalRef(e, scls);
  arrCls := e^^.FindClass(e, '[Ljava/lang/String;');
  CheckJ('array class');
  e^^.DeleteLocalRef(e, arrCls);
end;

destructor TBridgeClient.Destroy;
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

function TBridgeClient.GetVersion: UTF8String;
begin
  Result := CallJString0(FMGetVersion);
end;

function TBridgeClient.CreatePool(const Url, User, Pw: UTF8String;
  MaxPool, MinIdle: Integer): Int64;
var
  e: PJNIEnv;
  args: array[0..4] of jvalue;
  ju, js, jp: jstring;
begin
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  ju := JStr(Url);
  js := JStr(User);
  jp := JStr(Pw);
  try
    args[0].l := ju;
    args[1].l := js;
    args[2].l := jp;
    args[3].i := MaxPool;
    args[4].i := MinIdle;
    Result := e^^.CallLongMethodA(e, FObj, FMCreatePool, @args[0]);
    CheckJ('createPool');
  finally
    e^^.DeleteLocalRef(e, ju);
    e^^.DeleteLocalRef(e, js);
    e^^.DeleteLocalRef(e, jp);
  end;
end;

procedure TBridgeClient.DestroyPool(PoolId: Int64);
begin
  CallVoid1J(FMDestroyPool, PoolId);
end;

function TBridgeClient.BorrowConnection(PoolId: Int64): Int64;
begin
  Result := CallLong1(FMBorrow, PoolId);
end;

procedure TBridgeClient.ReleaseConnection(ConnId: Int64);
begin
  CallVoid1J(FMRelease, ConnId);
end;

function TBridgeClient.ExecUpdate(ConnId: Int64; const SQL: UTF8String): Integer;
var
  e: PJNIEnv;
  args: array[0..1] of jvalue;
  js: jstring;
begin
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  js := JStr(SQL);
  try
    args[0].j := ConnId;
    args[1].l := js;
    Result := e^^.CallIntMethodA(e, FObj, FMExecUpdate, @args[0]);
    CheckJ('execUpdate');
  finally
    e^^.DeleteLocalRef(e, js);
  end;
end;

function TBridgeClient.ExecUpdateTimeout(ConnId: Int64; const SQL: UTF8String;
  TimeoutSecs: Integer): Integer;
var
  e: PJNIEnv;
  args: array[0..2] of jvalue;
  js: jstring;
begin
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  js := JStr(SQL);
  try
    args[0].j := ConnId;
    args[1].l := js;
    args[2].i := TimeoutSecs;
    Result := e^^.CallIntMethodA(e, FObj, FMExecUpdateTimeout, @args[0]);
    CheckJ('execUpdateTimeout');
  finally
    e^^.DeleteLocalRef(e, js);
  end;
end;

function TBridgeClient.ExecBatch(ConnId: Int64; const SQL: UTF8String;
  const Rows: TJavaRows; const Nulls: TJavaNulls): Integer;
var
  e: PJNIEnv;
  args: array[0..2] of jvalue;
  js: jstring;
  scls, arrCls: jclass;
  outer, inner: jobjectArray;
  i, j: Integer;
  cell: jstring;
begin
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  js := JStr(SQL);
  scls := e^^.FindClass(e, 'java/lang/String');
  CheckJ('string class');
  arrCls := e^^.FindClass(e, '[Ljava/lang/String;');
  CheckJ('array class');
  try
    outer := e^^.NewObjectArray(e, Length(Rows), arrCls, nil);
    CheckJ('new batch outer');
    if outer = nil then
      raise EJDBCError.CreateChain('bridge.execBatch failed', 'HY000', 99,
        'null outer array');
    try
      for i := 0 to High(Rows) do
      begin
        inner := e^^.NewObjectArray(e, Length(Rows[i]), scls, nil);
        CheckJ('new batch row');
        for j := 0 to High(Rows[i]) do
        begin
          if (i <= High(Nulls)) and (j <= High(Nulls[i])) and Nulls[i][j] then
            e^^.SetObjectArrayElement(e, inner, j, nil)
          else
          begin
            cell := JStr(Rows[i][j]);
            try
              e^^.SetObjectArrayElement(e, inner, j, cell);
            finally
              e^^.DeleteLocalRef(e, cell);
            end;
          end;
        end;
        e^^.SetObjectArrayElement(e, outer, i, inner);
        e^^.DeleteLocalRef(e, inner);
        CheckJ('fill batch row');
      end;
      args[0].j := ConnId;
      args[1].l := js;
      args[2].l := outer;
      Result := e^^.CallIntMethodA(e, FObj, FMExecBatch, @args[0]);
      CheckJ('execBatch');
    finally
      e^^.DeleteLocalRef(e, outer);
    end;
  finally
    e^^.DeleteLocalRef(e, js);
    e^^.DeleteLocalRef(e, scls);
    e^^.DeleteLocalRef(e, arrCls);
  end;
end;

function TBridgeClient.FetchBatch(ConnId: Int64; const SQL: UTF8String;
  Offset, Limit, FetchSize: Integer): TJavaRows;
var
  e: PJNIEnv;
  args: array[0..4] of jvalue;
  js: jstring;
  outer, inner: jobjectArray;
  nr, nc, i, j: Integer;
  cell: jobject;
begin
  SetLength(Result, 0);
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  js := JStr(SQL);
  try
    args[0].j := ConnId;
    args[1].l := js;
    args[2].i := Offset;
    args[3].i := Limit;
    args[4].i := FetchSize;
    outer := jobjectArray(e^^.CallObjectMethodA(e, FObj, FMFetchBatch, @args[0]));
    CheckJ('fetchBatch');
    if outer = nil then
      Exit;
    try
      nr := e^^.GetArrayLength(e, outer);
      CheckJ('batch len');
      SetLength(Result, nr);
      for i := 0 to nr - 1 do
      begin
        inner := jobjectArray(e^^.GetObjectArrayElement(e, outer, i));
        CheckJ('batch row');
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
            CheckJ('batch cell');
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

procedure TBridgeClient.Cancel(ConnId: Int64);
begin
  CallVoid1J(FMCancel, ConnId);
end;

function TBridgeClient.PoolStats(PoolId: Int64): UTF8String;
var
  e: PJNIEnv;
  args: array[0..0] of jvalue;
  js: jstring;
begin
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  args[0].j := PoolId;
  js := jstring(e^^.CallObjectMethodA(e, FObj, FMPoolStats, @args[0]));
  CheckJ('poolStats');
  if js = nil then
    Exit('');
  try
    Result := FromJStr(js);
  finally
    e^^.DeleteLocalRef(e, js);
  end;
end;

function TBridgeClient.GetErrorChain: UTF8String;
begin
  Result := CallJString0(FMErrorChain);
end;

procedure TBridgeClient.SetAutoCommit(ConnId: Int64; Auto: Boolean);
var
  e: PJNIEnv;
  args: array[0..1] of jvalue;
begin
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  args[0].j := ConnId;
  args[1].z := Byte(Ord(Auto));
  e^^.CallVoidMethodA(e, FObj, FMSetAutoCommit, @args[0]);
  CheckJ('setAutoCommit');
end;

procedure TBridgeClient.Commit(ConnId: Int64);
begin
  CallVoid1J(FMCommit, ConnId);
end;

procedure TBridgeClient.Rollback(ConnId: Int64);
begin
  CallVoid1J(FMRollback, ConnId);
end;

procedure TBridgeClient.Savepoint(ConnId: Int64; const Name: UTF8String);
var
  e: PJNIEnv;
  args: array[0..1] of jvalue;
  js: jstring;
begin
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  js := JStr(Name);
  try
    args[0].j := ConnId;
    args[1].l := js;
    e^^.CallVoidMethodA(e, FObj, FMSavepoint, @args[0]);
    CheckJ('savepoint');
  finally
    e^^.DeleteLocalRef(e, js);
  end;
end;

procedure TBridgeClient.RollbackToSavepoint(ConnId: Int64; const Name: UTF8String);
var
  e: PJNIEnv;
  args: array[0..1] of jvalue;
  js: jstring;
begin
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  js := JStr(Name);
  try
    args[0].j := ConnId;
    args[1].l := js;
    e^^.CallVoidMethodA(e, FObj, FMRollbackTo, @args[0]);
    CheckJ('rollbackToSavepoint');
  finally
    e^^.DeleteLocalRef(e, js);
  end;
end;

procedure TBridgeClient.ReleaseSavepoint(ConnId: Int64; const Name: UTF8String);
var
  e: PJNIEnv;
  args: array[0..1] of jvalue;
  js: jstring;
begin
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  js := JStr(Name);
  try
    args[0].j := ConnId;
    args[1].l := js;
    e^^.CallVoidMethodA(e, FObj, FMReleaseSp, @args[0]);
    CheckJ('releaseSavepoint');
  finally
    e^^.DeleteLocalRef(e, js);
  end;
end;

function TBridgeClient.WriteBlob(ConnId: Int64; const SQL: UTF8String;
  const Data: TBytes): Integer;
var
  e: PJNIEnv;
  args: array[0..2] of jvalue;
  js: jstring;
  arr: jbyteArray;
begin
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  js := JStr(SQL);
  arr := e^^.NewByteArray(e, Length(Data));
  CheckJ('new bytes');
  try
    if Length(Data) > 0 then
      e^^.SetByteArrayRegion(e, arr, 0, Length(Data), PJByte(@Data[0]));
    CheckJ('fill bytes');
    args[0].j := ConnId;
    args[1].l := js;
    args[2].l := arr;
    Result := e^^.CallIntMethodA(e, FObj, FMWriteBlob, @args[0]);
    CheckJ('writeBlob');
  finally
    e^^.DeleteLocalRef(e, arr);
    e^^.DeleteLocalRef(e, js);
  end;
end;

function TBridgeClient.FetchBlob(ConnId: Int64; const SQL: UTF8String): TBytes;
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
  e := TJVMManager.GetJNIEnv;
  FillChar(args, SizeOf(args), 0);
  js := JStr(SQL);
  try
    args[0].j := ConnId;
    args[1].l := js;
    arr := jbyteArray(e^^.CallObjectMethodA(e, FObj, FMFetchBlob, @args[0]));
    CheckJ('fetchBlob');
    if arr = nil then
      Exit;
    try
      n := e^^.GetArrayLength(e, arr);
      SetLength(Result, n);
      if n > 0 then
      begin
        isCopy := 0;
        elems := e^^.GetByteArrayElements(e, arr, isCopy);
        CheckJ('blob elems');
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

function TBridgeClient.HeapUsedBytes: Int64;
var
  e: PJNIEnv;
begin
  e := TJVMManager.GetJNIEnv;
  Result := e^^.CallLongMethod(e, FObj, FMHeapUsed);
  CheckJ('heapUsed');
end;

function TBridgeClient.HeapMaxBytes: Int64;
var
  e: PJNIEnv;
begin
  e := TJVMManager.GetJNIEnv;
  Result := e^^.CallLongMethod(e, FObj, FMHeapMax);
  CheckJ('heapMax');
end;

end.
