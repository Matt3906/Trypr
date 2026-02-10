$ErrorActionPreference = 'Stop'

# ─── Build Earth (3D Globe) React app first ───
$earthDir = Join-Path $PSScriptRoot '..\Earth'
if (Test-Path (Join-Path $earthDir 'package.json')) {
  Write-Host 'Building Earth 3D globe app...' -ForegroundColor Cyan
  Push-Location $earthDir
  if (-not (Test-Path 'node_modules')) {
    Write-Host '  Installing Earth dependencies...' -ForegroundColor Yellow
    npm install
  }
  npm run build
  if ($LASTEXITCODE -ne 0) {
    Write-Host 'Earth build failed!' -ForegroundColor Red
    Pop-Location
    exit 1
  }
  Pop-Location
  Write-Host 'Earth 3D globe built -> web/earth/' -ForegroundColor Green
} else {
  Write-Host 'Earth folder not found, skipping globe build.' -ForegroundColor Yellow
}

# ─── Build Flutter web ───
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

# Build web with optimizations
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

# Copy .htaccess into build output (flutter build web doesn't copy dotfiles)
$htaccess = "web\.htaccess"
if (Test-Path $htaccess) {
  Copy-Item $htaccess "build\web\.htaccess" -Force
  Write-Host '.htaccess copied to build/web/' -ForegroundColor Green
}

exit $LASTEXITCODE
