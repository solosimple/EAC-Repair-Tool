#requires -Version 5.1
<#
EAC Repair & Restore v2.0 - Windows 10/11, Windows PowerShell 5.1
No downloads, no Defender exclusions, no service-directory deletion.
Backups are atomic, same-volume directory renames next to original folders.
A persistent JSON journal records every reversible change before it happens.
#>
[CmdletBinding()]
param(
    [switch]$SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not $SelfTest) {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        Write-Host 'This tool is for Windows 10/11 only.' -ForegroundColor Red
        exit 1
    }
    if (-not (Test-IsAdministrator)) {
        Write-Host 'Requesting administrator permission. Close games before using this tool.'
        try {
            $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
            Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') `
                -ArgumentList $arguments -Verb RunAs `
                -WorkingDirectory (Split-Path -Parent $PSCommandPath) -ErrorAction Stop | Out-Null
        } catch {
            Write-Host "Administrator permission was not granted: $($_.Exception.Message)" -ForegroundColor Red
            exit 1
        }
        exit 0
    }
}

$script:DataRoot = if ($SelfTest) {
    Join-Path ([IO.Path]::GetTempPath()) ('EACRepairSelfTest_' + [Guid]::NewGuid().ToString('N'))
} else {
    Join-Path $env:LOCALAPPDATA 'EACRepairTool'
}
$script:StatePath = Join-Path $script:DataRoot 'state.json'
$script:LogPath = Join-Path $script:DataRoot 'activity.log'
$script:State = $null
$script:Lock = $null

function Write-Event {
    param([string]$Message, [ValidateSet('INFO','OK','WARN','ERROR')][string]$Level = 'INFO')
    $colour = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        default { 'Gray' }
    }
    Write-Host ('[{0}] {1}' -f $Level, $Message) -ForegroundColor $colour
    if (Test-Path -LiteralPath $script:DataRoot -PathType Container) {
        try {
            Add-Content -LiteralPath $script:LogPath -Value ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message) -Encoding UTF8
        } catch {
            Write-Host 'WARNING: Could not write activity log.' -ForegroundColor Yellow
        }
    }
}

function Save-State {
    # Write temp in the same directory, then atomically replace state.json.
    $tempFile = Join-Path $script:DataRoot ('state.{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    $json = ConvertTo-Json -InputObject $script:State -Depth 8
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    try {
        [IO.File]::WriteAllText($tempFile, $json, $utf8)
        if (Test-Path -LiteralPath $script:StatePath) {
            [IO.File]::Replace($tempFile, $script:StatePath, ($script:StatePath + '.previous'), $true)
        } else {
            [IO.File]::Move($tempFile, $script:StatePath)
        }
    } finally {
        if (Test-Path -LiteralPath $tempFile) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Initialize-State {
    New-Item -ItemType Directory -Path $script:DataRoot -Force | Out-Null
    # An exclusive handle, not a stale lock file, prevents two simultaneous runs.
    $script:Lock = [IO.File]::Open((Join-Path $script:DataRoot 'instance.lock'),
        [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    if (Test-Path -LiteralPath $script:StatePath) {
        try {
            $script:State = Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($script:State.Version -ne 2 -or -not $script:State.PSObject.Properties['Actions']) {
                throw 'Unknown state format.'
            }
            if ($null -eq $script:State.Actions) { $script:State.Actions = @() }
        } catch {
            throw "Cannot safely read state.json; it has NOT been overwritten. Check state.json.previous. Details: $($_.Exception.Message)"
        }
    } else {
        $script:State = [pscustomobject]@{ Version = 2; Actions = @() }
        Save-State
    }
}

function Add-Action {
    param([psobject]$Action)
    $script:State.Actions = @($script:State.Actions) + @($Action)
    Save-State
}

function Pause-Menu {
    [void](Read-Host 'Press Enter to continue')
}

function Confirm-Yes {
    param([string]$Message)
    $answer = Read-Host ("$Message Type YES to confirm")
    return ($answer -ceq 'YES')
}

function Select-Index {
    param([int]$Count, [string]$Prompt = 'Choose a number (Enter to cancel)')
    $answer = (Read-Host $Prompt).Trim()
    $number = 0
    if ($answer -match '^[0-9]+$' -and [int]::TryParse($answer, [ref]$number) -and
        $number -ge 1 -and $number -le $Count) {
        return ($number - 1)
    }
    return -1
}

function Get-ActiveActions {
    return @($script:State.Actions | Where-Object { $_.Status -in @('Pending','Active','Restoring') })
}

function Backup-Folder {
    param([string]$Original, [string]$Description)
    if (-not (Test-Path -LiteralPath $Original -PathType Container)) {
        Write-Event "Not present: $Original"
        return $false
    }
    $existing = @($script:State.Actions | Where-Object {
        $_.Kind -eq 'Folder' -and $_.Original -ieq $Original -and $_.Status -in @('Pending','Active','Restoring')
    })
    if ($existing.Count -gt 0) {
        Write-Event "Already backed up and awaiting restore: $Original" 'WARN'
        return $false
    }
    $item = Get-Item -LiteralPath $Original -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Write-Event "Skipping linked/junction directory: $Original" 'WARN'
        return $false
    }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $suffix = [Guid]::NewGuid().ToString('N').Substring(0,8)
    $backupName = '{0}.EACRepairBackup.{1}.{2}' -f $item.Name, $stamp, $suffix
    $backupPath = Join-Path $item.Parent.FullName $backupName
    $action = [pscustomobject]@{
        Id = [Guid]::NewGuid().ToString('N')
        Kind = 'Folder'
        Status = 'Pending'
        Description = $Description
        Original = $Original
        Backup = $backupPath
        CreatedAt = (Get-Date).ToString('o')
    }
    try {
        Add-Action $action   # Persist BEFORE changing files.
        Rename-Item -LiteralPath $Original -NewName $backupName -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $backupPath -PathType Container)) {
            throw 'Backup path not found after rename.'
        }
        $action.Status = 'Active'
        Save-State
        Write-Event "Backed up $Description to: $backupPath" 'OK'
        return $true
    } catch {
        Write-Event "Could not back up ${Original}: $($_.Exception.Message)" 'ERROR'
        # Pending remains in the journal if the rename succeeded but journalling failed.
        return $false
    }
}

function Restore-FolderAction {
    param([psobject]$Action, [switch]$PreserveConflictAutomatically)
    $original = [string]$Action.Original
    $backup = [string]$Action.Backup
    if (-not (Test-Path -LiteralPath $backup -PathType Container)) {
        if (Test-Path -LiteralPath $original -PathType Container) {
            if ($Action.Status -eq 'Restoring') {
                Write-Event "Restore was interrupted: original exists but backup is absent. Cannot prove which settings were restored; inspect manually: $original" 'WARN'
                return $false
            }
            if ($Action.Status -eq 'Pending') {
                $Action.Status = 'NotApplied'
                Save-State
                Write-Event "No backup to restore (original still present): $original"
            } else {
                Write-Event "Backup MISSING, leaving current folder untouched: $backup" 'ERROR'
            }
        } else {
            Write-Event "Both original and backup are missing. Manual recovery needed: $original" 'ERROR'
        }
        return $false
    }
    $heldNew = $null
    if (Test-Path -LiteralPath $original) {
        Write-Event "The game recreated settings at: $original" 'WARN'
        if (-not $PreserveConflictAutomatically) {
            if (-not (Confirm-Yes 'Preserve the newer folder separately, then restore the old one?')) {
                Write-Event 'Skipped restore; both versions are still safe.' 'WARN'
                return $false
            }
        }
        $current = Get-Item -LiteralPath $original -Force
        $heldName = '{0}.EACRepairNewer.{1}.{2}' -f $current.Name,
            (Get-Date -Format 'yyyyMMdd_HHmmss'), ([Guid]::NewGuid().ToString('N').Substring(0,8))
        $heldNew = Join-Path $current.Parent.FullName $heldName
        try {
            $Action.Status = 'Restoring'
            Save-State
            Write-Event "Preserving newer folder at: $heldNew"
            Rename-Item -LiteralPath $original -NewName $heldName -ErrorAction Stop
        } catch {
            Write-Event "Could not preserve newer folder: $($_.Exception.Message)" 'ERROR'
            return $false
        }
    }
    try {
        if ($Action.Status -ne 'Restoring') {
            $Action.Status = 'Restoring'
            Save-State
        }
        Rename-Item -LiteralPath $backup -NewName ([IO.Path]::GetFileName($original)) -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $original -PathType Container)) {
            throw 'Original folder still missing after restore.'
        }
        $Action.Status = 'Restored'
        Save-State
        Write-Event "Restored: $original" 'OK'
        if ($heldNew) {
            Write-Event "Newer settings have NOT been deleted: $heldNew" 'WARN'
        }
        return $true
    } catch {
        Write-Event "Restore failed for ${original}: $($_.Exception.Message)" 'ERROR'
        # Best-effort reversal if the newer directory was moved aside.
        if ($heldNew -and -not (Test-Path -LiteralPath $original) -and (Test-Path -LiteralPath $heldNew)) {
            try {
                Rename-Item -LiteralPath $heldNew -NewName ([IO.Path]::GetFileName($original)) -ErrorAction Stop
                Write-Event 'Put newer settings back after unsuccessful restore.' 'WARN'
            } catch {
                Write-Event "Could not put newer settings back; inspect: $heldNew" 'ERROR'
            }
        }
        return $false
    }
}

function Stop-EacServices {
    foreach ($serviceName in @('EasyAntiCheat', 'EasyAntiCheat_EOS')) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($null -ne $service -and $service.Status -eq 'Running') {
            try {
                Stop-Service -Name $serviceName -ErrorAction Stop
                Write-Event "Stopped service $serviceName"
            } catch {
                Write-Event "Could not stop ${serviceName}. Close EAC games first: $($_.Exception.Message)" 'WARN'
            }
        }
    }
}

function Reset-EacCache {
    Clear-Host
    Write-Host 'QUICK RESET - only per-user EAC data, NEVER installed service files'
    Write-Host 'Games and launchers should be closed first.'
    if (-not (Confirm-Yes 'Back up and rename EAC user data?')) { return }
    Stop-EacServices
    $targets = @(
        (Join-Path $env:APPDATA 'EasyAntiCheat'),
        (Join-Path $env:APPDATA 'EasyAntiCheat_EOS'),
        (Join-Path $env:LOCALAPPDATA 'EasyAntiCheat'),
        (Join-Path $env:LOCALAPPDATA 'EasyAntiCheat_EOS')
    )
    $changed = 0
    foreach ($target in ($targets | Select-Object -Unique)) {
        if (Backup-Folder -Original $target -Description 'EAC user data') { $changed++ }
    }
    Write-Event "Quick reset finished. Folder backups made: $changed. Verify your game files if EAC still fails."
}

function Get-FixedDrives {
    return @([IO.DriveInfo]::GetDrives() | Where-Object {
        $_.DriveType -eq [IO.DriveType]::Fixed -and $_.IsReady
    } | ForEach-Object { $_.RootDirectory.FullName })
}

function Get-QuickScanRoots {
    $roots = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($drive in (Get-FixedDrives)) {
        foreach ($relative in @(
            'SteamLibrary\steamapps\common',
            'Steam\steamapps\common',
            'Program Files (x86)\Steam\steamapps\common',
            'Program Files\Steam\steamapps\common',
            'Epic Games', 'Games', 'GOG Games', 'XboxGames',
            'EA Games', 'Origin Games',
            'Program Files (x86)\Ubisoft\Ubisoft Game Launcher\games'
        )) {
            $path = Join-Path $drive $relative
            if (Test-Path -LiteralPath $path -PathType Container) { [void]$roots.Add($path) }
        }
    }
    # Steam libraries can be anywhere, not just on C: or in SteamLibrary.
    $vdfCandidates = @()
    foreach ($drive in (Get-FixedDrives)) {
        foreach ($relative in @('Program Files (x86)\Steam\steamapps\libraryfolders.vdf',
                'Program Files\Steam\steamapps\libraryfolders.vdf',
                'Steam\steamapps\libraryfolders.vdf')) {
            $vdfCandidates += (Join-Path $drive $relative)
        }
    }
    foreach ($vdf in ($vdfCandidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $vdf -PathType Leaf)) { continue }
        try {
            $contents = Get-Content -LiteralPath $vdf -Raw -Encoding UTF8
            foreach ($match in [regex]::Matches($contents, '"path"\s+"([^"]+)"', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                $library = $match.Groups[1].Value.Replace('\\', '\')
                $root = Join-Path $library 'steamapps\common'
                if (Test-Path -LiteralPath $root -PathType Container) { [void]$roots.Add($root) }
            }
        } catch { Write-Event "Could not parse Steam library map: $vdf" 'WARN' }
    }
    # Epic Games installer manifests include the real location on any drive.
    $epicManifests = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
    if (Test-Path -LiteralPath $epicManifests -PathType Container) {
        foreach ($manifest in (Get-ChildItem -LiteralPath $epicManifests -File -Filter '*.item' -ErrorAction SilentlyContinue)) {
            try {
                $metadata = Get-Content -LiteralPath $manifest.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $path = [string]$metadata.InstallLocation
                if ($path -and (Test-Path -LiteralPath $path -PathType Container)) {
                    [void]$roots.Add($path)
                }
            } catch { }
        }
    }
    return @($roots | ForEach-Object { $_ })
}

function Add-SetupResult {
    param([string]$Path, [string]$GameName,
          [System.Collections.Generic.Dictionary[string,object]]$Results)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $name = [IO.Path]::GetFileName($Path)
    if ($name -notin @('EasyAntiCheat_EOS_Setup.exe','EasyAntiCheat_Setup.exe')) { return }
    $full = [IO.Path]::GetFullPath($Path)
    if ($Results.ContainsKey($full)) { return }
    $type = if ($name -eq 'EasyAntiCheat_EOS_Setup.exe') { 'EOS' } else { 'Legacy' }
    $Results.Add($full, [pscustomobject]@{ Name=$GameName; Type=$type; Setup=$full })
}

function Search-GameInstall {
    param([string]$GameDir, [System.Collections.Generic.Dictionary[string,object]]$Results)
    $name = Split-Path -Path $GameDir -Leaf
    $subdirs = @('', 'EasyAntiCheat', 'EasyAntiCheat_EOS',
        'Binaries\Win64\EasyAntiCheat',
        'FortniteGame\Binaries\Win64\EasyAntiCheat',
        'bin\EasyAntiCheat', 'Engine\Binaries\ThirdParty\EasyAntiCheat')
    foreach ($folder in $subdirs) {
        $base = if ($folder) { Join-Path $GameDir $folder } else { $GameDir }
        foreach ($file in @('EasyAntiCheat_EOS_Setup.exe','EasyAntiCheat_Setup.exe')) {
            Add-SetupResult -Path (Join-Path $base $file) -GameName $name -Results $Results
        }
    }
}

function Find-EacGames {
    param([switch]$FullScan, [string]$ManualPath)
    $results = [System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($ManualPath) {
        $inputPath = $ManualPath.Trim().Trim('"')
        if (Test-Path -LiteralPath $inputPath -PathType Leaf) {
            Add-SetupResult -Path $inputPath -GameName 'Selected installer' -Results $results
        } elseif (Test-Path -LiteralPath $inputPath -PathType Container) {
            Write-Event "Searching supplied folder: $inputPath"
            Search-GameInstall -GameDir $inputPath -Results $results
            foreach ($file in (Get-ChildItem -LiteralPath $inputPath -File -Recurse -Filter 'EasyAntiCheat*Setup.exe' -ErrorAction SilentlyContinue)) {
                Add-SetupResult -Path $file.FullName -GameName ([IO.Path]::GetFileName($inputPath.TrimEnd('\'))) -Results $results
            }
        } else {
            Write-Event "Path does not exist: $inputPath" 'WARN'
        }
    } elseif ($FullScan) {
        foreach ($drive in (Get-FixedDrives)) {
            Write-Event "Deep scanning $drive (Ctrl+C cancels; large drives can take a while)"
            foreach ($file in (Get-ChildItem -LiteralPath $drive -File -Recurse -Filter 'EasyAntiCheat*Setup.exe' -ErrorAction SilentlyContinue)) {
                $dir = Split-Path -Path $file.DirectoryName -Parent
                $name = if ($dir) { Split-Path -Path $dir -Leaf } else { 'EAC location' }
                Add-SetupResult -Path $file.FullName -GameName $name -Results $results
            }
        }
    } else {
        foreach ($root in (Get-QuickScanRoots)) {
            # Epic manifest entries point directly at a game; library roots contain games.
            Search-GameInstall -GameDir $root -Results $results
            foreach ($game in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
                if (($game.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                Search-GameInstall -GameDir $game.FullName -Results $results
            }
        }
    }
    return @($results.Values | Sort-Object Name, Setup)
}

function Invoke-EacSetup {
    param([psobject]$Game)
    $setup = [string]$Game.Setup
    if (-not (Test-Path -LiteralPath $setup -PathType Leaf)) {
        Write-Event "Installer no longer exists: $setup" 'ERROR'
        return
    }
    Write-Host "`nSelected: $($Game.Name) [$($Game.Type)]"
    Write-Host "Executable: $setup"
    Write-Host 'Close the game and its launcher before proceeding.'
    $argument = $null
    if ($Game.Type -eq 'EOS') {
        Write-Host '  [1] Repair EAC EOS service (recommended)'
        Write-Host '  [2] Install/re-register this game product (requires Settings.json)'
        Write-Host '  [0] Cancel'
        $choice = (Read-Host 'Choose').Trim()
        if ($choice -eq '1') { $argument = @('repair') }
        elseif ($choice -eq '2') {
            $settingsPath = Join-Path ([IO.Path]::GetDirectoryName($setup)) 'Settings.json'
            if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
                Write-Event 'Settings.json is missing. Use the launcher to verify game files instead.' 'WARN'
                return
            }
            try {
                $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $productId = [string]$settings.productid
                if ($productId -notmatch '^[a-zA-Z0-9_-]{3,128}$') {
                    throw 'Invalid productid in Settings.json.'
                }
            } catch {
                Write-Event "Cannot read valid game product ID: $($_.Exception.Message)" 'ERROR'
                return
            }
            $argument = @('install', $productId)
        } else { return }
    } else {
        Write-Host 'Legacy EAC: the graphical installer will open; choose Repair Service.'
        if (-not (Confirm-Yes 'Launch the legacy setup program?')) { return }
    }
    if (-not (Confirm-Yes 'Run the selected EAC installer as administrator?')) { return }
    try {
        $options = @{ FilePath=$setup; WorkingDirectory=[IO.Path]::GetDirectoryName($setup);
            Wait=$true; PassThru=$true; ErrorAction='Stop' }
        if ($null -ne $argument) { $options.ArgumentList = $argument }
        $process = Start-Process @options
        if ($Game.Type -eq 'EOS') {
            if ($process.ExitCode -eq 0) {
                Write-Event 'EAC EOS installer returned exit code 0. Test the game; service repair does not guarantee every issue is fixed.' 'OK'
            } else {
                Write-Event "EAC EOS installer failed; exit code $($process.ExitCode). Verify game files in the launcher." 'ERROR'
            }
        } else {
            Write-Event 'Legacy installer closed. Confirm the repair in its UI, then test the game.'
        }
    } catch {
        Write-Event "EAC installer could not start: $($_.Exception.Message)" 'ERROR'
    }
}

function Repair-GameMenu {
    Clear-Host
    Write-Host 'FIND AND REPAIR INSTALLED EASY ANTI-CHEAT'
    Write-Host '  [1] Quick multi-drive game-library scan'
    Write-Host '  [2] Deep scan every local fixed drive (slower)'
    Write-Host '  [3] Enter a game folder or EAC setup path'
    Write-Host '  [0] Cancel'
    $choice = (Read-Host 'Choose').Trim()
    $games = @()
    switch ($choice) {
        '1' { $games = @(Find-EacGames) }
        '2' { $games = @(Find-EacGames -FullScan) }
        '3' {
            $path = Read-Host 'Full path to game folder or EAC setup executable'
            if ($path.Trim()) { $games = @(Find-EacGames -ManualPath $path) }
        }
        default { return }
    }
    if ($games.Count -eq 0) {
        Write-Event 'No game EAC installers found. Use a manual folder or verify game files in your launcher.' 'WARN'
        return
    }
    Write-Host "`nFound $($games.Count) EAC installer(s):"
    for ($i=0; $i -lt $games.Count; $i++) {
        Write-Host ('  [{0}] {1} ({2})' -f ($i+1), $games[$i].Name, $games[$i].Type)
        Write-Host ('      {0}' -f $games[$i].Setup)
    }
    $index = Select-Index -Count $games.Count
    if ($index -ge 0) { Invoke-EacSetup -Game $games[$index] }
}

function Reset-UnrealConfig {
    Clear-Host
    Write-Host 'UNREAL ENGINE CONFIG RESET (no save-game files touched)'
    $configs = @()
    foreach ($game in (Get-ChildItem -LiteralPath $env:LOCALAPPDATA -Directory -ErrorAction SilentlyContinue)) {
        if (($game.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        foreach ($configName in @('WindowsClient','Windows','WindowsNoEditor')) {
            $candidate = Join-Path $game.FullName ("Saved\Config\$configName")
            if (Test-Path -LiteralPath $candidate -PathType Container) {
                $configs += [pscustomobject]@{ Name=$game.Name; Config=$candidate }
            }
        }
    }
    if ($configs.Count -eq 0) {
        Write-Event 'No Unreal Engine config folders detected under LocalAppData.'
        return
    }
    for ($i=0; $i -lt $configs.Count; $i++) {
        Write-Host ('  [{0}] {1} - {2}' -f ($i+1), $configs[$i].Name, $configs[$i].Config)
    }
    $index = Select-Index -Count $configs.Count
    if ($index -lt 0) { return }
    Write-Host 'This will reset graphics, controls, and preferences when the game next starts.' -ForegroundColor Yellow
    Write-Host 'The old settings will be kept in a sibling backup.'
    if (-not (Confirm-Yes "Back up settings for $($configs[$index].Name)?")) { return }
    [void](Backup-Folder -Original $configs[$index].Config -Description ('Unreal config: ' + $configs[$index].Name))
}

function Get-AdapterByGuid {
    param([string]$Guid)
    return (Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object {
        ([string]$_.InterfaceGuid) -ieq $Guid
    } | Select-Object -First 1)
}

function Restore-IPv6Action {
    param([psobject]$Action)
    try {
        $adapter = Get-AdapterByGuid -Guid ([string]$Action.AdapterGuid)
        if ($null -eq $adapter) {
            Write-Event "Adapter no longer present: $($Action.AdapterName). IPv6 unchanged." 'ERROR'
            return $false
        }
        $binding = Get-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -ErrorAction Stop
        if (-not $binding.Enabled) {
            Enable-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -Confirm:$false -ErrorAction Stop
            $binding = Get-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -ErrorAction Stop
            if (-not $binding.Enabled) { throw 'IPv6 still disabled after attempting to enable it.' }
        }
        $Action.Status = 'Restored'
        Save-State
        Write-Event "IPv6 enabled (previous state restored) on: $($adapter.Name)" 'OK'
        return $true
    } catch {
        Write-Event "Could not restore IPv6: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Change-IPv6 {
    Write-Host "`nMicrosoft recommends leaving IPv6 enabled for normal Windows operation." -ForegroundColor Yellow
    Write-Host 'Disabling a network binding may interrupt connectivity. Try game-file repair first.'
    $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' } | Sort-Object Name)
    if ($adapters.Count -eq 0) {
        Write-Event 'No active network adapters available.' 'WARN'
        return
    }
    for ($i=0; $i -lt $adapters.Count; $i++) {
        $binding = Get-NetAdapterBinding -Name $adapters[$i].Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
        $state = if ($binding) { if ($binding.Enabled) { 'Enabled' } else { 'Disabled' } } else { 'Unknown' }
        Write-Host ('  [{0}] {1} (IPv6 {2})' -f ($i+1), $adapters[$i].Name, $state)
    }
    $index = Select-Index -Count $adapters.Count
    if ($index -lt 0) { return }
    $adapter = $adapters[$index]
    $guid = [string]$adapter.InterfaceGuid
    if ([string]::IsNullOrWhiteSpace($guid)) {
        Write-Event 'This adapter has no stable interface GUID; refusing to change IPv6.' 'WARN'
        return
    }
    $previous = @(Get-ActiveActions | Where-Object {
        $_.Kind -eq 'IPv6' -and $_.AdapterGuid -ieq $guid
    })
    if ($previous.Count -gt 0) {
        Write-Event 'This adapter already has an outstanding tracked IPv6 change. Use Restore instead.' 'WARN'
        return
    }
    $binding = Get-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -ErrorAction Stop
    if (-not $binding.Enabled) {
        Write-Event "IPv6 is already disabled on $($adapter.Name). Leaving it unchanged and untracked." 'WARN'
        return
    }
    if ((Read-Host 'Type DISABLE (uppercase) to temporarily disable IPv6') -cne 'DISABLE') { return }
    $action = [pscustomobject]@{
        Id = [Guid]::NewGuid().ToString('N')
        Kind = 'IPv6'
        Status = 'Pending'
        Description = 'IPv6 binding on adapter'
        AdapterGuid = $guid
        AdapterName = [string]$adapter.Name
        PreviousEnabled = $true
        CreatedAt = (Get-Date).ToString('o')
    }
    try {
        Add-Action $action # Persistent intent survives a reboot / interruption.
        Disable-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -Confirm:$false -ErrorAction Stop
        $after = Get-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -ErrorAction Stop
        if ($after.Enabled) { throw 'IPv6 still enabled after requested change.' }
        $action.Status = 'Active'
        Save-State
        Write-Event "Temporarily disabled IPv6 on $($adapter.Name). Restore via menu 6." 'OK'
    } catch {
        Write-Event "IPv6 change failed or could not be verified: $($_.Exception.Message)" 'ERROR'
        Write-Event 'Use menu 6 to verify and restore the tracked original state.' 'WARN'
    }
}

function Network-Menu {
    Clear-Host
    Write-Host 'NETWORK TROUBLESHOOTING (OPTIONAL)'
    Write-Host '  [1] Flush Windows DNS resolver cache'
    Write-Host '  [2] Advanced: temporarily disable IPv6 on one adapter'
    Write-Host '  [0] Cancel'
    $choice = (Read-Host 'Choose').Trim()
    switch ($choice) {
        '1' {
            try {
                & ipconfig.exe /flushdns
                if ($LASTEXITCODE -ne 0) { throw "ipconfig exit code $LASTEXITCODE" }
                Write-Event 'DNS resolver cache flushed.' 'OK'
            } catch { Write-Event "DNS flush failed: $($_.Exception.Message)" 'ERROR' }
        }
        '2' {
            try { Change-IPv6 } catch { Write-Event "Adapter query failed: $($_.Exception.Message)" 'ERROR' }
        }
    }
}

function Repair-Windows {
    Clear-Host
    Write-Host 'WINDOWS REPAIR - DISM followed by SFC'
    Write-Host 'These Windows tools modify system files and can take considerable time.'
    if (-not (Confirm-Yes 'Run DISM RestoreHealth and sfc /scannow?')) { return }
    try {
        Write-Event 'Starting DISM /Online /Cleanup-Image /RestoreHealth'
        & dism.exe /Online /Cleanup-Image /RestoreHealth
        $dismCode = $LASTEXITCODE
        if ($dismCode -ne 0) { Write-Event "DISM exit code: $dismCode (not successful)." 'ERROR' }
        else { Write-Event 'DISM returned exit code 0.' 'OK' }
        Write-Event 'Starting sfc /scannow'
        & sfc.exe /scannow
        $sfcCode = $LASTEXITCODE
        if ($sfcCode -ne 0) { Write-Event "SFC exit code: $sfcCode (review SFC output)." 'WARN' }
        else { Write-Event 'SFC returned exit code 0; check its reported result above.' 'OK' }
        Write-Event 'Windows checks finished. Restart the PC if repairs were made.'
    } catch {
        Write-Event "Windows repair did not complete: $($_.Exception.Message)" 'ERROR'
    }
}

function Restore-Tracked {
    Clear-Host
    $active = @(Get-ActiveActions)
    Write-Host 'RESTORE TRACKED CHANGES'
    Write-Host 'Only folders and IPv6 changed by THIS version can be restored here.'
    Write-Host 'This cannot reverse EAC service installer runs, DISM/SFC or DNS flushing.'
    if ($active.Count -eq 0) {
        Write-Event 'No outstanding tracked changes.'
        return
    }
    for ($i=0; $i -lt $active.Count; $i++) {
        $destination = if ($active[$i].Kind -eq 'Folder') { $active[$i].Original } else { $active[$i].AdapterName }
        Write-Host ('  {0}. {1}: {2}' -f ($i+1), $active[$i].Kind, $destination)
    }
    if (-not (Confirm-Yes "Attempt to restore all $($active.Count) tracked changes?")) { return }
    $restored = 0
    $skipped = 0
    # Reverse sequence handles dependent folder changes safely.
    for ($i=$active.Count-1; $i -ge 0; $i--) {
        $action = $active[$i]
        $ok = $false
        if ($action.Kind -eq 'Folder') { $ok = Restore-FolderAction -Action $action }
        elseif ($action.Kind -eq 'IPv6') { $ok = Restore-IPv6Action -Action $action }
        if ($ok) { $restored++ } else { $skipped++ }
    }
    Write-Event "Restore finished: $restored restored; $skipped skipped or unresolved. No folders were deleted."
}

function Show-Diagnostics {
    Clear-Host
    Write-Host 'STATUS / JOURNAL'
    Write-Host ('Journal: {0}' -f $script:StatePath)
    Write-Host ('Activity log: {0}' -f $script:LogPath)
    $active = @(Get-ActiveActions)
    Write-Host ('Outstanding reversible changes: {0}' -f $active.Count)
    foreach ($action in $active) {
        if ($action.Kind -eq 'Folder') {
            Write-Host ('  Folder: {0}' -f $action.Original)
            Write-Host ('  Backup: {0}' -f $action.Backup)
        } elseif ($action.Kind -eq 'IPv6') {
            Write-Host ('  IPv6: {0} (previously enabled)' -f $action.AdapterName)
        }
    }
    foreach ($serviceName in @('EasyAntiCheat','EasyAntiCheat_EOS')) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($null -eq $service) { Write-Host "  Service $serviceName : not installed" }
        else { Write-Host ('  Service {0}: {1}' -f $serviceName, $service.Status) }
    }
    Write-Host 'Defender exclusions: NEVER added or removed by this version.'
    Write-Host 'NOTE: If you previously ran the original batch tool, its older backups'
    Write-Host 'and Defender exclusions are not in this version''s journal.'
    if ((Read-Host 'Open the journal folder in Explorer? [y/N]') -match '^[yY]$') {
        Start-Process -FilePath explorer.exe -ArgumentList ('"{0}"' -f $script:DataRoot) | Out-Null
    }
}

function Invoke-SelfTest {
    Write-Host 'Running local backup/restore self-tests (no Windows settings touched)...'
    $source = Join-Path $script:DataRoot 'SampleGame\Saved\Config\WindowsClient'
    New-Item -Path $source -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $source 'Game.ini') -Value 'old-config' -Encoding ASCII
    if (-not (Backup-Folder -Original $source -Description 'self-test')) { throw 'Test backup failed' }
    $action = @(Get-ActiveActions)[0]
    if (Test-Path -LiteralPath $source) { throw 'Original was not renamed' }
    if (-not (Test-Path -LiteralPath (Join-Path $action.Backup 'Game.ini'))) { throw 'Backup lost data' }
    New-Item -Path $source -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $source 'New.ini') -Value 'new-config' -Encoding ASCII
    if (-not (Restore-FolderAction -Action $action -PreserveConflictAutomatically)) { throw 'Test restore failed' }
    if ((Get-Content -LiteralPath (Join-Path $source 'Game.ini') -Raw).Trim() -ne 'old-config') {
        throw 'Old content not restored'
    }
    $parent = Split-Path $source -Parent
    $newer = @(Get-ChildItem -LiteralPath $parent -Directory -Filter 'WindowsClient.EACRepairNewer.*')
    if ($newer.Count -ne 1 -or -not (Test-Path -LiteralPath (Join-Path $newer[0].FullName 'New.ini'))) {
        throw 'Newer folder was not preserved'
    }
    if ((Get-ActiveActions).Count -ne 0) { throw 'Journal did not mark restoration' }
    $script:State = $null
    $script:Lock.Dispose()
    $script:Lock = $null
    Remove-Item -LiteralPath $script:DataRoot -Recurse -Force
    Write-Host 'PASS: atomic backup, journal tracking, conflict-safe restore, newer-settings preservation.' -ForegroundColor Green
}

function Start-MainMenu {
    while ($true) {
        Clear-Host
        Write-Host '=================================================================='
        Write-Host '       EAC REPAIR & RESTORE v2.0 - Windows 10 / 11'
        Write-Host '=================================================================='
        Write-Host '  [1] Quick reset: back up EAC user data'
        Write-Host '  [2] Multi-drive scan + repair one game''s EAC service'
        Write-Host '  [3] Reset one Unreal Engine config (backed up)'
        Write-Host '  [4] Network: flush DNS / advanced IPv6 workaround'
        Write-Host '  [5] Windows repair: DISM + SFC'
        Write-Host '  [6] Restore tracked folder and IPv6 changes'
        Write-Host '  [7] Diagnostics / view backup journal'
        Write-Host '  [0] Exit'
        Write-Host '=================================================================='
        Write-Host ('  Journal: {0}' -f $script:DataRoot)
        Write-Host ('  Pending changes: {0}' -f @(Get-ActiveActions).Count)
        $choice = (Read-Host 'Select an option [0-7]').Trim()
        try {
            switch ($choice) {
                '1' { Reset-EacCache }
                '2' { Repair-GameMenu }
                '3' { Reset-UnrealConfig }
                '4' { Network-Menu }
                '5' { Repair-Windows }
                '6' { Restore-Tracked }
                '7' { Show-Diagnostics }
                '0' { return }
                default { Write-Host 'Please select 0-7.' }
            }
        } catch {
            Write-Event "Unexpected error, existing backups kept: $($_.Exception.Message)" 'ERROR'
        }
        Pause-Menu
    }
}

try {
    Initialize-State
    if ($SelfTest) { Invoke-SelfTest }
    else { Start-MainMenu }
} catch {
    Write-Host "FATAL: $($_.Exception.Message)" -ForegroundColor Red
    if (-not $SelfTest) { [void](Read-Host 'Press Enter to exit') }
    exit 1
} finally {
    if ($null -ne $script:Lock) { $script:Lock.Dispose() }
}
