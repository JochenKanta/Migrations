# Variablen definieren 
$sourceHost = "dns-name-of-source"  # Quell-Hostname
$sourceShare = "source-path"
$targetHost = "dns-name-of-target"  # Ziel-Hostname
$targetShare = "target-path"
$logPath = "log-path"  # Pfad für die Log-Dateien
$threads = 40  # Multithreading (Anzahl der Threads für Robocopy)
$retryCount = 5  # Anzahl der Wiederholungen bei Fehlern
$waitTime = 10  # Wartezeit (Sekunden) zwischen Wiederholungen
$maxParallelJobs = 8  # Maximale Anzahl paralleler Jobs
$scriptLogFile = Join-Path -Path $logPath -ChildPath "MigrationScript_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Funktion für Logging in Konsole und Datei
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Ausgabe in Konsole
    switch ($Level) {
        "ERROR" { Write-Host $logMessage -ForegroundColor Red }
        "WARNING" { Write-Host $logMessage -ForegroundColor Yellow }
        default { Write-Host $logMessage }
    }
    
    # Ausgabe in Logfile
    Add-Content -Path $scriptLogFile -Value $logMessage
}

# Funktion zum Auflösen von Hostnamen zu IPs mit zufälliger Auswahl
function Resolve-HostToIP {
    param (
        [string]$hostName
    )
    try {
        $ips = [System.Net.Dns]::GetHostAddresses($hostName) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -ExpandProperty IPAddressToString
        if ($ips) {
            # Zufällige IP aus der Liste auswählen
            $selectedIP = $ips | Get-Random
            Write-Log "Host $hostName aufgelöst, zufällig ausgewählte IP: $selectedIP"
            return $selectedIP
        } else {
            Write-Log "Keine IPv4-Adresse für $hostName gefunden." -Level "WARNING"
            return $null
        }
    } catch {
        Write-Log "Fehler beim Auflösen von $hostName : $_" -Level "WARNING"
        return $null
    }
}

# Log-Verzeichnis erstellen, falls nicht vorhanden
if (-not (Test-Path -Path $logPath)) {
    New-Item -ItemType Directory -Path $logPath | Out-Null
    Write-Log "Log-Verzeichnis erstellt: $logPath"
}

# Initialer Quellpfad für Verzeichnis- und Dateiauflistung (einmalige Auflösung für Initialprüfung)
$initialSourceIP = Resolve-HostToIP -hostName $sourceHost
if (-not $initialSourceIP) {
    Write-Log "Keine gültige IP für $sourceHost erhalten. Skript wird abgebrochen." -Level "ERROR"
    exit
}
$sourcePath = "\\$initialSourceIP\$sourceShare"
if (-not (Test-Path $sourcePath)) {
    Write-Log "Quellpfad $sourcePath nicht erreichbar!" -Level "ERROR"
    exit
}

# Alle Elemente (Ordner und Dateien) auf der obersten Ebene holen
$items = Get-ChildItem -Path $sourcePath | Select-Object -Property Name, @{Name="IsDirectory";Expression={$_.PSIsContainer}}
Write-Log "Gefundene Elemente: $($items.Count)"

# Funktion zum Warten, bis Jobs abgeschlossen sind
function Wait-For-Jobs {
    param (
        [int]$maxJobs
    )
    while ((Get-Job -State Running).Count -ge $maxJobs) {
        Start-Sleep -Seconds 1
    }
}

# HashTable zum Speichern der Zuordnung von Job-ID zu Item-Name
$jobItemMap = @{}

# Skript generieren und Befehle parallel ausführen
foreach ($item in $items) {
    # Neue DNS-Auflösung für jeden Job
    $currentSourceIP = Resolve-HostToIP -hostName $sourceHost
    $currentTargetIP = Resolve-HostToIP -hostName $targetHost

    if (-not $currentSourceIP -or -not $currentTargetIP) {
        Write-Log "DNS-Auflösung fehlgeschlagen für Item $($item.Name). Überspringe Job." -Level "WARNING"
        continue
    }

    # Quell- und Zielpfade mit den aufgelösten IPs
    $sourceItemPath = "\\$currentSourceIP\$sourceShare\$($item.Name)"
    $targetItemPath = "\\$currentTargetIP\$targetShare\$($item.Name)"
    $logFile = Join-Path -Path $logPath -ChildPath "$($item.Name).log"

    # Typ des Elements (Ordner oder Datei) für die Ausgabe
    $itemType = if ($item.IsDirectory) { "Ordner" } else { "Datei" }
    Write-Log "Starte Job für $itemType $($item.Name) mit Source IP: $currentSourceIP, Target IP: $currentTargetIP"

    # Warten, bis Platz für neue Jobs ist
    Wait-For-Jobs -maxJobs $maxParallelJobs

    # PowerShell-Job starten
    $job = Start-Job -ScriptBlock {
        param($sourceItemPath, $targetItemPath, $logFile, $threads, $retryCount, $waitTime, $sourceIP, $targetIP, $sourceShare, $targetShare, $isDirectory, $scriptLogFile)

        # Write-Log Funktion innerhalb des Jobs definieren
        function Write-Log {
            param (
                [string]$Message,
                [string]$Level = "INFO"
            )
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $logMessage = "[$timestamp] [$Level] $Message"
            
            # Ausgabe in Konsole
            switch ($Level) {
                "ERROR" { Write-Host $logMessage -ForegroundColor Red }
                "WARNING" { Write-Host $logMessage -ForegroundColor Yellow }
                default { Write-Host $logMessage }
            }
            
            # Ausgabe in Logfile
            Add-Content -Path $scriptLogFile -Value $logMessage
        }

        # Funktion für SMB-Verbindung mit IP
        function New-SMBConnection {
            param (
                [string]$ip,
                [string]$share
            )
            $fullPath = "\\$ip\$share"
            net use $fullPath /delete 2>$null
            net use $fullPath 2>$null
        }

        # Neue SMB-Verbindungen für Quelle und Ziel
        New-SMBConnection -ip $sourceIP -share $sourceShare
        New-SMBConnection -ip $targetIP -share $targetShare

        # Robocopy-Befehl zusammenstellen und loggen
        # Für Ordner: komplette Struktur kopieren
            # bei Bedarf um die Parameter /Z /B oder /ZB erweitern, ACHTUNG /ZB dieser Parameter führt zu einem drastischen Einbruch des Durchsatzes und verzehnfachung der IOPS.
            # bei großen Dateien zusätzlich /J für unbuffered IO verwenden.
            #/J = unbuffered IO, /Z = restartable mode, /B = backup mode
            # Bei einem Abgleich wo auf der Quelle und dem target gerarbeite worden ist, könne die Parameter /E /XO sinnvoll sein.
            # /XO = exclude older files, /E = copy all subdirectories, including empty ones
        if ($isDirectory) {
            $robocopyCommand = "robocopy $sourceItemPath $targetItemPath /COPYALL /SL /MIR /MT:$threads /R:$retryCount /W:$waitTime /LOG:$logFile /TEE /NP"
            Write-Log "Robocopy-Befehl: $robocopyCommand"
            # Für Ordner: komplette Struktur kopieren
            & robocopy $sourceItemPath $targetItemPath /COPYALL /SL /MIR /MT:$threads /R:$retryCount /W:$waitTime /LOG:$logFile /TEE /NP 2>&1 | Out-Null
        } else {
            $robocopyCommand = "robocopy $(Split-Path $sourceItemPath -Parent) $(Split-Path $targetItemPath -Parent) $(Split-Path $sourceItemPath -Leaf) /COPYALL /SL /MT:$threads /R:$retryCount /W:$waitTime /LOG:$logFile /TEE /NP"
            Write-Log "Robocopy-Befehl: $robocopyCommand"
            # Für Dateien: nur die Datei kopieren, keine Unterverzeichnisse
            & robocopy (Split-Path $sourceItemPath -Parent) (Split-Path $targetItemPath -Parent) (Split-Path $sourceItemPath -Leaf) /COPYALL /SL /MT:$threads /R:$retryCount /W:$waitTime /LOG:$logFile /TEE /NP 2>&1 | Out-Null
        }
        $exitCode = $LASTEXITCODE
        # Erfolg melden, wenn Exit-Code 0-7 (Robocopy-Erfolgscodes)
        if ($exitCode -le 7) {
            Write-Output "Job erfolgreich beendet (Exit-Code: $exitCode)"
        } else {
            Write-Output "Job fehlerhaft beendet (Exit-Code: $exitCode)"
        }
    } -ArgumentList $sourceItemPath, $targetItemPath, $logFile, $threads, $retryCount, $waitTime, $currentSourceIP, $currentTargetIP, $sourceShare, $targetShare, $item.IsDirectory, $scriptLogFile

    # Job-ID und Item-Name in HashTable speichern
    $jobItemMap[$job.Id] = $item.Name

    Write-Log "Job gestartet: $($job.Id) für $itemType $($item.Name)"
}

# Warten auf Job-Abschluss und erweiterte Ausgabe
Write-Log "Warte auf Abschluss der Jobs..."
while (Get-Job -State Running) {
    $completedJobs = Get-Job -State Completed
    foreach ($job in $completedJobs) {
        $result = Receive-Job -Id $job.Id
        $itemName = $jobItemMap[$job.Id]
        Write-Log "Job $($job.Id) für $($itemName): $result"
        Remove-Job -Id $job.Id
    }
    Start-Sleep -Seconds 5
}

# Finale Ergebnisse ausgeben
$remainingJobs = Get-Job
foreach ($job in $remainingJobs) {
    $result = Receive-Job -Id $job.Id
    $itemName = $jobItemMap[$job.Id]
    Write-Log "Job $($job.Id) für $($itemName): $result"
    Remove-Job -Id $job.Id
}

Write-Log "Alle Robocopy-Jobs abgeschlossen. Logs finden Sie unter $logPath."

# --- Den gesamte Protokollordner mit Zeitstempel Archivieren ---------------------------------
try {
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $logFolderName = Split-Path -Path $logPath -Leaf
    $archiveRoot   = Join-Path -Path (Split-Path -Path $logPath -Parent) -ChildPath 'LogArchives'

    if (-not (Test-Path $archiveRoot)) {
        New-Item -Path $archiveRoot -ItemType Directory | Out-Null
        Write-Log "Archiv-Ordner erstellt: $archiveRoot"
    }

    $zipName = "${logFolderName}_$ts.zip"
    $zipPath = Join-Path -Path $archiveRoot -ChildPath $zipName

    Write-Log "Komprimiere Log-Verzeichnis '$logPath' nach '$zipPath'..."
    if (Test-Path $zipPath) { Remove-Item -Path $zipPath -Force }
    Compress-Archive -Path (Join-Path $logPath '*') -DestinationPath $zipPath -Force

    Write-Log "Archiv erstellt: $zipPath"
} catch {
    Write-Log "Fehler beim Erstellen des Log-Archivs: $_" -Level "ERROR"
}
# ------------------------------------------------------------------------------
