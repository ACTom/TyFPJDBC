unit TyFPJDBC.Errors;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, TyFPJDBC.Handles;

type
  { Error classes: retryable (safe to retry with backoff), fatal (do not
    retry blindly), config (fix SQL/config first), driver (see chain). }
  TJdbcErrClass = (ecRetryable, ecFatal, ecConfig, ecDriver);

function RetryableState(const SQLState: string): Boolean;
function JdbcErrClassOf(const E: EJDBCError): TJdbcErrClass;
function ErrAdvice(Cl: TJdbcErrClass): string;

implementation

function RetryableState(const SQLState: string): Boolean;
begin
  Result := (SQLState = 'HYT00') or (SQLState = 'HY008') or
    (SQLState = '08001') or (SQLState = '08006') or (SQLState = '40001');
end;

function JdbcErrClassOf(const E: EJDBCError): TJdbcErrClass;
begin
  if RetryableState(E.SQLState) then
    Exit(ecRetryable);
  if (E.SQLState = 'HY000') or (E.SQLState = 'HY092') or (E.SQLState = '08000') then
    Exit(ecConfig);
  if (Length(E.SQLState) = 5) and (Copy(E.SQLState, 1, 2) = '23') then
    Exit(ecFatal);
  Result := ecDriver;
end;

function ErrAdvice(Cl: TJdbcErrClass): string;
begin
  case Cl of
    ecRetryable:
      Result := 'safe to retry with backoff after re-validating the connection';
    ecConfig:
      Result := 'fix configuration or SQL and retry';
    ecFatal:
      Result := 'do not retry blindly; inspect constraint or data';
    else
      Result := 'see driver error chain via Bridge.ErrorChain';
  end;
end;

end.
