[CmdletBinding()]
param(
    [switch]$Launch,
    [switch]$Backup,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Pause,
    [switch]$Resume,
    [switch]$Status
)

$ErrorActionPreference = 'Continue'

$EngineDir      = $PSScriptRoot
$Root           = Split-Path -Parent $EngineDir
$BackupDir      = Join-Path $Root 'backup'
$BackupDb       = Join-Path $BackupDir 'leveldb'
$PreviousDb     = Join-Path $BackupDir 'leveldb-previous'
$StateDir       = Join-Path $Root 'state'
$LogFile        = Join-Path $StateDir 'monitor.log'
$PauseFlag      = Join-Path $StateDir 'paused.flag'
$BusyFlag       = Join-Path $StateDir 'busy.flag'
$ReadyFlag      = Join-Path $StateDir 'ready.flag'
$RepairFile     = Join-Path $StateDir 'repair-history.txt'
$SettingsFile   = Join-Path $Root 'Settings.ini'
$ScriptPath     = Join-Path $EngineDir 'Monitor.ps1'
$PowerShellPath = Join-Path $PSHOME 'powershell.exe'
$DiscordDataDir = Join-Path $env:APPDATA 'discord'
$StorePath      = Join-Path $DiscordDataDir 'Local Storage\leveldb'
$SessionStore   = Join-Path $DiscordDataDir 'Session Storage'
$StartupDir     = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$MonitorVbsName = 'Discord-Session-Monitor.vbs'
$MonitorVbsPath = Join-Path $StartupDir $MonitorVbsName
$LauncherVbs    = Join-Path $Root '2-Open-Discord.vbs'
$AppIcon        = Join-Path $env:LOCALAPPDATA 'Discord\app.ico'
$DesktopDir     = [Environment]::GetFolderPath('Desktop')
$ShortcutPath   = Join-Path $DesktopDir 'Discord (Auto Login).lnk'
$MutexName      = 'Local\DiscordSessionMonitor'

$script:LogEnabled = $true

function Write-Log {
    param([string]$Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    if ($script:LogEnabled) {
        if (-not (Test-Path -LiteralPath $StateDir)) {
            New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
        }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
        $info = Get-Item -LiteralPath $LogFile -ErrorAction SilentlyContinue
        if ($info -and $info.Length -gt 524288) {
            $tail = Get-Content -LiteralPath $LogFile -Tail 400 -ErrorAction SilentlyContinue
            Set-Content -LiteralPath $LogFile -Value $tail -Encoding UTF8
        }
    }
}

function Get-Setting {
    param([string]$Name, [string]$Default)
    if (-not (Test-Path -LiteralPath $SettingsFile)) { return $Default }
    foreach ($line in (Get-Content -LiteralPath $SettingsFile -ErrorAction SilentlyContinue)) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '') { continue }
        if ($trimmed.StartsWith(';') -or $trimmed.StartsWith('#')) { continue }
        $parts = $trimmed.Split('=', 2)
        if ($parts.Count -eq 2 -and $parts[0].Trim() -ieq $Name) { return $parts[1].Trim() }
    }
    return $Default
}

function Test-DiscordRunning {
    $processes = Get-Process -Name 'Discord', 'DiscordPTB', 'DiscordCanary' -ErrorAction SilentlyContinue
    return [bool]$processes
}

function Get-FolderSize {
    param([string]$Path)
    $sum = Get-ChildItem -LiteralPath $Path -File -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum
    if (-not $sum -or -not $sum.Sum) { return [int64]0 }
    return [int64]$sum.Sum
}

function Test-CopyValid {
    param([string]$Path, [int]$MinSize = 102400)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $Path 'CURRENT'))) { return $false }
    return ((Get-FolderSize $Path) -ge $MinSize)
}

function Test-SessionInStore {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    foreach ($file in (Get-ChildItem -LiteralPath $Path -File -Force -ErrorAction SilentlyContinue)) {
        if ($file.Length -eq 0) { continue }
        try {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            $text = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
            if ($text -match 'eyJ[A-Za-z0-9_\-]{30,}') { return $true }
            if (($text -match 'Token') -and ($text -match 'eyJ[A-Za-z0-9_\-]{12,}')) { return $true }
        } catch { }
    }
    return $false
}

function Test-SessionFromLog {
    $log = Join-Path $DiscordDataDir 'logs\renderer_js.log'
    if (-not (Test-Path -LiteralPath $log)) { return $null }
    $lines = @(Get-Content -LiteralPath $log -Tail 20000 -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) { return $null }
    $readyIndex = -1
    $loginIndex = -1
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $current = $lines[$i]
        if ($readyIndex -lt 0 -and $current -like '*GatewaySocket*READY*') { $readyIndex = $i }
        if ($loginIndex -lt 0 -and $current -like '*Transitioning to /login*') { $loginIndex = $i }
        if ($readyIndex -ge 0 -and $loginIndex -ge 0) { break }
    }
    if ($readyIndex -lt 0) { return $null }
    if ($loginIndex -lt 0) { return $true }
    return ($readyIndex -gt $loginIndex)
}

function Test-SessionEvidence {
    $fromLog = Test-SessionFromLog
    if ($fromLog -ne $null) { return [bool]$fromLog }
    return (Test-SessionInStore $StorePath)
}

function Get-LastReadyTime {
    $log = Join-Path $DiscordDataDir 'logs\renderer_js.log'
    if (-not (Test-Path -LiteralPath $log)) { return $null }
    $lines = @(Get-Content -LiteralPath $log -Tail 8000 -ErrorAction SilentlyContinue)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -like '*GatewaySocket*READY*') {
            $match = [regex]::Match($lines[$i], '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})')
            if ($match.Success) {
                $stamp = [datetime]::MinValue
                if ([datetime]::TryParse($match.Groups[1].Value, [ref]$stamp)) { return $stamp }
            }
            return $null
        }
    }
    return $null
}

function Get-DiscordStartTime {
    $process = Get-Process -Name 'Discord', 'DiscordPTB', 'DiscordCanary' -ErrorAction SilentlyContinue |
        Sort-Object StartTime | Select-Object -First 1
    if ($process) { return $process.StartTime }
    return $null
}

function Close-Discord {
    param([int]$WaitSeconds = 20)
    Get-Process -Name 'Discord', 'DiscordPTB', 'DiscordCanary' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-DiscordRunning)) {
            Start-Sleep -Milliseconds 800
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    return (-not (Test-DiscordRunning))
}

function Start-Discord {
    $updater = Join-Path $env:LOCALAPPDATA 'Discord\Update.exe'
    if (Test-Path -LiteralPath $updater) {
        Start-Process -FilePath $updater -ArgumentList '--processStart', 'Discord.exe' -ErrorAction SilentlyContinue | Out-Null
        return $true
    }
    $installDir = Join-Path $env:LOCALAPPDATA 'Discord'
    $candidates = Get-ChildItem -LiteralPath $installDir -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending
    foreach ($candidate in $candidates) {
        $exe = Join-Path $candidate.FullName 'Discord.exe'
        if (Test-Path -LiteralPath $exe) {
            Start-Process -FilePath $exe -ErrorAction SilentlyContinue | Out-Null
            return $true
        }
    }
    return $false
}

function Save-SessionBackup {
    if (-not (Test-Path -LiteralPath $StorePath)) { return $false }
    if (-not (Test-CopyValid $StorePath 51200)) { return $false }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-Path -LiteralPath $BackupDb) {
            if (Test-CopyValid $BackupDb 51200) {
                if (Test-Path -LiteralPath $PreviousDb) {
                    Remove-Item -LiteralPath $PreviousDb -Recurse -Force -ErrorAction SilentlyContinue
                }
                Move-Item -LiteralPath $BackupDb -Destination $PreviousDb -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $BackupDb) {
                Remove-Item -LiteralPath $BackupDb -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        New-Item -ItemType Directory -Path $BackupDb -Force | Out-Null
        Copy-Item -Path (Join-Path $StorePath '*') -Destination $BackupDb -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-CopyValid $BackupDb 51200) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Restore-SessionBackup {
    if (-not (Test-Path -LiteralPath $BackupDb)) { return $false }
    if (-not (Test-CopyValid $BackupDb 51200)) { return $false }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-Path -LiteralPath $StorePath) {
            Remove-Item -LiteralPath $StorePath -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType Directory -Path $StorePath -Force | Out-Null
        Copy-Item -Path (Join-Path $BackupDb '*') -Destination $StorePath -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-CopyValid $StorePath 51200) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Remove-SessionData {
    if (Test-Path -LiteralPath $StorePath) {
        Remove-Item -LiteralPath $StorePath -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $SessionStore) {
        Remove-Item -LiteralPath $SessionStore -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Set-ReadyFlag {
    if (-not (Test-Path -LiteralPath $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }
    Set-Content -LiteralPath $ReadyFlag -Value (Get-Date).ToString('o') -Encoding ASCII
}

function Test-ReadyFlagFresh {
    param([int]$Seconds = 180)
    if (-not (Test-Path -LiteralPath $ReadyFlag)) { return $false }
    $stamp = (Get-Item -LiteralPath $ReadyFlag -ErrorAction SilentlyContinue).LastWriteTime
    if (-not $stamp) { return $false }
    return (((Get-Date) - $stamp).TotalSeconds -lt $Seconds)
}

function Set-BusyFlag {
    if (-not (Test-Path -LiteralPath $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }
    Set-Content -LiteralPath $BusyFlag -Value (Get-Date).ToString('o') -Encoding ASCII
}

function Clear-BusyFlag {
    if (Test-Path -LiteralPath $BusyFlag) {
        Remove-Item -LiteralPath $BusyFlag -Force -ErrorAction SilentlyContinue
    }
}

function Test-Busy {
    return ((Test-Path -LiteralPath $PauseFlag) -or (Test-Path -LiteralPath $BusyFlag))
}

function Test-MonitorRunning {
    try {
        $mutex = [System.Threading.Mutex]::OpenExisting($MutexName)
        $mutex.Dispose()
        return $true
    } catch {
        return $false
    }
}

function Test-Installed {
    return (Test-Path -LiteralPath $MonitorVbsPath)
}

function Invoke-Backup {
    if (Test-DiscordRunning) {
        Write-Host ''
        Write-Host ' [ERROR] Discord is currently running.' -ForegroundColor Red
        Write-Host '         Discord must be fully closed so the session can be saved.'
        Write-Host '         Close the Discord window, then right click the tray icon'
        Write-Host '         and choose "Quit Discord", then run this again.'
        return 1
    }
    if (-not (Test-Path -LiteralPath $StorePath)) {
        Write-Host ''
        Write-Host ' [ERROR] Discord data not found:' -ForegroundColor Red
        Write-Host ('         ' + $StorePath)
        Write-Host '         Sign in to Discord first and run this again.'
        return 1
    }
    Write-Host ' Looking for the session token in Discord data...'
    if (-not (Test-SessionInStore $StorePath)) {
        Write-Host ''
        Write-Host ' [ERROR] No Discord session token found.' -ForegroundColor Red
        Write-Host '         Sign in to Discord, close it completely and run this again.'
        return 1
    }
    if (-not (Save-SessionBackup)) {
        Write-Host ''
        Write-Host ' [ERROR] The session could not be saved.' -ForegroundColor Red
        return 1
    }
    Write-Log 'Session backup saved'
    Write-Host ''
    Write-Host ' [OK] Session saved and token verified inside the backup.' -ForegroundColor Green
    Write-Host ('      ' + $BackupDb)
    return 0
}

function Invoke-Launch {
    if (-not (Test-Path -LiteralPath $BackupDb)) {
        Write-Host ''
        Write-Host ' [ERROR] No session backup found.' -ForegroundColor Red
        Write-Host '         Run "1-Backup-Session.bat" first.'
        return 1
    }
    if (-not (Test-Installed)) {
        Write-Host ''
        Write-Host ' [WARNING] The monitor is not installed, so Discord will not be logged out on close.' -ForegroundColor Yellow
        Write-Host '           Run "Install.bat" once to install it.'
    }
    Write-Host ' Restoring the saved session...'
    Set-BusyFlag
    try {
        $null = Close-Discord
        if (-not (Restore-SessionBackup)) {
            Write-Host ' [ERROR] The session could not be restored, please try again.' -ForegroundColor Red
            return 1
        }
        Set-ReadyFlag
        if (-not (Start-Discord)) {
            Write-Host ' [ERROR] Discord.exe was not found.' -ForegroundColor Red
            return 1
        }
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline -and -not (Test-DiscordRunning)) { Start-Sleep -Milliseconds 500 }
        Start-Sleep -Seconds 3
    } finally {
        Clear-BusyFlag
    }
    Write-Log 'Discord started with the saved session'
    Write-Host ' [OK] Discord started with the saved session.' -ForegroundColor Green
    return 0
}

function Invoke-Install {
    if (-not (Test-Path -LiteralPath $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $PauseFlag) { Remove-Item -LiteralPath $PauseFlag -Force -ErrorAction SilentlyContinue }

    $monitorVbsContent = @'
Option Explicit
Dim sh, cmd
Set sh = CreateObject("WScript.Shell")
cmd = "{0} -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{1}"""
sh.Run cmd, 0, False
'@ -f $PowerShellPath, $ScriptPath
    $monitorVbsContent = $monitorVbsContent -replace "(?<!`r)`n", "`r`n"
    [System.IO.File]::WriteAllText($MonitorVbsPath, $monitorVbsContent, [System.Text.Encoding]::Unicode)

    $launcherVbsContent = @'
Option Explicit
Dim fso, sh, root, ps, cmd, code
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
root = fso.GetParentFolderName(WScript.ScriptFullName)
ps = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
cmd = """" & ps & """ -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & root & "\engine\Monitor.ps1"" -Launch"
code = sh.Run(cmd, 0, True)
If code <> 0 Then
    MsgBox "Discord could not be started with the saved session (code " & code & ")." & vbCrLf & vbCrLf & "Solution: run 1-Backup-Session.bat and try again." & vbCrLf & "For details run 3-Status.bat.", 48, "Discord Auto Login"
End If
'@
    $launcherVbsContent = $launcherVbsContent -replace "(?<!`r)`n", "`r`n"
    [System.IO.File]::WriteAllText($LauncherVbs, $launcherVbsContent, (New-Object System.Text.ASCIIEncoding))

    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        $shortcut.TargetPath = (Join-Path $env:SystemRoot 'System32\wscript.exe')
        $shortcut.Arguments = ('"' + $LauncherVbs + '"')
        $shortcut.WorkingDirectory = $Root
        $shortcut.Description = 'Discord with saved session'
        $shortcut.WindowStyle = 1
        if (Test-Path -LiteralPath $AppIcon) { $shortcut.IconLocation = ($AppIcon + ',0') }
        $shortcut.Save()
        $shortcutOk = $true
    } catch {
        $shortcutOk = $false
    }

    if (-not (Test-MonitorRunning)) {
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $MonitorVbsPath + '"') -ErrorAction SilentlyContinue | Out-Null
        Start-Sleep -Seconds 2
    }

    Write-Host ''
    Write-Host ' [OK] Installation finished.' -ForegroundColor Green
    Write-Host ('      Startup entry  : ' + $MonitorVbsPath)
    if ($shortcutOk) { Write-Host ('      Desktop shortcut: ' + $ShortcutPath) }
    Write-Host ('      Monitor running : ' + (Test-MonitorRunning))
    Write-Host '      The shortcut opens Discord without any console window.'
    if (-not (Test-Path -LiteralPath $BackupDb)) {
        Write-Host '      [WARNING] No session backup yet: run 1-Backup-Session.bat first.' -ForegroundColor Yellow
    }
    return 0
}

function Invoke-Uninstall {
    if (Test-Path -LiteralPath $MonitorVbsPath) { Remove-Item -LiteralPath $MonitorVbsPath -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $LauncherVbs) { Remove-Item -LiteralPath $LauncherVbs -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $ShortcutPath) { Remove-Item -LiteralPath $ShortcutPath -Force -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine -like '*Monitor.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $PauseFlag) { Remove-Item -LiteralPath $PauseFlag -Force -ErrorAction SilentlyContinue }
    Write-Log 'Monitor uninstalled'
    Write-Host ''
    Write-Host ' [OK] The monitor and the desktop shortcut were removed.' -ForegroundColor Green
    Write-Host '      The "backup" folder was kept so you can install again.'
    return 0
}

function Invoke-Pause {
    if (-not (Test-Path -LiteralPath $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }
    Set-Content -LiteralPath $PauseFlag -Value (Get-Date).ToString('o') -Encoding ASCII
    Write-Log 'Monitor paused'
    Write-Host ' [OK] Monitor paused. Auto login and auto logout are disabled.' -ForegroundColor Yellow
    return 0
}

function Invoke-Resume {
    if (Test-Path -LiteralPath $PauseFlag) { Remove-Item -LiteralPath $PauseFlag -Force -ErrorAction SilentlyContinue }
    Write-Log 'Monitor resumed'
    Write-Host ' [OK] Monitor is active again.' -ForegroundColor Green
    return 0
}

function Invoke-Status {
    Write-Host ''
    Write-Host ' --- Discord Session Monitor - Status ---'
    Write-Host ('  Installed (runs at logon)   : ' + (Test-Installed))
    Write-Host ('  Monitor running             : ' + (Test-MonitorRunning))
    Write-Host ('  Paused                      : ' + (Test-Path -LiteralPath $PauseFlag))
    Write-Host ('  Discord running             : ' + (Test-DiscordRunning))
    Write-Host ('  Token found in Discord data : ' + (Test-SessionInStore $StorePath))
    Write-Host ('  Session evidence in logs    : ' + (Test-SessionEvidence))
    Write-Host ('  Backup valid (CURRENT file) : ' + (Test-CopyValid $BackupDb 51200))
    Write-Host ('  Backup last updated         : ' + (Get-Item -LiteralPath $BackupDb -ErrorAction SilentlyContinue).LastWriteTime)
    Write-Host ('  Backup size (KB)            : ' + [int]((Get-FolderSize $BackupDb) / 1024))
    Write-Host ('  Previous backup generation  : ' + (Test-CopyValid $PreviousDb 51200))
    if (Test-Path -LiteralPath $LogFile) {
        Write-Host ''
        Write-Host ' --- Latest log entries ---'
        foreach ($line in (Get-Content -LiteralPath $LogFile -Tail 8 -ErrorAction SilentlyContinue)) {
            Write-Host ('  ' + $line)
        }
    }
    return 0
}

function Invoke-Repair {
    param([int]$PollSeconds)
    $now = Get-Date
    $stamps = @()
    if (Test-Path -LiteralPath $RepairFile) {
        foreach ($entry in (Get-Content -LiteralPath $RepairFile -ErrorAction SilentlyContinue)) {
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParse($entry, [ref]$parsed)) { $stamps += $parsed }
        }
    }
    $stamps = @($stamps | Where-Object { ($now - $_).TotalMinutes -lt 10 })
    if ($stamps.Count -ge 3) {
        Write-Log 'REPAIR ABORTED: 3 attempts within 10 minutes, restart loop prevented'
        return
    }
    if (-not (Test-Path -LiteralPath $BackupDb)) {
        Write-Log 'Repair skipped: no backup available'
        return
    }
    $stamps += $now
    Set-Content -LiteralPath $RepairFile -Value ($stamps | ForEach-Object { $_.ToString('o') }) -Encoding ASCII
    Write-Log 'Empty session detected -> restarting Discord with the saved session'
    $null = Close-Discord
    if (Test-Path -LiteralPath $StorePath) {
        Remove-Item -LiteralPath $StorePath -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $StorePath -Force | Out-Null
    Copy-Item -Path (Join-Path $BackupDb '*') -Destination $StorePath -Recurse -Force -ErrorAction SilentlyContinue
    Set-ReadyFlag
    $null = Start-Discord
    Start-Sleep -Seconds $PollSeconds
}

function Remove-LeftoverSession {
    if (-not (Test-Path -LiteralPath $StorePath)) { return $false }
    if (Test-ReadyFlagFresh 180) { return $false }
    Write-Log 'Leftover session data found at startup -> removed'
    Remove-SessionData
    return $true
}

function Watch-Session {
    $pollSeconds = 3
    try { $pollSeconds = [int](Get-Setting 'POLL_SECONDS' '3') } catch { $pollSeconds = 3 }
    if ($pollSeconds -lt 2) { $pollSeconds = 2 }
    $autoRepair = ((Get-Setting 'AUTO_REPAIR' '0') -eq '1')
    $refreshBackup = ((Get-Setting 'REFRESH_BACKUP' '1') -eq '1')
    $script:LogEnabled = ((Get-Setting 'WRITE_LOG' '1') -eq '1')

    if (-not (Test-Path -LiteralPath $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }

    try {
        $created = $false
        $mutex = New-Object System.Threading.Mutex($false, $MutexName, [ref]$created)
        if (-not $created) { return 0 }
    } catch {
        $mutex = $null
    }

    Write-Log ('Monitor started (poll ' + $pollSeconds + 's, autoRepair=' + $autoRepair + ')')

    $script:ShutdownHook = $false
    try {
        $hookBody = @"
Get-Process -Name 'Discord','DiscordPTB','DiscordCanary' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 1500
`$store = Join-Path `$env:APPDATA 'discord\Local Storage\leveldb'
if (Test-Path -LiteralPath `$store) { Remove-Item -LiteralPath `$store -Recurse -Force -ErrorAction SilentlyContinue }
`$sessionStore = Join-Path `$env:APPDATA 'discord\Session Storage'
if (Test-Path -LiteralPath `$sessionStore) { Remove-Item -LiteralPath `$sessionStore -Recurse -Force -ErrorAction SilentlyContinue }
try { Add-Content -LiteralPath '$LogFile' -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  SHUTDOWN: session removed') -Encoding UTF8 } catch { }
"@
        $hook = [scriptblock]::Create($hookBody)
        Register-ObjectEvent -InputObject ([Microsoft.Win32.SystemEvents]) -EventName SessionEnding -SourceIdentifier 'DiscordSessionEnd' -Action $hook -ErrorAction Stop | Out-Null
        $script:ShutdownHook = $true
    } catch {
        $script:ShutdownHook = $false
    }
    Write-Log ('Shutdown hook active: ' + $script:ShutdownHook)

    $wasRunning = $false
    $firstPass = $true
    $script:DiscordStarted = $null
    $script:SessionConfirmed = $false
    $script:LastReadyCheck = Get-Date
    $script:RepairedStart = $null

    if (-not (Test-DiscordRunning)) {
        $null = Remove-LeftoverSession
        if (((Get-Setting 'OPEN_AT_STARTUP' '0') -eq '1') -and (Test-Path -LiteralPath $BackupDb)) {
            Write-Log 'OPEN_AT_STARTUP=1 -> starting Discord with the saved session'
            Set-BusyFlag
            try {
                if (Restore-SessionBackup) {
                    Set-ReadyFlag
                    $null = Start-Discord
                    $deadline = (Get-Date).AddSeconds(20)
                    while ((Get-Date) -lt $deadline -and -not (Test-DiscordRunning)) { Start-Sleep -Milliseconds 500 }
                    Start-Sleep -Seconds 3
                }
            } finally {
                Clear-BusyFlag
            }
        }
    }

    while ($true) {
        if (Test-Busy) {
            Start-Sleep -Seconds 1
            $firstPass = $false
            continue
        }
        $isRunning = Test-DiscordRunning
        if (-not $isRunning -and $firstPass) {
            $null = Remove-LeftoverSession
        }
        if ($isRunning) {
            if (-not $wasRunning) {
                Write-Log 'Discord started'
                $script:DiscordStarted = Get-DiscordStartTime
                $script:SessionConfirmed = $false
                $script:LastReadyCheck = (Get-Date).AddSeconds(-30)
                $script:RepairedStart = $null
            }
            if (-not $script:SessionConfirmed -and $script:DiscordStarted) {
                if (((Get-Date) - $script:LastReadyCheck).TotalSeconds -ge 30) {
                    $script:LastReadyCheck = Get-Date
                    $lastReady = Get-LastReadyTime
                    if ($lastReady -and $lastReady -ge $script:DiscordStarted.AddSeconds(-90)) {
                        $script:SessionConfirmed = $true
                        Write-Log 'Login confirmed (Discord session established)'
                    }
                }
                $repairEnabled = ((Get-Setting 'AUTO_REPAIR' '0') -eq '1')
                if ($repairEnabled -and $script:RepairedStart -ne $script:DiscordStarted) {
                    if (((Get-Date) - $script:DiscordStarted).TotalSeconds -gt 60) {
                        $script:RepairedStart = $script:DiscordStarted
                        Invoke-Repair $pollSeconds
                        $script:DiscordStarted = Get-DiscordStartTime
                        $script:LastReadyCheck = (Get-Date).AddSeconds(-30)
                    }
                }
            }
            $wasRunning = $true
        } else {
            if ($wasRunning) {
                Start-Sleep -Seconds 4
                if (Test-Busy) {
                    $firstPass = $false
                    Start-Sleep -Seconds 1
                    continue
                }
                Write-Log 'Discord closed -> ending the session'
                if (-not $refreshBackup) {
                    Write-Log 'Backup refresh disabled'
                } elseif ($script:SessionConfirmed) {
                    if (Save-SessionBackup) { Write-Log 'Backup refreshed with the current token' }
                    else { Write-Log 'WARNING: backup could not be saved, previous backup kept' }
                } else {
                    Write-Log 'Backup not refreshed: no login confirmed in this session, previous backup kept'
                }
                Remove-SessionData
                if (Test-Path -LiteralPath $ReadyFlag) { Remove-Item -LiteralPath $ReadyFlag -Force -ErrorAction SilentlyContinue }
                Write-Log 'Logged out'
                $wasRunning = $false
            }
        }
        $firstPass = $false
        Start-Sleep -Seconds $pollSeconds
    }
}

try {
    if ($Launch)    { exit (Invoke-Launch) }
    if ($Backup)    { exit (Invoke-Backup) }
    if ($Install)   { exit (Invoke-Install) }
    if ($Uninstall) { exit (Invoke-Uninstall) }
    if ($Pause)     { exit (Invoke-Pause) }
    if ($Resume)    { exit (Invoke-Resume) }
    if ($Status)    { exit (Invoke-Status) }
    exit (Watch-Session)
} catch {
    Write-Log ('ERROR: ' + $_.Exception.Message)
    Write-Host (' [ERROR] ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
