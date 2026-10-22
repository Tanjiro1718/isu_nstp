param(
    [string]$BaseHref = "/"
)

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$frontend = Join-Path $root "isu_nstp_frontend"
$output = Join-Path $root "webapp"

Push-Location $frontend
try {
    flutter build web --release --base-href $BaseHref
    if ($LASTEXITCODE -ne 0) {
        throw "flutter build web failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}

if (Test-Path -LiteralPath $output) {
    Remove-Item -LiteralPath $output -Recurse -Force
}

Copy-Item -LiteralPath (Join-Path $frontend "build\web") -Destination $output -Recurse
Write-Host "Flutter web build copied to $output"
