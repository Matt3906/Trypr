$ErrorActionPreference = 'Stop'

# Read from persisted user env (setx), fallback to current process env.
$k = [Environment]::GetEnvironmentVariable('GOOGLE_MAPS_API_KEY', 'User')
$source = 'User'
if ([string]::IsNullOrWhiteSpace($k)) {
  $k = $env:GOOGLE_MAPS_API_KEY
  $source = 'Process'
}

$mapId = [Environment]::GetEnvironmentVariable('GOOGLE_MAPS_MAP_ID', 'User')
if ([string]::IsNullOrWhiteSpace($mapId)) {
  $mapId = $env:GOOGLE_MAPS_MAP_ID
}

if ([string]::IsNullOrWhiteSpace($k)) {
  Write-Host 'GOOGLE_MAPS_API_KEY not set. Maps will show "not configured".' -ForegroundColor Yellow
  flutter run -d chrome
  exit $LASTEXITCODE
}

Write-Host ("GOOGLE_MAPS_API_KEY found (source={0}, length={1})" -f $source, $k.Length) -ForegroundColor Green

$args = @('--dart-define=GOOGLE_MAPS_API_KEY=' + $k)
if (-not [string]::IsNullOrWhiteSpace($mapId)) {
  $args += ('--dart-define=GOOGLE_MAPS_MAP_ID=' + $mapId)
}

flutter run -d chrome @args
exit $LASTEXITCODE
