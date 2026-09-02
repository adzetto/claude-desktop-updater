<#
.SYNOPSIS
    Repairs and updates Claude Desktop on Windows when the built-in updater
    and the official bootstrapper ("Claude Setup.exe") keep failing.

.DESCRIPTION
    Claude Desktop ships as an MSIX package that contains a packaged Windows
    service (CoworkVMService). On many machines the official installer cannot
    replace a previous version: the stale service cannot be removed ("Access
    is denied"), data-preserving removal is rejected with 0x80073CFA, the
    in-place AddPackage fails with 0x80073CFF, and the user is told to wipe
    the app and reinstall from scratch after every release.

    This tool performs the full repair in two phases:

      user phase      resolve the latest release for the machine architecture,
                      download the MSIX with BITS (resumable, live progress),
                      verify the Authenticode signature, hand off to the
                      elevated phase (one UAC prompt).
      elevated phase  stop only real Claude Desktop processes (Claude Code CLI
                      is never touched), remove the stale CoworkVMService by
                      taking ownership of its registry key, fix sideloading
                      policy (including Group Policy / MDM overrides that
                      silently block AppX deployment), remove stale package
                      registrations, install the package with a live progress
                      bar, verify, and launch.

    User data (sessions, settings) is preserved unless -PurgeUserData is given.

.PARAMETER Force
    Reinstall even if the installed version already matches the latest release.
.PARAMETER CleanOnly
    Run the cleanup steps only; do not download or install.
.PARAMETER PurgeUserData
    Also delete %LOCALAPPDATA%\Claude and the package data folder.
.PARAMETER NoLaunch
    Do not start Claude Desktop (or open the download page) at the end.
.PARAMETER NoColor
    Disable ANSI colours and animations (plain log output).

.NOTES
    Exit codes: 0 success, 1 install failed, 2 download/resolve failed,
                3 elevation refused, 4 policy blocked by management,
                5 reboot required to finish removing the stale service.
    Log:        %ProgramData%\claude-desktop-updater\updater.log
    Project:    https://github.com/adzetto/claude-desktop-updater
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$CleanOnly,
    [switch]$PurgeUserData,
    [switch]$NoLaunch,
    [switch]$NoColor,
    # internal: marks the elevated child process
    [switch]$ElevatedPhase
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Script:Version   = '3.0.0'
$Script:UserAgent = "claude-desktop-updater/$Script:Version"

$ExitOk            = 0
$ExitInstallFailed = 1
$ExitDownloadFail  = 2
$ExitNeedsAdmin    = 3
$ExitPolicyBlocked = 4
$ExitRebootNeeded  = 5

# --------------------------------------------------------------------------
# Working directory, log files, hand-off path
# --------------------------------------------------------------------------
$Script:WorkDir = Join-Path $env:ProgramData 'claude-desktop-updater'
if (-not (Test-Path $Script:WorkDir)) { New-Item -ItemType Directory -Path $Script:WorkDir -Force | Out-Null }
# The elevated child writes to its own file; two processes appending to one
# file caused lock collisions and silently dropped lines.
$Script:LogPath     = Join-Path $Script:WorkDir $(if ($ElevatedPhase) { 'updater.elevated.log' } else { 'updater.log' })
# Fixed hand-off location so no path has to survive command-line quoting.
$Script:PendingMsix = Join-Path $Script:WorkDir 'pending.msix'

# ==========================================================================
# Console layer: VT enable, 24-bit colour, box drawing, progress, spinner
# ==========================================================================
$Script:VT = $false
if (-not $NoColor) {
    try {
        if (-not ('ConsoleVT' -as [type])) {
            Add-Type -Namespace '' -Name 'ConsoleVT' -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetConsoleMode(IntPtr h, out uint mode);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleMode(IntPtr h, uint mode);
'@ -ErrorAction Stop
        }
        $h = [ConsoleVT]::GetStdHandle(-11); $m = 0
        if ([ConsoleVT]::GetConsoleMode($h, [ref]$m)) { $Script:VT = [ConsoleVT]::SetConsoleMode($h, $m -bor 0x0004) }
    } catch { $Script:VT = $false }
}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$Script:Unicode = $false
try { $Script:Unicode = ([Console]::OutputEncoding.CodePage -eq 65001) } catch {}

$E = [char]27
function Esc([string]$code) { if ($Script:VT) { "$E[$code" } else { '' } }
function Rgb([int]$r, [int]$g, [int]$b) { Esc "38;2;$r;$g;${b}m" }
$Script:C = @{
    Reset = Esc '0m'; Bold = Esc '1m'; Dim = Esc '2m'
    Red = Rgb 255 95 95; Green = Rgb 80 220 120; Yellow = Rgb 255 200 70
    Cyan = Rgb 60 200 235; Blue = Rgb 110 130 255; Grey = Rgb 130 140 150
    White = Rgb 235 240 245; Violet = Rgb 150 110 255; Amber = Rgb 245 166 35
}
$Script:G = if ($Script:Unicode) {
    @{ Full = [string][char]0x2588; Empty = [string][char]0x2591; Ok = [string][char]0x2714
       Fail = [string][char]0x2716; Warn = [string][char]0x25B2; Arrow = [string][char]0x276F
       TL = [char]0x256D; TR = [char]0x256E; BL = [char]0x2570; BR = [char]0x256F; H = [char]0x2500; V = [char]0x2502 }
} else {
    @{ Full = '#'; Empty = '-'; Ok = 'OK'; Fail = '!!'; Warn = '!'; Arrow = '>'
       TL = '+'; TR = '+'; BL = '+'; BR = '+'; H = '-'; V = '|' }
}
$Script:Spinner = if ($Script:Unicode) {
    @(0x280B,0x2819,0x2839,0x2838,0x283C,0x2834,0x2826,0x2827,0x2807,0x280F) | ForEach-Object { [string][char]$_ }
} else { @('|','/','-','\') }
$Script:SpinIdx  = 0
$Script:LineOpen = $false
$Script:Step     = 0
$Script:Steps    = 7

function Get-Width { try { $w = [Console]::WindowWidth; if ($w -gt 40) { return $w } } catch {}; 100 }
function Strip([string]$s) { $s -replace "$E\[[0-9;]*m", '' }

function Close-Line {
    if ($Script:LineOpen) { Write-Host ("`r" + (' ' * ((Get-Width) - 1)) + "`r") -NoNewline; $Script:LineOpen = $false }
}

# Gradient text: interpolates between two RGB triplets across the string.
function Gradient([string]$text, [int[]]$from, [int[]]$to) {
    if (-not $Script:VT) { return $text }
    $n = [Math]::Max(1, $text.Length - 1); $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $text.Length; $i++) {
        $t = $i / $n
        $r = [int]($from[0] + ($to[0] - $from[0]) * $t)
        $g = [int]($from[1] + ($to[1] - $from[1]) * $t)
        $b = [int]($from[2] + ($to[2] - $from[2]) * $t)
        [void]$sb.Append((Rgb $r $g $b)).Append($text[$i])
    }
    [void]$sb.Append($Script:C.Reset); $sb.ToString()
}

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK','STEP','DETAIL')][string]$Level = 'INFO', [switch]$NoConsole)
    $line = "{0}  [{1,-5}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    for ($i = 0; $i -lt 5; $i++) {
        try { [System.IO.File]::AppendAllText($Script:LogPath, $line + [Environment]::NewLine); break } catch { Start-Sleep -Milliseconds 40 }
    }
    if ($NoConsole) { return }
    Close-Line
    $c = $Script:C; $g = $Script:G
    $clock = "$($c.Grey)$(Get-Date -Format 'HH:mm:ss')$($c.Reset)"
    switch ($Level) {
        'STEP'   { $Script:Step++
                   $tag = "$($c.Violet)[$($Script:Step)/$($Script:Steps)]$($c.Reset)"
                   Write-Host ""; Write-Host "  $clock $tag $($c.Bold)$($c.White)$Message$($c.Reset)" }
        'OK'     { Write-Host "  $clock   $($c.Green)$($g.Ok)$($c.Reset)  $Message" }
        'WARN'   { Write-Host "  $clock   $($c.Yellow)$($g.Warn)$($c.Reset)  $($c.Yellow)$Message$($c.Reset)" }
        'ERROR'  { Write-Host "  $clock   $($c.Red)$($g.Fail)$($c.Reset)  $($c.Red)$Message$($c.Reset)" }
        'DETAIL' { Write-Host "  $clock      $($c.Grey)$Message$($c.Reset)" }
        default  { Write-Host "  $clock   $($c.Grey)$($g.Arrow)$($c.Reset)  $Message" }
    }
}

function Write-Banner {
    $c = $Script:C; $g = $Script:G
    $title = "CLAUDE DESKTOP UPDATER"
    $sub   = "MSIX repair and update tool for Windows"
    $meta  = "v$Script:Version   github.com/adzetto/claude-desktop-updater"
    $inner = [Math]::Max($title.Length, [Math]::Max($sub.Length, $meta.Length)) + 6
    $inner = [Math]::Min($inner, (Get-Width) - 4)
    $bar   = [string]$g.H * $inner
    $pad = { param($s) $s + (' ' * [Math]::Max(0, $inner - (Strip $s).Length)) }
    Write-Host ""
    Write-Host "  $($c.Violet)$($g.TL)$bar$($g.TR)$($c.Reset)"
    Write-Host "  $($c.Violet)$($g.V)$($c.Reset)$(& $pad ("   " + (Gradient $title @(150,110,255) @(245,166,35))))$($c.Violet)$($g.V)$($c.Reset)"
    Write-Host "  $($c.Violet)$($g.V)$($c.Reset)$(& $pad ("   $($c.White)$sub$($c.Reset)"))$($c.Violet)$($g.V)$($c.Reset)"
    Write-Host "  $($c.Violet)$($g.V)$($c.Reset)$(& $pad ("   $($c.Grey)$meta$($c.Reset)"))$($c.Violet)$($g.V)$($c.Reset)"
    Write-Host "  $($c.Violet)$($g.BL)$bar$($g.BR)$($c.Reset)"
}

function Format-Bytes([double]$b) {
    if ($b -ge 1GB) { '{0:N2} GB' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:N1} MB' -f ($b / 1MB) }
    elseif ($b -ge 1KB) { '{0:N0} KB' -f ($b / 1KB) } else { "$([int]$b) B" }
}
function Format-Duration([double]$s) {
    if ($s -lt 0 -or [double]::IsInfinity($s) -or [double]::IsNaN($s)) { return '--:--' }
    $ts = [TimeSpan]::FromSeconds([Math]::Round($s))
    if ($ts.TotalHours -ge 1) { '{0:00}:{1:00}:{2:00}' -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds } else { '{0:00}:{1:00}' -f $ts.Minutes, $ts.Seconds }
}

# Single-line progress bar redrawn in place. Percent -1 => indeterminate wave.
function Show-Progress([string]$Label, [double]$Percent, [string]$Detail = '') {
    $c = $Script:C; $g = $Script:G
    $width = [Math]::Max(14, [Math]::Min(36, (Get-Width) - 58))
    if ($Percent -lt 0) {
        $pos = $Script:SpinIdx % ($width * 2); if ($pos -ge $width) { $pos = 2 * $width - $pos - 1 }
        $bar = ''
        for ($i = 0; $i -lt $width; $i++) { $bar += if ([Math]::Abs($i - $pos) -le 2) { $g.Full } else { $g.Empty } }
        $barStr = "$($c.Cyan)$bar$($c.Reset)"; $pct = '      '
    } else {
        $Percent = [Math]::Max(0, [Math]::Min(100, $Percent))
        $filled  = [int][Math]::Round($width * $Percent / 100)
        $fillStr = ''
        for ($i = 0; $i -lt $filled; $i++) {
            $t = if ($width -gt 1) { $i / ($width - 1) } else { 0 }
            $fillStr += (Rgb ([int](150 + 95 * $t)) ([int](110 + 56 * $t)) ([int](255 - 220 * $t))) + $g.Full
        }
        $barStr = "$fillStr$($c.Grey)$($g.Empty * ($width - $filled))$($c.Reset)"
        $pct = '{0,5:N1}%' -f $Percent
    }
    $spin = $Script:Spinner[$Script:SpinIdx % $Script:Spinner.Count]; $Script:SpinIdx++
    $line = "  $($c.Cyan)$spin$($c.Reset) $($c.Bold)$($Label.PadRight(12))$($c.Reset) $barStr $($c.White)$pct$($c.Reset)  $($c.Grey)$Detail$($c.Reset)"
    $pad  = [Math]::Max(0, (Get-Width) - 1 - (Strip $line).Length)
    Write-Host ("`r" + $line + (' ' * $pad)) -NoNewline
    $Script:LineOpen = $true
}
function Complete-Progress([string]$Label, [string]$Detail, [switch]$Failed) {
    Close-Line; $c = $Script:C; $g = $Script:G
    if ($Failed) { Write-Host "  $($c.Red)$($g.Fail)$($c.Reset) $($c.Bold)$($Label.PadRight(12))$($c.Reset) $($c.Red)$Detail$($c.Reset)" }
    else         { Write-Host "  $($c.Green)$($g.Ok)$($c.Reset) $($c.Bold)$($Label.PadRight(12))$($c.Reset) $($c.Grey)$Detail$($c.Reset)" }
}

function Test-IsElevated {
    (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-SelfPath {
    $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ($exe -and ($exe -notmatch '(powershell|pwsh)\.exe$')) { return @{ Path = $exe; IsExe = $true } }
    $ps1 = $PSCommandPath; if (-not $ps1) { $ps1 = $MyInvocation.MyCommand.Definition }
    @{ Path = $ps1; IsExe = $false }
}

if ($ElevatedPhase) {
    $c = $Script:C
    Write-Host ""; Write-Host "  $($c.Violet)$($c.Bold)ELEVATED PHASE$($c.Reset) $($c.Grey)cleanup and installation$($c.Reset)"
} else { Write-Banner }
Write-Log "=== claude-desktop-updater v$Script:Version started (elevated=$(Test-IsElevated), phase=$(if ($ElevatedPhase) {'elevated'} else {'user'}), args: $($PSBoundParameters.Keys -join ' ')) ===" -NoConsole

# ==========================================================================
# Step: stop Claude Desktop processes (never the Claude Code CLI)
# ==========================================================================
function Stop-ClaudeDesktopProcesses {
    Write-Log "Stopping Claude Desktop processes" 'STEP'
    $patterns = @('\\WindowsApps\\Claude', '\\AnthropicClaude\\', '\\Claude\\Claude\.exe')
    $killed = 0; $kept = 0
    Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(Claude|Claude Setup|CoworkVM.*)$' } | ForEach-Object {
        $p = $_; $path = $null; try { $path = $p.Path } catch {}
        $isDesktop = $false
        if ($path) { foreach ($pat in $patterns) { if ($path -match $pat) { $isDesktop = $true; break } } }
        elseif ($p.ProcessName -like 'Claude Setup*' -or $p.ProcessName -like 'CoworkVM*') { $isDesktop = $true }
        if ($isDesktop) {
            Write-Log "Stopping $($p.ProcessName) (PID $($p.Id))" 'DETAIL'
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; $killed++
        } elseif ($path) { $kept++ }
    }
    if ($kept -gt 0) { Write-Log "$kept other 'claude' process(es) left untouched (Claude Code CLI)" 'DETAIL' }
    Write-Log "$killed Claude Desktop process(es) stopped" 'OK'
    if ($killed -gt 0) { Start-Sleep -Seconds 2 }
}

# ==========================================================================
# Step: remove the stale CoworkVMService
# ==========================================================================
# Returns 'absent', 'removed', 'present' (could not touch it) or 'pending'
# (only a reboot completes the removal; package registration would fail
# with 0x80073CF6 until then).
function Remove-CoworkService {
    Write-Log "Checking for a stale CoworkVMService" 'STEP'
    $name = 'CoworkVMService'
    if (-not (Get-Service -Name $name -ErrorAction SilentlyContinue)) { Write-Log "Service not present" 'OK'; return 'absent' }
    if (-not (Test-IsElevated)) { Write-Log "Administrator rights required to remove the service, skipping" 'WARN'; return 'present' }

    & sc.exe stop $name 2>&1 | Out-Null
    $key    = "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
    $hasKey = Test-Path $key
    if (-not $hasKey) {
        # An earlier manual cleanup deleted the key while the SCM still holds
        # the service. The SCM persists both the descriptor change and the
        # delete flag in this key, so every attempt fails with error 2 until
        # the key exists again. Recreate the skeleton, then delete properly.
        Write-Log "Service is known to the SCM but its registry key is missing; recreating the key skeleton" 'WARN'
        try {
            New-Item -Path $key -Force | Out-Null
            New-Item -Path (Join-Path $key 'Security') -Force | Out-Null
            $hasKey = $true
        } catch { Write-Log "Could not recreate the key: $($_.Exception.Message)" 'WARN' }
    }

    # 1) plain deletion as administrator (works when the descriptor allows it)
    $o = & sc.exe delete $name 2>&1; Write-Log "sc delete as administrator: $o" 'DETAIL'
    if (-not (Get-Service -Name $name -ErrorAction SilentlyContinue)) { Write-Log "CoworkVMService removed" 'OK'; return 'removed' }

    # 2) The packaged service's security descriptor denies administrators
    #    (OpenService fails with 5), but grants SYSTEM. Repeat the deletion as
    #    SYSTEM through a one-shot scheduled task; this does not need a reboot.
    $task = 'claude-desktop-updater-svc'
    $cmd  = Join-Path $Script:WorkDir 'svc-delete.cmd'
    $out  = Join-Path $Script:WorkDir 'svc-delete.out'
    $sd   = 'D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)'
    @('@echo off', "sc.exe sdset $name $sd > `"$out`" 2>&1", "sc.exe delete $name >> `"$out`" 2>&1") | Set-Content -Path $cmd -Encoding ASCII
    Remove-Item $out -Force -ErrorAction SilentlyContinue
    try {
        & schtasks.exe /Create /F /RU SYSTEM /SC ONCE /ST 23:59 /TN $task /TR "`"$cmd`"" 2>&1 | Out-Null
        & schtasks.exe /Run /TN $task 2>&1 | Out-Null
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Milliseconds 250
            if ((Test-Path $out) -and -not (Get-Service -Name $name -ErrorAction SilentlyContinue)) { break }
        }
        if (Test-Path $out) { Write-Log "sc delete as SYSTEM: $(((Get-Content $out) | Where-Object { $_ }) -join ' | ')" 'DETAIL' }
    } catch { Write-Log "SYSTEM task failed: $($_.Exception.Message)" 'WARN' }
    finally {
        & schtasks.exe /Delete /F /TN $task 2>&1 | Out-Null
        Remove-Item $cmd, $out -Force -ErrorAction SilentlyContinue
    }
    if (-not (Get-Service -Name $name -ErrorAction SilentlyContinue)) { Write-Log "CoworkVMService removed (SYSTEM context)" 'OK'; return 'removed' }

    # 3) Last resort: take ownership of the registry key and drop it. The SCM
    #    keeps its in-memory entry until the next boot, so report 'pending'.
    if ($hasKey) {
        try {
            $rk = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SYSTEM\CurrentControlSet\Services\$name",
                    [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::TakeOwnership)
            if ($rk) {
                $acl = $rk.GetAccessControl([System.Security.AccessControl.AccessControlSections]::None)
                $acl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User); $rk.SetAccessControl($acl); $rk.Close()
            }
            $acl2 = Get-Acl $key; $acl2.SetAccessRuleProtection($false, $false)
            $acl2.AddAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule(
                [Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
            Set-Acl -Path $key -AclObject $acl2 -ErrorAction SilentlyContinue
            Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Deleted the service registry key" 'DETAIL'
        } catch { Write-Log "Registry key removal failed: $($_.Exception.Message)" 'WARN' }
    }
    Write-Log "Service removal is pending a reboot; the package cannot register its service until then" 'WARN'
    'pending'
}

# ==========================================================================
# Step: sideloading policy, including Group Policy / MDM overrides
# ==========================================================================
function Enable-SideloadingPolicy {
    Write-Log "Verifying sideloading policy" 'STEP'
    if (-not (Test-IsElevated)) { Write-Log "Administrator rights required, skipping" 'WARN'; return $true }
    $unlock = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
    try {
        if (-not (Test-Path $unlock)) { New-Item -Path $unlock -Force | Out-Null }
        New-ItemProperty -Path $unlock -Name 'AllowDevelopmentWithoutDevLicense' -PropertyType DWord -Value 1 -Force | Out-Null
        New-ItemProperty -Path $unlock -Name 'AllowAllTrustedApps' -PropertyType DWord -Value 1 -Force | Out-Null
        Write-Log "AppModelUnlock keys set" 'DETAIL'
    } catch { Write-Log "Could not write AppModelUnlock: $($_.Exception.Message)" 'WARN' }

    # Policy keys under Policies\Microsoft\Windows\Appx take precedence over
    # AppModelUnlock. A managed device (MdmHosts present) typically has
    # AllowAllTrustedApps=0 here, and that is the real cause of 0x80073CFF
    # "you need a developer license or a sideloading-enabled system" even
    # when Developer Mode looks enabled in Settings.
    $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx'
    if (-not (Test-Path $policy)) { Write-Log "No policy override present" 'OK'; return $true }
    $pol = Get-ItemProperty -Path $policy -ErrorAction SilentlyContinue
    if (-not $pol -or ($pol.AllowAllTrustedApps -ne 0 -and $pol.AllowDevelopmentWithoutDevLicense -ne 0)) {
        Write-Log "Policy keys allow sideloading" 'OK'; return $true
    }
    Write-Log "Group Policy / MDM is blocking sideloading (Policies\Appx AllowAllTrustedApps=0)" 'WARN'
    try {
        Set-ItemProperty -Path $policy -Name 'AllowAllTrustedApps' -Value 1 -Type DWord -Force -ErrorAction Stop
        Set-ItemProperty -Path $policy -Name 'AllowDevelopmentWithoutDevLicense' -Value 1 -Type DWord -Force -ErrorAction Stop
        Write-Log "Policy keys set to allow sideloading" 'OK'
        try { Restart-Service -Name AppXSvc -Force -ErrorAction Stop; Write-Log "AppX Deployment Service restarted" 'DETAIL' }
        catch { Write-Log "AppXSvc restart failed: $($_.Exception.Message)" 'WARN' }
        if ($pol.MdmHosts) { Write-Log "This device is MDM managed; a policy sync may revert this setting later" 'WARN' }
        $true
    } catch {
        Write-Log "Could not change the policy keys: $($_.Exception.Message)" 'ERROR'; $false
    }
}

# ==========================================================================
# Step: remove stale package registrations
# ==========================================================================
function Remove-ClaudePackages {
    Write-Log "Removing existing Claude package registrations" 'STEP'
    $found = @(Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue)
    if (Test-IsElevated) { $found += @(Get-AppxPackage -AllUsers -Name '*Claude*' -ErrorAction SilentlyContinue) }
    $found = @($found | Sort-Object PackageFullName -Unique)
    if ($found.Count -eq 0) { Write-Log "No package installed" 'OK'; return }
    foreach ($p in $found) {
        Write-Log "Removing $($p.PackageFullName)" 'DETAIL'
        $done = $false
        try { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop; $done = $true; Write-Log "Removed (current user)" 'OK' }
        catch { Write-Log "User-scope removal failed: $($_.Exception.Message)" 'WARN' }
        if (-not $done -and (Test-IsElevated)) {
            try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop; Write-Log "Removed (all users)" 'OK' }
            catch { Write-Log "All-users removal failed: $($_.Exception.Message)" 'ERROR' }
        }
    }
    if (Test-IsElevated) {
        try {
            Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.PackageName -like '*Claude*' } | ForEach-Object {
                Write-Log "Removing provisioned package $($_.PackageName)" 'DETAIL'
                Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null
            }
        } catch {}
    }
}

# ==========================================================================
# Step: leftovers and winget registration
# ==========================================================================
function Clear-Leftovers([bool]$Purge, [string]$Keep) {
    Write-Log "Cleaning leftovers (user data: $(if ($Purge) {'purged'} else {'preserved'}))" 'STEP'
    $paths = @((Join-Path $env:LOCALAPPDATA 'AnthropicClaude'), (Join-Path $env:LOCALAPPDATA 'SquirrelTemp'))
    Get-ChildItem -Path $env:TEMP -Filter 'Claude-*.msix' -ErrorAction SilentlyContinue |
        Where-Object { -not $Keep -or $_.FullName -ne $Keep } | ForEach-Object { $paths += $_.FullName }
    if ($Purge) {
        $paths += (Join-Path $env:LOCALAPPDATA 'Claude')
        Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue | ForEach-Object { $paths += $_.FullName }
    }
    $n = 0
    foreach ($p in ($paths | Sort-Object -Unique)) {
        if ($p -and (Test-Path $p)) {
            Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $p) { Write-Log "Could not delete $p (in use)" 'WARN' } else { Write-Log "Deleted $p" 'DETAIL'; $n++ }
        }
    }
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        try {
            $list = & winget list --id Anthropic.Claude --accept-source-agreements 2>$null | Out-String
            if ($list -match 'Anthropic\.Claude') {
                & winget uninstall --id Anthropic.Claude --silent --accept-source-agreements 2>$null | Out-Null
                Write-Log "Removed winget registration Anthropic.Claude" 'DETAIL'; $n++
            }
        } catch { Write-Log "winget check failed: $($_.Exception.Message)" 'WARN' }
    }
    Write-Log "$n item(s) cleaned" 'OK'
}

# ==========================================================================
# Resolve, download, verify
# ==========================================================================
function Resolve-LatestRelease {
    $arch = 'x64'
    try { if ((Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1).Architecture -eq 12) { $arch = 'arm64' } } catch {}
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $arch = 'arm64' }
    $redirect = "https://api.anthropic.com/api/desktop/win32/$arch/msix/latest/redirect"
    $url = $null
    for ($i = 1; $i -le 3 -and -not $url; $i++) {
        try {
            $req = [System.Net.HttpWebRequest]::Create($redirect)
            $req.AllowAutoRedirect = $false; $req.UserAgent = $Script:UserAgent; $req.Timeout = 30000
            $resp = $req.GetResponse(); $url = $resp.Headers['Location']; if (-not $url) { $url = $resp.ResponseUri.AbsoluteUri }; $resp.Close()
        } catch {
            try { $url = $_.Exception.Response.Headers['Location'] } catch {}
            if (-not $url) { Write-Log "Resolve attempt $i failed: $($_.Exception.Message)" 'WARN'; Start-Sleep -Seconds (2 * $i) }
        }
    }
    if (-not $url) { return $null }
    $ver = $null; if ($url -match "/releases/win32/$arch/([0-9.]+)/") { $ver = $Matches[1] }
    @{ Url = $url; Version = $ver; Arch = $arch }
}

function Test-Signature([string]$Path) {
    try {
        $sig = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
        if ($sig.Status -ne 'Valid') { Write-Log "Signature invalid (Status=$($sig.Status))" 'ERROR'; return $false }
        if ($sig.SignerCertificate.Subject -notmatch 'Anthropic') { Write-Log "Unexpected signer: $($sig.SignerCertificate.Subject)" 'ERROR'; return $false }
        Write-Log "Authenticode signature valid: $(($sig.SignerCertificate.Subject -split ',')[0])" 'OK'; $true
    } catch { Write-Log "Signature check failed: $($_.Exception.Message)" 'ERROR'; $false }
}

function Get-Package([string]$Url, [string]$Destination) {
    if ((Test-Path $Destination) -and (Get-Item $Destination).Length -gt 100MB) {
        try {
            $sig = Get-AuthenticodeSignature -FilePath $Destination -ErrorAction Stop
            if ($sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -match 'Anthropic') { Write-Log "Valid package already present, skipping download" 'OK'; return $true }
        } catch {}
        Remove-Item $Destination -Force -ErrorAction SilentlyContinue
    }
    # BITS: resumable, survives transient network faults, polled every 0.5 s
    $job = $null
    try {
        Import-Module BitsTransfer -ErrorAction Stop
        $job = Start-BitsTransfer -Source $Url -Destination $Destination -Asynchronous -DisplayName 'claude-desktop-updater' -Priority Foreground -ErrorAction Stop
        $t0 = Get-Date; $lastB = 0.0; $lastT = $t0; $speed = 0.0; $stall = 0
        while ($true) {
            Start-Sleep -Milliseconds 500
            $j = Get-BitsTransfer -JobId $job.JobId -ErrorAction SilentlyContinue
            if (-not $j) { throw "BITS job disappeared" }
            $now = Get-Date; $b = [double]$j.BytesTransferred; $tot = [double]$j.BytesTotal; $dt = ($now - $lastT).TotalSeconds
            if ($dt -gt 0) {
                $inst = ($b - $lastB) / $dt
                $speed = if ($speed -eq 0) { $inst } else { 0.7 * $speed + 0.3 * $inst }
                if ($inst -lt 1KB) { $stall++ } else { $stall = 0 }
                $lastB = $b; $lastT = $now
            }
            switch ($j.JobState) {
                'Transferred' {
                    Complete-BitsTransfer -BitsJob $j -ErrorAction Stop; $job = $null
                    $len = (Get-Item $Destination).Length
                    Complete-Progress 'Downloading' "$(Format-Bytes $len) in $(Format-Duration ((Get-Date) - $t0).TotalSeconds)"
                    Write-Log "Download complete: $len bytes" -NoConsole; return $true
                }
                'Error'          { $e = $j.ErrorDescription; Remove-BitsTransfer -BitsJob $j -ErrorAction SilentlyContinue; $job = $null; throw "BITS error: $e" }
                'TransientError' { Show-Progress 'Downloading' $(if ($tot -gt 0) { 100 * $b / $tot } else { -1 }) 'transient network error, retrying' }
                'Connecting'     { Show-Progress 'Downloading' -1 'connecting' }
                'Queued'         { Show-Progress 'Downloading' -1 'queued' }
                default {
                    if ($tot -gt 0) {
                        $eta = if ($speed -gt 0) { ($tot - $b) / $speed } else { -1 }
                        Show-Progress 'Downloading' (100 * $b / $tot) "$(Format-Bytes $b) / $(Format-Bytes $tot)   $(Format-Bytes $speed)/s   ETA $(Format-Duration $eta)"
                    } else { Show-Progress 'Downloading' -1 "$(Format-Bytes $b) received" }
                }
            }
            if ($stall -gt 360) { throw "no progress for 3 minutes" }
        }
    } catch {
        if ($job) { Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue }
        Close-Line; Write-Log "BITS unavailable ($($_.Exception.Message)), falling back to HTTP" 'WARN'
    }
    # HTTP fallback with Range resume (only appended when the server answers 206)
    for ($a = 1; $a -le 4; $a++) {
        try {
            $have = 0; if (Test-Path $Destination) { $have = (Get-Item $Destination).Length }
            $req = [System.Net.HttpWebRequest]::Create($Url); $req.UserAgent = $Script:UserAgent; $req.Timeout = 60000; $req.ReadWriteTimeout = 120000
            if ($have -gt 0) { $req.AddRange($have) }
            $resp = $req.GetResponse()
            if ($have -gt 0 -and $resp.StatusCode -ne [System.Net.HttpStatusCode]::PartialContent) { $have = 0 }
            $tot = $resp.ContentLength + $have; $stream = $resp.GetResponseStream()
            $fs = New-Object System.IO.FileStream($Destination, $(if ($have -gt 0) { 'Append' } else { 'Create' }), 'Write')
            $buf = New-Object byte[] 1048576; $got = $have; $t0 = Get-Date; $lastDraw = $t0
            while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
                $fs.Write($buf, 0, $n); $got += $n
                if (((Get-Date) - $lastDraw).TotalMilliseconds -ge 500) {
                    $el = ((Get-Date) - $t0).TotalSeconds; $sp = if ($el -gt 0) { ($got - $have) / $el } else { 0 }
                    Show-Progress 'Downloading' $(if ($tot -gt 0) { 100 * $got / $tot } else { -1 }) "$(Format-Bytes $got) / $(Format-Bytes $tot)   $(Format-Bytes $sp)/s   attempt $a"
                    $lastDraw = Get-Date
                }
            }
            $fs.Close(); $stream.Close(); $resp.Close()
            $size = (Get-Item $Destination).Length
            if ($size -gt 100MB) { Complete-Progress 'Downloading' "$(Format-Bytes $size) (HTTP)"; return $true }
            throw "file too small ($size bytes)"
        } catch { Close-Line; Write-Log "HTTP attempt $a failed: $($_.Exception.Message)" 'WARN'; if ($a -lt 4) { Start-Sleep -Seconds (5 * $a) } }
    }
    $false
}

# ==========================================================================
# Install with progress: WinRT PackageManager first, Add-AppxPackage fallback
# ==========================================================================
function Install-ViaWinRT([string]$Path) {
    try {
        $pm = New-Object -TypeName 'Windows.Management.Deployment.PackageManager, Windows.Management.Deployment, ContentType=WindowsRuntime' -ErrorAction Stop
        $op = $pm.AddPackageAsync((New-Object System.Uri($Path)), $null, [Windows.Management.Deployment.DeploymentOptions]::ForceApplicationShutdown)
        $Script:Pct = [double]0
        try { $op.Progress = { param($s, $p) $Script:Pct = [double]$p.percentage } } catch {}
        $t0 = Get-Date
        $started = [Windows.Foundation.AsyncStatus]::Started
        if ($op.Status -eq $null -or "$($op.Status)" -eq '') { return $null }   # runtime not usable in this host
        while ($op.Status -eq $started) {
            $el = ((Get-Date) - $t0).TotalSeconds
            if ($Script:Pct -gt 0) { Show-Progress 'Installing' $Script:Pct "elapsed $(Format-Duration $el)" }
            else { Show-Progress 'Installing' -1 "registering package, elapsed $(Format-Duration $el)" }
            Start-Sleep -Milliseconds 200
        }
        $res = $null; try { $res = $op.GetResults() } catch {}
        if ($op.Status -eq [Windows.Foundation.AsyncStatus]::Completed -and (-not $res -or -not $res.ExtendedErrorCode -or $res.ExtendedErrorCode.HResult -eq 0)) {
            Complete-Progress 'Installing' "done in $(Format-Duration ((Get-Date) - $t0).TotalSeconds)"; return $true
        }
        $err = if ($res -and $res.ExtendedErrorCode) { $res.ExtendedErrorCode.Message } else { "status $($op.Status)" }
        Complete-Progress 'Installing' $err -Failed; Write-Log "WinRT deployment failed: $err" 'WARN'; $false
    } catch { Close-Line; Write-Log "WinRT deployment path unavailable: $($_.Exception.Message)" -NoConsole; $null }
}

function Install-ViaCmdlet([string]$Path, [bool]$AnyVersion) {
    $sb = { param($p, $any)
        try { if ($any) { Add-AppxPackage -Path $p -ForceApplicationShutdown -ForceUpdateFromAnyVersion -ErrorAction Stop } else { Add-AppxPackage -Path $p -ForceApplicationShutdown -ErrorAction Stop }; @{ Ok = $true } }
        catch { @{ Ok = $false; Message = $_.Exception.Message } } }
    $job = Start-Job -ScriptBlock $sb -ArgumentList $Path, $AnyVersion; $t0 = Get-Date
    while ($job.State -eq 'Running') { Show-Progress 'Installing' -1 "Add-AppxPackage, elapsed $(Format-Duration ((Get-Date) - $t0).TotalSeconds)"; Start-Sleep -Milliseconds 200 }
    $r = Receive-Job -Job $job -ErrorAction SilentlyContinue; Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    if ($r -and $r.Ok) { Complete-Progress 'Installing' "done in $(Format-Duration ((Get-Date) - $t0).TotalSeconds)"; return @{ Ok = $true } }
    $msg = if ($r) { $r.Message } else { 'unknown error' }
    Complete-Progress 'Installing' (($msg -split "`n")[0]) -Failed; @{ Ok = $false; Message = $msg }
}

function Install-Package([string]$Path) {
    Write-Log "Installing package" 'STEP'
    if (-not (Test-Signature $Path)) { return $false }
    $r = Install-ViaWinRT $Path
    if ($r -eq $true) { return $true }
    foreach ($any in @($true, $false)) {
        $res = Install-ViaCmdlet $Path $any
        if ($res.Ok) { return $true }
        $Script:LastInstallError = $res.Message
        Write-Log (($res.Message -split "`n")[0]) 'WARN'
        if ($res.Message -match '0x80073CFF') { Write-Log "0x80073CFF: sideloading is blocked by policy or a stale registration conflicts" 'WARN' }
        if ($res.Message -match '0x80073CF6') { Write-Log "0x80073CF6: the package could not register its service; a stale service entry is still held by the SCM" 'WARN'; break }
        if ($res.Message -match '0x80073D02') { Stop-ClaudeDesktopProcesses }
        if ($res.Message -match '0x80073D28') { Write-Log "0x80073D28: a packaged service requires administrator rights" 'WARN' }
    }
    $false
}

function Start-ClaudeDesktop {
    $pkg = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pkg) { return }
    try {
        $appId = @((Get-AppxPackageManifest $pkg).Package.Applications.Application)[0].Id
        Start-Process "shell:AppsFolder\$($pkg.PackageFamilyName)!$appId"; Write-Log "Claude Desktop launched" 'OK'
    } catch { Write-Log "Launch failed: $($_.Exception.Message)" 'WARN' }
}

function Compare-Version([string]$Installed, [string]$Latest) {
    if (-not $Installed -or -not $Latest) { return $false }
    try {
        $a = ($Installed.Split('.') + @('0','0','0','0'))[0..2] -join '.'
        $b = ($Latest.Split('.')    + @('0','0','0','0'))[0..2] -join '.'
        ([version]$a) -ge ([version]$b)
    } catch { $false }
}

function Invoke-ElevatedPhase([string]$Msix) {
    $self = Get-SelfPath
    $args = @('-ElevatedPhase'); if ($PurgeUserData) { $args += '-PurgeUserData' }; if ($CleanOnly) { $args += '-CleanOnly' }; if ($NoColor) { $args += '-NoColor' }
    if ($Msix -and (Test-Path $Msix) -and $Msix -ne $Script:PendingMsix) {
        try { Move-Item -Path $Msix -Destination $Script:PendingMsix -Force -ErrorAction Stop }
        catch { Copy-Item -Path $Msix -Destination $Script:PendingMsix -Force -ErrorAction SilentlyContinue }
    }
    Write-Log "Requesting administrator rights (UAC)" 'STEP'
    try {
        $p = if ($self.IsExe) { Start-Process -FilePath $self.Path -ArgumentList $args -Verb RunAs -PassThru -Wait }
             else { Start-Process -FilePath 'powershell.exe' -ArgumentList (@('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$($self.Path)`"") + $args) -Verb RunAs -PassThru -Wait }
        $elev = Join-Path $Script:WorkDir 'updater.elevated.log'
        if (Test-Path $elev) {
            try { [System.IO.File]::AppendAllLines($Script:LogPath, [string[]](@('--- elevated phase ---') + (Get-Content $elev) + @('--- end elevated phase ---'))); Remove-Item $elev -Force } catch {}
        }
        Write-Log "Elevated phase finished with exit code $($p.ExitCode)" -NoConsole
        $p.ExitCode
    } catch { Write-Log "Elevation refused or failed: $($_.Exception.Message)" 'ERROR'; $ExitNeedsAdmin }
}

# ==========================================================================
# Elevated phase
# ==========================================================================
if ($ElevatedPhase) {
    if (-not (Test-IsElevated)) { Write-Log "Elevated phase started without administrator rights" 'ERROR'; exit $ExitNeedsAdmin }
    $Script:Steps = if ($CleanOnly) { 5 } else { 6 }
    Stop-ClaudeDesktopProcesses
    $svcState = Remove-CoworkService
    $policyOk = Enable-SideloadingPolicy
    Remove-ClaudePackages
    Clear-Leftovers $PurgeUserData.IsPresent $Script:PendingMsix
    if ($CleanOnly) { Write-Log "Cleanup finished (-CleanOnly)" 'OK'; exit $(if ($svcState -eq 'pending') { $ExitRebootNeeded } else { $ExitOk }) }
    if ($svcState -eq 'pending') {
        Write-Log "Skipping installation: the stale service entry disappears only after a reboot" 'ERROR'
        exit $ExitRebootNeeded
    }
    if (-not (Test-Path $Script:PendingMsix)) { Write-Log "No package queued at $Script:PendingMsix" 'ERROR'; exit $ExitInstallFailed }
    if (-not (Install-Package $Script:PendingMsix)) {
        if (-not $policyOk) { exit $ExitPolicyBlocked }
        if ($Script:LastInstallError -match '0x80073CF6') { exit $ExitRebootNeeded }
        exit $ExitInstallFailed
    }
    $pkg = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pkg) { Write-Log "Package not found after installation" 'ERROR'; exit $ExitInstallFailed }
    Write-Log "Installed version $($pkg.Version)" 'OK'
    exit $ExitOk
}

# ==========================================================================
# User phase
# ==========================================================================
$Script:Steps = 3
$before = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue | Select-Object -First 1
Write-Log "Inspecting current installation" 'STEP'
if ($before) { Write-Log "Installed: $($before.Version) (status $($before.Status))" 'DETAIL' } else { Write-Log "Claude Desktop is not installed" 'DETAIL' }

if ($CleanOnly) { exit (Invoke-ElevatedPhase $null) }

$latest = Resolve-LatestRelease
if (-not $latest) {
    Write-Log "Could not resolve the latest release (network or proxy problem)" 'ERROR'
    if (-not $NoLaunch) { Start-Process 'https://claude.ai/download' }
    exit $ExitDownloadFail
}
Write-Log "Latest release: $($latest.Version) ($($latest.Arch))" 'OK'
Write-Log $latest.Url 'DETAIL'

$healthy = -not ($before -and $before.Status -and $before.Status -ne 'Ok')
if (-not $healthy) { Write-Log "Installed package is in state '$($before.Status)', reinstalling" 'WARN' }
if ($before -and $healthy -and -not $Force -and (Compare-Version $before.Version $latest.Version)) {
    Write-Log "Already up to date ($($before.Version)); use -Force to reinstall" 'OK'
    if (-not $NoLaunch) { Start-ClaudeDesktop }
    exit $ExitOk
}

Write-Log "Fetching package" 'STEP'
$msix = Join-Path $env:TEMP ("Claude-{0}.msix" -f $latest.Version)
$reuse = $false
if (Test-Path $Script:PendingMsix) {
    try {
        $sig = Get-AuthenticodeSignature -FilePath $Script:PendingMsix -ErrorAction Stop
        if ($sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -match 'Anthropic' -and (Get-Item $Script:PendingMsix).Length -gt 100MB) {
            Write-Log "Reusing the package left from the previous attempt" 'OK'; $msix = $Script:PendingMsix; $reuse = $true
        }
    } catch {}
    if (-not $reuse) { Remove-Item $Script:PendingMsix -Force -ErrorAction SilentlyContinue }
}
if (-not $reuse -and -not (Get-Package $latest.Url $msix)) {
    Write-Log "Download failed" 'ERROR'
    if (-not $NoLaunch) { Start-Process 'https://claude.ai/download' }
    exit $ExitDownloadFail
}
if (-not (Test-Signature $msix)) { Remove-Item $msix -Force -ErrorAction SilentlyContinue; exit $ExitDownloadFail }

$rc = Invoke-ElevatedPhase $msix
if ($rc -ne $ExitOk) {
    $why = switch ($rc) {
        3 { 'elevation was refused' }
        4 { 'sideloading is blocked by device management' }
        5 { 'a reboot is required to finish removing the stale CoworkVMService; restart Windows and run the updater again' }
        default { 'installation failed' } }
    Write-Log "Update did not complete: $why (exit $rc). The downloaded package is kept for the next run." 'ERROR'
    Write-Log "Log: $Script:LogPath" 'DETAIL'
    exit $rc
}
Remove-Item -Path $Script:PendingMsix -Force -ErrorAction SilentlyContinue

$after = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $after) { Write-Log "Package not found after installation" 'ERROR'; exit $ExitInstallFailed }
if (-not $NoLaunch) { Start-ClaudeDesktop }

$c = $Script:C; $g = $Script:G
$prev = if ($before) { $before.Version } else { 'not installed' }
Write-Host ""
Write-Host "  $($c.Green)$($c.Bold)$($g.Ok) UPDATE COMPLETE$($c.Reset)"
Write-Host "  $($c.Grey)$([string]$g.H * 44)$($c.Reset)"
Write-Host "    $($c.Grey)previous version $($c.Reset) $prev"
Write-Host "    $($c.Grey)installed version$($c.Reset) $($c.Bold)$($c.White)$($after.Version)$($c.Reset)"
Write-Host "    $($c.Grey)user data        $($c.Reset) $(if ($PurgeUserData) {'purged'} else {'preserved'})"
Write-Host "    $($c.Grey)log              $($c.Reset) $($c.Dim)$Script:LogPath$($c.Reset)"
Write-Host "  $($c.Grey)$([string]$g.H * 44)$($c.Reset)"
Write-Host ""
Write-Log "SUMMARY: $prev -> $($after.Version)" -NoConsole
exit $ExitOk
