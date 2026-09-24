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
Copy-Item C:\Tools\sqlite3.dll (Join-Path $bin "sqlite3.dll") -Force

Section "guard"
& "$ws\scripts\guard.ps1" 2>&1
Check "guard-exit-0" ($?)

Section "mautool-build"
fpc "-o$bin\mautool.exe" "$ws\src\tools\mautool.lpr" 2>&1
Check "mautool-compile" ($LASTEXITCODE -eq 0)
$mautool = Join-Path $bin "mautool.exe"

Section "bridge-classes-first"
# Live FPC tests drive real JNI into tyfpjdbc.Bridge, so the classes must
# exist before the fpc-tests section runs. The java section reuses $jm.
$jm = Join-Path $work "jmain"
New-Item -ItemType Directory -Force -Path $jm | Out-Null
$cp0 = "$libs\HikariCP-5.1.0.jar;$libs\slf4j-api-2.0.9.jar;$libs\h2-2.2.224.jar;$libs\sqlite-jdbc-3.46.1.0.jar"
& "$jh\bin\javac.exe" -encoding UTF-8 -cp $cp0 -d $jm "$ws\java\bridge\src\main\java\tyfpjdbc\Bridge.java" 2>&1
Check "javac-main-first" ($LASTEXITCODE -eq 0)

Section "fpc-tests-compile-run"
foreach ($t in @("TestParser","TestTypeMap","TestQuery","TestBridge","TestPoolDataset","TestRealWorld","TestLiveBridge","TestLiveGrid")) {
  Write-Output ("--- " + $t + " ---")
  $exe = Join-Path $bin ($t.ToLower() + ".exe")
  $lpr = Join-Path $ws ("tests\" + $t + ".lpr")
  $extraFu = @()
  if ($t -eq "TestLiveGrid") { $extraFu = @("-Fu$ws\examples\ex09_dbgrid") }
  fpc "-Fu$ws\src\core" "-Fu$ws\src\db" @extraFu "-o$exe" $lpr 2>&1
  Check "$t-compile" ($LASTEXITCODE -eq 0)
  if (($t -eq "TestLiveBridge") -or ($t -eq "TestLiveGrid")) {
    $liveOut = Join-Path $work ($t.ToLower() + ".dbdir")
    New-Item -ItemType Directory -Force -Path $liveOut | Out-Null
    $out = & $exe $jm $liveOut 2>&1 | Out-String
  } else {
    $out = & $exe 2>&1 | Out-String
  }
  Write-Output $out
  if ($t -eq "TestParser") { Check "$t-37-0" ($out -match "TOTAL pass=37 fail=0") }
  if ($t -eq "TestTypeMap") { Check "$t-50-0" ($out -match "TOTAL pass=50 fail=0") }
  if ($t -eq "TestRealWorld") { Check "$t-88-0" ($out -match "TOTAL pass=88 fail=0") }
  if ($t -eq "TestBridge") { Check "$t-fails-0" ($out -match "fails=0") }
  if ($t -eq "TestQuery") { Check "$t-fails-0" ($out -match "fails=0") }
  if ($t -eq "TestPoolDataset") { Check "$t-fails-0" ($out -match "fails=0") }
  if ($t -eq "TestLiveBridge") { Check "$t-fails-0" ($out -match "fails=0") }
  if ($t -eq "TestLiveGrid") { Check "$t-fails-0" ($out -match "fails=0") }
  if ($t -eq "TestLiveBridge") { Check "$t-bulk" ($out -match "PERF live-bulk-10k") }
  if ($t -eq "TestLiveBridge") { Check "$t-cancel" (($out -match "cancel-raised") -and ($out -match "timeout-raised")) }
  if ($t -eq "TestLiveGrid") { Check "$t-reread" (($out -match "grid-reread") -and ($out -match "grid-edit")) }
  if ($t -eq "TestQuery") { Check "$t-perf" (($out -match "PERF 10k") -and ($out -match "perf-100k-bounded")) }
  if ($out -cmatch "FAIL") { Check "$t-no-fail-lines" $false } else { Check "$t-no-fail-lines" $true }
}

Section "java-bridge-18-tests"
$jt = Join-Path $work "jtest"
New-Item -ItemType Directory -Force -Path $jm,$jt | Out-Null
$cp = "$libs\HikariCP-5.1.0.jar;$libs\slf4j-api-2.0.9.jar;$libs\h2-2.2.224.jar;$libs\sqlite-jdbc-3.46.1.0.jar"
& "$jh\bin\javac.exe" -encoding UTF-8 -cp $cp -d $jm "$ws\java\bridge\src\main\java\tyfpjdbc\Bridge.java" 2>&1
Check "javac-main" ($LASTEXITCODE -eq 0)
$cp2 = "$jm;$libs\HikariCP-5.1.0.jar;$libs\slf4j-api-2.0.9.jar;$libs\h2-2.2.224.jar;$libs\sqlite-jdbc-3.46.1.0.jar;$libs\junit-platform-console-standalone-1.10.2.jar"
& "$jh\bin\javac.exe" -encoding UTF-8 -cp $cp2 -d $jt "$ws\java\bridge\src\test\java\tyfpjdbc\BridgeTest.java" "$ws\java\bridge\src\test\java\tyfpjdbc\PerfCompare.java" 2>&1
Check "javac-test" ($LASTEXITCODE -eq 0)
$cpRun = "$jm;$jt;$libs\HikariCP-5.1.0.jar;$libs\slf4j-api-2.0.9.jar;$libs\slf4j-simple-2.0.9.jar;$libs\h2-2.2.224.jar;$libs\sqlite-jdbc-3.46.1.0.jar;$libs\junit-platform-console-standalone-1.10.2.jar"
$jout = & "$jh\bin\java.exe" "-Dfile.encoding=UTF-8" -jar "$libs\junit-platform-console-standalone-1.10.2.jar" --class-path "$cpRun" --select-class tyfpjdbc.BridgeTest 2>&1 | Out-String
Write-Output $jout
Check "java-18-found" ($jout -match "18 tests found")
Check "java-18-ok" ($jout -match "18 tests successful")
Check "java-0-failed" ($jout -match "0 tests failed")
Check "java-sqlite-present" ($jout -match "sqliteRoundTrip")
Check "java-pg-present" ($jout -match "postgresDialectRoundTrip")
Check "java-perf-present" ($jout -match "perfSmoke10kFetch")
Check "java-wide-present" ($jout -match "wideTableJoinGroupBy")
Check "java-shop-present" ($jout -match "shopBulkInsertAndJoinAggregate")
Check "java-batch-present" ($jout -match "execBatchBulkInsert")
Check "java-odoo-present" ($jout -match "odooSalesFunnel")
Check "java-bom-present" ($jout -match "erpRecursiveBom")
Check "java-ledger-present" ($jout -match "erpUnionTrialBalance")
Check "java-tx-present" ($jout -match "complexTransactionPartialRollback")
Check "java-ddl-present" ($jout -match "ddlMigrateAddColumnAndIndex")
Check "java-hostile-present" ($jout -match "hostileValuesStayData")

Section "perf-tiers-shipped-live-path"
# Tiers on the SHIPPED live path (Pascal -> JNI -> Bridge -> sqlite file DB).
# 10k/100k run in-matrix; the 1M tier is covered by the 3x scratch perf.log
# runs (acceptance evidence) because a single 1M scan already takes ~2min.
$tiersExe = Join-Path $bin "testperftiers.exe"
fpc "-Fu$ws\src\core" "-Fu$ws\src\db" "-o$tiersExe" "$ws\tests\TestPerfTiers.lpr" 2>&1
Check "perf-tiers-compile" ($LASTEXITCODE -eq 0)
$tout = & $tiersExe $jm (Join-Path $work "tiers") 1 skip1M 2>&1 | Out-String
Write-Output $tout
Check "perf-tiers-pass" ($tout -match "fails=0")
Check "perf-tier-10k" ($tout -match "PERF tier=10000 insert")
Check "perf-tier-100k" ($tout -match "PERF tier=100000 insert")
Check "perf-tier-checksum" (($tout -match "checksum=500000") -and ($tout -match "checksum=5000000"))
Check "perf-tier-heap" ($tout -match "heap-used=")

Section "perf-compare-sqlite-vs-bridge-20k"
# Same workload, same 20k rows, separate file DBs. Pool/connect + warmup run
# BEFORE the timers on both sides, so JVM/Hikari startup is never counted.
$perfExe = Join-Path $bin "testperfcompare.exe"
fpc "-Fu$ws\src\core" "-Fu$ws\src\db" "-o$perfExe" "$ws\tests\TestPerfCompare.lpr" 2>&1
Check "perf-fpc-compile" ($LASTEXITCODE -eq 0)
$fout = & $perfExe (Join-Path $work "perf-fpc.db") 20000 2>&1 | Out-String
Write-Output $fout
Check "perf-fpc-pass" (($fout -match "fails=0") -and ($fout -match "checksum=1000000"))
$bout = & "$jh\bin\java.exe" "-Dfile.encoding=UTF-8" -cp "$cpRun" tyfpjdbc.PerfCompare (Join-Path $work "perf-bridge.db") 20000 2>&1 | Out-String
Write-Output $bout
Check "perf-bridge-pass" (($bout -match "PERF-DONE rows=20000") -and ($bout -match "checksum=1000000"))
Check "perf-checksum-agree" (($fout -match "checksum=1000000") -and ($bout -match "checksum=1000000"))
function Ms($txt, $pat) { $mm = [regex]::Match($txt, $pat + ' ms=(\d+)'); if ($mm.Success) { return [int]$mm.Groups[1].Value } else { return -1 } }
$fi = Ms $fout "PERF fpc-insert"; $fs = Ms $fout "PERF fpc-scan"; $fp = Ms $fout "PERF fpc-paged"; $fu = Ms $fout "PERF fpc-update"
$bi = Ms $bout "PERF bridge-insert"; $bs = Ms $bout "PERF bridge-scan"; $bp = Ms $bout "PERF bridge-paged"; $bu = Ms $bout "PERF bridge-update"
Write-Output "PERF-TABLE phase | sqlite3conn-direct-ms | bridge-jdbc-ms"
Write-Output ("PERF-TABLE insert-20k | " + $fi + " | " + $bi)
Write-Output ("PERF-TABLE scan-20k | " + $fs + " | " + $bs)
Write-Output ("PERF-TABLE paged-20k | " + $fp + " | " + $bp)
Write-Output ("PERF-TABLE update-10k | " + $fu + " | " + $bu)
Check "perf-table-complete" (($fi -ge 0) -and ($fs -ge 0) -and ($fp -ge 0) -and ($fu -ge 0) -and ($bi -ge 0) -and ($bs -ge 0) -and ($bp -ge 0) -and ($bu -ge 0))

Section "examples-compile-run"
foreach ($e in @("ex01_connect_select","ex02_named_params","ex03_batch_fetch","ex04_edit_apply","ex05_transaction","ex06_blob_stream","ex07_script_migrate","ex08_pool_stats","ex10_json_config")) {
  $exe = Join-Path $bin ($e + ".exe")
  if ($e -eq "ex10_json_config") {
    fpc "-o$exe" (Join-Path $ws ("examples\" + $e + ".lpr")) 2>&1
  } else {
    fpc "-Fu$ws\src\core" "-Fu$ws\src\db" "-o$exe" (Join-Path $ws ("examples\" + $e + ".lpr")) 2>&1
  }
  Check "$e-compile" ($LASTEXITCODE -eq 0)
  if ($e -eq "ex10_json_config") {
    $o = & $exe "$ws\configs" 2>&1 | Out-String
  } else {
    $o = & $exe 2>&1 | Out-String
  }
  Write-Output $o
  if ($e -eq "ex10_json_config") {
    Check "$e-run" (($o -match "PASS json-reuse") -and ($o -match "ex10 ok"))
  } else {
    Check "$e-run" ($o -match ($e.Substring(0,4) + " ok"))
  }
}
$jd = Join-Path $work "jdemo"
New-Item -ItemType Directory -Force -Path $jd | Out-Null
& "$jh\bin\javac.exe" -encoding UTF-8 -cp "$jm;$cp" -d $jd "$ws\examples\BridgeDemo.java" 2>&1
Check "bridgedemo-compile" ($LASTEXITCODE -eq 0)
$dout = & "$jh\bin\java.exe" "-Dfile.encoding=UTF-8" -cp "$jd;$cpRun" tyfpjdbc.BridgeDemo 2>&1 | Out-String
Write-Output $dout
Check "bridgedemo-run" ($dout -match "demo ok")

Section "example-lcl-dbgrid"
# LCL graphical example: full lazbuild (lfm resources linked). No GUI
# interaction in CI; smoke-run proves the form creates without exceptions.
& lazbuild "$ws\examples\ex09_dbgrid\ex09_dbgrid.lpi" 2>&1
Check "ex09-compile" ($LASTEXITCODE -eq 0)
$exe09 = Join-Path $bin "ex09\ex09_dbgrid.exe"
Check "ex09-exe" (Test-Path $exe09)
if (Test-Path $exe09) {
  $gp = Start-Process -FilePath $exe09 -PassThru
  Start-Sleep -Seconds 4
  $gAlive = -not $gp.HasExited
  Write-Output ("ex09-alive-4s=" + $gAlive)
  Check "ex09-smoke-run" $gAlive
  try { Stop-Process -Id $gp.Id -Force -ErrorAction SilentlyContinue } catch {}
}

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

Section "v2-bridge-classes"
# BridgeV2 is the V2 single state machine; V2 Pascal tests drive real JNI
# into these classes, so they must be compiled before the v2-live section.
$jv2 = Join-Path $work "jv2"
New-Item -ItemType Directory -Force -Path $jv2 | Out-Null
$cpv = "$libs\HikariCP-5.1.0.jar;$libs\slf4j-api-2.0.9.jar;$libs\h2-2.2.224.jar;$libs\sqlite-jdbc-3.46.1.0.jar"
& "$jh\bin\javac.exe" -encoding UTF-8 -cp $cpv -d $jv2 "$ws\java\bridge\src\main\java\tyfpjdbc\PoolCfg.java" "$ws\java\bridge\src\main\java\tyfpjdbc\BridgeV2.java" "$ws\java\bridge\src\main\java\tyfpjdbc\BridgeV2Smoke.java" 2>&1
Check "v2-javac" ($LASTEXITCODE -eq 0)
$smoke = & "$jh\bin\java.exe" "-Dfile.encoding=UTF-8" -cp "$jv2;$cpv" tyfpjdbc.BridgeV2Smoke 2>&1 | Out-String
Write-Output $smoke
Check "v2-smoke-17" (($smoke -match "TOTAL fails=0") -and (([regex]::Matches($smoke, "(?m)^PASS ").Count) -eq 17))

Section "v2-live-h2-sqlite"
# Live V2 loopback on the drivers present on this host (H2 + SQLite jars).
# PG/MySQL/MSSQL/Oracle have no local servers here: recorded as env-missing,
# covered by dialect pure-logic asserts in TestV2Dialect instead of faked.
foreach ($t in @("TestV2Handles","TestV2Jvm","TestV2Engine","TestV2Data","TestV2Dialect","TestV2ProcBlob","TestV2Distrib","TestV2Lcl","TestV2Soak")) {
  Write-Output ("--- " + $t + " ---")
  $exe = Join-Path $bin ($t.ToLower() + ".exe")
  $lpr = Join-Path $ws ("tests\" + $t + ".lpr")
  if ($t -eq "TestV2Lcl") {
    fpc "-Fu$ws\src\core" "-Fu$ws\src\db" "-Fu$ws\src\lcl" "-o$exe" $lpr 2>&1
  } else {
    fpc "-Fu$ws\src\core" "-Fu$ws\src\db" "-o$exe" $lpr 2>&1
  }
  Check "$t-compile" ($LASTEXITCODE -eq 0)
  if ($t -eq "TestV2Handles") { $o = & $exe 2>&1 | Out-String }
  elseif ($t -eq "TestV2Dialect") { $o = & $exe 2>&1 | Out-String }
  elseif ($t -eq "TestV2Jvm") { $o = & $exe 2>&1 | Out-String }
  elseif ($t -eq "TestV2Distrib") { $o = & $exe 2>&1 | Out-String }
  else { $o = & $exe $jv2 2>&1 | Out-String }
  Write-Output $o
  Check "$t-fails-0" ($o -match "TOTAL fails=0")
  if ($o -cmatch "(?m)^FAIL ") { Check "$t-no-fail-lines" $false } else { Check "$t-no-fail-lines" $true }
}
foreach ($pg in @("pg","mysql","mssql","oracle")) {
  Write-Output ("SKIP-MATRIX: " + $pg + " no local server (env-missing, dialect asserts cover SQL shape)")
}

Section "v2-examples-lpk"
foreach ($e in @("ex11_code_first","ex12_dbgrid")) {
  $exe = Join-Path $bin ($e + ".exe")
  fpc "-Fu$ws\src\core" "-Fu$ws\src\db" "-o$exe" (Join-Path $ws ("examples\" + $e + ".lpr")) 2>&1
  Check "$e-compile" ($LASTEXITCODE -eq 0)
  $o = & $exe $jv2 2>&1 | Out-String
  Write-Output $o
  if ($e -eq "ex11_code_first") { Check "$e-run" (($o -match "inserted=3") -and ($o -match "ex11 ok")) }
  else { Check "$e-run" (($o -match "requery-rows=4") -and ($o -match "ex12 ok")) }
}
& "$ws\scripts\guard.ps1" 2>&1
Check "v2-guard" ($?)
Remove-Item "$ws\src\lcl\lib" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$ws\src\lcl\tyfpjdbc.pas" -Force -ErrorAction SilentlyContinue
Remove-Item "$ws\src\lcl\packagefiles.xml" -Force -ErrorAction SilentlyContinue
& lazbuild --build-all "$ws\src\lcl\tyfpjdbc.lpk" 2>&1
Check "v2-lpk" ($LASTEXITCODE -eq 0)
Remove-Item "$ws\src\lcl\tyfpjdbc.pas" -Force -ErrorAction SilentlyContinue
Remove-Item "$ws\src\lcl\packagefiles.xml" -Force -ErrorAction SilentlyContinue
Remove-Item "$ws\src\lcl\lib" -Recurse -Force -ErrorAction SilentlyContinue

Section "summary"
Write-Output ("MATRIX-FAILURES=" + $script:failures)
if ($script:failures -gt 0) { exit 1 } else { Write-Output "MATRIX-OK"; exit 0 }
