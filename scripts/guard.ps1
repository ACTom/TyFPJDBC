$hits = Select-String -Path "src/core/*.pas" -Pattern "Forms|Dialogs|LCL" -CaseSensitive -ErrorAction SilentlyContinue
if ($hits) { Write-Error "Core references UI units"; exit 1 }
Write-Output "guard ok"
