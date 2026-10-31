param(
    [Parameter(Mandatory=$true)][string]$GameDirectory,
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$GameArgs
)
$ErrorActionPreference = 'Stop'
$elf = (Resolve-Path (Join-Path $GameDirectory 'elf/hod4M.elf')).Path
$expected = (Get-Content (Join-Path $PSScriptRoot 'hod4M.elf.sha256') -Raw).Trim()
if ((Get-FileHash $elf -Algorithm SHA256).Hash -ne $expected) {
    throw 'Game ELF does not match this build. Rebuild using this copy of HOTD4.'
}
$exe = Join-Path $PSScriptRoot 'hotd4.exe'
$log = Join-Path $PSScriptRoot 'hotd4.log'
# Cg's precompiled programs sit below the game tree.
$env:TEA_DIR = (Resolve-Path $GameDirectory).Path
$code = 1
Push-Location (Split-Path $elf)
try {
    Write-Host "Starting HOTD4 OpenXR; log: $log"
    # Windows PowerShell 5 represents native stderr as error records.
    $ErrorActionPreference = 'Continue'
    & $exe 'hod4M.elf' @GameArgs *> $log
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}
exit $code
