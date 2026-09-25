program TestErrors;

{$mode objfpc}{$H+}

uses SysUtils, TyFPJDBC.Handles, TyFPJDBC.Errors;

var Fails: Integer = 0;

procedure Ok(const N: string; C: Boolean);
begin
  if C then WriteLn('PASS ', N) else begin Inc(Fails); WriteLn('FAIL ', N); end;
end;

begin
  Ok('timeout-retryable', RetryableState('HYT00'));
  Ok('cancel-retryable', RetryableState('HY008'));
  Ok('deadlock-retryable', RetryableState('40001'));
  Ok('syntax-not-retryable', not RetryableState('42000'));
  try
    CheckHandle('pool', 0);
    Ok('bad-handle-raises', False);
  except
    on E: EJDBCError do Ok('bad-handle-config', JdbcErrClassOf(E) = ecConfig);
  end;
  Ok('advice-nonempty', ErrAdvice(ecRetryable) <> '');
  WriteLn('TOTAL fails=', Fails);
  if Fails > 0 then Halt(1);
end.
