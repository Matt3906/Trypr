$ErrorActionPreference = 'Stop'

# Read from persisted user env (setx), fallback to current process env.
$k = [Environment]::GetEnvironmentVariable('GOOGLE_MAPS_API_KEY', 'User')
$source = 'User'
if ([string]::IsNullOrWhiteSpace($k)) {
  $k = $env:GOOGLE_MAPS_API_KEY
  $source = 'Process'
}

if ([string]::IsNullOrWhiteSpace($k)) {
  Write-Host 'GOOGLE_MAPS_API_KEY not set. Maps will show "not configured".' -ForegroundColor Yellow
  flutter build web --dart-define=GOOGLE_MAPS_API_KEY=
  exit $LASTEXITCODE
}

Write-Host ("GOOGLE_MAPS_API_KEY found (source={0}, length={1})" -f $source, $k.Length) -ForegroundColor Green

flutter build web --dart-define=GOOGLE_MAPS_API_KEY=$k

# Inject the API key into the built index.html (build/web is in .gitignore, so this is safe)
$indexPath = "build\web\index.html"
if (Test-Path $indexPath) {
  Write-Host 'Injecting Google Maps API key into build/web/index.html...' -ForegroundColor Cyan
  $content = Get-Content $indexPath -Raw
  $content = $content -replace '<meta name="google-maps-api-key" content="">', "<meta name=`"google-maps-api-key`" content=`"$k`">"
  Set-Content $indexPath -Value $content -NoNewline
  Write-Host 'API key injected successfully!' -ForegroundColor Green
}

exit $LASTEXITCODE
