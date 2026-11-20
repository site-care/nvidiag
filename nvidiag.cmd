@echo off
setlocal
title Nvidiag v4.0 - NVIDIA driver SSD write bug diagnostic and fix
chcp 65001 >nul

set "SELF_PATH=%~f0"
set "ARG_SEC=%~1"
set "NVIDIAG_ELEVATED="
if /i "%~1"=="__NVIDIAG_ELEVATED" (
    set "NVIDIAG_ELEVATED=1"
    set "ARG_SEC=%~2"
)

:: Administrator check. fltmc needs admin rights and, unlike "net session",
:: does not depend on the Server (LanmanServer) service being enabled.
fltmc >nul 2>&1
if %errorlevel% equ 0 goto :is_admin

if defined NVIDIAG_ELEVATED (
    echo.
    echo [Nvidiag] Still not running as Administrator after the UAC prompt.
    echo [Nvidiag] Right-click nvidiag.cmd and choose "Run as administrator".
    pause
    exit /b 1
)

echo [Nvidiag] Requesting Administrator rights (UAC)...
powershell -NoProfile -Command "try { $a = '__NVIDIAG_ELEVATED'; if ($env:ARG_SEC) { $a = $a + ' ' + $env:ARG_SEC }; Start-Process -FilePath $env:SELF_PATH -ArgumentList $a -Verb RunAs; exit 0 } catch { exit 1 }"
if %errorlevel% neq 0 (
    echo [Nvidiag] The UAC prompt was cancelled. Nothing was changed.
    pause
)
exit /b

:is_admin
:: Prefer PowerShell 7 (pwsh), fall back to Windows PowerShell 5.1
where pwsh >nul 2>&1
if %errorlevel% equ 0 (
    set "PS_EXE=pwsh"
) else (
    set "PS_EXE=powershell"
)

:: Extract and run the embedded PowerShell payload below the marker line
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "$c = Get-Content -LiteralPath $env:SELF_PATH -Raw; $m = '#___' + 'PS_PAYLOAD___'; $code = $c.Substring($c.IndexOf($m) + $m.Length); $sb = [scriptblock]::Create($code); $s = 0; if ([int]::TryParse($env:ARG_SEC, [ref]$s)) { & $sb -Seconds $s } else { & $sb }"
if %errorlevel% neq 0 (
    echo.
    echo [Nvidiag] PowerShell exited with code %errorlevel%.
    pause
)
exit /b
#___PS_PAYLOAD___
<#
.SYNOPSIS
    Nvidiag v4.0 - diagnose and work around the NVIDIA Display Container
    (NVDisplay.Container.exe) excessive SSD write bug, where the _nvtopps
    plugin keeps rewriting %ProgramData%\NVIDIA Corporation\nvtopps\nct\nvlog.nvlgstg.
.NOTES
    https://github.com/site-care/nvidiag - MIT License - not affiliated with NVIDIA.
#>
[CmdletBinding()]
param(
    [int]$Seconds = 60
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}

if ($Seconds -lt 5)    { $Seconds = 5 }
if ($Seconds -gt 3600) { $Seconds = 3600 }

$AppName         = 'Nvidiag'
$AppVersion      = '4.0'
$RegPath         = 'HKLM:\SYSTEM\CurrentControlSet\Services\NVDisplay.ContainerLocalSystem\Parameters\LocalSystem\_nvtopps'
$ServiceName     = 'NVDisplay.ContainerLocalSystem'
$ProcessName     = 'NVDisplay.Container.exe'
$NvLogFile       = Join-Path $env:ProgramData 'NVIDIA Corporation\nvtopps\nct\nvlog.nvlgstg'
$ServiceLogFile  = Join-Path $env:ProgramData 'NVIDIA\NVDisplay.ContainerLocalSystem.log'
$ReportedDrivers = @('621.14', '621.24')   # community reports, Nov 2026
$CleanDriver     = '621.01'                # last driver reported clean
$BugMBh          = 500                     # MB/h at or above = bug pattern
$WarnMBh         = 50                      # MB/h at or above = elevated
$Width           = 76

try {
    if ([Console]::WindowWidth -lt ($Width + 2)) {
        if ([Console]::BufferWidth -lt ($Width + 2)) { [Console]::BufferWidth = $Width + 4 }
        [Console]::WindowWidth = $Width + 2
    }
} catch {}

# --- Solid pixel glyphs (no shade characters, 100% ASCII source) ---
$PX   = [string][char]0x2588   # full block
$PXUP = [string][char]0x2580   # upper half block
$PXDN = [string][char]0x2584   # lower half block
$Rainbow = @('Red', 'DarkYellow', 'Yellow', 'Green', 'Cyan', 'Blue', 'Magenta')

function Set-CursorVisible {
    param([bool]$Visible)
    try { [Console]::CursorVisible = $Visible } catch {}
}

function Fit-Text {
    param([string]$Text, [int]$Len)
    if ($null -eq $Text) { $Text = '' }
    if ($Text.Length -gt $Len) {
        if ($Len -gt 3) { return $Text.Substring(0, $Len - 3) + '...' }
        return $Text.Substring(0, $Len)
    }
    return $Text.PadRight($Len)
}

function Write-Seg {
    param([string]$Text, [ConsoleColor]$Fg = 'Gray', $Bg = $null)
    if ($null -ne $Bg) {
        Write-Host -NoNewline $Text -ForegroundColor $Fg -BackgroundColor ([ConsoleColor]$Bg)
    } else {
        Write-Host -NoNewline $Text -ForegroundColor $Fg
    }
}

# --- Atari-style art: every 'X' is one square pixel (two full blocks) ---

$Font = @{
    'N' = @('X..X', 'XX.X', 'X.XX', 'X..X', 'X..X')
    'V' = @('X..X', 'X..X', 'X..X', 'X..X', '.XX.')
    'I' = @('XXX',  '.X.',  '.X.',  '.X.',  'XXX')
    'D' = @('XXX.', 'X..X', 'X..X', 'X..X', 'XXX.')
    'A' = @('.XX.', 'X..X', 'XXXX', 'X..X', 'X..X')
    'G' = @('.XXX', 'X...', 'X.XX', 'X..X', '.XXX')
}

$Sprites = @{
    'Idle'  = @('.X...X.', 'XXXXXXX', 'XX.X.XX', 'XXXXXXX', 'X.X.X.X')
    'Blink' = @('.X...X.', 'XXXXXXX', 'XXXXXXX', 'XXXXXXX', 'X.X.X.X')
    'Happy' = @('X.....X', '.XXXXX.', 'XX.X.XX', 'XXXXXXX', '.X...X.')
    'Warn'  = @('.X...X.', 'XXXXXXX', 'XX.X.XX', 'XXXXXXX', '..X.X..')
    'Alert' = @('X.....X', 'XXXXXXX', 'X..X..X', 'XXXXXXX', 'X.X.X.X')
}

function ConvertTo-Pixels {
    param([string]$Pattern)
    return ($Pattern.Replace('X', "$PX$PX").Replace('.', '  '))
}

function Get-LogoRows {
    $rows = @('', '', '', '', '')
    $first = $true
    foreach ($ch in 'NVIDIAG'.ToCharArray()) {
        $glyph = $Font[[string]$ch]
        for ($r = 0; $r -lt 5; $r++) {
            if (-not $first) { $rows[$r] += '  ' }
            $rows[$r] += ConvertTo-Pixels $glyph[$r]
        }
        $first = $false
    }
    return $rows
}

function Draw-Stripe {
    param([string]$Glyph = $PXDN)
    $seg = [math]::Ceiling($Width / $Rainbow.Count)
    $done = 0
    foreach ($c in $Rainbow) {
        $n = [math]::Min($seg, $Width - $done)
        if ($n -le 0) { break }
        Write-Seg ($Glyph * $n) $c
        $done += $n
    }
    Write-Host ''
}

function Draw-Rule {
    param([ConsoleColor]$Color = 'DarkBlue')
    Write-Host ($PXUP * $Width) -ForegroundColor $Color
}

function Draw-Bar {
    param([string]$Text, [ConsoleColor]$Bg = 'Blue', [ConsoleColor]$Fg = 'White')
    $t = Fit-Text -Text ('  ' + $Text) -Len $Width
    Write-Seg $t $Fg $Bg
    Write-Host ''
}

function Draw-Logo {
    $rowColors = @('Yellow', 'Yellow', 'DarkYellow', 'Red', 'Red')
    $logo = Get-LogoRows
    $pad = ' ' * [math]::Max(0, [math]::Floor(($Width - $logo[0].Length) / 2))
    for ($r = 0; $r -lt 5; $r++) {
        Write-Host ($pad + $logo[$r]) -ForegroundColor $rowColors[$r]
    }
}

function Draw-Banner {
    param([bool]$Compact = $false)
    Draw-Stripe -Glyph $PXDN
    if (-not $Compact) {
        Write-Host ''
        Draw-Logo
        Write-Host ''
        $tag = 'NVIDIA DRIVER SSD WRITE BUG  //  DIAGNOSE  FIX  REVERT  //  v' + $AppVersion
        $pad = ' ' * [math]::Max(0, [math]::Floor(($Width - $tag.Length) / 2))
        Write-Host ($pad + $tag) -ForegroundColor Cyan
        Write-Host ''
    } else {
        $left  = " $AppName v$AppVersion "
        $right = ' NVDisplay.Container SSD write bug '
        Write-Seg $left Black Yellow
        Write-Seg (' ' * ($Width - $left.Length - $right.Length)) Gray
        Write-Seg $right Black Cyan
        Write-Host ''
    }
    Draw-Stripe -Glyph $PXUP
}

function Draw-Header {
    param([string]$Num, [string]$Title, [ConsoleColor]$Color = 'Cyan')
    Write-Host ''
    Write-Seg '  '
    Write-Seg " $Num " Black $Color
    Write-Seg " $Title" $Color
    Write-Host ''
}

function Draw-Text {
    param([string]$Text = '', [ConsoleColor]$Color = 'Gray')
    Write-Host ('  ' + (Fit-Text -Text $Text -Len ($Width - 2))) -ForegroundColor $Color
}

function Draw-Check {
    param(
        [string]$Label,
        [string]$Value,
        [ValidateSet('OK', 'WARN', 'FAIL', 'INFO')]
        [string]$Status = 'INFO'
    )
    $bg = switch ($Status) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'DarkCyan' } }
    $badge = switch ($Status) { 'OK' { '  OK  ' } 'WARN' { ' WARN ' } 'FAIL' { ' FAIL ' } default { ' INFO ' } }
    $valWidth = $Width - 2 - 18 - 1 - 6
    Write-Seg '  '
    Write-Seg (Fit-Text -Text $Label -Len 18) White
    Write-Seg (Fit-Text -Text $Value -Len $valWidth) Gray
    Write-Seg ' '
    Write-Seg $badge Black $bg
    Write-Host ''
}

function Draw-Sprite {
    param(
        [ValidateSet('Idle', 'Blink', 'Happy', 'Warn', 'Alert')]
        [string]$Mood = 'Idle',
        [ConsoleColor]$SpriteColor = 'Cyan',
        [string[]]$Lines = @(),
        [ConsoleColor]$TitleColor = 'White',
        [ConsoleColor]$BodyColor = 'Gray'
    )
    $art = $Sprites[$Mood]
    $textWidth = $Width - 2 - 14 - 3
    for ($i = 0; $i -lt 5; $i++) {
        $text = if ($i -lt $Lines.Count) { $Lines[$i] } else { '' }
        $col  = if ($i -eq 0) { $TitleColor } else { $BodyColor }
        Write-Seg '  '
        Write-Seg (ConvertTo-Pixels $art[$i]) $SpriteColor
        Write-Seg '   '
        Write-Seg (Fit-Text -Text $text -Len $textWidth) $col
        Write-Host ''
    }
}

function Draw-MenuItem {
    param([string]$Key, [string]$Label, [string]$Desc, [ConsoleColor]$Color)
    Write-Seg '  '
    Write-Seg " $Key " Black $Color
    Write-Seg (' ' + (Fit-Text -Text $Label -Len 12)) $Color
    Write-Seg (Fit-Text -Text $Desc -Len ($Width - 2 - 3 - 13)) Gray
    Write-Host ''
}

function Show-BootScreen {
    Set-CursorVisible -Visible $false
    try {
        Clear-Host
        Draw-Banner -Compact $false
        Write-Host ''
        Draw-Sprite -Mood 'Idle' -SpriteColor Cyan -TitleColor Yellow -BodyColor Gray -Lines @(
            'PLAYER 1 READY',
            "Target:  $ProcessName (Display Container LS)",
            'Plugin:  _nvtopps.dll -> nvlog.nvlgstg log rewrites',
            'Checks:  driver, service, registry, log file, live writes',
            "Engine:  PowerShell $($PSVersionTable.PSVersion)"
        )
        Write-Host ''
        foreach ($step in @('Reading GPU and driver', 'Reading service state', 'Reading registry', 'Arming write monitor')) {
            Write-Seg ('  ' + $PX + $PX + ' ' + $step.PadRight(40, '.')) DarkCyan
            Start-Sleep -Milliseconds 120
            Write-Seg ' READY ' Black Green
            Write-Host ''
        }
        Start-Sleep -Milliseconds 400
    }
    finally {
        Set-CursorVisible -Visible $true
    }
}

# --- System probes ---

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$id
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-NvidiaVersion {
    # Windows reports e.g. 32.0.16.2124 -> NVIDIA marketing version 621.24
    param([string]$RawVersion)
    if ([string]::IsNullOrWhiteSpace($RawVersion)) { return 'Unknown' }
    $parts = $RawVersion.Split('.')
    if ($parts.Count -eq 4 -and $parts[2].Length -ge 1 -and $parts[3].Length -le 4) {
        $combined = $parts[2].Substring($parts[2].Length - 1) + $parts[3].PadLeft(4, '0')
        return "$($combined.Substring(0, 3)).$($combined.Substring(3, 2))"
    }
    return $RawVersion
}

function Get-NvProcess {
    return @(Get-CimInstance Win32_Process -Filter "Name='$ProcessName'" -ErrorAction SilentlyContinue)
}

function Get-DisableLoadValue {
    if (-not (Test-Path -LiteralPath $RegPath)) { return $null }
    $prop = Get-ItemProperty -LiteralPath $RegPath -Name DisableLoad -ErrorAction SilentlyContinue
    if ($null -eq $prop) { return $null }
    return $prop.DisableLoad
}

function Get-NvLogInfo {
    $info = [PSCustomObject]@{ Exists = $false; SizeMB = 0.0; AgeSec = -1; PluginSkipped = $false }
    try {
        if (Test-Path -LiteralPath $NvLogFile) {
            $f = Get-Item -LiteralPath $NvLogFile -Force
            $info.Exists = $true
            $info.SizeMB = [math]::Round($f.Length / 1MB, 1)
            $info.AgeSec = [math]::Max(0, [int]((Get-Date) - $f.LastWriteTime).TotalSeconds)
        }
    } catch {}
    try {
        if (Test-Path -LiteralPath $ServiceLogFile) {
            $hit = Get-Content -LiteralPath $ServiceLogFile -Tail 4000 -ErrorAction SilentlyContinue |
                Select-String -Pattern 'Disable loading of plugin.*_nvtopps' -SimpleMatch:$false |
                Select-Object -Last 1
            $info.PluginSkipped = ($null -ne $hit)
        }
    } catch {}
    return $info
}

function Get-SystemReport {
    $os  = Get-CimInstance Win32_OperatingSystem
    $gpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -like '*NVIDIA*' } | Select-Object -First 1
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    $prc = Get-NvProcess

    $rawVer = 'N/A'; $shortVer = 'N/A'; $driverDate = 'N/A'; $reported = $false
    if ($gpu) {
        $rawVer   = $gpu.DriverVersion
        $shortVer = ConvertTo-NvidiaVersion -RawVersion $rawVer
        $reported = $ReportedDrivers -contains $shortVer
        if ($gpu.DriverDate) { $driverDate = ([datetime]$gpu.DriverDate).ToString('yyyy-MM-dd') }
    }
    $disableLoad = Get-DisableLoadValue

    return [PSCustomObject]@{
        OSName        = ($os.Caption -replace 'Microsoft ', '').Trim()
        OSBuild       = $os.BuildNumber
        PSVersion     = $PSVersionTable.PSVersion.ToString()
        IsAdmin       = Test-IsAdmin
        HasNvidia     = ($null -ne $gpu)
        GpuName       = if ($gpu) { $gpu.Name } else { 'Not detected' }
        DriverRaw     = $rawVer
        DriverShort   = $shortVer
        DriverDate    = $driverDate
        IsReported    = $reported
        ServiceExists = ($null -ne $svc)
        ServiceStatus = if ($svc) { $svc.Status.ToString() } else { 'Missing' }
        ServiceStart  = if ($svc) { $svc.StartType.ToString() } else { 'N/A' }
        ProcessCount  = $prc.Count
        DisableLoad   = $disableLoad
        WorkaroundOn  = ($disableLoad -eq 1)
        NvLog         = Get-NvLogInfo
    }
}

# --- Live write monitor (logical per-process write I/O) ---

function Invoke-WriteScan {
    param([int]$DurationSeconds)

    $before = Get-NvProcess
    if ($before.Count -eq 0) {
        Draw-Check -Label 'Write monitor' -Value "No $ProcessName process running" -Status 'FAIL'
        return $null
    }

    $startMap = @{}   # PID -> WriteTransferCount at start (or 0 for new PIDs)
    $lastMap  = @{}   # PID -> last seen WriteTransferCount (keeps PIDs that exit)
    $isNew    = @{}
    foreach ($p in $before) {
        $startMap[[int]$p.ProcessId] = [double]$p.WriteTransferCount
        $lastMap[[int]$p.ProcessId]  = [double]$p.WriteTransferCount
        $isNew[[int]$p.ProcessId]    = $false
    }

    $barWidth  = 30
    $track     = 10
    $liveMB    = 0.0
    $liveRate  = 0.0
    $frame     = 0
    $lastPoll  = -10.0

    Draw-Text ("Sampling $ProcessName write I/O for {0} s. Keep the PC idle." -f $DurationSeconds) Cyan
    Write-Host ''
    Set-CursorVisible -Visible $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        while ($true) {
            $elapsed = $sw.Elapsed.TotalSeconds
            $ratio   = [math]::Min($elapsed, $DurationSeconds) / $DurationSeconds
            $pct     = [int][math]::Floor($ratio * 100)
            $filled  = [int][math]::Floor($ratio * $barWidth)
            $remain  = [int][math]::Ceiling([math]::Max(0, $DurationSeconds - $elapsed))

            if (($elapsed - $lastPoll) -ge 2.0 -or $elapsed -ge $DurationSeconds) {
                foreach ($p in (Get-NvProcess)) {
                    $id = [int]$p.ProcessId
                    if (-not $startMap.ContainsKey($id)) { $startMap[$id] = 0.0; $isNew[$id] = $true }
                    $lastMap[$id] = [double]$p.WriteTransferCount
                }
                $sum = 0.0
                foreach ($id in $lastMap.Keys) { $sum += [math]::Max(0.0, $lastMap[$id] - $startMap[$id]) }
                $liveMB = $sum / 1MB
                if ($elapsed -ge 2.0) { $liveRate = ($liveMB / $elapsed) * 3600.0 }
                $lastPoll = $elapsed
            }

            $barColor = if ($liveRate -ge $BugMBh) { 'Red' } elseif ($liveRate -ge $WarnMBh) { 'Yellow' } else { 'Green' }
            $pos = $frame % (2 * ($track - 1))
            if ($pos -ge $track) { $pos = 2 * ($track - 1) - $pos }
            $court = (' ' * $pos) + $PX + (' ' * ($track - 1 - $pos))
            $stats = Fit-Text -Text (' {0,3}%  {1,4}s  {2,10:N1} MB' -f $pct, $remain, $liveMB) -Len ($Width - 2 - 12 - 1 - $barWidth)

            Write-Seg "`r  "
            Write-Seg $PX Magenta
            Write-Seg $court White
            Write-Seg $PX Magenta
            Write-Seg ' '
            Write-Seg ($PX * $filled) $barColor
            Write-Seg ($PX * ($barWidth - $filled)) DarkGray
            Write-Seg $stats Yellow

            if ($elapsed -ge $DurationSeconds) { break }
            $frame++
            Start-Sleep -Milliseconds 150
        }
    }
    finally {
        $sw.Stop()
        Write-Host ''
        Set-CursorVisible -Visible $true
    }

    $actual = [math]::Max(0.1, $sw.Elapsed.TotalSeconds)
    $rows = @()
    foreach ($id in ($lastMap.Keys | Sort-Object)) {
        $deltaMB = [math]::Max(0.0, $lastMap[$id] - $startMap[$id]) / 1MB
        $rows += [PSCustomObject]@{
            PID       = $id
            TotalMB   = [math]::Round($lastMap[$id] / 1MB, 1)
            DeltaMB   = [math]::Round($deltaMB, 2)
            MBPerHour = [math]::Round(($deltaMB / $actual) * 3600.0, 1)
            Note      = if ($isNew[$id]) { 'NEW PID' } else { '' }
        }
    }
    return [PSCustomObject]@{ Rows = $rows; ActualSeconds = [math]::Round($actual, 1) }
}

# --- Workaround: _nvtopps DisableLoad = 1 ---

function Wait-NvidiaProcessReady {
    param([int]$TimeoutSeconds = 15)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if ((Get-NvProcess).Count -gt 0) { Start-Sleep -Milliseconds 1500; return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Write-Step {
    param([string]$Text, [ConsoleColor]$Color = 'Cyan')
    Write-Seg ('  ' + $PX + $PX + ' ') $Color
    Write-Host $Text -ForegroundColor $Color
}

function Set-NvidiaWorkaround {
    param([bool]$Enable)

    Write-Host ''
    if (-not (Test-IsAdmin)) {
        Write-Step 'Administrator rights are required. Nothing was changed.' Red
        return $false
    }

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Step "Service $ServiceName not found. Nothing was changed." Red
        return $false
    }

    try {
        if ($Enable) {
            if (-not (Test-Path -LiteralPath $RegPath)) {
                Write-Step 'Creating registry key ...\LocalSystem\_nvtopps'
                # Only create when missing: New-Item -Force on an existing key recreates it and wipes its values
                New-Item -Path $RegPath -Force | Out-Null
            }
            Write-Step 'Writing DisableLoad = 1 (REG_DWORD)'
            New-ItemProperty -LiteralPath $RegPath -Name DisableLoad -PropertyType DWord -Value 1 -Force | Out-Null
            if ((Get-DisableLoadValue) -ne 1) { throw 'Read-back failed: DisableLoad is not 1.' }
        } else {
            if ($null -ne (Get-DisableLoadValue)) {
                Write-Step 'Removing DisableLoad from _nvtopps' Yellow
                Remove-ItemProperty -LiteralPath $RegPath -Name DisableLoad
            } else {
                Write-Step 'DisableLoad is not set (already default).' Gray
            }
            if (Test-Path -LiteralPath $RegPath) {
                $key = Get-Item -LiteralPath $RegPath
                if ($key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0) {
                    Write-Step 'Removing the now empty _nvtopps key' Yellow
                    Remove-Item -LiteralPath $RegPath
                }
            }
            if ($null -ne (Get-DisableLoadValue)) { throw 'Read-back failed: DisableLoad is still present.' }
        }

        if ($svc.StartType.ToString() -eq 'Disabled') {
            Write-Step "Registry updated, but $ServiceName is Disabled, so it was not restarted." Yellow
            return $false
        }

        Write-Step "Restarting $ServiceName (the screen may flicker)" Yellow
        Restart-Service -Name $ServiceName -Force

        Write-Step "Waiting for $ProcessName to come back" DarkGray
        if (Wait-NvidiaProcessReady -TimeoutSeconds 15) {
            Write-Step 'Service and process are back online.' Green
            return $true
        }
        Write-Step 'Service restarted, but the process did not reappear within 15 s.' Yellow
        return $false
    }
    catch {
        Write-Step "ERROR: $($_.Exception.Message)" Red
        return $false
    }
}

# --- Full diagnostic ---

function Invoke-Diagnostic {
    param([int]$TestDuration)

    Clear-Host
    Draw-Banner -Compact $true
    $r = Get-SystemReport

    Draw-Header '01' 'SYSTEM' Cyan
    Draw-Check 'Windows'    "$($r.OSName) (build $($r.OSBuild))" 'INFO'
    Draw-Check 'PowerShell' "v$($r.PSVersion)" 'INFO'
    Draw-Check 'Rights' $(if ($r.IsAdmin) { 'Administrator' } else { 'Standard user (read-only)' }) $(if ($r.IsAdmin) { 'OK' } else { 'WARN' })

    Draw-Header '02' 'NVIDIA GPU AND DRIVER' Green
    if (-not $r.HasNvidia) {
        Draw-Check 'GPU' 'No NVIDIA GPU detected' 'FAIL'
        Write-Host ''
        Draw-Bar 'NO NVIDIA GPU  -  NOTHING TO DO' DarkRed White
        Write-Host ''
        Draw-Sprite -Mood 'Warn' -SpriteColor Yellow -TitleColor Yellow -Lines @(
            'No NVIDIA display adapter was found.',
            'Nvidiag only targets the NVIDIA Display Container service.',
            'No changes were made to this PC.'
        )
        return [PSCustomObject]@{ CanContinue = $false; Report = $r; TotalPerHour = 0 }
    }
    Draw-Check 'GPU' $r.GpuName 'OK'
    if ($r.IsReported) {
        Draw-Check 'Driver' "$($r.DriverShort) ($($r.DriverDate)) reported affected" 'WARN'
    } elseif ($r.DriverShort -eq $CleanDriver) {
        Draw-Check 'Driver' "$($r.DriverShort) ($($r.DriverDate)) reported clean" 'OK'
    } else {
        Draw-Check 'Driver' "$($r.DriverShort) ($($r.DriverDate), $($r.DriverRaw))" 'INFO'
    }

    Draw-Header '03' 'DISPLAY CONTAINER SERVICE' Yellow
    Draw-Check 'Service' "NVIDIA Display Container LS: $($r.ServiceStatus), $($r.ServiceStart)" $(if ($r.ServiceStatus -eq 'Running') { 'OK' } else { 'WARN' })
    Draw-Check 'Processes' "$ProcessName x $($r.ProcessCount)" $(if ($r.ProcessCount -gt 0) { 'OK' } else { 'FAIL' })

    Draw-Header '04' 'WORKAROUND AND LOG FILE' Magenta
    if ($r.WorkaroundOn) {
        Draw-Check 'Workaround' '_nvtopps DisableLoad = 1 (plugin off)' 'OK'
    } elseif ($null -ne $r.DisableLoad) {
        Draw-Check 'Workaround' "_nvtopps DisableLoad = $($r.DisableLoad) (plugin on)" 'WARN'
    } else {
        Draw-Check 'Workaround' 'Not set (driver default, plugin on)' 'INFO'
    }
    if ($r.NvLog.Exists) {
        $fresh = ($r.NvLog.AgeSec -ge 0 -and $r.NvLog.AgeSec -le 60)
        Draw-Check 'nvlog.nvlgstg' ("{0} MB, last written {1} s ago" -f $r.NvLog.SizeMB, $r.NvLog.AgeSec) $(if ($fresh) { 'WARN' } else { 'INFO' })
    } else {
        Draw-Check 'nvlog.nvlgstg' 'Not present' 'OK'
    }
    if ($r.WorkaroundOn) {
        Draw-Check 'Service log' $(if ($r.NvLog.PluginSkipped) { '"Disable loading of plugin _nvtopps" found' } else { 'Skip message not found yet' }) $(if ($r.NvLog.PluginSkipped) { 'OK' } else { 'INFO' })
    }

    Draw-Header '05' 'LIVE WRITE SCAN' Red
    $test = Invoke-WriteScan -DurationSeconds $TestDuration

    $totalPerHour = 0.0
    if ($test -and $test.Rows.Count -gt 0) {
        Write-Host ''
        Draw-Text ('{0,-8} {1,14} {2,14} {3,16}  {4}' -f 'PID', 'TOTAL MB', 'SCAN MB', 'RATE MB/h', 'NOTE') White
        foreach ($row in $test.Rows) {
            $col = if ($row.MBPerHour -ge $BugMBh) { 'Red' } elseif ($row.MBPerHour -ge $WarnMBh) { 'Yellow' } else { 'Green' }
            Draw-Text ('{0,-8} {1,14:N1} {2,14:N2} {3,16:N1}  {4}' -f $row.PID, $row.TotalMB, $row.DeltaMB, $row.MBPerHour, $row.Note) $col
            $totalPerHour += $row.MBPerHour
        }
        Draw-Text ("Window {0} s. Logical write I/O (WriteTransferCount), not NAND writes." -f $test.ActualSeconds) DarkGray
    }

    $gbPerDay = ($totalPerHour * 24.0) / 1024.0
    Write-Host ''

    if ($r.ProcessCount -eq 0 -or $null -eq $test) {
        Draw-Bar 'CANNOT MEASURE  -  PROCESS NOT RUNNING' DarkYellow Black
        Write-Host ''
        Draw-Sprite -Mood 'Warn' -SpriteColor Yellow -TitleColor Yellow -Lines @(
            "$ProcessName is not running.",
            'Check "NVIDIA Display Container LS" in services.msc.',
            'Nothing to measure, no changes were made.'
        )
    }
    elseif ($totalPerHour -ge $BugMBh -and -not $r.WorkaroundOn) {
        Draw-Bar ("BUG DETECTED  -  ~{0:N0} MB/h  -  ~{1:N1} GB/day" -f $totalPerHour, $gbPerDay) Red White
        Write-Host ''
        Draw-Sprite -Mood 'Alert' -SpriteColor Red -TitleColor Red -BodyColor Yellow -Lines @(
            'NVDisplay.Container.exe is writing far above normal.',
            'This matches the _nvtopps / nvlog.nvlgstg write bug.',
            'Press [1] to disable the _nvtopps plugin (reversible),',
            'or roll back to driver 621.01 (reported clean).'
        )
    }
    elseif ($totalPerHour -ge $BugMBh -and $r.WorkaroundOn) {
        Draw-Bar ("STILL HIGH WITH WORKAROUND  -  ~{0:N0} MB/h" -f $totalPerHour) Red White
        Write-Host ''
        Draw-Sprite -Mood 'Alert' -SpriteColor Red -TitleColor Red -BodyColor Yellow -Lines @(
            'DisableLoad = 1 is set, but writes are still high.',
            'Press [1] again to restart the service and reload it.',
            'If it persists, find the file with Resource Monitor',
            '(resmon, Disk tab) or Sysinternals Process Monitor.'
        )
    }
    elseif ($totalPerHour -ge $WarnMBh) {
        Draw-Bar ("ELEVATED WRITES  -  ~{0:N1} MB/h" -f $totalPerHour) Yellow Black
        Write-Host ''
        Draw-Sprite -Mood 'Warn' -SpriteColor Yellow -TitleColor Yellow -Lines @(
            'Above a clean baseline, below the typical bug rate.',
            'The bug grows with uptime. Run a longer scan with [4]',
            '(for example 300 s) or apply the workaround with [1].'
        )
    }
    elseif ($r.WorkaroundOn) {
        Draw-Bar ("ALL CLEAR  -  ~{0:N1} MB/h  -  WORKAROUND ACTIVE" -f $totalPerHour) Green Black
        Write-Host ''
        Draw-Sprite -Mood 'Happy' -SpriteColor Green -TitleColor Green -Lines @(
            'The _nvtopps plugin is off and writes are normal.',
            'A driver update or reinstall may reset this setting.',
            'Re-run Nvidiag after every NVIDIA driver update.',
            $(if ($r.IsReported) { 'Keep the workaround while on this driver.' } else { 'On a fixed driver you can test [2] Revert.' })
        )
    }
    else {
        Draw-Bar ("ALL CLEAR  -  ~{0:N1} MB/h  -  DRIVER DEFAULT" -f $totalPerHour) Green Black
        Write-Host ''
        Draw-Sprite -Mood 'Happy' -SpriteColor Green -TitleColor Green -Lines @(
            'No abnormal write activity right now.',
            'The bug grows with uptime: if this PC was just booted,',
            'scan again later or use a longer scan with [4].',
            'No workaround is needed at this moment.'
        )
    }

    Write-Host ''
    Draw-Stripe -Glyph $PXUP
    return [PSCustomObject]@{ CanContinue = $true; Report = $r; TotalPerHour = $totalPerHour }
}

function Show-Menu {
    Write-Host ''
    Draw-MenuItem '1' 'APPLY FIX'   'Disable _nvtopps, restart service, 30 s verify' Green
    Draw-MenuItem '2' 'REVERT'      'Remove DisableLoad, restart service, 30 s verify' Yellow
    Draw-MenuItem '3' 'RESCAN'      "Run the full diagnostic again ($Seconds s)" Cyan
    Draw-MenuItem '4' 'CUSTOM SCAN' 'Pick a scan length (5-3600 s)' Blue
    Draw-MenuItem 'Q' 'QUIT'        "Exit $AppName" Magenta
    Write-Host ''
}

# --- Main loop ---

try {
    Show-BootScreen
    $state = Invoke-Diagnostic -TestDuration $Seconds

    if (-not $state.CanContinue) {
        Write-Host ''
        Read-Host '  Press Enter to exit' | Out-Null
        exit 0
    }

    $running = $true
    while ($running) {
        Show-Menu
        $choice = ([string](Read-Host '  SELECT [1/2/3/4/Q]')).Trim().ToUpper()
        switch ($choice) {
            '1' {
                if (Set-NvidiaWorkaround -Enable $true) {
                    Write-Step 'Running a 30 s verification scan...' Cyan
                    Start-Sleep -Seconds 1
                    $state = Invoke-Diagnostic -TestDuration 30
                }
            }
            '2' {
                if (Set-NvidiaWorkaround -Enable $false) {
                    Write-Step 'Running a 30 s verification scan...' Yellow
                    Start-Sleep -Seconds 1
                    $state = Invoke-Diagnostic -TestDuration 30
                }
            }
            '3' { $state = Invoke-Diagnostic -TestDuration $Seconds }
            '4' {
                $raw = [string](Read-Host '  Scan length in seconds (5-3600)')
                $sec = 0
                if ([int]::TryParse($raw.Trim(), [ref]$sec) -and $sec -ge 5 -and $sec -le 3600) {
                    $state = Invoke-Diagnostic -TestDuration $sec
                } else {
                    Write-Step 'Please enter a number from 5 to 3600.' Red
                }
            }
            'Q' {
                Write-Step "GAME OVER. Thanks for playing $AppName." Magenta
                $running = $false
            }
            default { Write-Step 'Unknown choice.' Red }
        }
    }
}
catch {
    Set-CursorVisible -Visible $true
    Write-Host ''
    Write-Host "  [FATAL ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkRed
    Write-Host ''
    Read-Host '  Press Enter to exit' | Out-Null
    exit 0
}
