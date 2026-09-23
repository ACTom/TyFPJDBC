param(
  [string]$Platform = "linux-x64",
  [string]$JreArchive = "",
  [string]$OutRoot = "runtimes",
  [string]$BridgeDir = "",
  [string]$LegalDir = ""
)
$ErrorActionPreference = "Stop"

# Reproducible procedure for TyFPJDBC runtimes that cannot be jlink-trimmed
# on a foreign host (upstream Temurin archives ship no jmods, and java.base
# records ModuleHashes, so cross-host jlink is rejected). Layout produced:
#   jre-25-tyfpjdbc-<platform>/{bin,conf,legal,lib,release,bridge,drivers}
# with bridge/ = Bridge.class + HikariCP + slf4j-api and drivers/ = README.
# macOS archives (Contents/Home/...) are flattened to Home contents.

$stage = Join-Path ([IO.Path]::GetTempPath()) ("tyfpjdbc-" + $Platform)
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
tar -xzf $JreArchive -C $stage
$root = Get-ChildItem $stage -Directory | Select-Object -First 1 -ExpandProperty FullName
if ($Platform -like "macos-*") { $root = Join-Path $root "Contents/Home" }
$out = Join-Path $OutRoot ("jre-25-tyfpjdbc-" + $Platform)
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
robocopy $root $out /E /NFL /NDL /NJH /NJS /XJ | Out-Null
if ($LegalDir -ne "") {
  Get-ChildItem $LegalDir -Recurse -File | ForEach-Object {
    $t = Join-Path (Join-Path $out "legal") $_.FullName.Substring($LegalDir.Length + 1)
    if (-not (Test-Path $t)) {
      New-Item -ItemType Directory -Force -Path (Split-Path $t) | Out-Null
      Copy-Item $_.FullName $t
    }
  }
}
New-Item -ItemType Directory -Force -Path (Join-Path $out "bridge"), (Join-Path $out "drivers") | Out-Null
Copy-Item (Join-Path $BridgeDir "*") (Join-Path $out "bridge")
"drivers are resolved at runtime: place JDBC driver jars here (e.g. h2-2.2.224.jar) and load via URLClassLoader; see configs/drivers.json" | Out-File -FilePath (Join-Path $out "drivers/README.txt") -Encoding utf8
$zip = Join-Path $OutRoot ("jre-25-tyfpjdbc-" + $Platform + ".zip")
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path $out -DestinationPath $zip
$h = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
$u = (Get-ChildItem $out -Recurse -File | Measure-Object Length -Sum).Sum
$b = (Get-Item $zip).Length
Write-Output ("packedBytes=" + $b)
Write-Output ("unpackedBytes=" + $u)
Write-Output ("sha256=" + $h)
Write-Output ("Record packedBytes/unpackedBytes/sha256 into configs/runtimes.json and verify with: mautool --verify-runtime --platform " + $Platform + " --sha256 " + $h + " --out " + $OutRoot)
