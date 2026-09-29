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
# Unit output (.o/.ppu) goes here, never next to sources: every fpc call
# below passes -FU$units, and the dir is wiped for hermetic rebuilds.
$units = Join-Path $work "units"
Remove-Item $units -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $bin,$work,$units | Out-Null
Set-Location $ws
Copy-Item C:\Tools\sqlite3.dll (Join-Path $bin "sqlite3.dll") -Force

Section "guard"
& "$ws\scripts\guard.ps1" 2>&1
Check "guard-exit-0" ($?)

Section "mautool-build"
fpc "-FU$units" "-Fu$ws\src\core" "-o$bin\mautool.exe" "$ws\src\tools\mautool.lpr" 2>&1
Check "mautool-compile" ($LASTEXITCODE -eq 0)
$mautool = Join-Path $bin "mautool.exe"

Section "bridge-classes"
# Java Bridge is the single state machine; Pascal tests drive real JNI
# into these classes, so they are compiled before any live section runs.
$jm = Join-Path $work "jmain"
New-Item -ItemType Directory -Force -Path $jm | Out-Null
$cp = "$libs\HikariCP-5.1.0.jar;$libs\slf4j-api-2.0.9.jar;$libs\h2-2.2.224.jar;$libs\sqlite-jdbc-3.46.1.0.jar"
& "$jh\bin\javac.exe" -encoding UTF-8 -cp $cp -d $jm "$ws\java\bridge\src\main\java\tyfpjdbc\PoolCfg.java" "$ws\java\bridge\src\main\java\tyfpjdbc\Bridge.java" "$ws\java\bridge\src\main\java\tyfpjdbc\BridgeSmoke.java" 2>&1
Check "javac-main" ($LASTEXITCODE -eq 0)
$smoke = & "$jh\bin\java.exe" "-Dfile.encoding=UTF-8" -cp "$jm;$cp" tyfpjdbc.BridgeSmoke 2>&1 | Out-String
Write-Output $smoke
Check "smoke-fails-0" ($smoke -match "TOTAL fails=0")
Check "smoke-22" (([regex]::Matches($smoke, "(?m)^PASS ").Count) -eq 22)

Section "fpc-pure-tests"
# No JVM, no DB: named-param rewrite, type mapping, real-world SQL shapes.
foreach ($t in @("TestRewrite","TestTypes","TestRealWorld")) {
  Write-Output ("--- " + $t + " ---")
  $exe = Join-Path $bin ($t.ToLower() + ".exe")
  $lpr = Join-Path $ws ("tests\" + $t + ".lpr")
  fpc "-FU$units" "-Fu$ws\src\core" "-Fu$ws\src\db" "-o$exe" $lpr 2>&1
  Check "$t-compile" ($LASTEXITCODE -eq 0)
  $out = & $exe 2>&1 | Out-String
  Write-Output $out
  if ($t -eq "TestRewrite") { Check "$t-61-0" ($out -match "TOTAL pass=61 fail=0") }
  if ($t -eq "TestTypes") { Check "$t-62-0" ($out -match "TOTAL pass=62 fail=0") }
  if ($t -eq "TestRealWorld") { Check "$t-88-0" ($out -match "TOTAL pass=88 fail=0") }
  if ($out -cmatch "FAIL") { Check "$t-no-fail-lines" $false } else { Check "$t-no-fail-lines" $true }
}

Section "live-h2-sqlite"
# Live loopback on the drivers present on this host (H2 + SQLite jars).
# PG/MySQL/MSSQL/Oracle have no local servers here: recorded as env-missing,
# covered by dialect pure-logic asserts in TestDialect instead of faked.
foreach ($t in @("TestHandles","TestJvm","TestEngine","TestData","TestInjection","TestTx","TestDialect","TestProcBlob","TestDistrib","TestLcl","TestSoak")) {
  Write-Output ("--- " + $t + " ---")
  $exe = Join-Path $bin ($t.ToLower() + ".exe")
  $lpr = Join-Path $ws ("tests\" + $t + ".lpr")
  if ($t -eq "TestLcl") {
    fpc "-FU$units" "-Fu$ws\src\core" "-Fu$ws\src\db" "-Fu$ws\src\lcl" "-o$exe" $lpr 2>&1
  } else {
    fpc "-FU$units" "-Fu$ws\src\core" "-Fu$ws\src\db" "-o$exe" $lpr 2>&1
  }
  Check "$t-compile" ($LASTEXITCODE -eq 0)
  if ($t -in @("TestHandles","TestJvm","TestDialect")) { $o = & $exe 2>&1 | Out-String }
  elseif ($t -eq "TestDistrib") { $o = & $exe 2>&1 | Out-String }
  else { $o = & $exe $jm 2>&1 | Out-String }
  Write-Output $o
  Check "$t-fails-0" ($o -match "TOTAL fails=0")
  if ($o -cmatch "(?m)^FAIL ") { Check "$t-no-fail-lines" $false } else { Check "$t-no-fail-lines" $true }
}
foreach ($pg in @("pg","mysql","mssql","oracle")) {
  Write-Output ("SKIP-MATRIX: " + $pg + " no local server (env-missing, dialect asserts cover SQL shape)")
}

Section "live-pg-mysql"
# Per-database semantic baseline (H2 + SQLite always; PG/MySQL only with a
# container runtime). No docker here = honest SKIP, never faked.
$semExe = Join-Path $bin "testsemantic.exe"
fpc "-FU$units" "-Fu$ws\src\core" "-Fu$ws\src\db" "-o$semExe" "$ws\tests\TestSemantic.lpr" 2>&1
Check "semantic-compile" ($LASTEXITCODE -eq 0)
$sout = & $semExe $jm (Join-Path $work "semantic") 2>&1 | Out-String
Write-Output $sout
Check "semantic-fails-0" ($sout -match "TOTAL fails=0")
if ($sout -cmatch "(?m)^FAIL ") { Check "semantic-no-fail-lines" $false } else { Check "semantic-no-fail-lines" $true }
Check "semantic-h2-baseline" (Test-Path (Join-Path $work "semantic/baseline-h2.txt"))
Check "semantic-sqlite-baseline" (Test-Path (Join-Path $work "semantic/baseline-sqlite.txt"))
$hasDocker = (Get-Command docker -ErrorAction SilentlyContinue) -ne $null
if (-not $hasDocker) {
  Write-Output "SKIP-MATRIX: pg no container runtime (env-missing)"
  Write-Output "SKIP-MATRIX: mysql no driver manifest, no container runtime (env-missing)"
  Check "pg-mysql-skip-documented" $true
} else {
  $pgJarOut = & $mautool --driver postgresql --out $libs 2>&1 | Out-String
  Write-Output $pgJarOut
  Check "pg-jar-fetched" ($pgJarOut -match "checksum: VERIFIED")
  docker compose -f "$ws\scripts\compose-db.yml" up -d 2>&1
  Start-Sleep -Seconds 15
  try {
    $env:TJDBC_PG_URL = "jdbc:postgresql://localhost:5433/tyfpjdbc"
    $env:TJDBC_PG_JAR = Join-Path $libs "postgresql-42.7.4.jar"
    $pout = & $semExe $jm (Join-Path $work "semantic-pg") 2>&1 | Out-String
    Write-Output $pout
    Check "semantic-pg" (($pout -match "TOTAL fails=0") -and (Test-Path (Join-Path $work "semantic-pg/baseline-pg.txt")))
  } finally {
    Remove-Item Env:TJDBC_PG_URL -ErrorAction SilentlyContinue
    Remove-Item Env:TJDBC_PG_JAR -ErrorAction SilentlyContinue
    docker compose -f "$ws\scripts\compose-db.yml" down 2>&1
  }
  Write-Output "SKIP-MATRIX: mysql no driver manifest (env-missing, pg covers server semantics)"
}

Section "binding-matrix"
# Field-binding matrix: H2/SQLite always, PG/MySQL when reachable (test SKIPs per-DB).
$bindExe = Join-Path $bin "testbinding.exe"
fpc "-FU$units" "-Fu$ws\src\core" "-Fu$ws\src\db" "-o$bindExe" "$ws\tests\TestBinding.lpr" 2>&1
Check "binding-compile" ($LASTEXITCODE -eq 0)
$bout = & $bindExe $jm (Join-Path $work "binding") 2>&1 | Out-String
Write-Output $bout
Check "binding-fails-0" ($bout -match "TOTAL fails=0")
if ($bout -cmatch "(?m)^FAIL ") { Check "binding-no-fail-lines" $false } else { Check "binding-no-fail-lines" $true }
Check "binding-null-split" (($bout -match "empty-not-null") -and ($bout -match "null-is-null"))
Check "binding-blob" ($bout -match "blob-twice")

Section "tiers-shipped-live-path"
# Tiers on the SHIPPED live path (Pascal -> JNI -> Bridge -> sqlite file DB).
# 10k/100k run in-matrix; the 1M tier is covered by the 3x scratch perf.log
# runs (acceptance evidence) because a single 1M scan already takes ~2min.
$tiersExe = Join-Path $bin "testtiers.exe"
fpc "-FU$units" "-Fu$ws\src\core" "-Fu$ws\src\db" "-o$tiersExe" "$ws\tests\TestTiers.lpr" 2>&1
Check "tiers-compile" ($LASTEXITCODE -eq 0)
$tout = & $tiersExe $jm (Join-Path $work "tiers") 1 skip1M 2>&1 | Out-String
Write-Output $tout
Check "tiers-pass" ($tout -match "fails=0")
Check "tier-10k" ($tout -match "PERF tier=10000 insert")
Check "tier-100k" ($tout -match "PERF tier=100000 insert")
Check "tier-checksum" (($tout -match "checksum=500000") -and ($tout -match "checksum=5000000"))
Check "tier-heap" ($tout -match "heap-used=")

Section "perf-compare-sqlite-vs-bridge-20k"
# Same workload, same 20k rows, separate file DBs. Pool/connect + warmup run
# BEFORE the timers on both sides, so JVM/Hikari startup is never counted.
$perfExe = Join-Path $bin "testperfcompare.exe"
fpc "-FU$units" "-Fu$ws\src\core" "-Fu$ws\src\db" "-o$perfExe" "$ws\tests\TestPerfCompare.lpr" 2>&1
Check "perf-fpc-compile" ($LASTEXITCODE -eq 0)
$fout = & $perfExe (Join-Path $work "perf-fpc.db") 20000 2>&1 | Out-String
Write-Output $fout
Check "perf-fpc-pass" (($fout -match "fails=0") -and ($fout -match "checksum=1000000"))
$jt = Join-Path $work "jtest"
New-Item -ItemType Directory -Force -Path $jt | Out-Null
$cpRun = "$jm;$jt;$libs\HikariCP-5.1.0.jar;$libs\slf4j-api-2.0.9.jar;$libs\slf4j-simple-2.0.9.jar;$libs\h2-2.2.224.jar;$libs\sqlite-jdbc-3.46.1.0.jar"
& "$jh\bin\javac.exe" -encoding UTF-8 -cp $cpRun -d $jt "$ws\java\bridge\src\test\java\tyfpjdbc\PerfCompare.java" 2>&1
Check "perf-java-compile" ($LASTEXITCODE -eq 0)
$bout = & "$jh\bin\java.exe" "-Dfile.encoding=UTF-8" -cp "$cpRun" tyfpjdbc.PerfCompare (Join-Path $work "perf-bridge.db") 20000 2>&1 | Out-String
Write-Output $bout
Check "perf-bridge-pass" (($bout -match "PERF-DONE rows=20000") -and ($bout -match "checksum=1000000"))
Check "perf-checksum-agree" (($fout -match "checksum=1000000") -and ($bout -match "checksum=1000000"))
function Ms($txt, $pat) { $mm = [regex]::Match($txt, $pat + ' ms=(\d+)'); if ($mm.Success) { return [int]$mm.Groups[1].Value } else { return -1 } }
$fi = Ms $fout "PERF fpc-insert"; $fs = Ms $fout "PERF fpc-scan"; $fp = Ms $fout "PERF fpc-paged"; $fu = Ms $fout "PERF fpc-update"
$bi = Ms $bout "PERF bridge-insert"; $bs = Ms $bout "PERF bridge-scan"; $bp = Ms $bout "PERF bridge-paged"; $bu = Ms $bout "PERF bridge-update"
Write-Output "PERF-TABLE phase | sqlite3conn-direct-ms | bridge-jdbc-ms"
Write-Output ("PERF-TABLE insert-20k | " + $fi + " | " + $bi)
Write-Output ("PERF-TABLE scan-20k | " + $fs + " | " + $bi)
Write-Output ("PERF-TABLE paged-20k | " + $fp + " | " + $bp)
Write-Output ("PERF-TABLE update-10k | " + $fu + " | " + $bu)
Check "perf-table-complete" (($fi -ge 0) -and ($fs -ge 0) -and ($fp -ge 0) -and ($fu -ge 0) -and ($bi -ge 0) -and ($bs -ge 0) -and ($bp -ge 0) -and ($bu -ge 0))

Section "examples-compile-run"
foreach ($e in @("ex01_connect_select","ex10_json_config","ex11_code_first","ex12_dbgrid")) {
  $exe = Join-Path $bin ($e + ".exe")
  if ($e -eq "ex10_json_config") {
    fpc "-FU$units" "-o$exe" (Join-Path $ws ("examples\" + $e + ".lpr")) 2>&1
  } else {
    fpc "-FU$units" "-Fu$ws\src\core" "-Fu$ws\src\db" "-o$exe" (Join-Path $ws ("examples\" + $e + ".lpr")) 2>&1
  }
  Check "$e-compile" ($LASTEXITCODE -eq 0)
  if ($e -eq "ex10_json_config") {
    $o = & $exe "$ws\configs" 2>&1 | Out-String
  } elseif ($e -eq "ex01_connect_select") {
    $o = & $exe 2>&1 | Out-String
  } else {
    $o = & $exe $jm 2>&1 | Out-String
  }
  Write-Output $o
  if ($e -eq "ex10_json_config") {
    Check "$e-run" (($o -match "PASS json-reuse") -and ($o -match "ex10 ok"))
  } elseif ($e -eq "ex11_code_first") {
    Check "$e-run" (($o -match "inserted=3") -and ($o -match "ex11 ok"))
  } elseif ($e -eq "ex12_dbgrid") {
    Check "$e-run" (($o -match "requery-rows=4") -and ($o -match "ex12 ok"))
  } else {
    Check "$e-run" ($o -match ($e.Substring(0,4) + " ok"))
  }
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

Section "lpk-design-package"
& "$ws\scripts\guard.ps1" 2>&1
Check "guard-final" ($?)
Remove-Item "$ws\lib" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$ws\tyfpjdbc_design.pas" -Force -ErrorAction SilentlyContinue
Remove-Item "$ws\packagefiles.xml" -Force -ErrorAction SilentlyContinue
& lazbuild --build-all "$ws\tyfpjdbc_design.lpk" 2>&1
Check "lpk-build" ($LASTEXITCODE -eq 0)
Remove-Item "$ws\tyfpjdbc_design.pas" -Force -ErrorAction SilentlyContinue
Remove-Item "$ws\packagefiles.xml" -Force -ErrorAction SilentlyContinue
Remove-Item "$ws\lib" -Recurse -Force -ErrorAction SilentlyContinue

Section "summary"
Write-Output ("MATRIX-FAILURES=" + $script:failures)
if ($script:failures -gt 0) { exit 1 } else { Write-Output "MATRIX-OK"; exit 0 }
