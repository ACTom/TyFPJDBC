param([string]$OutDir = "test-results")
$ErrorActionPreference = "Continue"
$script:failures = 0
function Section($n) { Write-Output ("`n=== " + $n + " ===") }
function Check($name, $cond) {
  if ($cond) { Write-Output ("PASS-MATRIX: " + $name) }
  else { Write-Output ("FAIL-MATRIX: " + $name); $script:failures++ }
}
$ws = "D:\Projects\TyFPJDBC"
$jh = "C:\Tools\ms-jdks\win64\jdk-25.0.4.1+1"
if (-not (Test-Path "$jh\bin\java.exe")) { $jh = "C:\Tools\jdk25\jdk-25.0.4.1+1" }
$libs = "C:\Tools\tyfpjdbc-libs"
$rtZips = "D:\Projects\TyFPJDBC-Runtimes\zips"
$bin = Join-Path $ws ($OutDir + "/bin")
$work = Join-Path $ws ($OutDir + "/work")
New-Item -ItemType Directory -Force -Path $bin,$work | Out-Null
Set-Location $ws

Section "guard"
& "$ws\scripts\guard.ps1" 2>&1
Check "guard-exit-0" ($?)

Section "mautool-build"
fpc "-o$bin\mautool.exe" "$ws\src\tools\mautool.lpr" 2>&1
Check "mautool-compile" ($LASTEXITCODE -eq 0)
$mautool = Join-Path $bin "mautool.exe"

Section "fpc-tests-compile-run"
foreach ($t in @("TestParser","TestTypeMap","TestQuery","TestBridge","TestPoolDataset")) {
  Write-Output ("--- " + $t + " ---")
  $exe = Join-Path $bin ($t.ToLower() + ".exe")
  $lpr = Join-Path $ws ("tests\" + $t + ".lpr")
  fpc "-Fu$ws\src\core" "-Fu$ws\src\db" "-o$exe" $lpr 2>&1
  Check "$t-compile" ($LASTEXITCODE -eq 0)
  $out = & $exe 2>&1 | Out-String
  Write-Output $out
  if ($t -eq "TestParser") { Check "$t-37-0" ($out -match "TOTAL pass=37 fail=0") }
  if ($t -eq "TestTypeMap") { Check "$t-50-0" ($out -match "TOTAL pass=50 fail=0") }
  if ($t -eq "TestBridge") { Check "$t-fails-0" ($out -match "fails=0") }
  if ($t -eq "TestQuery") { Check "$t-fails-0" ($out -match "fails=0") }
  if ($t -eq "TestPoolDataset") { Check "$t-fails-0" ($out -match "fails=0") }
  if ($t -eq "TestQuery") { Check "$t-perf" (($out -match "PERF 10k") -and ($out -match "perf-100k-bounded")) }
  if ($out -cmatch "FAIL") { Check "$t-no-fail-lines" $false } else { Check "$t-no-fail-lines" $true }
}

Section "java-bridge-9-tests"
$jm = Join-Path $work "jmain"
$jt = Join-Path $work "jtest"
New-Item -ItemType Directory -Force -Path $jm,$jt | Out-Null
$cp = "$libs\HikariCP-5.1.0.jar;$libs\slf4j-api-2.0.9.jar;$libs\h2-2.2.224.jar;$libs\sqlite-jdbc-3.46.1.0.jar"
& "$jh\bin\javac.exe" -encoding UTF-8 -cp $cp -d $jm "$ws\java\bridge\src\main\java\tyfpjdbc\Bridge.java" 2>&1
Check "javac-main" ($LASTEXITCODE -eq 0)
$cp2 = "$jm;$libs\HikariCP-5.1.0.jar;$libs\slf4j-api-2.0.9.jar;$libs\h2-2.2.224.jar;$libs\sqlite-jdbc-3.46.1.0.jar;$libs\junit-platform-console-standalone-1.10.2.jar"
& "$jh\bin\javac.exe" -encoding UTF-8 -cp $cp2 -d $jt "$ws\java\bridge\src\test\java\tyfpjdbc\BridgeTest.java" 2>&1
Check "javac-test" ($LASTEXITCODE -eq 0)
$cpRun = "$jm;$jt;$libs\HikariCP-5.1.0.jar;$libs\slf4j-api-2.0.9.jar;$libs\slf4j-simple-2.0.9.jar;$libs\h2-2.2.224.jar;$libs\sqlite-jdbc-3.46.1.0.jar;$libs\junit-platform-console-standalone-1.10.2.jar"
$jout = & "$jh\bin\java.exe" -jar "$libs\junit-platform-console-standalone-1.10.2.jar" --class-path "$cpRun" --select-class tyfpjdbc.BridgeTest 2>&1 | Out-String
Write-Output $jout
Check "java-9-found" ($jout -match "9 tests found")
Check "java-9-ok" ($jout -match "9 tests successful")
Check "java-0-failed" ($jout -match "0 tests failed")
Check "java-sqlite-present" ($jout -match "sqliteRoundTrip")
Check "java-pg-present" ($jout -match "postgresDialectRoundTrip")
Check "java-perf-present" ($jout -match "perfSmoke10kFetch")

Section "mautool-manifests"
$mout = & $mautool --verify-manifests 2>&1 | Out-String
Write-Output $mout
Check "manifests-verified" ($mout -match "manifests verified")

Section "mautool-drivers-sqlite-chain"
$dh2 = & $mautool --driver h2 --out $libs 2>&1 | Out-String
Write-Output $dh2
Check "driver-h2-verified" ($dh2 -match "checksum: VERIFIED")
$dsl = & $mautool --driver sqlite --out $libs 2>&1 | Out-String
Write-Output $dsl
Check "driver-sqlite-verified" ($dsl -match "checksum: VERIFIED")
Check "driver-sqlite-sha1" ($dsl -match "97ca06712e2afa8c0e551245da72280fca5474cf")
$vfA = & $mautool --verify-file --driver sqlite --sha1 97ca06712e2afa8c0e551245da72280fca5474cf --out $libs 2>&1 | Out-String
Write-Output $vfA
Check "verify-file-accept" ($vfA -match "checksum: VERIFIED")
$vfR = & $mautool --verify-file --driver sqlite --sha1 0000000000000000000000000000000000000000 --out $libs 2>&1 | Out-String
Write-Output $vfR
Check "verify-file-reject" ($vfR -match "checksum MISMATCH")

Section "mautool-verify-runtime-accept-reject"
$m = Get-Content "$ws\configs\runtimes.json" -Raw
foreach ($p in @("win64","linux-x64","linux-arm64","macos-x64","macos-arm64")) {
  $rx = '(?s)platform": "' + $p + '".*?sha256": "([0-9a-f]{64})"'
  $h = [regex]::Match($m, $rx).Groups[1].Value
  $o = & $mautool --verify-runtime --platform $p --sha256 $h --out $rtZips 2>&1 | Out-String
  Write-Output $o
  Check "runtime-accept-$p" ($o -match "checksum: VERIFIED")
}
$rej = & $mautool --verify-runtime --platform win64 --sha256 0000000000000000000000000000000000000000000000000000000000000000 --out $rtZips 2>&1 | Out-String
Write-Output $rej
Check "runtime-reject" ($rej -match "checksum MISMATCH")

Section "deterministic-proof"
$da = Join-Path $work "det-a.zip"
$logA = & pwsh -NoProfile -File "$ws\scripts\build-runtime-zip.ps1" -StageDir "D:\Projects\TyFPJDBC-Runtimes\stages\jre-25-tyfpjdbc-win64" -OutZip $da 2>&1 | Out-String
Write-Output $logA
$db = Join-Path $work "det-b.zip"
$logB = & pwsh -NoProfile -File "$ws\scripts\build-runtime-zip.ps1" -StageDir "D:\Projects\TyFPJDBC-Runtimes\stages\jre-25-tyfpjdbc-win64" -OutZip $db 2>&1 | Out-String
Write-Output $logB
$ha = (Get-FileHash $da -Algorithm SHA256).Hash.ToLower()
$hb = (Get-FileHash $db -Algorithm SHA256).Hash.ToLower()
Write-Output ("det-a=" + $ha)
Write-Output ("det-b=" + $hb)
Check "deterministic-byte-identical" ($ha -eq $hb)
$rxw = '(?s)platform": "win64".*?sha256": "([0-9a-f]{64})"'
$hw = [regex]::Match($m, $rxw).Groups[1].Value
Check "deterministic-matches-manifest" ($ha -eq $hw)

Section "summary"
Write-Output ("MATRIX-FAILURES=" + $script:failures)
if ($script:failures -gt 0) { exit 1 } else { Write-Output "MATRIX-OK"; exit 0 }
