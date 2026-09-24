program ex06_blob_stream;

{$mode objfpc}{$H+}

{ ex06: BLOB maps to ftBlob and must go through a stream, not a string. }

uses
  SysUtils, Classes, DB, TyFPJDBC.&Type.Map;

var
  ms: TMemoryStream;
  payload: string;
begin
  WriteLn('BLOB => ', BoolToStr(TJdbcTypeMap.ToFieldType('BLOB') = ftBlob, True));
  WriteLn('BYTEA needs stream? ',
    BoolToStr(TJdbcTypeMap.NeedStream('BYTEA'), True));
  WriteLn('VARCHAR needs stream? ',
    BoolToStr(TJdbcTypeMap.NeedStream('VARCHAR'), True));
  ms := TMemoryStream.Create;
  try
    payload := 'blob-bytes-中文';
    ms.WriteBuffer(payload[1], Length(payload));
    ms.Position := 0;
    WriteLn('stream bytes=', ms.Size);
  finally
    ms.Free;
  end;
  WriteLn('ex06 ok');
end.
