$hits = Select-String -Path "src/core/*.pas" -Pattern "Forms|Dialogs|LCL" -CaseSensitive -ErrorAction SilentlyContinue
if ($hits) { Write-Error "Core references UI units"; exit 1 }
$stale = Get-ChildItem -Path src,tests,examples -Recurse -Include *.o,*.ppu -ErrorAction SilentlyContinue
if ($stale) { Write-Error "Build artifacts beside sources"; exit 1 }
$root = Get-ChildItem -Path lib -Recurse -Include *.o,*.ppu -ErrorAction SilentlyContinue
if ($root) { Write-Error "Build artifacts in root lib/"; exit 1 }
Write-Output "guard ok"
