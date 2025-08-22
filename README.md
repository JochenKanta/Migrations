File Migration Script
This PowerShell script automates the migration of files and directories from a source to a target server using Robocopy with multithreading and DNS-based IP resolution for load balancing. It supports parallel processing, logging, and error handling for efficient and reliable data transfer.
Features

Parallel Processing: Executes multiple Robocopy jobs concurrently, with a configurable maximum number of parallel jobs.
DNS Load Balancing: Resolves source and target hostnames to IPs randomly for each job to distribute load across multiple servers.
Comprehensive Logging: Logs all actions to both console and file, including errors, warnings, and informational messages.
Flexible Configuration: Allows customization of threads, retry counts, wait times, and log paths.
Directory and File Handling: Supports both directory (with full structure) and individual file copying.
Error Handling: Retries failed operations and logs detailed error messages.

Prerequisites

PowerShell 5.1 or later.
Administrative access to source and target file shares.
Robocopy installed (included with Windows).
Network connectivity to source and target servers.
Write permissions for the log directory.

Usage

Configure Variables: Edit the script to set the following variables:

$sourceHost: DNS name of the source server.
$sourceShare: Share path on the source server.
$targetHost: DNS name of the target server.
$targetShare: Share path on the target server.
$logPath: Directory for log files.
$threads: Number of threads for Robocopy (default: 40).
$retryCount: Number of retries for failed operations (default: 5).
$waitTime: Wait time (seconds) between retries (default: 10).
$maxParallelJobs: Maximum number of parallel jobs (default: 8).


Run the Script: Execute the script in PowerShell with administrative privileges:
.\MigrationScript.ps1


Monitor Logs: Check the log directory ($logPath) for detailed logs of each job and the main script log (MigrationScript_YYYYMMDD_HHMMSS.log).


Script Details

DNS Resolution: Uses Resolve-HostToIP function to randomly select an IPv4 address for each job, supporting load balancing.
Logging: The Write-Log function outputs to both console and file, with color-coded console output for errors (red) and warnings (yellow).
Job Management: Limits concurrent jobs to $maxParallelJobs to prevent system overload, using Wait-For-Jobs to manage job queues.
Robocopy Options:
/COPYALL: Copies all file attributes, including security permissions.
/SL: Copies symbolic links as links.
/MIR: Mirrors directory structure (for directories).
/MT:$threads: Uses multithreading for faster copying.
/R:$retryCount: Retries failed operations.
/W:$waitTime: Waits between retries.
/LOG:$logFile: Logs output to a file.
/TEE: Outputs to both log file and console.
/NP: Suppresses progress percentage for cleaner logs.


SMB Connections: Establishes fresh SMB connections for each job using resolved IPs to ensure reliable access.

Notes

Performance Tuning: Adjust $threads and $maxParallelJobs based on system resources and network capacity.
Robocopy Parameters: Additional parameters like /Z (restartable mode), /B (backup mode), or /J (unbuffered I/O for large files) can be added for specific use cases, but note that /ZB may reduce throughput.
Error Handling: The script exits if the source path is unreachable or DNS resolution fails for the initial check.
Log Management: Ensure sufficient disk space in $logPath for logs, especially for large migrations.

Example
$sourceHost = "fileserver1.example.com"
$sourceShare = "Data"
$targetHost = "fileserver2.example.com"
$targetShare = "DataBackup"
$logPath = "C:\Logs"
$threads = 40
$retryCount = 5
$waitTime = 10
$maxParallelJobs = 8

Contributing
Contributions are welcome! Please submit pull requests or open issues for bug reports or feature requests.
License
This project is licensed under the MIT License.
