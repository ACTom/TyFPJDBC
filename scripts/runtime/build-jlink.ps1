param(
  [string]$Platform = "win64",
  [string]$WindowsJavaHome = $env:JAVA_HOME,
  [string]$TargetJdkHome = "",
  [string]$OutRoot = "runtimes",
  [string]$BridgeDir = ""
)
$ErrorActionPreference = "Stop"

# Single-tier TyFPJDBC runtime builder (all 5 platforms are jlink trims).
# win64: same-host jlink from the Windows JDK in $WindowsJavaHome.
# linux-*/macos-*: cross-host jlink -- the jlink binary still comes from the
# Windows JDK, but --module-path points at the TARGET platform's jmods
# (upstream Temurin archives ship no jmods, so use a same-version donor that
# carries target jmods, e.g. Microsoft Build of OpenJDK 25.0.4.1).
# Fixed flags for every platform:
#   --disable-plugin generate-jli-classes --vm server
#   --strip-debug --no-man-pages --no-header-files --compress=zip-9
#   --exclude-resources "**/classes*.jsa"   (drops ~45MB CDS archives)
# Layout produced:
#   jre-25-tyfpjdbc-<platform>/{bin,conf,legal,lib,release,bridge,drivers}
# with bridge/ = Bridge.class + HikariCP + slf4j-api and drivers/ = README.

$modules = "java.base,java.sql,java.naming,java.logging,java.management,java.xml,java.security.sasl,jdk.unsupported,java.transaction.xa"

if ([string]::IsNullOrEmpty($TargetJdkHome)) { $TargetJdkHome = $WindowsJavaHome }
if ([string]::IsNullOrEmpty($TargetJdkHome)) { throw "no JDK home given" }
$targetJmods = Join-Path $TargetJdkHome "jmods"
if ($Platform -like "macos-*") {
  $homeDir = Join-Path $TargetJdkHome "Contents/Home"
  if (Test-Path (Join-Path $homeDir "jmods")) { $targetJmods = Join-Path $homeDir "jmods" }
}
if (-not (Test-Path (Join-Path $targetJmods "java.base.jmod"))) { throw "target jmods missing: $targetJmods" }
$jlinkName = "jlink.exe"
if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) { $jlinkName = "jlink" }
$jlink = Join-Path (Join-Path $WindowsJavaHome "bin") $jlinkName
if (-not (Test-Path $jlink)) { throw "jlink not found under $WindowsJavaHome" }

$out = Join-Path $OutRoot ("jre-25-tyfpjdbc-" + $Platform)
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
Write-Output ("modules: " + $modules)
Write-Output ("target-jmods: " + $targetJmods)
Write-Output ("output: " + $out)
& $jlink --disable-plugin generate-jli-classes --vm server --module-path $targetJmods --add-modules $modules --output $out --strip-debug --no-man-pages --no-header-files --compress=zip-9 --exclude-resources "**/classes*.jsa"
$javaExe = Join-Path $out "bin/java.exe"
if (-not (Test-Path $javaExe)) { $javaExe = Join-Path $out "bin/java" }
if (($Platform -eq "win64") -and (Test-Path $javaExe)) { & $javaExe -version }
if ($BridgeDir -ne "") {
  New-Item -ItemType Directory -Force -Path (Join-Path $out "bridge"), (Join-Path $out "drivers") | Out-Null
  Copy-Item (Join-Path $BridgeDir "*") (Join-Path $out "bridge")
  "drivers are resolved at runtime: place JDBC driver jars here (e.g. h2-2.2.224.jar) and load via URLClassLoader; see configs/drivers.json" | Out-File -FilePath (Join-Path $out "drivers/README.txt") -Encoding utf8
}
# Deterministic packaging: sorted entries, fixed 2026-01-01 timestamp, Optimal.
# Must run under PowerShell 7 (pwsh) so System.IO.Compression output is stable;
# Windows PowerShell 5.1 uses a different Deflate encoder and yields different
# bytes for identical inputs. Rebuilding the same stage dir twice with this
# script under the same pwsh/.NET produces byte-identical zips.
$zip = Join-Path $OutRoot ("jre-25-tyfpjdbc-" + $Platform + ".zip")
$packer = Join-Path $PSScriptRoot "build-runtime-zip.ps1"
& $packer -StageDir $out -OutZip $zip
$h = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
$u = (Get-ChildItem $out -Recurse -File | Measure-Object Length -Sum).Sum
$b = (Get-Item $zip).Length
Write-Output ("packedBytes=" + $b)
Write-Output ("unpackedBytes=" + $u)
Write-Output ("sha256=" + $h)
Write-Output ("Record packedBytes/unpackedBytes/sha256 into configs/runtimes.json and verify with: mautool --verify-runtime --platform " + $Platform + " --sha256 " + $h + " --out " + $OutRoot)
Write-Output ("jlink done " + $Platform)
