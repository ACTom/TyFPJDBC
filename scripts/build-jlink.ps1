param(
  [string]$Platform = "win64",
  [string]$JavaHome = $env:JAVA_HOME,
  [string]$OutRoot = "runtimes",
  [switch]$VerifyProbe
)
$ErrorActionPreference = "Stop"
$modules = "java.base,java.sql,java.naming,java.logging,java.management,java.xml,java.security.sasl,jdk.unsupported,java.transaction.xa"
if ([string]::IsNullOrEmpty($JavaHome)) { throw "JAVA_HOME not set" }
$jlink = Join-Path $JavaHome "bin/jlink.exe"
if (-not (Test-Path $jlink)) { $jlink = Join-Path $JavaHome "bin/jlink" }
if (-not (Test-Path $jlink)) { throw "jlink not found under $JavaHome" }
$out = Join-Path $OutRoot ("jre-25-tyfpjdbc-" + $Platform)
Write-Output ("modules: " + $modules)
Write-Output ("output: " + $out)
& $jlink --module-path (Join-Path $JavaHome "jmods") --add-modules $modules --output $out --strip-debug --no-man-pages --no-header-files --compress=zip-9
$javaExe = Join-Path $out "bin/java.exe"
if (-not (Test-Path $javaExe)) { $javaExe = Join-Path $out "bin/java" }
& $javaExe -version
$full = (Get-ChildItem (Join-Path $JavaHome "") -Recurse -File | Measure-Object Length -Sum).Sum
$trim = (Get-ChildItem $out -Recurse -File | Measure-Object Length -Sum).Sum
Write-Output ("full-bytes=" + $full)
Write-Output ("trimmed-bytes=" + $trim)
Write-Output ("jlink done " + $Platform)
