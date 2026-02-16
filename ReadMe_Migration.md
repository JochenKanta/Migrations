# High-Performance Migration Script (Dynamic Queueing)

Dieses PowerShell-Skript migriert Daten **parallel** via **Robocopy** von einer UNC-Quelle zu einem UNC-Ziel.
Es nutzt eine **dynamische Queue**: sobald ein Job fertig ist, wird sofort der nächste gestartet.
Dadurch bleibt CPU/Netzwerk konstant ausgelastet (besonders sinnvoll auf Hosts mit vielen Kernen/RAM).

## Features

- **Dynamic Queueing**: konstante Auslastung durch Nachrücken, keine „Batch-Wartezeiten“
- **Per-Item Robocopy-Logs**: jedes Top-Level Element bekommt ein eigenes Log
- **MasterLog**: zentrale Status-/Zusammenfassungs-Logs
- **ThreadJobs bevorzugt**: `Start-ThreadJob` wird genutzt, wenn vorhanden (geringerer Overhead)
- **Log-Zip am Ende**: Logs werden automatisch archiviert

## Voraussetzungen

- Windows PowerShell 5.1 oder PowerShell 7+
- `robocopy` (auf Windows standardmäßig vorhanden)
- Netzwerkzugriff auf Quelle und Ziel (UNC-Pfade)
- Optional (empfohlen): PowerShell-Modul **ThreadJob** / `Start-ThreadJob`
  - Wenn nicht verfügbar, fällt das Skript automatisch auf `Start-Job` zurück.

## Robocopy ExitCodes (Kurzüberblick)

Robocopy liefert ExitCodes, die **nicht** wie klassische „0=OK, >0=Fehler“ interpretiert werden:

- **0–7**: i.d.R. OK (z.B. kopiert, übersprungen, Extras gefunden, etc.)
- **>= 8**: Fehler (wird vom Skript als Fehler gezählt)

## Nutzung

### Standardlauf (Defaults)

```powershell
.\Migration.ps1
