param(
  [string]$StageDir = "",
  [string]$OutZip = "",
  [string]$FixedDate = "2026-01-01T00:00:00Z"
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression

# Deterministic zip for TyFPJDBC runtimes: entries sorted by relative path
# (forward slashes), every entry timestamp fixed, Optimal compression,
# top-level folder kept (entry names prefixed with the stage dir name).
# Rebuilding the same stage dir yields byte-identical output, so the sha256
# recorded in configs/runtimes.json reproduces on any machine.
# NOTE: same limitation as Compress-Archive -- no unix permission bits are
# stored; on Linux/macOS run `chmod +x bin/*` after extraction (documented
# in the Release notes of TyFPJDBC-Runtimes).

if ($StageDir -eq "" -or $OutZip -eq "") { throw "need -StageDir and -OutZip" }
$root = (Resolve-Path $StageDir).Path
if (Test-Path $OutZip) { Remove-Item -Force $OutZip }
$fixed = [DateTimeOffset]::Parse($FixedDate)
$prefix = Split-Path $root -Leaf
$files = Get-ChildItem $root -Recurse -File | ForEach-Object {
  $prefix + "/" + (($_.FullName.Substring($root.Length + 1) -replace "\\", "/"))
} | Sort-Object
$fs = [System.IO.File]::Open($OutZip, [System.IO.FileMode]::CreateNew)
try {
  $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create, $false)
  try {
    foreach ($rel in $files) {
      $entry = $zip.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
      $entry.LastWriteTime = $fixed
      $local = $rel.Substring($prefix.Length + 1) -replace "/", [IO.Path]::DirectorySeparatorChar
      $src = [System.IO.File]::OpenRead((Join-Path $root $local))
      try {
        $dst = $entry.Open()
        try { $src.CopyTo($dst) } finally { $dst.Close() }
      } finally { $src.Close() }
    }
  } finally { $zip.Dispose() }
} finally { $fs.Close() }
$h = (Get-FileHash $OutZip -Algorithm SHA256).Hash.ToLower()
$b = (Get-Item $OutZip).Length
Write-Output ("entries=" + $files.Count)
Write-Output ("bytes=" + $b)
Write-Output ("sha256=" + $h)
