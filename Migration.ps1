<#
.SYNOPSIS
High-Performance Migration Script (Dynamic Queueing)

.DESCRIPTION
Kopiert Daten parallel mittels Robocopy.
Nutzt eine dynamische Warteschlange (Queue): Sobald ein Job fertig ist, startet sofort der nächste.
Optimiert für Systeme mit vielen Kernen/RAM (z.B. 48 Cores / 512GB).

FEATURES
- Dynamic Queue: Konstante Auslastung durch sofortiges Nachrücken.
- Per-Item Logging: Jedes Top-Level Element bekommt eine eigene Robocopy-Logdatei.
- Master-Log: Konsolidierte Laufzeit-/Status-Logs.
- Optional Start-ThreadJob: Wenn verfügbar, werden ThreadJobs verwendet (geringerer Overhead als Start-Job).
- Log-Zip am Ende: Archiviert die Logs.

NOTES
Robocopy ExitCodes:
0-7  => i.d.R. OK (Kopiert/Übersprungen/Extra-Dateien etc.)
>= 8 => Fehler (wird als Error gezählt)
#>

[CmdletBinding()]
param (
    [Parameter()]
    [string]$SourceHost = "sorce",

    [Parameter()]
    [string]$SourceShare = "path",

    [Parameter()]
    [string]$TargetHost = "target",

    [Parameter()]
    [string]$TargetShare = "path",

    [Parameter()]
    [string]$LogBasePath = "C:\MigrationLogs",

    # --- TUNING ---
    [Parameter()]
    [ValidateRange(1, 512)]
    [int]$MaxParallelJobs = 24,

    [Parameter()]
    [ValidateRange(1, 256)]
    [int]$RoboThreads = 24,

    [Parameter()]
    [ValidateRange(0, 100)]
    [int]$RetryCount = 3,

    [Parameter()]
    [ValidateRange(0, 300)]
    [int]$WaitTime = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- INIT ---
$startTime    = Get-Date
$startTimeStr = $startTime.ToString("yyyyMMdd_HHmmss")

$logDir        = Join-Path -Path $LogBasePath -ChildPath "Migration_$startTimeStr"
$masterLogFile = Join-Path -Path $logDir -ChildPath "_MasterLog.log"

# Verzeichnisse erstellen
New-Item -Path $logDir -ItemType Directory -Force | Out-Null

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine   = "[$timestamp] [$Level] $Message"

    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARNING" { "Yellow" }
        "SUCCESS" { "Green" }
        default   { "Gray" }
    }

    Write-Host $logLine -ForegroundColor $color

    try {
        Add-Content -Path $masterLogFile -Value $logLine -Encoding UTF8
    } catch {
        # Logging soll niemals das Skript stoppen
        Write-Host "[$timestamp] [WARNING] Konnte MasterLog nicht schreiben: $_" -ForegroundColor Yellow
    }
}

function Resolve-UncRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$SharePath
    )
    return "\\$HostName\$SharePath"
}

$sourceRoot = Resolve-UncRoot -HostName $SourceHost -SharePath $SourceShare
$targetRoot = Resolve-UncRoot -HostName $TargetHost -SharePath $TargetShare

Write-Log "Quelle: $sourceRoot"
Write-Log "Ziel:   $targetRoot"
Write-Log "Logs:   $logDir"

if (-not (Test-Path -LiteralPath $sourceRoot)) {
    Write-Log "Quelle nicht erreichbar: $sourceRoot" -Level "ERROR"
    exit 1
}
if (-not (Test-Path -LiteralPath $targetRoot)) {
    Write-Log "Ziel nicht erreichbar: $targetRoot" -Level "ERROR"
    exit 1
}

# ThreadJobs sind performanter (wenn verfügbar)
$useThreadJob = $false
if (Get-Command -Name Start-ThreadJob -ErrorAction SilentlyContinue) {
    $useThreadJob = $true
    Write-Log "Start-ThreadJob verfügbar -> nutze ThreadJobs." -Level "SUCCESS"
} else {
    Write-Log "Start-ThreadJob nicht verfügbar -> nutze Start-Job." -Level "WARNING"
}

# --- DISCOVERY ---
Write-Log "Analysiere Quelle (Top-Level Items): $sourceRoot ..."
try {
    $allItems = Get-ChildItem -LiteralPath $sourceRoot -ErrorAction Stop |
        Select-Object Name, FullName, PSIsContainer
} catch {
    Write-Log "Fehler beim Lesen der Quelle: $_" -Level "ERROR"
    exit 1
}

$totalCount = $allItems.Count
Write-Log "Gefundene Elemente: $totalCount" -Level "SUCCESS"

if ($totalCount -eq 0) {
    Write-Log "Keine Elemente gefunden. Nichts zu tun." -Level "WARNING"
    exit 0
}

# --- WORKER (Single Item) ---
$workerBlock = {
    param(
        [Parameter(Mandatory)] $Item,
        [Parameter(Mandatory)] [string]$TargetRoot,
        [Parameter(Mandatory)] [string]$LogDir,
        [Parameter(Mandatory)] [int]$RoboThreads,
        [Parameter(Mandatory)] [int]$RetryCount,
        [Parameter(Mandatory)] [int]$WaitTime
    )

    $itemName = $Item.Name
    $srcPath  = $Item.FullName
    $dstPath  = Join-Path -Path $TargetRoot -ChildPath $itemName
    $itemLog  = Join-Path -Path $LogDir     -ChildPath ($itemName + ".log")

    # Robocopy Standardargumente
    $argsList = @(
        "/COPYALL",
        "/DCOPY:DAT",
        "/IT",
        "/MT:$RoboThreads",
        "/R:$RetryCount",
        "/W:$WaitTime",
        "/LOG:$itemLog",
        "/NP",
        "/J",
        "/FFT",
        "/TS",
        "/FP"
    )

    try {
        if ($Item.PSIsContainer) {
            # Ordner -> Mirror
            $finalArgs = @($srcPath, $dstPath) + $argsList + "/MIR"
            & robocopy @finalArgs | Out-Null
        } else {
            # Datei -> robocopy: <srcDir> <dstDir> <file>
            $srcParent = Split-Path -Path $srcPath -Parent
            $dstParent = Split-Path -Path $dstPath -Parent
            $finalArgs = @($srcParent, $dstParent, $itemName) + $argsList
            & robocopy @finalArgs | Out-Null
        }

        $exitCode = $LASTEXITCODE
    } catch {
        # Falls robocopy selbst nicht startbar ist o.ä.
        $exitCode = 9999
    }

    [PSCustomObject]@{
        ItemName = $itemName
        ExitCode = $exitCode
    }
}

# --- DYNAMIC QUEUE EXECUTION ---
Write-Log "Starte Migration (MaxParallelJobs=$MaxParallelJobs, RoboThreads=$RoboThreads) ..."

$runningJobs    = [System.Collections.Generic.List[object]]::new()
$queue          = [System.Collections.Generic.Queue[object]]::new($allItems)
$completedCount = 0
$globalErrors   = 0

function Start-MigrationJob {
    param(
        [Parameter(Mandatory)] $NextItem
    )

    $argList = @($NextItem, $targetRoot, $logDir, $RoboThreads, $RetryCount, $WaitTime)

    if ($useThreadJob) {
        return Start-ThreadJob -ScriptBlock $workerBlock -ArgumentList $argList
    }

    return Start-Job -ScriptBlock $workerBlock -ArgumentList $argList
}

while ($queue.Count -gt 0 -or $runningJobs.Count -gt 0) {

    # 1) Fertige Jobs einsammeln (rückwärts iterieren)
    for ($i = $runningJobs.Count - 1; $i -ge 0; $i--) {
        $job = $runningJobs[$i]

        if ($job.State -ne "Running") {
            $results = @()
            try {
                $results = Receive-Job -Job $job -ErrorAction Stop
            } catch {
                # Wenn Receive-Job scheitert, zählt das als Fehler
                $results = @([PSCustomObject]@{ ItemName = "<unknown>"; ExitCode = 9998 })
            }

            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            $runningJobs.RemoveAt($i)
            $completedCount++

            foreach ($res in $results) {
                # Robocopy: >= 8 bedeutet Fehler
                if ([int]$res.ExitCode -ge 8) {
                    $globalErrors++
                }
            }
        }
    }

    # 2) Neue Jobs starten, solange Slots frei sind
    while ($runningJobs.Count -lt $MaxParallelJobs -and $queue.Count -gt 0) {
        $nextItem = $queue.Dequeue()
        $newJob   = Start-MigrationJob -NextItem $nextItem
        $runningJobs.Add($newJob)
    }

    # 3) Fortschritt anzeigen
    $percent = if ($totalCount -gt 0) { [math]::Round(($completedCount / $totalCount) * 100, 1) } else { 0 }

    Write-Progress `
        -Activity "Migration" `
        -Status ("In Queue: {0} | Aktiv: {1} | Fertig: {2}/{3} ({4}%) | Errors: {5}" -f $queue.Count, $runningJobs.Count, $completedCount, $totalCount, $percent, $globalErrors) `
        -PercentComplete $percent

    # Mini-Sleep nur wenn noch Jobs laufen (CPU schonen)
    if ($runningJobs.Count -gt 0) {
        Start-Sleep -Milliseconds 200
    }
}

Write-Progress -Activity "Migration" -Completed

# --- SUMMARY ---
[System.GC]::Collect()

$endTime  = Get-Date
$duration = $endTime - $startTime

Write-Log "--- ZUSAMMENFASSUNG ---"
Write-Log ("Dauer: {0}" -f $duration.ToString("hh\:mm\:ss"))
Write-Log ("Logs liegen unter: {0}" -f $logDir)

if ($globalErrors -gt 0) {
    Write-Log ("Es gab {0} Fehler (Robocopy ExitCode >= 8). Bitte Item-Logs prüfen!" -f $globalErrors) -Level "WARNING"
} else {
    Write-Log "Alle Jobs erfolgreich (ExitCodes 0-7)." -Level "SUCCESS"
}

# --- ZIP LOGS ---
Write-Log "Archiviere Logs ..."
try {
    $zipPath = Join-Path -Path $LogBasePath -ChildPath "MigrationLogs_$startTimeStr.zip"
    Compress-Archive -Path (Join-Path $logDir "*") -DestinationPath $zipPath -Force -ErrorAction Stop
    Write-Log "Log-Archiv erstellt: $zipPath" -Level "SUCCESS"
} catch {
    Write-Log "Konnte Logs nicht zippen: $_" -Level "WARNING"
}

# Optional: ExitCode für CI/Automation
if ($globalErrors -gt 0) { exit 2 } else { exit 0 }
