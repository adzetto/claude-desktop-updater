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

    The repair runs in two phases:

      user phase      resolve the latest release for the machine architecture,
                      download the MSIX with BITS (resumable, live progress),
                      verify the Authenticode signature, hand off to the
                      elevated phase (one UAC prompt).
      elevated phase  stop only real Claude Desktop processes (Claude Code CLI
                      is never touched), delete the stale CoworkVMService
                      through the SCM as SYSTEM, fix sideloading policy
                      (including Group Policy / MDM overrides), remove stale
                      package registrations, install the package with a live
                      progress bar, verify, and launch.

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

$Script:Version   = '3.1.0'
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
# The elevated log is owned by the elevated process; the user phase can read
# and merge it but cannot delete it, so the elevated phase starts it fresh.
if ($ElevatedPhase) { Remove-Item $Script:LogPath -Force -ErrorAction SilentlyContinue }
# Fixed hand-off location so no path has to survive command-line quoting.
$Script:PendingMsix = Join-Path $Script:WorkDir 'pending.msix'
$Script:RunStart    = Get-Date

# ==========================================================================
# Console layer
#   one accent colour, a step list that is rewritten in place when a step
#   finishes, a single live progress line, no timestamps on screen (they are
#   in the log file).
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
    Reset  = Esc '0m'; Bold = Esc '1m'
    Accent = Rgb 217 119 87        # terracotta
    Ok     = Rgb 63 185 80
    Warn   = Rgb 210 153 34
    Err    = Rgb 248 81 73
    Dim    = Rgb 139 148 158
}
$Script:G = if ($Script:Unicode) {
    @{ Active = [string][char]0x25CF; Done = [string][char]0x2713; Warn = '!'; Fail = [string][char]0x2717
       BarFull = [string][char]0x2501; BarHead = [string][char]0x2578; BarEmpty = [string][char]0x2500; Dot = [string][char]0x00B7 }
} else {
    @{ Active = '*'; Done = '+'; Warn = '!'; Fail = 'x'; BarFull = '='; BarHead = '>'; BarEmpty = '-'; Dot = '.' }
}
$Script:Spinner = if ($Script:Unicode) {
    @(0x280B,0x2819,0x2839,0x2838,0x283C,0x2834,0x2826,0x2827,0x2807,0x280F) | ForEach-Object { [string][char]$_ }
} else { @('|','/','-','\') }
$Script:SpinIdx  = 0
$Script:LiveOpen = $false
$Script:Step     = $null

function Get-Width { try { $w = [Console]::WindowWidth; if ($w -gt 40) { return [Math]::Min($w, 110) } } catch {}; 100 }
function Strip([string]$s) { $s -replace "$E\[[0-9;]*m", '' }
function Fit([string]$s, [int]$max) { if ($s.Length -le $max) { $s } else { $s.Substring(0, [Math]::Max(0, $max - 1)) + [string][char]0x2026 } }

function Close-Live {
    if ($Script:LiveOpen) { Write-Host ("`r" + (' ' * ((Get-Width) - 1)) + "`r") -NoNewline; $Script:LiveOpen = $false }
}
function Write-Line([string]$s) {
    Close-Live
    Write-Host $s
    if ($Script:Step) { $Script:Step.Lines++ }
}
function Format-Elapsed([double]$s) {
    if ($s -lt 1) { return ('{0:N0}ms' -f ($s * 1000)) }
    if ($s -lt 60) { return ('{0:N1}s' -f $s) }
    $ts = [TimeSpan]::FromSeconds([Math]::Round($s))
    if ($ts.TotalHours -ge 1) { return ('{0}h {1:00}m' -f [int]$ts.TotalHours, $ts.Minutes) }
    '{0}m {1:00}s' -f $ts.Minutes, $ts.Seconds
}
function Format-Bytes([double]$b) {
    if ($b -ge 1GB) { '{0:N2} GB' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:N1} MB' -f ($b / 1MB) }
    elseif ($b -ge 1KB) { '{0:N0} KB' -f ($b / 1KB) } else { "$([int]$b) B" }
}
function Format-Clock([double]$s) {
    if ($s -lt 0 -or [double]::IsInfinity($s) -or [double]::IsNaN($s)) { return '--:--' }
    $ts = [TimeSpan]::FromSeconds([Math]::Round($s))
    if ($ts.TotalHours -ge 1) { '{0:00}:{1:00}:{2:00}' -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds } else { '{0:00}:{1:00}' -f $ts.Minutes, $ts.Seconds }
}

# A step line is printed when the step starts and rewritten in place when it
# ends (glyph reflects the worst level logged meanwhile, duration on the right).
function Start-Step([string]$text) {
    Complete-Step
    Write-Line "  $($Script:C.Accent)$($Script:G.Active)$($Script:C.Reset) $text"
    $Script:Step = @{ Text = $text; Start = Get-Date; Lines = 0; State = 'ok' }
}
function Complete-Step {
    if (-not $Script:Step) { return }
    $s = $Script:Step; $Script:Step = $null
    $c = $Script:C; $g = $Script:G
    $dur = Format-Elapsed ((Get-Date) - $s.Start).TotalSeconds
    $glyph = switch ($s.State) { 'warn' { "$($c.Warn)$($g.Warn)" } 'fail' { "$($c.Err)$($g.Fail)" } default { "$($c.Ok)$($g.Done)" } }
    $left = "  $glyph$($c.Reset) $($s.Text)"
    $pad  = [Math]::Max(1, (Get-Width) - 2 - (Strip $left).Length - $dur.Length)
    $line = $left + (' ' * $pad) + "$($c.Dim)$dur$($c.Reset)"
    if ($Script:VT) {
        Close-Live
        $up = $s.Lines + 1
        Write-Host ("$E[${up}A`r$line$E[K$E[${up}B`r") -NoNewline
    } else {
        Write-Host "    done in $dur"
    }
}
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK','STEP','DETAIL')][string]$Level = 'INFO', [switch]$NoConsole)
    $line = "{0}  [{1,-6}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    for ($i = 0; $i -lt 5; $i++) {
        try { [System.IO.File]::AppendAllText($Script:LogPath, $line + [Environment]::NewLine); break } catch { Start-Sleep -Milliseconds 40 }
    }
    if ($NoConsole) { return }
    $c = $Script:C; $g = $Script:G
    $max = (Get-Width) - 9
    switch ($Level) {
        'STEP'   { Start-Step $Message }
        'OK'     { Write-Line "      $(Fit $Message $max)" }
        'WARN'   { if ($Script:Step -and $Script:Step.State -ne 'fail') { $Script:Step.State = 'warn' }
                   Write-Line "      $($c.Warn)$($g.Warn) $(Fit $Message ($max - 2))$($c.Reset)" }
        'ERROR'  { if ($Script:Step) { $Script:Step.State = 'fail' }
                   Write-Line "      $($c.Err)$($g.Fail) $(Fit $Message ($max - 2))$($c.Reset)" }
        default  { Write-Line "      $($c.Dim)$(Fit $Message $max)$($c.Reset)" }
    }
}
function Write-Header {
    $c = $Script:C
    $tag = if ($ElevatedPhase) { "v$Script:Version $($Script:G.Dot) elevated" } else { "v$Script:Version" }
    Write-Host ""
    Write-Host "  $($c.Bold)claude-desktop-updater$($c.Reset) $($c.Dim)$tag$($c.Reset)"
    Write-Host ""
}
# Live line at the bottom: spinner, thin bar, percent and detail. Percent -1
# draws an indeterminate bar.
function Show-Progress([string]$Label, [double]$Percent, [string]$Detail = '') {
    $c = $Script:C; $g = $Script:G
    $width = [Math]::Max(16, [Math]::Min(40, (Get-Width) - 62))
    if ($Percent -lt 0) {
        $pos = $Script:SpinIdx % ($width * 2); if ($pos -ge $width) { $pos = 2 * $width - $pos - 1 }
        $bar = ''
        for ($i = 0; $i -lt $width; $i++) { $bar += if ([Math]::Abs($i - $pos) -le 3) { "$($c.Accent)$($g.BarFull)" } else { "$($c.Dim)$($g.BarEmpty)" } }
        $bar += $c.Reset; $pct = '      '
    } else {
        $Percent = [Math]::Max(0, [Math]::Min(100, $Percent))
        $filled = [int][Math]::Floor($width * $Percent / 100)
        $head = if ($filled -gt 0 -and $filled -lt $width) { $g.BarHead } else { '' }
        $bar = "$($c.Accent)$($g.BarFull * $filled)$head$($c.Dim)$($g.BarEmpty * ($width - $filled - $head.Length))$($c.Reset)"
        $pct = '{0,5:N1}%' -f $Percent
    }
    $spin = $Script:Spinner[$Script:SpinIdx % $Script:Spinner.Count]; $Script:SpinIdx++
    $line = "      $($c.Accent)$spin$($c.Reset) $bar $pct  $($c.Dim)$Detail$($c.Reset)"
    $pad  = [Math]::Max(0, (Get-Width) - 1 - (Strip $line).Length)
    Write-Host ("`r" + $line + (' ' * $pad)) -NoNewline
    $Script:LiveOpen = $true
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

Write-Header
Write-Log "=== claude-desktop-updater v$Script:Version started (elevated=$(Test-IsElevated), phase=$(if ($ElevatedPhase) {'elevated'} else {'user'}), args: $($PSBoundParameters.Keys -join ' ')) ===" -NoConsole

# ==========================================================================
# Step: stop Claude Desktop processes (never the Claude Code CLI)
# ==========================================================================
function Stop-ClaudeDesktopProcesses {
    Write-Log "Stopping Claude Desktop" 'STEP'
    $patterns = @('\\WindowsApps\\Claude', '\\AnthropicClaude\\', '\\Claude\\Claude\.exe')
    $killed = 0; $kept = 0
    Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(Claude|Claude Setup|CoworkVM.*)$' } | ForEach-Object {
        $p = $_; $path = $null; try { $path = $p.Path } catch {}
        $isDesktop = $false
        if ($path) { foreach ($pat in $patterns) { if ($path -match $pat) { $isDesktop = $true; break } } }
        elseif ($p.ProcessName -like 'Claude Setup*' -or $p.ProcessName -like 'CoworkVM*') { $isDesktop = $true }
        if ($isDesktop) {
            Write-Log "stopped $($p.ProcessName) (PID $($p.Id))" 'DETAIL'
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; $killed++
        } elseif ($path) { $kept++ }
    }
    if ($kept -gt 0) { Write-Log "$kept Claude Code CLI process(es) left untouched" 'DETAIL' }
    Write-Log "$killed process(es) stopped" 'OK'
    if ($killed -gt 0) { Start-Sleep -Seconds 2 }
}

# ==========================================================================
# Step: remove the stale CoworkVMService
# Returns 'absent', 'removed', 'present' (could not touch it) or 'pending'
# (only a reboot completes the removal; package registration would fail
# with 0x80073CF6 until then).
# ==========================================================================
function Remove-CoworkService {
    Write-Log "Removing stale CoworkVMService" 'STEP'
    $name = 'CoworkVMService'
    if (-not (Get-Service -Name $name -ErrorAction SilentlyContinue)) { Write-Log "no stale service registered" 'OK'; return 'absent' }
    if (-not (Test-IsElevated)) { Write-Log "administrator rights required, skipped" 'WARN'; return 'present' }

    & sc.exe stop $name 2>&1 | Out-Null
    $key    = "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
    $hasKey = Test-Path $key
    if (-not $hasKey) {
        # An earlier manual cleanup deleted the key while the SCM still holds
        # the service. The SCM persists both the descriptor change and the
        # delete flag in this key, so every attempt fails with error 2 until
        # the key exists again. Recreate the skeleton, then delete properly.
        Write-Log "registry key missing while the SCM still holds the service, recreating the key skeleton" 'WARN'
        try {
            New-Item -Path $key -Force | Out-Null
            New-Item -Path (Join-Path $key 'Security') -Force | Out-Null
            $hasKey = $true
        } catch { Write-Log "could not recreate the key: $($_.Exception.Message)" 'WARN' }
    }

    # 1) plain deletion as administrator (works when the descriptor allows it)
    $o = & sc.exe delete $name 2>&1; Write-Log "sc delete as administrator: $o" 'DETAIL'
    if (-not (Get-Service -Name $name -ErrorAction SilentlyContinue)) { Write-Log "service removed" 'OK'; return 'removed' }

    # 2) The packaged service's security descriptor denies administrators
    #    (OpenService fails with 5) but its owner is SYSTEM. Repeat the
    #    deletion as SYSTEM through a one-shot scheduled task; no reboot needed.
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
    if (-not (Get-Service -Name $name -ErrorAction SilentlyContinue)) { Write-Log "service removed in SYSTEM context" 'OK'; return 'removed' }

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
            Write-Log "deleted the service registry key" 'DETAIL'
        } catch { Write-Log "registry key removal failed: $($_.Exception.Message)" 'WARN' }
    }
    Write-Log "removal is pending a reboot; the package cannot register its service until then" 'WARN'
    'pending'
}

# ==========================================================================
# Step: sideloading policy, including Group Policy / MDM overrides
# ==========================================================================
function Enable-SideloadingPolicy {
    Write-Log "Verifying sideloading policy" 'STEP'
    if (-not (Test-IsElevated)) { Write-Log "administrator rights required, skipped" 'WARN'; return $true }
    $unlock = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
    try {
        if (-not (Test-Path $unlock)) { New-Item -Path $unlock -Force | Out-Null }
        New-ItemProperty -Path $unlock -Name 'AllowDevelopmentWithoutDevLicense' -PropertyType DWord -Value 1 -Force | Out-Null
        New-ItemProperty -Path $unlock -Name 'AllowAllTrustedApps' -PropertyType DWord -Value 1 -Force | Out-Null
        Write-Log "AppModelUnlock keys set" 'DETAIL'
    } catch { Write-Log "could not write AppModelUnlock: $($_.Exception.Message)" 'WARN' }

    # Policy keys under Policies\Microsoft\Windows\Appx take precedence over
    # AppModelUnlock. A managed device (MdmHosts present) typically has
    # AllowAllTrustedApps=0 here, and that is the real cause of 0x80073CFF
    # "you need a developer license or a sideloading-enabled system" even
    # when Developer Mode looks enabled in Settings.
    $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx'
    if (-not (Test-Path $policy)) { Write-Log "no policy override present" 'OK'; return $true }
    $pol = Get-ItemProperty -Path $policy -ErrorAction SilentlyContinue
    if (-not $pol -or ($pol.AllowAllTrustedApps -ne 0 -and $pol.AllowDevelopmentWithoutDevLicense -ne 0)) {
        Write-Log "policy keys allow sideloading" 'OK'; return $true
    }
    Write-Log "Group Policy / MDM blocks sideloading (Policies\Appx AllowAllTrustedApps=0)" 'WARN'
    try {
        Set-ItemProperty -Path $policy -Name 'AllowAllTrustedApps' -Value 1 -Type DWord -Force -ErrorAction Stop
        Set-ItemProperty -Path $policy -Name 'AllowDevelopmentWithoutDevLicense' -Value 1 -Type DWord -Force -ErrorAction Stop
        Write-Log "policy keys set to allow sideloading" 'OK'
        try { Restart-Service -Name AppXSvc -Force -ErrorAction Stop; Write-Log "AppX Deployment Service restarted" 'DETAIL' }
        catch { Write-Log "AppXSvc restart failed: $($_.Exception.Message)" 'WARN' }
        if ($pol.MdmHosts) { Write-Log "this device is MDM managed; a policy sync may revert this setting later" 'WARN' }
        $true
    } catch {
        Write-Log "could not change the policy keys: $($_.Exception.Message)" 'ERROR'; $false
    }
}

# ==========================================================================
# Step: remove stale package registrations
# ==========================================================================
function Remove-ClaudePackages {
    Write-Log "Removing existing package registration" 'STEP'
    $found = @(Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue)
    if (Test-IsElevated) { $found += @(Get-AppxPackage -AllUsers -Name '*Claude*' -ErrorAction SilentlyContinue) }
    $found = @($found | Sort-Object PackageFullName -Unique)
    if ($found.Count -eq 0) { Write-Log "no package registered" 'OK'; return }
    foreach ($p in $found) {
        $done = $false
        try { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop; $done = $true; Write-Log "removed $($p.PackageFullName)" 'OK' }
        catch { Write-Log "user-scope removal failed: $($_.Exception.Message)" 'WARN' }
        if (-not $done -and (Test-IsElevated)) {
            try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop; Write-Log "removed $($p.PackageFullName) for all users" 'OK' }
            catch { Write-Log "all-users removal failed: $($_.Exception.Message)" 'ERROR' }
        }
    }
    if (Test-IsElevated) {
        try {
            Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.PackageName -like '*Claude*' } | ForEach-Object {
                Write-Log "removed provisioned package $($_.PackageName)" 'DETAIL'
                Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null
            }
        } catch {}
    }
}

# ==========================================================================
# Step: leftovers and winget registration
# ==========================================================================
function Clear-Leftovers([bool]$Purge, [string]$Keep) {
    Write-Log "Cleaning leftovers" 'STEP'
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
            if (Test-Path $p) { Write-Log "could not delete $p (in use)" 'WARN' } else { Write-Log "deleted $p" 'DETAIL'; $n++ }
        }
    }
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        try {
            $list = & winget list --id Anthropic.Claude --accept-source-agreements 2>$null | Out-String
            if ($list -match 'Anthropic\.Claude') {
                & winget uninstall --id Anthropic.Claude --silent --accept-source-agreements 2>$null | Out-Null
                Write-Log "removed winget registration Anthropic.Claude" 'DETAIL'; $n++
            }
        } catch { Write-Log "winget check failed: $($_.Exception.Message)" 'WARN' }
    }
    Write-Log "$n item(s) cleaned, user data $(if ($Purge) {'purged'} else {'preserved'})" 'OK'
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
            if (-not $url) { Write-Log "resolve attempt $i failed: $($_.Exception.Message)" 'WARN'; Start-Sleep -Seconds (2 * $i) }
        }
    }
    if (-not $url) { return $null }
    $ver = $null; if ($url -match "/releases/win32/$arch/([0-9.]+)/") { $ver = $Matches[1] }
    @{ Url = $url; Version = $ver; Arch = $arch }
}

function Test-Signature([string]$Path) {
    try {
        $sig = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
        if ($sig.Status -ne 'Valid') { Write-Log "signature invalid (Status=$($sig.Status))" 'ERROR'; return $false }
        if ($sig.SignerCertificate.Subject -notmatch 'Anthropic') { Write-Log "unexpected signer: $($sig.SignerCertificate.Subject)" 'ERROR'; return $false }
        $cn = if ($sig.SignerCertificate.Subject -match 'CN="?([^"]+?)"?(,|$)') { $Matches[1] } else { $sig.SignerCertificate.Subject }
        Write-Log "Authenticode signature valid, signer $cn" 'OK'; $true
    } catch { Write-Log "signature check failed: $($_.Exception.Message)" 'ERROR'; $false }
}

function Get-Package([string]$Url, [string]$Destination) {
    if ((Test-Path $Destination) -and (Get-Item $Destination).Length -gt 100MB) {
        try {
            $sig = Get-AuthenticodeSignature -FilePath $Destination -ErrorAction Stop
            if ($sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -match 'Anthropic') { Write-Log "valid package already present, download skipped" 'OK'; return $true }
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
                    Write-Log "$(Format-Bytes $len) in $(Format-Clock ((Get-Date) - $t0).TotalSeconds) via BITS" 'OK'; return $true
                }
                'Error'          { $e = $j.ErrorDescription; Remove-BitsTransfer -BitsJob $j -ErrorAction SilentlyContinue; $job = $null; throw "BITS error: $e" }
                'TransientError' { Show-Progress 'download' $(if ($tot -gt 0) { 100 * $b / $tot } else { -1 }) 'transient network error, retrying' }
                'Connecting'     { Show-Progress 'download' -1 'connecting' }
                'Queued'         { Show-Progress 'download' -1 'queued' }
                default {
                    if ($tot -gt 0) {
                        $eta = if ($speed -gt 0) { ($tot - $b) / $speed } else { -1 }
                        Show-Progress 'download' (100 * $b / $tot) "$(Format-Bytes $b) / $(Format-Bytes $tot) $($Script:G.Dot) $(Format-Bytes $speed)/s $($Script:G.Dot) $(Format-Clock $eta) left"
                    } else { Show-Progress 'download' -1 "$(Format-Bytes $b) received" }
                }
            }
            if ($stall -gt 360) { throw "no progress for 3 minutes" }
        }
    } catch {
        if ($job) { Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue }
        Close-Live; Write-Log "BITS unavailable ($($_.Exception.Message)), falling back to HTTP" 'WARN'
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
                    Show-Progress 'download' $(if ($tot -gt 0) { 100 * $got / $tot } else { -1 }) "$(Format-Bytes $got) / $(Format-Bytes $tot) $($Script:G.Dot) $(Format-Bytes $sp)/s $($Script:G.Dot) HTTP attempt $a"
                    $lastDraw = Get-Date
                }
            }
            $fs.Close(); $stream.Close(); $resp.Close()
            $size = (Get-Item $Destination).Length
            if ($size -gt 100MB) { Write-Log "$(Format-Bytes $size) via HTTP" 'OK'; return $true }
            throw "file too small ($size bytes)"
        } catch { Close-Live; Write-Log "HTTP attempt $a failed: $($_.Exception.Message)" 'WARN'; if ($a -lt 4) { Start-Sleep -Seconds (5 * $a) } }
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
            if ($Script:Pct -gt 0) { Show-Progress 'install' $Script:Pct "registering package $($Script:G.Dot) $(Format-Clock $el)" }
            else { Show-Progress 'install' -1 "registering package $($Script:G.Dot) $(Format-Clock $el)" }
            Start-Sleep -Milliseconds 200
        }
        $res = $null; try { $res = $op.GetResults() } catch {}
        if ($op.Status -eq [Windows.Foundation.AsyncStatus]::Completed -and (-not $res -or -not $res.ExtendedErrorCode -or $res.ExtendedErrorCode.HResult -eq 0)) {
            Close-Live; return $true
        }
        $err = if ($res -and $res.ExtendedErrorCode) { $res.ExtendedErrorCode.Message } else { "status $($op.Status)" }
        Close-Live; Write-Log "WinRT deployment failed: $err" 'WARN'; $false
    } catch { Close-Live; Write-Log "WinRT deployment path unavailable: $($_.Exception.Message)" -NoConsole; $null }
}

function Install-ViaCmdlet([string]$Path, [bool]$AnyVersion) {
    $sb = { param($p, $any)
        try { if ($any) { Add-AppxPackage -Path $p -ForceApplicationShutdown -ForceUpdateFromAnyVersion -ErrorAction Stop } else { Add-AppxPackage -Path $p -ForceApplicationShutdown -ErrorAction Stop }; @{ Ok = $true } }
        catch { @{ Ok = $false; Message = $_.Exception.Message } } }
    $job = Start-Job -ScriptBlock $sb -ArgumentList $Path, $AnyVersion; $t0 = Get-Date
    while ($job.State -eq 'Running') { Show-Progress 'install' -1 "registering package $($Script:G.Dot) $(Format-Clock ((Get-Date) - $t0).TotalSeconds)"; Start-Sleep -Milliseconds 200 }
    $r = Receive-Job -Job $job -ErrorAction SilentlyContinue; Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    Close-Live
    if ($r -and $r.Ok) { return @{ Ok = $true } }
    $msg = if ($r) { $r.Message } else { 'unknown error' }
    @{ Ok = $false; Message = $msg }
}

function Install-Package([string]$Path) {
    Write-Log "Installing package" 'STEP'
    if (-not (Test-Signature $Path)) { return $false }
    $t0 = Get-Date
    $r = Install-ViaWinRT $Path
    if ($r -eq $true) { Write-Log "registered in $(Format-Elapsed ((Get-Date) - $t0).TotalSeconds)" 'OK'; return $true }
    foreach ($any in @($true, $false)) {
        $res = Install-ViaCmdlet $Path $any
        if ($res.Ok) { Write-Log "registered in $(Format-Elapsed ((Get-Date) - $t0).TotalSeconds)" 'OK'; return $true }
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
    } catch { Write-Log "launch failed: $($_.Exception.Message)" 'WARN' }
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
    Write-Log "Installing with administrator rights" 'STEP'
    Write-Log "approve the UAC prompt; the elevated phase reports in its own window" 'DETAIL'
    try {
        $p = if ($self.IsExe) { Start-Process -FilePath $self.Path -ArgumentList $args -Verb RunAs -PassThru -Wait }
             else { Start-Process -FilePath 'powershell.exe' -ArgumentList (@('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$($self.Path)`"") + $args) -Verb RunAs -PassThru -Wait }
        $elev = Join-Path $Script:WorkDir 'updater.elevated.log'
        if (Test-Path $elev) {
            try { [System.IO.File]::AppendAllLines($Script:LogPath, [string[]](@('--- elevated phase ---') + (Get-Content $elev) + @('--- end elevated phase ---'))); Remove-Item $elev -Force } catch {}
        }
        Write-Log "elevated phase finished with exit code $($p.ExitCode)" -NoConsole
        if ($p.ExitCode -eq 0) { Write-Log "elevated phase completed" 'OK' }
        $p.ExitCode
    } catch { Write-Log "elevation refused or failed: $($_.Exception.Message)" 'ERROR'; $ExitNeedsAdmin }
}

function Write-Outcome([bool]$Ok, [string]$Title, [string[]]$Rows) {
    Complete-Step
    $c = $Script:C; $g = $Script:G
    $dur = Format-Elapsed ((Get-Date) - $Script:RunStart).TotalSeconds
    $glyph = if ($Ok) { "$($c.Ok)$($g.Done)" } else { "$($c.Err)$($g.Fail)" }
    $left = "  $glyph$($c.Reset) $($c.Bold)$Title$($c.Reset)"
    $pad = [Math]::Max(1, (Get-Width) - 2 - (Strip $left).Length - $dur.Length)
    Write-Host ""
    Write-Host ($left + (' ' * $pad) + "$($c.Dim)$dur$($c.Reset)")
    Write-Host ""
    foreach ($r in $Rows) {
        $k, $v = $r -split '=', 2
        Write-Host ("      $($c.Dim)$($k.PadRight(10))$($c.Reset)$v")
    }
    Write-Host ""
}

# ==========================================================================
# Elevated phase
# ==========================================================================
if ($ElevatedPhase) {
    if (-not (Test-IsElevated)) { Write-Log "elevated phase started without administrator rights" 'ERROR'; exit $ExitNeedsAdmin }
    Stop-ClaudeDesktopProcesses
    $svcState = Remove-CoworkService
    $policyOk = Enable-SideloadingPolicy
    Remove-ClaudePackages
    Clear-Leftovers $PurgeUserData.IsPresent $Script:PendingMsix
    if ($CleanOnly) { Complete-Step; exit $(if ($svcState -eq 'pending') { $ExitRebootNeeded } else { $ExitOk }) }
    if ($svcState -eq 'pending') {
        Write-Log "installation skipped: the stale service entry disappears only after a reboot" 'ERROR'
        Complete-Step; exit $ExitRebootNeeded
    }
    if (-not (Test-Path $Script:PendingMsix)) { Write-Log "no package queued at $Script:PendingMsix" 'ERROR'; Complete-Step; exit $ExitInstallFailed }
    if (-not (Install-Package $Script:PendingMsix)) {
        Complete-Step
        if (-not $policyOk) { exit $ExitPolicyBlocked }
        if ($Script:LastInstallError -match '0x80073CF6') { exit $ExitRebootNeeded }
        exit $ExitInstallFailed
    }
    $pkg = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pkg) { Write-Log "package not found after installation" 'ERROR'; Complete-Step; exit $ExitInstallFailed }
    Write-Log "installed version $($pkg.Version)" 'OK'
    Complete-Step
    exit $ExitOk
}

# ==========================================================================
# User phase
# ==========================================================================
Write-Log "Inspecting installation" 'STEP'
$before = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($before) { Write-Log "installed $($before.Version), status $($before.Status)" 'OK' } else { Write-Log "Claude Desktop is not installed" 'OK' }

if ($CleanOnly) { $rc = Invoke-ElevatedPhase $null; Complete-Step; exit $rc }

Write-Log "Resolving latest release" 'STEP'
$latest = Resolve-LatestRelease
if (-not $latest) {
    Write-Log "could not resolve the latest release (network or proxy problem)" 'ERROR'
    Write-Outcome $false "Update did not complete" @("reason=the release endpoint could not be reached", "log=$Script:LogPath")
    if (-not $NoLaunch) { Start-Process 'https://claude.ai/download' }
    exit $ExitDownloadFail
}
Write-Log "$($latest.Version) for $($latest.Arch)" 'OK'
Write-Log $latest.Url 'DETAIL'

$healthy = -not ($before -and $before.Status -and $before.Status -ne 'Ok')
if (-not $healthy) { Write-Log "installed package is in state '$($before.Status)', reinstalling" 'WARN' }
if ($before -and $healthy -and -not $Force -and (Compare-Version $before.Version $latest.Version)) {
    Write-Log "already up to date, use -Force to reinstall" 'OK'
    Write-Outcome $true "Already up to date" @("installed=$($before.Version)", "latest=$($latest.Version)", "log=$Script:LogPath")
    if (-not $NoLaunch) { Start-ClaudeDesktop }
    exit $ExitOk
}

Write-Log "Downloading package" 'STEP'
$msix = Join-Path $env:TEMP ("Claude-{0}.msix" -f $latest.Version)
$reuse = $false
if (Test-Path $Script:PendingMsix) {
    try {
        $sig = Get-AuthenticodeSignature -FilePath $Script:PendingMsix -ErrorAction Stop
        if ($sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -match 'Anthropic' -and (Get-Item $Script:PendingMsix).Length -gt 100MB) {
            Write-Log "reusing the package kept from the previous attempt" 'OK'; $msix = $Script:PendingMsix; $reuse = $true
        }
    } catch {}
    if (-not $reuse) { Remove-Item $Script:PendingMsix -Force -ErrorAction SilentlyContinue }
}
if (-not $reuse -and -not (Get-Package $latest.Url $msix)) {
    Write-Log "download failed" 'ERROR'
    Write-Outcome $false "Update did not complete" @("reason=the package could not be downloaded", "log=$Script:LogPath")
    if (-not $NoLaunch) { Start-Process 'https://claude.ai/download' }
    exit $ExitDownloadFail
}
if (-not (Test-Signature $msix)) {
    Remove-Item $msix -Force -ErrorAction SilentlyContinue
    Write-Outcome $false "Update did not complete" @("reason=the downloaded package failed signature verification", "log=$Script:LogPath")
    exit $ExitDownloadFail
}

$rc = Invoke-ElevatedPhase $msix
if ($rc -ne $ExitOk) {
    $why = switch ($rc) {
        3 { 'the UAC prompt was refused' }
        4 { 'sideloading is blocked by device management' }
        5 { 'a reboot is required to finish removing the stale CoworkVMService; restart and run again' }
        default { 'the elevated installation failed, see the log' } }
    Write-Log "update did not complete: $why (exit $rc)" 'ERROR'
    Write-Outcome $false "Update did not complete" @("reason=$why", "package=kept for the next run", "log=$Script:LogPath")
    exit $rc
}
Remove-Item -Path $Script:PendingMsix -Force -ErrorAction SilentlyContinue

$after = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $after) {
    Write-Log "package not found after installation" 'ERROR'
    Write-Outcome $false "Update did not complete" @("reason=the package is not registered after installation", "log=$Script:LogPath")
    exit $ExitInstallFailed
}
Write-Log "installed $($after.Version)" 'OK'
if (-not $NoLaunch) { Start-ClaudeDesktop }

$prev = if ($before) { $before.Version } else { 'not installed' }
Write-Log "SUMMARY: $prev -> $($after.Version)" -NoConsole
Write-Outcome $true "Update complete" @("previous=$prev", "installed=$($after.Version)", "user data=$(if ($PurgeUserData) {'purged'} else {'preserved'})", "log=$Script:LogPath")
exit $ExitOk
