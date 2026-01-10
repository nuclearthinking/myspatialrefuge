# Tail PZ console.txt filtered for myspatialrefuge mod output
# Usage: .\tail-log.ps1 [lines]
# Example: .\tail-log.ps1 100

param(
    [int]$Tail = 50
)

$logPath = "$env:USERPROFILE\Zomboid\console.txt"

if (-not (Test-Path $logPath)) {
    Write-Host "Log file not found: $logPath" -ForegroundColor Red
    Write-Host "Make sure Project Zomboid has been run at least once." -ForegroundColor Yellow
    exit 1
}

Write-Host "Monitoring: $logPath" -ForegroundColor Cyan
Write-Host "Filter: [\\myspatialrefuge]" -ForegroundColor Cyan
Write-Host "Showing last $Tail lines, waiting for new output..." -ForegroundColor Gray
Write-Host "Press Ctrl+C to stop" -ForegroundColor Gray
Write-Host "----------------------------------------" -ForegroundColor DarkGray

Get-Content -Path $logPath -Wait -Tail $Tail | Select-String -Pattern "\[\\myspatialrefuge\]"
