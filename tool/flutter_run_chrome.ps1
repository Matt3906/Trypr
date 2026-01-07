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
  flutter run -d chrome
  exit $LASTEXITCODE
}

Write-Host ("GOOGLE_MAPS_API_KEY found (source={0}, length={1})" -f $source, $k.Length) -ForegroundColor Green

flutter run -d chrome --dart-define=GOOGLE_MAPS_API_KEY=$k
exit $LASTEXITCODE
