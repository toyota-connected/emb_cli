# Fetch a cached Dart SDK and install `emb` from this checkout (Windows).
# Mirrors bootstrap.sh; all flags pass through, e.g.
#   .\bootstrap.ps1 --version 3.10.1
#
# Emit an Invoke-Expression-able PATH export of both Dart + the emb shim dir:
#   Invoke-Expression (.\bootstrap.ps1 --shellenv)
#   emb --version

$ErrorActionPreference = 'Stop'
# bootstrap_dart.py logs progress to stderr; don't let a non-empty native
# stderr be treated as a terminating error (PowerShell 7.4+ default).
$PSNativeCommandUseErrorActionPreference = $false

$root = Split-Path -Parent $MyInvocation.MyCommand.Path

$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
if (-not $py) { Write-Error 'python (3.6+) is required on PATH'; exit 1 }

& $py.Source (Join-Path $root 'tool\bootstrap_dart.py') --activate $root @args
exit $LASTEXITCODE
