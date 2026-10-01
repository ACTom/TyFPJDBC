param(
  [Parameter(Mandatory = $true)][string]$ManifestPath,
  [Parameter(Mandatory = $true)][string]$Platform,
  [Parameter(Mandatory = $true)][long]$PackedBytes,
  [Parameter(Mandatory = $true)][long]$UnpackedBytes,
  [Parameter(Mandatory = $true)][string]$Sha256,
  [Parameter(Mandatory = $true)][string]$JdkVersion,
  [Parameter(Mandatory = $true)][string]$BridgeVersion,
  [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ReleaseTag,
  [Parameter(Mandatory = $true)][string]$AssetUrl
)
$ErrorActionPreference = "Stop"

# Updates exactly one platform entry in configs/runtimes.json, preserving
# every other byte: same 2-space indent, same key order, same encoding
# (UTF-8 without BOM), same CRLF newlines. Only the seven value tokens of
# that platform's entry change; indentation and quoting are untouched
# because each replacement rewrites the value token only.

$bytes = [System.IO.File]::ReadAllBytes($ManifestPath)
$hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
$enc = New-Object System.Text.UTF8Encoding($false)
$text = $enc.GetString($bytes)
if ($hasBom -and $text.StartsWith([char]0xFEFF)) { $text = $text.Substring(1) }

$blockRx = [regex]("\{[^{}]*`"platform`"\s*:\s*`"" + [regex]::Escape($Platform) + "`"[^{}]*\}")
$m = $blockRx.Match($text)
if (-not $m.Success) { throw "platform entry not found: $Platform" }
$block = $m.Value

function Replace-Value([string]$b, [string]$field, [string]$pattern, [string]$replacement) {
  $rx = [regex]("`"" + $field + "`"\s*:\s*" + $pattern)
  if (-not $rx.IsMatch($b)) { throw "field not found in entry ${Platform}: $field" }
  return $rx.Replace($b, ("`"" + $field + "`": " + $replacement), 1)
}

$newBlock = $block
$newBlock = Replace-Value $newBlock "packedBytes" "\d+" "$PackedBytes"
$newBlock = Replace-Value $newBlock "unpackedBytes" "\d+" "$UnpackedBytes"
$newBlock = Replace-Value $newBlock "sha256" "`"[0-9a-fA-F]*`"" ("`"" + $Sha256.ToLower() + "`"")
$newBlock = Replace-Value $newBlock "jdkVersion" "`"[^`"]*`"" ("`"" + $JdkVersion + "`"")
$newBlock = Replace-Value $newBlock "bridgeVersion" "`"[^`"]*`"" ("`"" + $BridgeVersion + "`"")
$newBlock = Replace-Value $newBlock "releaseTag" "`"[^`"]*`"" ("`"" + $ReleaseTag + "`"")
$newBlock = Replace-Value $newBlock "url" "`"[^`"]*`"" ("`"" + $AssetUrl + "`"")

$text = $text.Substring(0, $m.Index) + $newBlock + $text.Substring($m.Index + $m.Length)
$body = $enc.GetBytes($text)
$ms = New-Object System.IO.MemoryStream
if ($hasBom) {
  $bom = New-Object byte[] 3
  $bom[0] = 0xEF; $bom[1] = 0xBB; $bom[2] = 0xBF
  $ms.Write($bom, 0, 3)
}
$ms.Write($body, 0, $body.Length)
[System.IO.File]::WriteAllBytes($ManifestPath, $ms.ToArray())
$ms.Close()
Write-Output ("manifest updated: " + $Platform)
