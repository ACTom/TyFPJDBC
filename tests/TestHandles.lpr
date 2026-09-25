program TestHandles;
{$mode objfpc}{$H+}
uses
  SysUtils, TyFPJDBC.Handles;
var
  Fails: Integer = 0;
procedure Ok(const N: string; C: Boolean);
begin
  if C then WriteLn('PASS ', N) else begin Inc(Fails); WriteLn('FAIL ', N); end;
end;
var
  e: EJDBCError;
begin
  Ok('invalid-handle-fails', not JdbcOk(0));
  Ok('valid-handle-ok', JdbcOk(7));
  try
    CheckHandle('pool', 0);
    Ok('check-raises', False);
  except
    on E: EJDBCError do
      Ok('check-raises', (E.SQLState = 'HY000') and (E.VendorCode = 99));
  end;
  e := EJDBCError.CreateChain('no pool', '08000', 31, 'pool=0');
  try
    Ok('chain-state', (e.SQLState = '08000') and (e.VendorCode = 31) and (e.Chain.Count = 2));
  finally
    e.Free;
  end;
  WriteLn('TOTAL fails=', Fails);
  if Fails > 0 then Halt(1);
end.
