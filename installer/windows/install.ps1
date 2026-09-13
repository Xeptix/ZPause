<#
    ZPause Manager -- every game ZPause runs on.

    Black Ops II, Black Ops and World at War on Plutonium; Black Ops III on
    BOIII, T7x or the t7-compiler; Black Ops 4 on Project BO4 / Shield.

    Finds each game you have, shows what is already there, and installs,
    updates or removes ZPause for any of them. It can fetch the latest release from GitHub,
    and keep a copy of itself on this PC so you never have to go looking for
    the download again.

    It only ever writes or removes zpause.gsc, at paths it found itself. It
    never deletes a folder it did not create, and nothing leaves this
    machine unless you say yes to a version check.

    Run it:  install.bat

    It also takes arguments, so one line can do the whole job:

        install.bat -Find                 show what it detects, change nothing
        install.bat -Install -Yes         install, asking nothing
        install.bat -Uninstall -Yes       remove every copy it can find
        install.bat -List                 what is installed, then stop
        install.bat -Configure            open the settings editor
        install.bat -Game t8              skip the "which one?" question
        install.bat -To "D:\Plutonium"    skip the "where?" question
#>
param(
    [switch]$Find,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$List,
    [switch]$Configure,
    [switch]$Yes,
    [switch]$NoColour,
    [switch]$NoColor,
    [string]$Game,
    [string]$To
)

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path

$script:AssumeYes = [bool]$Yes
# Plain output: no colour, and a progress bar that prints lines instead of
# redrawing one, so a transcript pasted into a forum post reads properly.
# NO_COLOR is the usual environment convention; both spellings of the
# switch are taken because both get typed.
$script:LastTenth = -1
$script:Plain = [bool]$NoColour -or [bool]$NoColor -or
                ($null -ne $env:NO_COLOR -and $env:NO_COLOR -ne '')
$script:Offline = $false
$script:RunStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:BackupN = 0
$script:RefCache = @{}

# The window is the whole interface, so it is worth naming, and worth being
# wide enough that the installed-versions table does not wrap. Both are best
# effort -- a host that refuses either is not an error worth reporting.
try {
    $Host.UI.RawUI.WindowTitle = 'ZPause Manager'
    $size = $Host.UI.RawUI.WindowSize
    if ($size.Width -lt 84) {
        $want = [Math]::Min(84, $Host.UI.RawUI.MaxPhysicalWindowSize.Width)
        $buffer = $Host.UI.RawUI.BufferSize
        if ($buffer.Width -lt $want) {
            $buffer.Width = $want
            $Host.UI.RawUI.BufferSize = $buffer
        }
        $size.Width = $want
        $Host.UI.RawUI.WindowSize = $size
    }
} catch {}

function Tint($c) {
    if ($script:Plain) { return 'Gray' }
    return $c
}
function Say($t, $c = 'Gray') { Write-Host "  $t" -ForegroundColor (Tint $c) }
function Blank { Write-Host '' }
function Head($t) {
    Write-Host ''
    Write-Host "  $t" -ForegroundColor (Tint Cyan)
    Write-Host ('  ' + ('-' * $t.Length)) -ForegroundColor (Tint DarkCyan)
}

# Join-Path validates the drive and throws when it is gone; a Steam library
# on a drive since removed is common enough to matter. Combine does not care.
function Path-Join($a, $b) {
    if (-not $a) { return $null }
    try { return [System.IO.Path]::Combine($a, $b) } catch { return $null }
}
function Test-Here($p) {
    if (-not $p) { return $false }
    try { return (Test-Path -LiteralPath $p) } catch { return $false }
}
function Read-Line($prompt) {
    # Read-Host hands back $null once stdin is closed, and throws under
    # -NonInteractive. Either way nobody is there to answer, so stop with a
    # line naming the flags that would have, rather than default an answer
    # or fall over on the next .Trim().
    $a = $null
    try { $a = Read-Host $prompt } catch { $a = $null }
    if ($null -eq $a) {
        Blank
        Say 'No terminal to read from -- stopping here.' Red
        Say 'For a run that asks nothing: -Install -Yes (add -Game and -To as needed),' DarkGray
        Say '-Uninstall -Yes, -List or -Find.' DarkGray
        Blank
        exit 2
    }
    return $a
}
function Ask($q, $default = 'n') {
    if ($default -eq 'y') { $hint = '[Y/n]' } else { $hint = '[y/N]' }
    # -Yes is consent given on the command line. The question is still
    # printed, so a scripted run reads like an interactive one.
    if ($script:AssumeYes) {
        Write-Host "  $q $hint y" -ForegroundColor (Tint DarkGray)
        return $true
    }
    $a = Read-Line "  $q $hint"
    if (-not $a) { return ($default -eq 'y') }
    return ($a.Trim().ToLower().StartsWith('y'))
}

# ------------------------------------------------- where things are kept
$StateDir = Path-Join $env:LOCALAPPDATA 'ZPause'
$CacheDir = Path-Join $StateDir 'cache'
$SettingsFile = Path-Join $StateDir 'settings.txt'

function Load-Settings {
    $s = @{}
    if (Test-Here $SettingsFile) {
        foreach ($line in (Get-Content -LiteralPath $SettingsFile)) {
            if ($line -match '^\s*([a-z_]+)\s*=\s*(.+?)\s*$') { $s[$Matches[1]] = $Matches[2] }
        }
    }
    return $s
}
function Save-Settings($s) {
    try {
        if (-not (Test-Here $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
        ($s.Keys | Sort-Object | ForEach-Object { "$_=" + $s[$_] }) |
            Set-Content -LiteralPath $SettingsFile -Encoding ASCII
    } catch {}
}
$Settings = Load-Settings

# The Black Ops 4 installer this replaced remembered its game folder in a
# file of its own. Take it over once, so nobody is asked again for a path
# they already gave.
$OldT8Path = Path-Join $StateDir 't8-path.txt'
if (-not $Settings['bo4'] -and (Test-Here $OldT8Path)) {
    try {
        $old = (Get-Content -LiteralPath $OldT8Path -TotalCount 1).Trim()
        if ($old -and (Test-Here (Path-Join $old 'BlackOps4.exe'))) {
            $Settings['bo4'] = $old
            Save-Settings $Settings
        }
    } catch {}
}

# ------------------------------------------------- the log
# Append-only, one line per file written or removed. It exists so "it did
# not work" can be answered with something concrete instead of a memory.
$LogFile = Path-Join $StateDir 'zpause.log'
function Log($what, $detail) {
    try {
        if (-not (Test-Here $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
        Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value (
            '{0}  {1,-10}  {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $what, $detail)
    } catch {}
}

# ------------------------------------------------- backups
# The version library can put back any version this ever downloaded. It
# cannot put back a file somebody edited by hand, so the file being
# overwritten is copied out first, with an index saying where it came from
# -- a pile of identically named scripts cannot be restored without one.
$BackupDir = Path-Join $StateDir 'backups'
$BackupIndex = Path-Join $BackupDir 'index.txt'

function Backup-File($path) {
    if (-not (Test-Here $path)) { return }
    try {
        $dir = Path-Join $BackupDir $script:RunStamp
        if (-not (Test-Here $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $script:BackupN++
        $name = '{0:d2}.gsc' -f $script:BackupN
        Copy-Item -LiteralPath $path -Destination (Path-Join $dir $name) -Force
        Add-Content -LiteralPath $BackupIndex -Encoding UTF8 -Value (
            '{0}|{1}|{2}|{3}' -f $script:RunStamp, $name, (Read-Version $path), $path)
    } catch {}
}

function Pretty-Stamp($s) {
    if ($s -match '^([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{2})([0-9]{2})') {
        return '{0}-{1}-{2} {3}:{4}' -f $Matches[1], $Matches[2], $Matches[3], $Matches[4], $Matches[5]
    }
    return $s
}

function Get-Backups {
    $rows = @()
    if (-not (Test-Here $BackupIndex)) { return @($rows) }
    foreach ($line in (Get-Content -LiteralPath $BackupIndex)) {
        $p = $line -split '\|', 4
        if ($p.Count -ne 4) { continue }
        $file = Path-Join (Path-Join $BackupDir $p[0]) $p[1]
        if (-not (Test-Here $file)) { continue }
        $rows += [pscustomobject]@{ Stamp = $p[0]; File = $file; Version = $p[2]; Dest = $p[3] }
    }
    return @($rows)
}

# ------------------------------------------------- the download root
# This lives in installer/windows/, so the payload and the manifest are two
# levels up. Walk until zpause.release turns up; if it never does, this is a
# kept copy with no mod files beside it and everything comes from GitHub.
function Find-Root($from) {
    $r = $from
    for ($i = 0; $i -lt 5; $i++) {
        if (Test-Here (Path-Join $r 'zpause.release')) { return $r }
        $parent = Split-Path -Parent $r
        if (-not $parent -or $parent -eq $r) { return $null }
        $r = $parent
    }
    return $null
}

# A download carries the drop-in tree. The source folder it is built from
# carries the script flat beside the manifest instead, and running the
# installer out of that folder should install that script -- it is the build
# being tested. Both shapes are accepted; everything downstream asks
# First-Script rather than assuming a folder.
function Source-Of($root) {
    # A download carries one or more drop-in trees; a source folder carries
    # the script flat beside the manifest. Whichever it is, this is the
    # thing Payload-For reads the per-game files out of.
    if (-not $root) { return $null }
    foreach ($tree in @('Plutonium', 'Black Ops III', 'zpause')) {
        if (Test-Here (Path-Join $root $tree)) { return $root }
    }
    foreach ($flat in @('zpause.gsc', 'zpause_t7x.gscc', 'metadata.json')) {
        if (Test-Here (Path-Join $root $flat)) { return $root }
    }
    return $null
}

function Is-Download($root) {
    # Only a real download has a drop-in tree, and only a real download has
    # a manifest worth checking: SHA256SUMS describes the zip's paths, which
    # a source folder does not have.
    if (-not $root) { return $false }
    foreach ($tree in @('Plutonium', 'Black Ops III', 't7x', 'zpause')) {
        if (Test-Here (Path-Join $root $tree)) { return $true }
    }
    return $false
}

function Read-Release($root) {
    $r = @{}
    $f = Path-Join $root 'zpause.release'
    if (Test-Here $f) {
        foreach ($line in (Get-Content -LiteralPath $f)) {
            if ($line -match '^\s*([a-z_]+)\s*=\s*(.+?)\s*$') { $r[$Matches[1]] = $Matches[2] }
        }
    }
    return $r
}

$Root = Find-Root $Here
if ($Root) { $Release = Read-Release $Root } else { $Release = @{} }
$Payload = Source-Of $Root
$HomeRoot = $Root

# ------------------------------------------------- what can be downloaded
# Used when this installer arrived on its own, with no mod files beside it:
# it can still fetch any of them. T7 is here because it is a ZPause release
# like the rest; it installs into Black Ops III rather than into Plutonium,
# so it is handed to its own installer once it has been unpacked.
$CATALOG = @(
    @{ Key = 'bundle'; Name = 'ZPause [Treyarch Bundle]'; Repo = 'Xeptix/ZPause'
       Asset = 'ZPause [Treyarch Bundle] v'; What = 'all five games in one download' }
    @{ Key = 't6'; Name = 'ZPause T6'; Repo = 'Xeptix/ZPause'
       Asset = 'ZPause T6 v'; What = 'Black Ops II only' }
    @{ Key = 't5'; Name = 'ZPause T5'; Repo = 'Xeptix/ZPauseT5'
       Asset = 'ZPause T5 v'; What = 'Black Ops only' }
    @{ Key = 't4'; Name = 'ZPause T4'; Repo = 'Xeptix/ZPauseT4'
       Asset = 'ZPause T4 v'; What = 'World at War only' }
    @{ Key = 't7'; Name = 'ZPause T7'; Repo = 'Xeptix/ZPauseT7'
       Asset = 'ZPause T7 v'; What = 'Black Ops III only' }
    @{ Key = 't8'; Name = 'ZPause T8'; Repo = 'Xeptix/ZPauseT8'
       Asset = 'ZPause T8 v'; What = 'Black Ops 4 only' }
)

# Where the list of other mods lives. It is optional: when the file is not
# in the repo, nothing is shown and nothing is said about it.
$HOME_REPO = 'Xeptix/ZPause'
$OTHER_MODS = 'OTHERMODS.MD'

# ------------------------------------------------- version arithmetic
# A public version is X.Y. A development build appends .N.d and is working
# towards X.Y, so it sorts below the release of the same number.
function Ver-Parts($v) {
    if (-not $v) { return $null }
    if ($v -match '^([0-9]+)\.([0-9]+)\.([0-9]+)\.d$') {
        return @([int]$Matches[1], [int]$Matches[2], 0, [int]$Matches[3])
    }
    if ($v -match '^([0-9]+)\.([0-9]+)$') { return @([int]$Matches[1], [int]$Matches[2], 1, 0) }
    return $null
}
function Ver-Compare($a, $b) {
    $x = Ver-Parts $a
    $y = Ver-Parts $b
    if (-not $x -or -not $y) { return 0 }
    for ($i = 0; $i -lt 4; $i++) {
        if ($x[$i] -ne $y[$i]) {
            if ($x[$i] -gt $y[$i]) { return 1 } else { return -1 }
        }
    }
    return 0
}

Write-Host ''
Write-Host '  ZPause Manager' -ForegroundColor (Tint Cyan)
Write-Host '  ==============' -ForegroundColor (Tint DarkCyan)
if ($Release['name']) {
    Say ('{0} v{1}' -f $Release['name'], $Release['version']) DarkGray
} else {
    Say 'no mod files beside this installer -- they can be downloaded' DarkGray
}

# ------------------------------------------------- the games
<#
    One entry per game ZPause runs on, and the family says how it installs,
    because there are three shapes rather than five:

      pluto   loose scripts at fixed paths under one Plutonium folder
      bo3     up to three routes under a Black Ops III folder, one of
              which takes a compiled build rather than the raw script
      bo4     a whole mod folder copied under project-bo4\mods

    Everything past this point -- the manager, the cache, the GitHub
    fetch, backups, the log, the doctor, profiles, the shortcut -- is the
    same for all five and is written once.
#>
$GAMES = @(
    @{ Key = 't6'; Tag = 'T6'; Name = 'Black Ops II';  Family = 'pluto'
       Repo = 'ZPause';   Asset = 'ZPause T6 v' }
    @{ Key = 't5'; Tag = 'T5'; Name = 'Black Ops';     Family = 'pluto'
       Repo = 'ZPauseT5'; Asset = 'ZPause T5 v' }
    @{ Key = 't4'; Tag = 'T4'; Name = 'World at War';  Family = 'pluto'
       Repo = 'ZPauseT4'; Asset = 'ZPause T4 v' }
    @{ Key = 't7'; Tag = 'T7'; Name = 'Black Ops III'; Family = 'bo3'
       Repo = 'ZPauseT7'; Asset = 'ZPause T7 v' }
    @{ Key = 't8'; Tag = 'T8'; Name = 'Black Ops 4';   Family = 'bo4'
       Repo = 'ZPauseT8'; Asset = 'ZPause T8 v' }
)

function Game-For($key) {
    foreach ($g in $GAMES) { if ($g.Key -eq $key) { return $g } }
    return $null
}

function Games-In($family) {
    return @($GAMES | Where-Object { $_.Family -eq $family })
}

<#
    What a folder has to contain to be that family's root, and where to go
    looking. One search serves all three; only this table differs.

    Marker is any-of: a Black Ops III folder may carry BlackOps3.exe, or
    only boiii.exe or t7x.exe if it is a client-only install, and a
    BO3Enhanced setup is the Windows Store build sitting on Steam files.
#>
$FAMILIES = @{
    'pluto' = @{
        Label   = 'Plutonium'
        Markers = @('storage')
        Steam   = @('Plutonium')
        Subs    = @('Plutonium', 'Games\Plutonium', 'Program Files\Plutonium',
                    'Program Files (x86)\Plutonium', 'Steam\Plutonium',
                    'SteamLibrary\Plutonium')
        AppData = @('Plutonium')
        Hint    = 'It is normally in %LOCALAPPDATA%\Plutonium.'
        Needs   = 'a storage folder inside it'
    }
    'bo3' = @{
        Label   = 'Black Ops III'
        Markers = @('BlackOps3.exe', 'boiii.exe', 't7x.exe')
        Steam   = @('steamapps\common\Call of Duty Black Ops III')
        Subs    = @('Call of Duty Black Ops III',
                    'Games\Call of Duty Black Ops III',
                    'COD\Call of Duty Black Ops III',
                    'Call of Duty\Black Ops III',
                    'SteamLibrary\steamapps\common\Call of Duty Black Ops III',
                    'Steam\steamapps\common\Call of Duty Black Ops III',
                    'Program Files (x86)\Steam\steamapps\common\Call of Duty Black Ops III')
        AppData = @()
        Hint    = 'It is the folder with BlackOps3.exe in it.'
        Needs   = 'BlackOps3.exe, boiii.exe or t7x.exe in it'
    }
    'bo4' = @{
        Label   = 'Black Ops 4'
        Markers = @('BlackOps4.exe')
        Steam   = @('steamapps\common\Call of Duty Black Ops 4',
                    'steamapps\common\Call of Duty Black Ops IIII')
        Subs    = @('Call of Duty Black Ops 4', 'BlackOps4',
                    'Games\Call of Duty Black Ops 4', 'Games\BlackOps4',
                    'COD\Call of Duty Black Ops 4', 'COD\BlackOps4',
                    'Call of Duty\Black Ops 4',
                    'SteamLibrary\steamapps\common\Call of Duty Black Ops 4',
                    'Steam\steamapps\common\Call of Duty Black Ops 4')
        AppData = @()
        Hint    = 'It is the folder with BlackOps4.exe in it.'
        Needs   = 'BlackOps4.exe in it'
    }
}

# Steam's own library list beats guessing at drive letters: it names every
# library, including one on a drive that is not where anybody would look.
function Steam-Roots {
    $out = @()
    foreach ($k in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam')) {
        $base = $null
        try {
            $v = Get-ItemProperty -Path $k -ErrorAction Stop
            if ($v.SteamPath) { $base = $v.SteamPath -replace '/', '\' }
            elseif ($v.InstallPath) { $base = $v.InstallPath }
        } catch {}
        if (-not $base) { continue }
        $out += $base
        $vdf = Path-Join $base 'steamapps\libraryfolders.vdf'
        if (-not (Test-Here $vdf)) { continue }
        try { $raw = Get-Content $vdf -Raw -ErrorAction Stop } catch { continue }
        foreach ($m in [regex]::Matches($raw, '"path"\s*"([^"]+)"')) {
            $out += ($m.Groups[1].Value -replace '\\\\', '\')
        }
    }
    return @($out | Select-Object -Unique)
}

function Is-Root($family, $path) {
    if (-not $path) { return $false }
    foreach ($m in $FAMILIES[$family].Markers) {
        if (Test-Here (Path-Join $path $m)) { return $true }
    }
    return $false
}

function Find-Roots($family) {
    $f = $FAMILIES[$family]
    $seen = New-Object System.Collections.ArrayList
    $add = {
        param($p)
        if ((Is-Root $family $p) -and ($seen -notcontains $p)) { [void]$seen.Add($p) }
    }

    foreach ($n in $f.AppData) {
        & $add (Path-Join $env:LOCALAPPDATA $n)
        & $add (Path-Join $env:APPDATA $n)
    }
    foreach ($base in (Steam-Roots)) {
        foreach ($sub in $f.Steam) { & $add (Path-Join $base $sub) }
    }
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if ($d.DriveType -ne 'Fixed' -or -not $d.IsReady) { continue }
        $r = $d.RootDirectory.FullName
        & $add $r
        foreach ($sub in $f.Subs) { & $add (Path-Join $r $sub) }
    }
    return $seen
}

function Choose-Root($family, $found, $forceAsk) {
    $f = $FAMILIES[$family]
    $label = $f.Label

    # A path given on the command line settles it outright.
    if ($To -and -not $forceAsk) {
        $t = $To.Trim().Trim('"')
        # Pointing at the folder that *holds* the install is the common slip.
        foreach ($sub in @('') + $f.Subs) {
            $try = $t
            if ($sub) { $try = Path-Join $t $sub }
            if (Is-Root $family $try) { return $try }
        }
        Say "That is not a $label folder: $To" Red
        return $null
    }

    # A remembered folder wins, so the second run asks nothing at all.
    if (-not $forceAsk -and $Settings[$family] -and (Is-Root $family $Settings[$family])) {
        return $Settings[$family]
    }

    if ($found.Count -eq 1 -and -not $forceAsk) { return $found[0] }
    if ($found.Count -ge 1) {
        Head "$label -- which one?"
        Blank
        for ($i = 0; $i -lt $found.Count; $i++) {
            Write-Host ('    {0}. {1}' -f ($i + 1), $found[$i])
        }
        Say '  0. somewhere else -- I will type the path' DarkGray
        Blank
        $p = Read-Line '  which'
        $idx = 0
        if ([int]::TryParse($p, [ref]$idx) -and $idx -ge 1 -and $idx -le $found.Count) {
            return $found[$idx - 1]
        }
        if ($p.Trim() -ne '0') { Blank; Say 'Not one of the choices.' Red; return $null }
    } else {
        Head $label
        Say "Could not find your $label install." Yellow
        Blank
        Say $f.Hint DarkGray
    }

    Blank
    Say "Paste the full path to your $label folder -- the one with" DarkGray
    Say ($f.Needs + ' -- or press Enter to give up.') DarkGray
    Blank
    $typed = Read-Line '  path'
    if (-not $typed) { return $null }
    $typed = $typed.Trim().Trim('"')
    foreach ($sub in @('') + $f.Subs) {
        $try = $typed
        if ($sub) { $try = Path-Join $typed $sub }
        if (Is-Root $family $try) { return $try }
    }
    Blank
    Say "That folder does not have $($f.Needs), so it is probably not" Red
    Say "your $label install." Red
    return $null
}

# Remembered per family, so finding one game never costs you another.
function Root-For($family, $forceAsk) {
    $root = Choose-Root $family @(Find-Roots $family) $forceAsk
    if ($root -and $Settings[$family] -ne $root) {
        $Settings[$family] = $root
        Save-Settings $Settings
    }
    return $root
}

if ($Find) {
    foreach ($fam in @('pluto', 'bo3', 'bo4')) {
        Head $FAMILIES[$fam].Label
        $hits = @(Find-Roots $fam)
        if ($hits.Count -eq 0) { Say 'none found' DarkGray }
        else { foreach ($p in $hits) { Say $p } }
    }
    Blank
    return
}

# ------------------------------------------------- what is installed
<#
    Every place any of the five games can read ZPause from.

    Family says which root the path hangs off. Kind says what the slot is:
    a file, a folder (Black Ops 4 takes a whole mod folder), or a compiled
    file (T7x loads compiled GSC and nothing else). Black Ops III's loaders
    are optional and independent, so a route there carries the markers
    that say whether that loader is even present.
#>
$SLOTS = @(
    @{ Key = 't6'; Family = 'pluto'; Kind = 'file'; Game = 'T6  Black Ops II'
       Path = 'storage\t6\raw\scripts\zm\zpause.gsc' }
    @{ Key = 't6'; Family = 'pluto'; Kind = 'file'; Game = 'T6  Black Ops II'
       Path = 'storage\t6\scripts\zm\zpause.gsc' }
    @{ Key = 't6'; Family = 'pluto'; Kind = 'file'; Game = 'T6  mod version'
       Path = 'storage\t6\mods\zm_pause\scripts\zm\zpause.gsc' }
    @{ Key = 't5'; Family = 'pluto'; Kind = 'file'; Game = 'T5  Black Ops'
       Path = 'storage\t5\raw\scripts\sp\zpause.gsc' }
    @{ Key = 't4'; Family = 'pluto'; Kind = 'file'; Game = 'T4  World at War'
       Path = 'storage\t4\raw\scripts\sp\zpause.gsc' }
    @{ Key = 't7'; Family = 'bo3'; Kind = 'file'; Game = 'T7  BOIII / Ezz BOIII'
       Path = 'boiii\custom_scripts\zpause.gsc'; Markers = @('boiii.exe', 'boiii')
       Note = 'loose script, no mod slot' }
    # BOIII also reads a second script folder under AppData, the same
    # client's other home. Not under the game root, so it names its own base.
    @{ Key = 't7'; Family = 'bo3'; Kind = 'file'; Game = 'T7  BOIII (AppData)'
       Path = 'custom_scripts\zpause.gsc'; Base = (Path-Join $env:LOCALAPPDATA 'boiii\data')
       Markers = @(); Note = 'the same client, its other script folder' }
    @{ Key = 't7'; Family = 'bo3'; Kind = 'compiled'; Game = 'T7  T7x'
       Path = 't7x\custom_scripts\zpause.gsc'; Markers = @('t7x.exe', 't7x')
       Note = 'compiled build, no mod slot' }
    @{ Key = 't8'; Family = 'bo4'; Kind = 'folder'; Game = 'T8  Black Ops 4'
       Path = 'project-bo4\mods\zpause' }
)

$GAME_NAMES = @{}
foreach ($g in $GAMES) { $GAME_NAMES[$g.Key] = $g.Name }

# The root a family resolved to, or $null if it has not yet. Each is found
# the first time a game in that family is wanted, and remembered from then
# on. Nothing is asked for until a game that needs it is chosen -- a Black
# Ops 4 player should not be stopped at the door with a Plutonium question.
$script:Roots = @{}

function Root-Of($family) {
    if ($script:Roots.ContainsKey($family) -and $script:Roots[$family]) { return $script:Roots[$family] }
    return $null
}

function Root-Quiet($family) {
    # The remembered or the only-found root, without asking anybody.
    # Scanning "what is installed" must never turn into a question.
    $r = Root-Of $family
    if ($r) { return $r }
    if ($Settings[$family] -and (Is-Root $family $Settings[$family])) {
        $script:Roots[$family] = $Settings[$family]
        return $Settings[$family]
    }
    $hits = @(Find-Roots $family)
    if ($hits.Count -eq 1) {
        $script:Roots[$family] = $hits[0]
        $Settings[$family] = $hits[0]
        Save-Settings $Settings
        return $hits[0]
    }
    return $null
}

function Root-Ask($family) {
    # The same, but it may ask -- for when the user has chosen a game in
    # that family and there is no getting on without a folder.
    $r = Root-Quiet $family
    if ($r) { return $r }
    $r = Root-For $family $false
    if ($r) { $script:Roots[$family] = $r }
    return $r
}

function Slot-Base($slot) {
    if ($slot.ContainsKey('Base') -and $slot.Base) { return $slot.Base }
    return (Root-Quiet $slot.Family)
}

function Slot-Path($slot) {
    $base = Slot-Base $slot
    if (-not $base) { return $null }
    return (Path-Join $base $slot.Path)
}

function Slot-Present($slot) {
    # For a Black Ops III route: is that loader even installed? Only the
    # routes whose loader exists are offered, and a route with no markers
    # is judged by its own folder being there.
    if (-not $slot.ContainsKey('Markers')) { return $true }
    $base = Slot-Base $slot
    if (-not $base) { return $false }
    if ($slot.Markers.Count -eq 0) { return (Test-Here $base) }
    foreach ($m in $slot.Markers) {
        if (Test-Here (Path-Join (Root-Quiet $slot.Family) $m)) { return $true }
    }
    return $false
}

$PLUTO = Root-Quiet 'pluto'
if ($PLUTO) {
    Head 'Plutonium'
    Say $PLUTO
}

function Read-Version($file) {
    if (-not (Test-Here $file)) { return $null }
    try {
        $head = (Get-Content -LiteralPath $file -TotalCount 40) -join "`n"
        if ($head -match 'ZPAUSE(?: T\d)? v([0-9][0-9.]*d?)') { return $Matches[1] }
    } catch {}
    return '?'
}

function Slot-Version($slot, $full) {
    if ($slot.Kind -eq 'folder') {
        # What the mod folder holds is compiled, so nothing in it says which
        # version it is. The stamp the installer wrote does.
        if (-not (Test-Here (Path-Join $full 'metadata.json'))) { return $null }
        $stamp = Path-Join $full 'zpause.installed'
        if (Test-Here $stamp) {
            try { return (Get-Content -LiteralPath $stamp -TotalCount 1).Trim() } catch {}
        }
        return '?'
    }
    $v = Read-Version $full
    if ($v -eq '?' -and $slot.Kind -eq 'compiled') {
        # A compiled script only shows a version at all because the build
        # stamp is a string literal, and a release build has no stamp. If
        # it is byte for byte what this download carries, it is this
        # download's version.
        $ref = Payload-For $slot.Key $slot.Kind
        if ($ref -and (Test-Here $ref) -and (Same-File $ref $full) -and $Release['version']) {
            $v = $Release['version']
        }
    }
    return $v
}

function Get-Installed {
    $rows = @()
    foreach ($slot in $SLOTS) {
        $full = Slot-Path $slot
        if (-not $full) { continue }
        $v = Slot-Version $slot $full
        if (-not $v) { continue }
        $rows += [pscustomobject]@{
            Key = $slot.Key; Family = $slot.Family; Kind = $slot.Kind
            Game = $slot.Game; Path = $full; Version = $v
        }
    }
    return @($rows)
}

function Short-Path($row) {
    $base = Root-Of $row.Family
    if ($base -and $row.Path.StartsWith($base)) { return ('...' + $row.Path.Substring($base.Length)) }
    return $row.Path
}

function Show-Installed {
    Head 'Installed'
    $rows = Get-Installed
    if ($rows.Count -eq 0) {
        Say 'ZPause is not installed on this PC yet.' DarkGray
        return @()
    }
    # Something to compare against: the mod files beside us, or whatever the
    # last GitHub check turned up, whichever is newer.
    $ref = $null
    if ($Release['version']) { $ref = $Release['version'] }
    if ($script:LatestVersion -and (Ver-Compare $script:LatestVersion $ref) -gt 0) {
        $ref = $script:LatestVersion
    }
    Blank
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $row = $rows[$i]
        $ver = 'v' + $row.Version
        $known = Ref-For $row.Version $row.Key $row.Kind
        $edited = $false
        if ($row.Kind -ne 'folder') {
            $edited = $known -and -not (Same-File $known $row.Path)
        }
        if ($edited) {
            if (Is-Applied $row.Path) { $ver += ', configured' } else { $ver += ', modified' }
        }
        Write-Host ('    {0}. {1,-24} {2,-18} {3}' -f ($i + 1), $row.Game, $ver, (Short-Path $row)) -ForegroundColor (Tint Gray)
        if ($edited -and (Is-Applied $row.Path)) {
            Write-Host '           carries your saved settings' -ForegroundColor (Tint DarkCyan)
        } elseif ($edited) {
            Write-Host '           does not match that version -- edited since it was installed' -ForegroundColor (Tint Yellow)
        }
        if ($ref) {
            $c = Ver-Compare $row.Version $ref
            if ($c -lt 0) { Write-Host ("           older than v$ref") -ForegroundColor (Tint Yellow) }
            elseif ($c -eq 0 -and -not $edited) { Write-Host '           up to date' -ForegroundColor (Tint Green) }
        }
    }
    return $rows
}

# ------------------------------------------------- downloading
function Fmt-Bytes($n) {
    if ($n -ge 1MB) { return ('{0:N1} MB' -f ($n / 1MB)) }
    if ($n -ge 1KB) { return ('{0:N0} KB' -f ($n / 1KB)) }
    return "$n B"
}

function Show-Progress($got, $total, $started, $done) {
    $width = 28
    if ($total -gt 0) {
        $frac = [double]$got / [double]$total
        if ($frac -gt 1) { $frac = 1 }
        $fill = [int][Math]::Round($frac * $width)
        $bar = ('#' * $fill) + ('-' * ($width - $fill))
        $line = '  [{0}] {1,3:N0}%  {2} of {3}' -f $bar, ($frac * 100),
                (Fmt-Bytes $got), (Fmt-Bytes $total)
    } else {
        $line = '  {0} downloaded' -f (Fmt-Bytes $got)
    }
    $secs = ((Get-Date) - $started).TotalSeconds
    if ($secs -gt 0.5) { $line += '  ' + (Fmt-Bytes ([long]($got / $secs))) + '/s' }
    if ($script:Plain) {
        # One line at a time, so a captured transcript is readable. A bar
        # redrawn with carriage returns is a single unreadable line there.
        if ($done -or ($script:LastTenth -ne [int]($got / [Math]::Max($total, 1) * 10))) {
            $script:LastTenth = [int]($got / [Math]::Max($total, 1) * 10)
            Write-Host $line
        }
        return
    }
    Write-Host ("`r" + $line.PadRight(74)) -NoNewline -ForegroundColor (Tint DarkGray)
    if ($done) { Write-Host '' }
}

function Get-Web($url, $dest, $quiet) {
    # Written by hand rather than with Invoke-WebRequest so the progress is
    # ours: one line with a bar, the size and the rate, instead of a silent
    # wait or PowerShell's own banner.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $res = $null
    $in = $null
    $out = $null
    try {
        $req = [Net.HttpWebRequest]::Create($url)
        $req.UserAgent = 'ZPause-Manager'
        $req.Timeout = 30000
        $res = $req.GetResponse()
        $total = $res.ContentLength
        $in = $res.GetResponseStream()
        $out = [IO.File]::Create($dest)
        $buf = New-Object byte[] 65536
        $got = 0
        $t0 = Get-Date
        $tick = Get-Date
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n)
            $got += $n
            # Ten redraws a second is smooth and costs nothing; redrawing on
            # every 64 KB chunk over a fast line is what makes it flicker.
            if (-not $quiet -and ((Get-Date) - $tick).TotalMilliseconds -ge 100) {
                Show-Progress $got $total $t0 $false
                $tick = Get-Date
            }
        }
        if (-not $quiet) { Show-Progress $got $total $t0 $true }
        return $true
    } catch {
        if (-not $quiet) {
            Write-Host ''
            Net-Problem $_
        }
        return $false
    } finally {
        if ($out) { $out.Close() }
        if ($in) { $in.Close() }
        if ($res) { $res.Close() }
    }
}

function Net-Problem($err) {
    # One line somebody can act on. A 404 is a missing release, not a
    # missing internet, and saying so saves a pointless retry.
    $m = "$($err.Exception.Message)"
    if ($m -match '\(404\)') {
        Say 'That one has no published release yet.' Yellow
        return
    }
    $script:Offline = $true
    Say 'GitHub is not reachable -- you may be offline.' Yellow
    Say 'Everything else here works without it.' DarkGray
}

function Net-Ready {
    # Once a connection has clearly failed, stop trying in the same run.
    if ($script:Offline) {
        Say 'Still offline, so nothing was contacted.' DarkGray
        return $false
    }
    return $true
}

function Norm-Name($s) {
    # Letters and digits, lowercased. Everything else is punctuation that a
    # download can pick up or lose on the way through GitHub.
    return ([regex]::Replace("$s", '[^A-Za-z0-9]', '')).ToLower()
}

function Get-Latest($repo, $assetPrefix) {
    # One call, and only after you have said yes to it.
    if (-not (Net-Ready)) { return $null }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        $api = "https://api.github.com/repos/$repo/releases/latest"
        $r = Invoke-RestMethod -Uri $api -UserAgent 'ZPause-Manager' -TimeoutSec 20
    } catch {
        Net-Problem $_
        return $null
    }
    $ver = $null
    if ("$($r.tag_name)" -match '([0-9]+\.[0-9]+(?:\.[0-9]+\.d)?)') { $ver = $Matches[1] }

    # GitHub rewrites the spaces in an uploaded asset's name, so what goes up
    # as "ZPause T6 v1.3 by Xep.zip" comes back as "ZPause.T6.v1.3.by.Xep.zip".
    # Comparing on letters and digits alone survives that -- and still tells
    # "ZPause T7" apart from "ZPause T7 Workshop", which a looser match would
    # not, and which is the whole reason the prefix exists.
    $want = Norm-Name $assetPrefix
    $asset = $null
    foreach ($a in $r.assets) {
        if ($a.name -like '*.zip' -and (Norm-Name $a.name).StartsWith($want)) { $asset = $a; break }
    }
    if (-not $asset) {
        foreach ($a in $r.assets) { if ($a.name -like '*.zip') { $asset = $a; break } }
    }
    if (-not $asset) {
        Say 'That release has no zip attached to it.' Red
        return $null
    }
    if (-not $ver -and $asset.name -match '[ .]v([0-9]+\.[0-9]+(?:\.[0-9]+\.d)?)[ .]') { $ver = $Matches[1] }
    # A manifest attached to the release itself, if there is one. The
    # manifest inside a zip cannot vouch for the zip.
    $sums = $null
    foreach ($a in $r.assets) {
        if ($a.name -eq 'SHA256SUMS' -or $a.name -like '*.sha256') {
            $sums = $a.browser_download_url
            break
        }
    }
    return [pscustomobject]@{
        Version = $ver
        Name = $asset.name
        Url = $asset.browser_download_url
        Size = [long]$asset.size
        Sums = $sums
    }
}

function Fetch-Payload($latest) {
    # Downloads into the cache and unpacks it there. Returns the extracted
    # folder, which then becomes this session's mod files.
    if (-not (Test-Here $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }
    $zip = Path-Join $CacheDir $latest.Name
    $out = Path-Join $CacheDir ([IO.Path]::GetFileNameWithoutExtension($latest.Name))

    $cached = $false
    if (Test-Here $zip) {
        try { $cached = ((Get-Item -LiteralPath $zip).Length -eq $latest.Size) } catch {}
    }
    if ($cached) {
        Blank
        Say ('Already downloaded: ' + $latest.Name) DarkGray
    } else {
        Blank
        Say ('Downloading {0}  ({1})' -f $latest.Name, (Fmt-Bytes $latest.Size))
        if (-not (Get-Web $latest.Url $zip $false)) { return $null }
    }

    # When the release publishes checksums, the zip is checked before it is
    # opened. Nothing to do when it does not.
    if ($latest.PSObject.Properties.Name -contains 'Sums' -and $latest.Sums) {
        $sf = Path-Join $CacheDir 'SHA256SUMS'
        if (Get-Web $latest.Sums $sf $true) {
            $want = $null
            foreach ($line in (Get-Content -LiteralPath $sf)) {
                if ($line -match '^([0-9a-fA-F]{64})\s+(.+?)\s*$') {
                    if ((Norm-Name $Matches[2]) -eq (Norm-Name $latest.Name)) {
                        $want = $Matches[1].ToLower()
                        break
                    }
                }
            }
            if ($want) {
                if ((Sha256 $zip) -eq $want) {
                    Say 'checksum: the download matches the one published' DarkGray
                } else {
                    Say 'That download does not match the checksum published with it.' Red
                    Say 'Nothing was installed. Try again, or fetch it by hand.' DarkGray
                    try { Remove-Item -LiteralPath $zip -Force } catch {}
                    return $null
                }
            }
        }
    }

    try {
        if (Test-Here $out) { Remove-Item -LiteralPath $out -Recurse -Force }
        $script:Downloaded = $true
        Say 'Unpacking...' DarkGray
        Expand-Archive -LiteralPath $zip -DestinationPath $out -Force
    } catch {
        Say ('Could not unpack it: ' + $_.Exception.Message) Red
        return $null
    }
    return $out
}

# ------------------------------------------------- the version library
#
# Every download is kept, and nothing here is deleted on its own. An older
# build is worth having when a newer one misbehaves, and keeping them is
# what turns going back into a menu entry rather than a trip to GitHub.
function Root-In($folder) {
    # The manifest is at the top of a download, or one folder down if the
    # zip was made with a wrapper. Never above: walking up out of the
    # extracted folder would adopt somebody else's manifest.
    if (Test-Here (Path-Join $folder 'zpause.release')) { return $folder }
    foreach ($d in (Get-ChildItem -LiteralPath $folder -Directory -ErrorAction SilentlyContinue)) {
        if (Test-Here (Path-Join $d.FullName 'zpause.release')) { return $d.FullName }
    }
    return $folder
}

function Release-Of($folder) {
    # A download's identity. Releases before v1.4 have no zpause.release in
    # them at all, so the name it arrived under is the fallback: "ZPause T6
    # v1.3 by Xep" says both things, and GitHub's dots do not get in the way.
    $r = Read-Release $folder
    $leaf = Split-Path -Leaf $folder
    if (-not $r['version'] -and $leaf -match '[ .]v([0-9]+\.[0-9]+(?:\.[0-9]+\.d)?)([ .]|$)') {
        $r['version'] = $Matches[1]
    }
    if (-not $r['name']) {
        $r['name'] = (($leaf -replace '[ .]v[0-9].*$', '') -replace '\.', ' ').Trim()
    }
    return $r
}

function Get-Library {
    $rows = @()
    if (-not (Test-Here $CacheDir)) { return @($rows) }
    foreach ($d in (Get-ChildItem -LiteralPath $CacheDir -Directory -ErrorAction SilentlyContinue)) {
        $rel = Release-Of $d.FullName
        $ver = $rel['version']
        $name = $rel['name']
        $src = Source-Of $d.FullName
        if (-not $src -or -not (Test-Here $src)) { continue }
        $rows += [pscustomobject]@{
            Name = $name
            Version = $ver
            Folder = $d.FullName
            Zip = (Path-Join $CacheDir ($d.Name + '.zip'))
            Source = $src
        }
    }
    return @($rows)
}

function Same-File($a, $b) {
    try {
        $x = [IO.File]::ReadAllBytes($a)
        $y = [IO.File]::ReadAllBytes($b)
        if ($x.Length -ne $y.Length) { return $false }
        for ($i = 0; $i -lt $x.Length; $i++) { if ($x[$i] -ne $y[$i]) { return $false } }
        return $true
    } catch { return $false }
}

function First-Script($source) {
    if (-not $source -or -not (Test-Here $source)) { return $null }
    try {
        if (-not (Get-Item -LiteralPath $source).PSIsContainer) { return $source }
    } catch { return $null }
    $f = @(Get-ChildItem -LiteralPath $source -Recurse -Filter '*.gsc' -ErrorAction SilentlyContinue) |
         Select-Object -First 1
    if ($f) { return $f.FullName }
    return $null
}

<#
    Where a game's files are inside a download or a source folder.

    A download lays each game out as it drops in: Plutonium\storage\<game>,
    Black Ops III\boiii\custom_scripts, t7x\custom_scripts, or a zpause mod
    folder. A source folder has the script flat beside the manifest, under
    its build name. Both are accepted.

    Kind picks which artifact: the text script, the compiled T7x build, or
    the Black Ops 4 mod folder. Returns $null when this root has none.
#>
function Payload-In($root, $key, $kind) {
    if (-not $root) { return $null }
    $flatGame = $Release['game']
    switch ($key) {
        { $_ -in 't6', 't5', 't4' } {
            $tree = First-Script (Path-Join $root ('Plutonium\storage\' + $key))
            if ($tree) { return $tree }
            if ($flatGame -eq $key -and (Test-Here (Path-Join $root 'zpause.gsc'))) {
                return (Path-Join $root 'zpause.gsc')
            }
            return $null
        }
        't7' {
            if ($kind -eq 'compiled') {
                foreach ($c in @('t7x\custom_scripts\zpause.gsc', 'zpause_t7x.gscc')) {
                    if (Test-Here (Path-Join $root $c)) { return (Path-Join $root $c) }
                }
                return $null
            }
            $inTree = Path-Join $root 'Black Ops III\boiii\custom_scripts\zpause.gsc'
            if (Test-Here $inTree) { return $inTree }
            if ($flatGame -eq 't7' -and (Test-Here (Path-Join $root 'zpause.gsc'))) {
                return (Path-Join $root 'zpause.gsc')
            }
            return $null
        }
        't8' {
            $folder = Path-Join $root 'zpause'
            if (Test-Here (Path-Join $folder 'metadata.json')) { return $folder }
            if ($flatGame -eq 't8' -and (Test-Here (Path-Join $root 'metadata.json'))) { return $root }
            return $null
        }
    }
    return $null
}

function Payload-For($key, $kind) {
    if (-not $kind) { $kind = 'file' }
    return (Payload-In $script:Root $key $kind)
}

function Games-Here {
    # Which of the five this download or source folder actually carries.
    $out = @()
    foreach ($g in $GAMES) {
        if (Payload-For $g.Key 'file') { $out += $g.Key; continue }
        if ($g.Key -eq 't8' -and (Payload-For 't8' 'folder')) { $out += $g.Key }
    }
    return @($out)
}

function Ref-For($version, $key, $kind) {
    # A known-good copy of that version of that game, for telling an
    # untouched install apart from one somebody has edited. Only versions
    # on this PC can be checked; anything else simply is not claimed either
    # way. Keyed by game as well as version: inside the bundle every game
    # shares a version, and the first script found was the wrong game's.
    if (-not $version -or $version -eq '?') { return $null }
    if (-not $kind) { $kind = 'file' }
    $ck = $version + '|' + $key + '|' + $kind
    if ($script:RefCache.ContainsKey($ck)) { return $script:RefCache[$ck] }
    $found = $null
    foreach ($c in (Get-Choices)) {
        if ($c.Version -ne $version) { continue }
        $found = Payload-In $c.Folder $key $kind
        if ($found) { break }
    }
    $script:RefCache[$ck] = $found
    return $found
}

function Sha256($path) {
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        return [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($path))).Replace('-', '').ToLower()
    } catch { return $null }
}

function Verify-Sums($root) {
    # SHA256SUMS ships inside every download from v1.4 on: one line per
    # file, coreutils format, so `sha256sum -c SHA256SUMS` says the same
    # thing this does. Returns the number of files checked, 0 when there is
    # no manifest (an older release), or -1 when something does not match.
    $f = Path-Join $root 'SHA256SUMS'
    if (-not (Test-Here $f)) { return 0 }
    $ok = 0
    $bad = @()
    foreach ($line in (Get-Content -LiteralPath $f)) {
        if ($line -notmatch '^([0-9a-fA-F]{64})\s+(.+?)\s*$') { continue }
        $want = $Matches[1].ToLower()
        $rel = $Matches[2]
        $p = Path-Join $root ($rel -replace '/', '\')
        if (-not (Test-Here $p)) { $bad += "$rel -- missing"; continue }
        if ((Sha256 $p) -ne $want) { $bad += "$rel -- does not match"; continue }
        $ok++
    }
    if ($bad.Count -gt 0) {
        Say 'That download does not match its own checksums:' Red
        foreach ($b in $bad) { Say ('    ' + $b) Red }
        return -1
    }
    return $ok
}

function Verify-Payload($root, $want) {
    # A zip that unpacked short is what this catches: the size check on the
    # cached file cannot see inside it, and half a script installs happily.
    $src = Source-Of $root
    if (-not $src -or -not (Test-Here $src)) {
        Say 'That download has no ZPause files in it.' Red
        return $false
    }
    $have = @()
    foreach ($g in $GAMES) {
        $one = Payload-In $root $g.Key 'file'
        if (-not $one -and $g.Key -eq 't8') { $one = Payload-In $root 't8' 'folder' }
        if ($one) { $have += $one }
    }
    if ($have.Count -eq 0) {
        Say 'That download has no zpause script or mod folder in it.' Red
        return $false
    }
    # The manifest checks every file, which is strictly better than checking
    # the one script; the version check below stays for downloads too old to
    # carry one, and for a source folder, which has no manifest describing it.
    $sums = 0
    if (Is-Download $root) { $sums = Verify-Sums $root }
    if ($sums -lt 0) {
        Say 'Not installing it -- delete it from the cache and try again.' DarkGray
        return $false
    }
    if ($sums -gt 0) { Say "checksums: $sums file(s) verified" DarkGray }
    foreach ($one in $have) {
        if ($one -notlike '*.gsc') { continue }
        $got = Read-Version $one
        if ($want -and $got -and $got -ne '?' -and $got -ne $want) {
            Say "That download is labelled v$want but the script inside says v$got." Red
            Say 'Not installing it -- delete it from the cache and try again.' DarkGray
            return $false
        }
    }
    return $true
}

function Show-Changes($root, $version) {
    # The README travels with every download, and its changelog section for
    # this version is exactly "what you are about to get" -- which matters
    # most on a downgrade, where it is what you are about to lose.
    if (-not $root -or -not $version) { return }
    $rme = Path-Join $root 'README.md'
    if (-not (Test-Here $rme)) { return }
    $base = $version -replace '^([0-9]+\.[0-9]+).*$', '$1'
    try { $text = [IO.File]::ReadAllText($rme) } catch { return }
    $a = $text.IndexOf("### v$base")
    if ($a -lt 0) { return }
    # Stop at the next version, or at whatever heading ends the changelog --
    # a port with only one version listed would otherwise run into Credits.
    $b = $text.IndexOf("### v", $a + 5)
    $h2 = $text.IndexOf("
## ", $a + 5)
    if ($h2 -ge 0 -and ($b -lt 0 -or $h2 -lt $b)) { $b = $h2 }
    if ($b -lt 0) { $b = $text.Length }
    $lines = @(($text.Substring($a, $b - $a).TrimEnd() -split "`r?`n") | Select-Object -Skip 1)
    $lines = @($lines | Where-Object { $_.Trim() -ne '' -and $_ -notmatch '^---' })
    if ($lines.Count -eq 0) { return }

    Head "What is in v$base"
    Blank
    $shown = 0
    foreach ($line in $lines) {
        if ($shown -ge 18) { Say ('    ...and more, in the README.') DarkGray; break }
        Say ('  ' + ($line -replace '\*\*', '' -replace '`', ''))
        $shown++
    }
}

function Get-Choices {
    # What could be installed right now: whatever came with this download,
    # then everything kept from an earlier one.
    $all = @()
    # $HomeRoot, not $Root: adopting a download moves $Root into the cache,
    # and the version you started with must not vanish off the list.
    $mine = Source-Of $HomeRoot
    if ($mine -and (Test-Here $mine)) {
        $rel = Release-Of $HomeRoot
        $all += [pscustomobject]@{
            Name = $rel['name']; Version = $rel['version']
            Folder = $HomeRoot; Source = $mine; Zip = $null; Here = $true
        }
    }
    foreach ($r in (Get-Library)) {
        if ($HomeRoot -and $r.Folder -eq $HomeRoot) { continue }
        $all += [pscustomobject]@{
            Name = $r.Name; Version = $r.Version
            Folder = $r.Folder; Source = $r.Source; Zip = $r.Zip; Here = $false
        }
    }
    return @($all)
}

function Get-Releases($repo, $assetPrefix) {
    # The whole list, not just the newest -- this is what makes going back to
    # an older build possible without hunting for the right zip by hand.
    if (-not (Net-Ready)) { return @() }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        $api = "https://api.github.com/repos/$repo/releases?per_page=30"
        $r = Invoke-RestMethod -Uri $api -UserAgent 'ZPause-Manager' -TimeoutSec 20
    } catch {
        Net-Problem $_
        return @()
    }
    $want = Norm-Name $assetPrefix
    $out = @()
    foreach ($rel in $r) {
        $asset = $null
        foreach ($a in $rel.assets) {
            if ($a.name -like '*.zip' -and (Norm-Name $a.name).StartsWith($want)) { $asset = $a; break }
        }
        if (-not $asset) { continue }
        $ver = $null
        if ("$($rel.tag_name)" -match '([0-9]+\.[0-9]+(?:\.[0-9]+\.d)?)') { $ver = $Matches[1] }
        if (-not $ver -and $asset.name -match '[ .]v([0-9]+\.[0-9]+(?:\.[0-9]+\.d)?)[ .]') {
            $ver = $Matches[1]
        }
        $out += [pscustomobject]@{
            Version = $ver; Name = $asset.name
            Url = $asset.browser_download_url; Size = [long]$asset.size
        }
    }
    return @($out)
}

function Do-PickRelease {
    $entry = Which-Game
    if (-not $entry) { return }
    Blank
    if (-not (Ask 'That asks GitHub which releases exist. Go ahead?' 'y')) {
        Say 'Nothing was contacted.' DarkGray
        return
    }
    $script:Online = $true

    Head ($entry.Name + ' -- releases on GitHub')
    $rels = @(Get-Releases $entry.Repo $entry.Asset)
    if ($rels.Count -eq 0) { Say 'No releases with a download attached.' Red; return }
    Blank
    for ($i = 0; $i -lt $rels.Count; $i++) {
        $tag = ''
        if ($i -eq 0) { $tag = '   latest' }
        Write-Host ('    {0}. v{1,-10} {2,-10}{3}' -f ($i + 1), $rels[$i].Version,
                    (Fmt-Bytes $rels[$i].Size), $tag)
    }
    Blank
    $n = 0
    $c = (Read-Line '  which').Trim()
    if (-not $c) { return }
    if (-not ([int]::TryParse($c, [ref]$n)) -or $n -lt 1 -or $n -gt $rels.Count) {
        Say 'Not one of the choices.' Red
        return
    }

    $folder = Fetch-Payload $rels[$n - 1]
    if (-not $folder) { return }
    [void](Adopt-Payload $folder)
    if (-not (Verify-Payload $script:Root $rels[$n - 1].Version)) { return }
    Log 'downloaded' ('v' + $Release['version'] + '  ' + $folder)
    Blank
    if (Ask ('Install v' + $Release['version'] + ' now?') 'y') { Do-Install $false }
}

function Do-Versions {
    Head 'Install a different version'
    $all = @(Get-Choices)
    if ($all.Count -eq 0) {
        Blank
        Say 'No ZPause download is on this PC yet.' DarkGray
    } else {
        Blank
        for ($i = 0; $i -lt $all.Count; $i++) {
            $where = 'kept on this PC'
            if ($all[$i].Here) { $where = 'came with this installer' }
            Write-Host ('    {0}. {1,-26} v{2,-10} {3}' -f ($i + 1), $all[$i].Name,
                        $all[$i].Version, $where)
        }
    }
    Blank
    Say '  d. download a different version from GitHub' DarkGray
    Say '     (Enter goes back)' DarkGray
    Blank
    $c = (Read-Line '  which').Trim().ToLower()
    if (-not $c) { return }
    if ($c -eq 'd') { Do-PickRelease; return }
    $n = 0
    if (-not ([int]::TryParse($c, [ref]$n)) -or $n -lt 1 -or $n -gt $all.Count) {
        Say 'Not one of the choices.' Red
        return
    }

    # Point the session at that version, then install exactly as normal --
    # upgrading and downgrading are the same operation from here.
    $pick = $all[$n - 1]
    $script:Root = $pick.Folder
    $script:Release = Release-Of $pick.Folder
    $script:Payload = $pick.Source
    Do-Install $false
}

function Do-Prune {
    # Offered once something has been downloaded, and never taken as read:
    # keeping every build is a perfectly good habit.
    if (-not $script:Downloaded) { return }
    $rows = @(Get-Library)
    if ($rows.Count -lt 2) { return }

    Head 'Downloads kept on this PC'
    Blank
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $tag = ''
        if ($Root -and $rows[$i].Folder -eq $Root) { $tag = '   just used' }
        Write-Host ('    {0}. {1,-26} v{2,-10}{3}' -f ($i + 1), $rows[$i].Name,
                    $rows[$i].Version, $tag)
    }
    Blank
    Say "They are kept on purpose: an older build is worth having if a newer one" DarkGray
    Say "misbehaves, and reinstalling one is two keystrokes from the menu." DarkGray
    Blank
    Say 'Type a number to delete that download, o for every older one, or press' DarkGray
    Say 'Enter to keep them all.' DarkGray
    Blank
    $c = (Read-Line '  delete').Trim().ToLower()
    if (-not $c) { Say 'Kept.' DarkGray; return }

    $targets = @()
    if ($c -eq 'o') {
        foreach ($r in $rows) { if (-not $Root -or $r.Folder -ne $Root) { $targets += $r } }
    } else {
        $n = 0
        if ([int]::TryParse($c, [ref]$n) -and $n -ge 1 -and $n -le $rows.Count) {
            $targets = @($rows[$n - 1])
        } else {
            Say 'Not one of the choices. Nothing deleted.' Red
            return
        }
    }

    $n = 0
    foreach ($t in $targets) {
        try {
            if (Test-Here $t.Folder) { Remove-Item -LiteralPath $t.Folder -Recurse -Force }
            if ($t.Zip -and (Test-Here $t.Zip)) { Remove-Item -LiteralPath $t.Zip -Force }
            Log 'discarded' ('v' + $t.Version + '  ' + $t.Folder)
            $n++
        } catch { Say ('could not delete ' + $t.Name) Red }
    }
    $script:CountDropped += $n
    Blank
    Say "Deleted $n download(s). What is installed in the game is untouched." Green
}

function Pick-Game {
    # -Yes means "do not ask me anything", so this is the one question it
    # cannot answer for you: say which with -Game instead of hanging on a
    # prompt nobody is there to read.
    if ($script:AssumeYes) {
        Say 'Which one? Add -Game bundle, or t6 / t5 / t4 / t7 / t8.' Red
        return $null
    }
    Head 'Which one?'
    Blank
    for ($i = 0; $i -lt $CATALOG.Count; $i++) {
        Write-Host ('    {0}. {1,-26} {2}' -f ($i + 1), $CATALOG[$i].Name, $CATALOG[$i].What)
    }
    Blank
    $p = Read-Line '  which'
    $idx = 0
    if ([int]::TryParse($p, [ref]$idx) -and $idx -ge 1 -and $idx -le $CATALOG.Count) {
        return $CATALOG[$idx - 1]
    }
    Say 'Not one of the choices.' Red
    return $null
}

function Which-Game {
    if ($Game) {
        $e = $CATALOG | Where-Object { $_.Key -eq $Game.Trim().ToLower() } | Select-Object -First 1
        if ($e) { return $e }
        Say ("No such game: $Game") Red
        return $null
    }
    if ($Release['game']) {
        $e = $CATALOG | Where-Object { $_.Key -eq $Release['game'] } | Select-Object -First 1
        if ($e) { return $e }
    }
    return Pick-Game
}

function Adopt-Payload($folder) {
    # A freshly unpacked download replaces whatever we started with.
    $r = Root-In $folder
    $script:Root = $r
    $script:Release = Release-Of $r
    $script:Payload = Source-Of $r
    return $script:Payload
}

# ------------------------------------------------- actions
function Get-Payload {
    # The mod files, from wherever they can be had. Returns $null when the
    # user declined to download them.
    if ($Payload -and (Test-Here $Payload)) { return $Payload }

    Blank
    Say 'The mod files are not next to this installer.' Yellow
    Blank
    if (-not (Ask 'Download them from GitHub?' 'y')) {
        Say 'Nothing downloaded.' DarkGray
        return $null
    }
    $script:Online = $true

    $entry = Which-Game
    if (-not $entry) { return $null }

    Head $entry.Name
    $latest = Get-Latest $entry.Repo $entry.Asset
    if (-not $latest) { return $null }
    Say ('latest release: v' + $latest.Version)

    $folder = Fetch-Payload $latest
    if (-not $folder) { return $null }
    $out = Adopt-Payload $folder
    if (-not (Verify-Payload $script:Root $latest.Version)) { return $null }
    Log 'downloaded' ('v' + $Release['version'] + '  ' + $folder)
    return $out
}

function Install-Plan($key) {
    # Where each file goes for this game: (From, To, Kind, Slot). A folder
    # slot expands to every file the mod is made of, so the copy loop can
    # stay the same for all three shapes.
    $plan = @()
    foreach ($slot in $SLOTS) {
        if ($slot.Key -ne $key) { continue }
        if (-not $slot.PickedForInstall) { continue }
        $to = Slot-Path $slot
        if (-not $to) { continue }
        if ($slot.Kind -eq 'folder') {
            $src = Payload-For $key 'folder'
            if (-not $src) { continue }
            foreach ($f in @(Get-ChildItem -LiteralPath $src -File -ErrorAction SilentlyContinue)) {
                # Only what the mod is made of. A README sitting beside the
                # payload in a source folder is not part of it.
                if ($f.Name -notmatch '\.(json|gscc|gsic|luac)$') { continue }
                $plan += [pscustomobject]@{ From = $f.FullName; To = (Path-Join $to $f.Name); Kind = 'file'; Slot = $slot }
            }
            $plan += [pscustomobject]@{ From = $null; To = (Path-Join $to 'zpause.installed'); Kind = 'stamp'; Slot = $slot }
            continue
        }
        $from = Payload-For $key $slot.Kind
        if (-not $from) { continue }
        # T6's mod-folder copy is a generated variant of the same script,
        # differing only in what zp_origin() returns. A download carries it
        # at its own path already; a source folder has it lying beside the
        # loose one, so pick it up here or the mod slot gets a copy that
        # calls itself the script one.
        if ($slot.Path -like '*mods\zm_pause*') {
            $inTree = Path-Join $script:Root ('Plutonium\' + $slot.Path)
            $flat = Path-Join (Split-Path -Parent $from) 'zpause_mod.gsc'
            if (Test-Here $inTree) { $from = $inTree }
            elseif (Test-Here $flat) { $from = $flat }
        }
        $plan += [pscustomobject]@{ From = $from; To = $to; Kind = $slot.Kind; Slot = $slot }
    }
    return @($plan)
}

function Pick-Install-Game($here) {
    # Which game to install. One question at most: a download for one game
    # answers it, a bundle or a kept installer asks, and -Game answers it
    # from the command line.
    $here = @($here)
    if ($Game) {
        $k = $Game.Trim().ToLower()
        if (Game-For $k) { return $k }
        if ($k -ne 'bundle') { Say "No such game: $Game" Red; return $null }
    }
    if ($here.Count -eq 1) { return $here[0] }
    if ($script:AssumeYes) {
        Say 'Which one? Add -Game t6 / t5 / t4 / t7 / t8.' Red
        return $null
    }
    Head 'Install for which game?'
    Blank
    $rows = @(Get-Installed)
    for ($i = 0; $i -lt $GAMES.Count; $i++) {
        $g = $GAMES[$i]
        $state = 'not installed'
        $mine = @($rows | Where-Object { $_.Key -eq $g.Key })
        if ($mine.Count -gt 0) { $state = 'installed v' + $mine[0].Version }
        $carry = ''
        if ($here -notcontains $g.Key) { $carry = '  (not in this download -- would be fetched)' }
        Write-Host ('    {0}. {1}  {2,-14} {3}{4}' -f ($i + 1), $g.Tag, $g.Name, $state, $carry)
    }
    Blank
    Say '     (Enter goes back)' DarkGray
    Blank
    $c = (Read-Line '  which').Trim()
    if (-not $c) { return $null }
    $n = 0
    if (-not ([int]::TryParse($c, [ref]$n)) -or $n -lt 1 -or $n -gt $GAMES.Count) {
        Say 'Not one of the choices.' Red
        return $null
    }
    return $GAMES[$n - 1].Key
}

function Pick-Routes($key) {
    # Black Ops III has three loaders, all optional and all independent, so
    # each route is a tick box: found loaders start ticked. Everywhere else
    # every slot for the game is written, the way it always was.
    $mine = @($SLOTS | Where-Object { $_.Key -eq $key })
    foreach ($slot in $mine) { $slot.PickedForInstall = $true }
    if ($key -ne 't7') { return $true }

    foreach ($slot in $mine) { $slot.PickedForInstall = (Slot-Present $slot) }
    Head 'Where ZPause can go'
    Blank
    for ($i = 0; $i -lt $mine.Count; $i++) {
        $r = $mine[$i]
        $box = '[ ]'; $col = 'DarkGray'
        if ($r.PickedForInstall) { $box = '[x]'; $col = 'Green' }
        $state = 'not found'
        if (Slot-Present $r) { $state = 'installed' }
        Write-Host ('    {0} {1}. {2,-24} {3,-10} {4}' -f $box, ($i + 1), $r.Game, $state, $r.Note) -ForegroundColor (Tint $col)
    }
    if (-not ($mine | Where-Object { $_.PickedForInstall })) {
        Blank
        Say 'None of the script loaders are installed.' Yellow
        Say 'ZPause also ships as a Steam Workshop mod, which needs none of them.' DarkGray
    }
    Blank
    Say 'Ticked boxes are what was found. Type a number to toggle one,' DarkGray
    Say 'or press Enter to install what is ticked.' DarkGray
    Blank
    # -Yes means the ticks stand as found: there is nobody at the keyboard.
    for (;;) {
        if ($script:AssumeYes) { break }
        $c = Read-Line '  >'
        if (-not $c) { break }
        $n = 0
        if ([int]::TryParse($c, [ref]$n) -and $n -ge 1 -and $n -le $mine.Count) {
            $mine[$n - 1].PickedForInstall = -not $mine[$n - 1].PickedForInstall
            $r = $mine[$n - 1]
            $box = '[ ]'; $col = 'DarkGray'
            if ($r.PickedForInstall) { $box = '[x]'; $col = 'Green' }
            Write-Host ('    {0} {1}' -f $box, $r.Game) -ForegroundColor (Tint $col)
        } else {
            Say 'Type one of the numbers, or Enter to go ahead.' Red
        }
    }
    return [bool]($mine | Where-Object { $_.PickedForInstall })
}

function Do-Install($noConfirm, $key) {
    # Nothing beside the installer -- a kept copy, or a bare install.ps1.
    # Which game comes first, so the one download is the right one: the
    # generic "download them?" of Get-Payload would fetch a release and then
    # find it was not the game picked, and fetch again.
    if (-not ($Payload -and (Test-Here $Payload))) {
        Blank
        Say 'Pick a game and its release is fetched from GitHub.' Yellow
        if (-not $key) { $key = Pick-Install-Game @() }
        if (-not $key) { return }
        if (-not (Fetch-Game $key)) { return }
    }

    $src = Get-Payload
    if (-not $src) { return }

    $here = @(Games-Here)
    if (-not $key) { $key = Pick-Install-Game $here }
    if (-not $key) { return }
    $g = Game-For $key

    # Another game's zip: the files for this one can be fetched.
    if ($here -notcontains $key) {
        Blank
        Say ("This download has no " + $g.Name + " files in it.") Yellow
        if (-not (Fetch-Game $key)) { return }
        $here = @(Games-Here)
        if ($here -notcontains $key) { Say 'Still nothing to install.' Red; return }
    }

    $root = Root-Ask $g.Family
    if (-not $root) { Blank; Say 'Nothing changed.' Red; return }

    $v = $Release['version']
    $already = @(@(Get-Installed) | Where-Object { $_.Key -eq $key } |
                 ForEach-Object { $_.Version } | Select-Object -Unique)
    # Worth reading when it is a change; noise when it is the same build again.
    if (-not ($already.Count -eq 1 -and $already[0] -eq $v)) {
        Show-Changes $Root $v
        Show-DefaultMoves $key
    }

    # Downloads are checked when they arrive; this catches the other way in,
    # which is a zip somebody extracted badly. A source folder has no
    # manifest that describes it, so there is nothing to check.
    if ((Is-Download $Root) -and (Verify-Sums $Root) -lt 0) {
        Blank
        Say 'Nothing installed. Extract the download again.' Red
        return
    }

    if (-not (Pick-Routes $key)) { Blank; Say 'Nothing ticked. Nothing installed.' Red; return }

    Head ('Installing -- ' + $g.Name)
    $plan = @(Install-Plan $key)
    if ($plan.Count -eq 0) { Say 'Nothing to install -- no files found for it.' Red; return }

    Blank
    foreach ($p in $plan) {
        if ($p.Kind -eq 'stamp') { continue }
        $show = $p.To
        if ($show.StartsWith($root)) { $show = $show.Substring($root.Length + 1) }
        Say ('    ' + $show)
    }
    Blank
    Say 'Any existing ZPause file at those paths is replaced -- a copy of it is' DarkGray
    Say 'kept first, so it can be put back. Nothing else here is touched.' DarkGray
    Blank
    if (-not $noConfirm) {
        if (-not (Ask 'Continue?' 'y')) { Blank; Say 'Cancelled.' Red; return }
    }

    $script:RunStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:BackupN = 0
    $n = 0
    foreach ($p in $plan) {
        try {
            $dir = Split-Path -Parent $p.To
            if (-not (Test-Here $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            if ($p.Kind -eq 'stamp') {
                # The mod folder holds compiled files, so nothing in it says
                # which version it is. This does.
                Set-Content -LiteralPath $p.To -Value $v -Encoding ASCII
                continue
            }
            Backup-File $p.To
            Copy-Item -LiteralPath $p.From -Destination $p.To -Force
            Log 'installed' ("v$v  " + $p.To)
            $n++
        } catch { Say ("failed: " + $p.To + " -- " + $_.Exception.Message) Red }
    }
    $script:RefCache = @{}
    Blank
    $script:CountInstalled += $n
    if ($v) { Say "Installed $n file(s) -- v$v." Green } else { Say "Installed $n file(s)." Green }
    Reapply-Config
    if ($g.Family -eq 'bo4') {
        Say 'Only the host needs ZPause. Start a zombies match to load it.' DarkGray
    } else {
        Say 'Only the host needs ZPause. End the current match and start a new one' DarkGray
        Say 'to load it -- no need to restart the game.' DarkGray
    }
    if ($g.Family -eq 'bo3' -and (Test-Here (Path-Join $root 'd3d11.dll'))) {
        Blank
        Say 'You have a community patch installed (T7 Patch or Clean Ops).' DarkCyan
        Say 'That is fine -- neither is a mod and neither takes the mod slot.' DarkGray
        Say 'Do not use the t7-compiler injector under one; use a route above.' DarkGray
    }
    if ($n -gt 0) { $script:DidInstall = $true }
}

function Fetch-Game($key) {
    # The files for one game, from its own repo, into the cache -- and then
    # adopted as this session's download, so the install that follows is
    # the ordinary one.
    $g = Game-For $key
    $entry = $CATALOG | Where-Object { $_.Key -eq $key } | Select-Object -First 1
    if (-not $entry) { return $false }
    if (-not (Ask ('Download ' + $g.Name + ' from GitHub?') 'y')) {
        Say 'Nothing downloaded.' DarkGray
        return $false
    }
    $script:Online = $true
    Head $entry.Name
    $latest = Get-Latest $entry.Repo $entry.Asset
    if (-not $latest) { return $false }
    Say ('latest release: v' + $latest.Version)
    $folder = Fetch-Payload $latest
    if (-not $folder) { return $false }
    [void](Adopt-Payload $folder)
    if (-not (Verify-Payload $script:Root $latest.Version)) { return $false }
    Log 'downloaded' ('v' + $Release['version'] + '  ' + $folder)
    return $true
}

function Do-Uninstall($all) {
    $rows = Show-Installed
    if ($rows.Count -eq 0) { return }

    $targets = @()
    if ($all) {
        # -Uninstall -Yes takes everything it can find; with -Game it takes
        # that game's copies and leaves the rest where they are.
        $targets = $rows
        if ($Game -and (Game-For $Game.Trim().ToLower())) {
            $targets = @($rows | Where-Object { $_.Key -eq $Game.Trim().ToLower() })
            if ($targets.Count -eq 0) { Say ('Nothing installed for ' + $Game + '.') DarkGray; return }
        }
    } else {
        Blank
        Say 'Type a number to remove that one, or a for all of them.' DarkGray
        Say 'Only the files ZPause put there are removed -- nothing else, and no folders.' DarkGray
        Blank
        $c = Read-Line '  remove'
        if (-not $c) { Say 'Cancelled.' Red; return }
        if ($c.Trim().ToLower() -eq 'a') {
            $targets = $rows
        } else {
            $n = 0
            if ([int]::TryParse($c, [ref]$n) -and $n -ge 1 -and $n -le $rows.Count) {
                $targets = @($rows[$n - 1])
            } else { Say 'Not one of the choices.' Red; return }
        }
    }

    Blank
    foreach ($t in $targets) { Say $t.Path }
    Blank
    if (-not (Ask 'Remove these?')) { Blank; Say 'Cancelled.' Red; return }

    $script:RunStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:BackupN = 0
    $n = 0
    foreach ($t in $targets) {
        try {
            if ($t.Kind -eq 'folder') {
                # Files only, and only the ones the mod is made of. The
                # folder stays: it is not ours to delete, and an empty one
                # costs nothing.
                foreach ($f in @(Get-ChildItem -LiteralPath $t.Path -File -ErrorAction SilentlyContinue)) {
                    if ($f.Name -notmatch '\.(json|gscc|gsic|luac|installed)$') { continue }
                    Backup-File $f.FullName
                    Remove-Item -LiteralPath $f.FullName -Force
                    Log 'removed' $f.FullName
                    $n++
                }
                continue
            }
            Backup-File $t.Path
            Remove-Item -LiteralPath $t.Path -Force
            Log 'removed' $t.Path
            $n++
        }
        catch { Say ('failed: ' + $t.Path) Red }
    }
    $script:CountRemoved += $n
    Blank
    Say "Removed $n file(s)." Green
    Say 'Empty folders are left alone.' DarkGray
    if ($targets | Where-Object { $_.Family -eq 'bo3' }) {
        Say 'A Steam Workshop copy is not removed here -- unsubscribe in Steam.' DarkGray
    }
    if ((Get-Installed).Count -eq 0) { $script:DidInstall = $false }
}

function Dir-Size($p) {
    try {
        return ((Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue) |
                Measure-Object -Property Length -Sum).Sum
    } catch { return 0 }
}

function Clear-Backups($sets) {
    # Backups accumulate for as long as you keep installing. Same rule as
    # the downloads: nothing goes without being asked, and the newest set
    # stays, because that is the one an accident would need.
    if ($sets.Count -lt 2) {
        Blank
        Say 'There is only one set, and it is the one worth keeping.' DarkGray
        return
    }
    Blank
    if (-not (Ask ('Delete all but the newest ' + ($sets.Count - 1) + ' set(s)?'))) {
        Say 'Kept.' DarkGray
        return
    }
    $n = 0
    for ($i = 1; $i -lt $sets.Count; $i++) {
        $dir = Path-Join $BackupDir $sets[$i].Name
        try {
            if (Test-Here $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
            $n++
        } catch { Say ('could not delete ' + $sets[$i].Name) Red }
    }
    # The index only describes files that still exist, so prune it too.
    try {
        $keep = @(Get-Content -LiteralPath $BackupIndex |
                  Where-Object { $_ -like ($sets[0].Name + '|*') })
        Set-Content -LiteralPath $BackupIndex -Value $keep -Encoding UTF8
    } catch {}
    Blank
    Say "Deleted $n backup set(s)." Green
}

function Do-Restore {
    Head 'Put back a file it replaced'
    $rows = @(Get-Backups)
    if ($rows.Count -eq 0) {
        Blank
        Say 'Nothing has been replaced yet, so there is nothing to put back.' DarkGray
        return
    }
    $sets = @($rows | Group-Object Stamp | Sort-Object Name -Descending)
    Blank
    for ($i = 0; $i -lt $sets.Count; $i++) {
        $vs = (@($sets[$i].Group | ForEach-Object { $_.Version }) |
               Select-Object -Unique | Where-Object { $_ }) -join ', '
        if (-not $vs) { $vs = 'unknown' }
        $size = Fmt-Bytes (Dir-Size (Path-Join $BackupDir $sets[$i].Name))
        Write-Host ('    {0}. {1}   {2} file(s)   was v{3}   {4}' -f ($i + 1),
                    (Pretty-Stamp $sets[$i].Name), $sets[$i].Count, $vs, $size)
    }
    Blank
    Say 'Each of these is what was sitting there before an install replaced it,' DarkGray
    Say 'including anything you had edited yourself.' DarkGray
    Blank
    Say 'A number puts that set back. x clears out everything but the newest.' DarkGray
    Say '  (Enter goes back)' DarkGray
    Blank
    $c = (Read-Line '  which').Trim().ToLower()
    if (-not $c) { return }
    if ($c -eq 'x') { Clear-Backups $sets; return }
    $n = 0
    if (-not ([int]::TryParse($c, [ref]$n)) -or $n -lt 1 -or $n -gt $sets.Count) {
        Say 'Not one of the choices.' Red
        return
    }

    $pick = @($sets[$n - 1].Group)
    Blank
    foreach ($b in $pick) { Say $b.Dest }
    Blank
    if (-not (Ask 'Put these back?')) { Blank; Say 'Cancelled.' Red; return }

    $done = 0
    foreach ($b in $pick) {
        try {
            $dir = Split-Path -Parent $b.Dest
            if (-not (Test-Here $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Copy-Item -LiteralPath $b.File -Destination $b.Dest -Force
            Log 'restored' ('v' + $b.Version + '  ' + $b.Dest)
            $done++
        } catch { Say ('failed: ' + $b.Dest) Red }
    }
    $script:RefCache = @{}
    $script:CountRestored += $done
    Blank
    Say "Put back $done file(s)." Green
}

function Do-Check {
    $entry = Which-Game
    if (-not $entry) { return }
    $script:Online = $true

    Head ($entry.Name + ' -- checking GitHub')
    $latest = Get-Latest $entry.Repo $entry.Asset
    if (-not $latest) { return }
    $script:LatestVersion = $latest.Version

    $have = $Release['version']
    Blank
    if ($have) { Say "you have:  v$have" }
    Say ('latest:    v' + $latest.Version) Green

    if ($have -and (Ver-Compare $have $latest.Version) -ge 0) {
        Blank
        Say 'You already have the latest release.' Green
        if (-not (Ask 'Download it again anyway?')) { return }
    } else {
        Blank
        if (-not (Ask 'Download it?' 'y')) { Say 'Nothing downloaded.' DarkGray; return }
    }

    $folder = Fetch-Payload $latest
    if (-not $folder) { return }

    [void](Adopt-Payload $folder)
    if (-not (Verify-Payload $script:Root $latest.Version)) { return }
    Log 'downloaded' ('v' + $Release['version'] + '  ' + $folder)
    Blank
    Say ('Ready to install v' + $Release['version']) Green
    Update-Self $script:Root
    if (Ask 'Install it now?' 'y') { Do-Install $false }
}

function Update-Self($root) {
    # The installer improves between releases too. Kept behind its own
    # prompt, because updating the mod and updating the tool that installs
    # it are two different decisions.
    $new = Path-Join $root 'installer\windows\install.ps1'
    if (-not (Test-Here $new)) { return }
    $mine = Path-Join $Here 'install.ps1'
    if (-not (Test-Here $mine)) { return }
    try {
        $a = [IO.File]::ReadAllBytes($new)
        $b = [IO.File]::ReadAllBytes($mine)
        if ($a.Length -eq $b.Length) {
            $same = $true
            for ($i = 0; $i -lt $a.Length; $i++) {
                if ($a[$i] -ne $b[$i]) { $same = $false; break }
            }
            if ($same) { return }
        }
    } catch { return }

    Blank
    Say 'This download also carries a newer copy of this installer.' DarkGray
    if (-not (Ask 'Update the installer as well?' 'y')) { return }
    try {
        foreach ($n in @('install.ps1', 'install.bat')) {
            $from = Path-Join $root ('installer\windows\' + $n)
            if (Test-Here $from) { Copy-Item -LiteralPath $from -Destination (Path-Join $Here $n) -Force }
        }
        Say 'Installer updated. It takes effect the next time you run it.' Green
    } catch { Say ('Could not update it: ' + $_.Exception.Message) Red }
}

function Do-Persist {
    $kept = Path-Join $StateDir 'install.ps1'
    if (Test-Here $kept) {
        Head 'The kept installer'
        Say $StateDir
        Blank
        Say 'That folder also holds your saved settings, the downloads it kept' DarkGray
        Say 'and the backups of files it replaced. All of it goes.' DarkGray
        Blank
        if (-not (Ask 'Remove it, along with anything it downloaded?')) { return }
        try {
            Remove-Item -LiteralPath $StateDir -Recurse -Force
            foreach ($p in @((Path-Join ([Environment]::GetFolderPath('Desktop')) 'ZPause Manager.lnk'),
                             (Path-Join ([Environment]::GetFolderPath('Programs')) 'ZPause Manager.lnk'))) {
                if (Test-Here $p) { Remove-Item -LiteralPath $p -Force }
            }
            Blank
            Say 'Removed. Your installed ZPause files were not touched.' Green
        } catch { Say ('Could not remove it: ' + $_.Exception.Message) Red }
        return
    }

    Head 'Keep this installer'
    Say 'A copy goes to:' DarkGray
    Say "  $StateDir" DarkGray
    Blank
    Say 'From there it can fetch any ZPause release by itself, so the folder' DarkGray
    Say 'you downloaded is no longer needed.' DarkGray
    Blank
    if (-not (Ask 'Keep it?' 'y')) { return }

    try {
        if (-not (Test-Here $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
        foreach ($n in @('install.ps1', 'install.bat')) {
            $from = Path-Join $Here $n
            if (Test-Here $from) { Copy-Item -LiteralPath $from -Destination (Path-Join $StateDir $n) -Force }
        }
    } catch {
        Say ('Could not copy it: ' + $_.Exception.Message) Red
        return
    }

    Blank
    Say 'Where would you like a shortcut?' DarkGray
    Blank
    Say '    1. Desktop'
    Say '    2. Start menu'
    Say '    3. both'
    Say '    4. neither'
    Blank
    $c = (Read-Line '  which').Trim()
    $where = @()
    if ($c -eq '1' -or $c -eq '3') { $where += [Environment]::GetFolderPath('Desktop') }
    if ($c -eq '2' -or $c -eq '3') { $where += [Environment]::GetFolderPath('Programs') }

    foreach ($dir in $where) {
        try {
            $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut((Path-Join $dir 'ZPause Manager.lnk'))
            $lnk.TargetPath = Path-Join $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Path-Join $StateDir 'install.ps1') + '"'
            $lnk.WorkingDirectory = $StateDir
            $lnk.Description = 'Install, update or remove ZPause'
            $lnk.Save()
            Log 'shortcut' (Path-Join $dir 'ZPause Manager.lnk')
        Say ('shortcut: ' + (Path-Join $dir 'ZPause Manager.lnk')) Green
        } catch { Say ('Could not make a shortcut in ' + $dir) Red }
    }

    Blank
    Say 'Kept. You can delete this download folder whenever you like --' Green
    Say 'the kept copy fetches whatever it needs.' DarkGray
}

# ------------------------------------------------- other mods
#
# OTHERMODS.MD in the ZPause repo, if it is there. Plain markdown, so the
# same file reads properly on GitHub and parses here:
#
#     ## Mod Name
#     *2026-09-08 - Xep*
#     What the mod does, in a line or three.
#     https://github.com/Xeptix/ModName
#
# The date and creator line is optional, and so is the link. Anything the
# file does not have is simply not printed.
function Parse-OtherMods($text) {
    $mods = @()
    $cur = $null
    $inComment = $false
    foreach ($raw in ($text -split "`r?`n")) {
        $line = $raw.Trim()
        # An HTML comment is how the file documents its own format, so what
        # is inside one is an example and must not become an entry.
        if ($inComment) {
            if ($line -match '-->') { $inComment = $false }
            continue
        }
        if ($line -match '^<!--') {
            if ($line -notmatch '-->') { $inComment = $true }
            continue
        }
        if ($line -match '^#{2,3}\s+(.+?)\s*$') {
            if ($cur) { $mods += $cur }
            $cur = [pscustomobject]@{ Name = ($Matches[1] -replace '[*_`]', ''); By = ''; Info = @(); Link = '' }
            continue
        }
        if (-not $cur -or $line -eq '' -or $line -match '^([-*_])\1{2,}$') { continue }
        if ($line -match '^\[[^\]]*\]\(\s*(https?://[^)\s]+)') { $cur.Link = $Matches[1]; continue }
        if ($line -match '^<?(https?://[^\s>]+)>?$') { $cur.Link = $Matches[1]; continue }
        # The first italic line under the heading is the date and creator.
        if (-not $cur.By -and $cur.Info.Count -eq 0 -and $line -match '^[*_]{1,2}(.+?)[*_]{1,2}$') {
            $cur.By = $Matches[1].Trim()
            continue
        }
        $cur.Info += (($line -replace '^[-*+]\s+', '') -replace '[*_`]', '')
    }
    if ($cur) { $mods += $cur }
    return @($mods)
}

function Show-OtherMods {
    # Only ever fetched when you already said yes to talking to GitHub.
    if (-not $script:Online) { return }
    $dest = Path-Join $CacheDir $OTHER_MODS
    try {
        if (-not (Test-Here $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }
    } catch { return }

    $got = $false
    foreach ($branch in @('main', 'master')) {
        $url = "https://raw.githubusercontent.com/$HOME_REPO/$branch/$OTHER_MODS"
        if (Get-Web $url $dest $true) { $got = $true; break }
    }
    # No file in the repo, or no connection: say nothing at all.
    if (-not $got -or -not (Test-Here $dest)) { return }

    try { $mods = Parse-OtherMods ([IO.File]::ReadAllText($dest)) } catch { return }
    if ($mods.Count -eq 0) { return }

    Head 'Also by Xep'
    foreach ($m in $mods) {
        Blank
        Write-Host ('    ' + $m.Name) -ForegroundColor (Tint White)
        if ($m.By) { Write-Host ('    ' + $m.By) -ForegroundColor (Tint DarkGray) }
        foreach ($line in $m.Info) { Write-Host ('    ' + $line) -ForegroundColor (Tint Gray) }
        if ($m.Link) { Write-Host ('    ' + $m.Link) -ForegroundColor (Tint DarkCyan) }
    }
}

# ------------------------------------------------- configuration
#
# Every setting is a dvar of the same name, and the script declares each one
# with its default. That declaration is the source of truth here: names,
# types, defaults, and -- from the "// --- section ---" markers around them
# -- the grouping. All of it travels with the mod, so this works for every
# port and for a bundle download that carries no per-game README.
#
# The README's dvar table supplies the one-line description when it is
# there. release_check.py already forces that table to agree with the
# script, so the two can never drift apart.
$ConfigDir = Path-Join $StateDir 'config'
$AppliedFile = Path-Join $ConfigDir 'applied.txt'

# One config per game was enough until it wasn't: a server and a solo game
# want different settings, and so does whoever you send a cfg to. Profiles
# are just named files in a folder per game, so exporting one is still a
# copy of a plain cfg.
function Profile-Name($game) {
    $p = $Settings["profile_$game"]
    if (-not $p) { $p = 'default' }
    return $p
}

function Config-Dir($game) {
    $dir = Path-Join $ConfigDir $game
    # v1.4 kept one file per game. Move it in as the default profile.
    $old = Path-Join $ConfigDir ($game + '.cfg')
    if ((Test-Here $old) -and -not (Test-Here $dir)) {
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Move-Item -LiteralPath $old -Destination (Path-Join $dir 'default.cfg') -Force
        } catch {}
    }
    return $dir
}

function Config-File($game) {
    return Path-Join (Config-Dir $game) ((Profile-Name $game) + '.cfg')
}

function Get-Profiles($game) {
    $dir = Config-Dir $game
    $names = @()
    if (Test-Here $dir) {
        $names = @(Get-ChildItem -LiteralPath $dir -Filter '*.cfg' -ErrorAction SilentlyContinue |
                   ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) })
    }
    if ($names -notcontains 'default') { $names = @('default') + $names }
    return @($names | Select-Object -Unique | Sort-Object)
}

function Do-Profiles($game, $dvars, $values) {
    # Returns $true when the active profile changed, so the caller reloads.
    for (;;) {
        Head 'Profiles'
        $names = @(Get-Profiles $game)
        $active = Profile-Name $game
        Blank
        for ($i = 0; $i -lt $names.Count; $i++) {
            $f = Path-Join (Config-Dir $game) ($names[$i] + '.cfg')
            $count = 0
            if (Test-Here $f) {
                $count = @(Get-Content -LiteralPath $f |
                           Where-Object { $_ -match '^\s*(?:set\s+)?zp_' }).Count
            }
            $mark = ' '
            if ($names[$i] -eq $active) { $mark = '*' }
            Write-Host ('   {0}{1}. {2,-20} {3} setting(s)' -f $mark, ($i + 1), $names[$i], $count)
        }
        Blank
        Say 'A number switches to that one. n makes a new one from what is open' DarkGray
        Say 'now, x deletes one.  (Enter goes back)' DarkGray
        Blank
        $c = (Read-Line '  >').Trim()
        if (-not $c) { return $false }

        if ($c.ToLower() -eq 'n') {
            Blank
            $name = (Read-Line '  name').Trim()
            if (-not $name) { continue }
            if ($name -notmatch '^[A-Za-z0-9 _-]{1,32}$') {
                Say 'Letters, digits, spaces, dashes and underscores, up to 32.' Red
                continue
            }
            try {
                $dir = Config-Dir $game
                if (-not (Test-Here $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                [IO.File]::WriteAllText((Path-Join $dir ($name + '.cfg')), (Cfg-Text $game $dvars $values))
                $Settings["profile_$game"] = $name
                Save-Settings $Settings
                Say "Made $name and switched to it." Green
                return $true
            } catch { Say ('Could not make it: ' + $_.Exception.Message) Red }
            continue
        }

        if ($c.ToLower() -eq 'x') {
            Blank
            $p = (Read-Line '  which to delete').Trim()
            $n = 0
            if (-not ([int]::TryParse($p, [ref]$n)) -or $n -lt 1 -or $n -gt $names.Count) {
                Say 'Not one of the choices.' Red
                continue
            }
            if ($names[$n - 1] -eq 'default') { Say 'The default one stays.' Red; continue }
            if (-not (Ask ('Delete ' + $names[$n - 1] + '?'))) { continue }
            try {
                Remove-Item -LiteralPath (Path-Join (Config-Dir $game) ($names[$n - 1] + '.cfg')) -Force
                if ($active -eq $names[$n - 1]) {
                    $Settings["profile_$game"] = 'default'
                    Save-Settings $Settings
                    Say 'Deleted, and back on default.' Green
                    return $true
                }
                Say 'Deleted.' Green
            } catch { Say 'Could not delete it.' Red }
            continue
        }

        $n = 0
        if ([int]::TryParse($c, [ref]$n) -and $n -ge 1 -and $n -le $names.Count) {
            if ($names[$n - 1] -eq $active) { return $false }
            if ($script:CfgDirty) {
                Blank
                if (Ask 'Save the open one first?' 'y') { Save-Config $game $dvars $values }
            }
            $Settings["profile_$game"] = $names[$n - 1]
            Save-Settings $Settings
            Say ('Now on ' + $names[$n - 1] + '.') Green
            return $true
        }
        Say 'Type a number, n, x, or Enter to go back.' Red
    }
}

function File-Hash($p) {
    try {
        $sha = [Security.Cryptography.SHA1]::Create()
        return [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($p))).Replace('-', '')
    } catch { return $null }
}

# Writing settings into an installed script changes its bytes, which would
# otherwise read as "somebody edited this". Recording the hash of what we
# wrote is how the listing tells its own work apart from yours.
function Mark-Applied($p) {
    try {
        if (-not (Test-Here $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
        $keep = @()
        if (Test-Here $AppliedFile) {
            $keep = @(Get-Content -LiteralPath $AppliedFile | Where-Object { $_ -notlike ($p + '|*') })
        }
        $keep += ($p + '|' + (File-Hash $p))
        Set-Content -LiteralPath $AppliedFile -Value $keep -Encoding UTF8
    } catch {}
}

function Is-Applied($p) {
    if (-not (Test-Here $AppliedFile)) { return $false }
    try {
        $h = File-Hash $p
        foreach ($line in (Get-Content -LiteralPath $AppliedFile)) {
            $parts = $line -split '\|', 2
            if ($parts.Count -eq 2 -and $parts[0] -eq $p -and $parts[1] -eq $h) { return $true }
        }
    } catch {}
    return $false
}

function Script-For($game) {
    # A pristine text copy first: an installed one may already carry
    # applied settings, and its "defaults" would then be your values.
    # Black Ops 4 has no text script -- its settings come from a manifest,
    # which the editor reads instead.
    if ($game -eq 't8') { return $null }
    $one = Payload-For $game 'file'
    if ($one) { return $one }
    foreach ($c in (Get-Choices)) {
        $one = Payload-In $c.Folder $game 'file'
        if ($one) { return $one }
    }
    foreach ($slot in $SLOTS) {
        if ($slot.Key -ne $game -or $slot.Kind -ne 'file') { continue }
        $f = Slot-Path $slot
        if ($f -and (Test-Here $f)) { return $f }
    }
    return $null
}

<#
    The list of settings for a game, in one shape whatever it came from.

    Four of the five carry a text script, and the settings are read out of
    it -- names, types, defaults, and the section markers that group them.
    Black Ops 4 ships compiled, so the build writes zpause.settings beside
    it instead: one line per setting, name|type|default|section|description,
    generated from the same script. Both end up as the rows the editor
    edits.
#>
function Manifest-For($key) {
    $name = 'zpause.settings'
    foreach ($root in @($script:Root, $HomeRoot)) {
        if (-not $root) { continue }
        foreach ($try in @((Path-Join $root $name), (Path-Join $root ('zpause-' + $key + '.settings')))) {
            if (Test-Here $try) { return $try }
        }
    }
    foreach ($c in (Get-Choices)) {
        foreach ($try in @((Path-Join $c.Folder $name), (Path-Join $c.Folder ('zpause-' + $key + '.settings')))) {
            if (Test-Here $try) { return $try }
        }
    }
    return $null
}

function Read-Manifest($path) {
    $out = @()
    if (-not $path -or -not (Test-Here $path)) { return @($out) }
    $seen = @{}
    foreach ($line in (Get-Content -LiteralPath $path)) {
        if ($line -match '^\s*#' -or -not $line.Trim()) { continue }
        $bits = $line -split '\|', 5
        if ($bits.Count -lt 4) { continue }
        if ($seen.ContainsKey($bits[0])) { continue }
        $seen[$bits[0]] = $true
        $desc = ''
        if ($bits.Count -gt 4) { $desc = $bits[4] }
        $out += [pscustomobject]@{
            Name = $bits[0]; Type = $bits[1]; Default = $bits[2]
            Section = (Get-Culture).TextInfo.ToTitleCase($bits[3].Trim()); Desc = $desc
        }
    }
    return @($out)
}

function Dvars-For($game) {
    if ($game -eq 't8') { return @(Read-Manifest (Manifest-For 't8')) }
    $sp = Script-For $game
    if (-not $sp) { return @() }
    $rows = @(Read-Dvars $sp)
    # The script has no descriptions in it. The manifest beside it does,
    # and unlike the README it travels with the game's files -- so this is
    # what keeps the editor readable when it runs from the bundle.
    $m = Manifest-For $game
    if ($m) {
        $desc = @{}
        foreach ($r in (Read-Manifest $m)) { if ($r.Desc) { $desc[$r.Name] = $r.Desc } }
        foreach ($r in $rows) { if (-not $r.Desc -and $desc.ContainsKey($r.Name)) { $r.Desc = $desc[$r.Name] } }
    }
    return $rows
}

function Read-Dvars($path) {
    $out = @()
    try { $text = [IO.File]::ReadAllText($path) } catch { return @($out) }
    $section = 'Other'
    $seen = @{}
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*//\s*---\s*(.+?)\s*-{3,}\s*$') {
            $section = (Get-Culture).TextInfo.ToTitleCase($Matches[1].Trim())
            continue
        }
        $m = [regex]::Match($line, 'zp_cfg_(int|float|str)\(\s*"([a-z0-9_]+)"\s*,\s*(.*?)\s*\)')
        if (-not $m.Success) { continue }
        $name = $m.Groups[2].Value
        if ($seen.ContainsKey($name)) { continue }
        $seen[$name] = $true
        $def = $m.Groups[3].Value
        if ($m.Groups[1].Value -eq 'str') { $def = $def.Trim('"') }
        $out += [pscustomobject]@{
            Name = $name; Type = $m.Groups[1].Value
            Default = $def; Section = $section; Desc = ''
        }
    }
    return @($out)
}

function Read-Descriptions {
    $d = @{}
    foreach ($root in @($Root, $HomeRoot)) {
        $rme = Path-Join $root 'README.md'
        if (-not (Test-Here $rme)) { continue }
        try { $text = [IO.File]::ReadAllText($rme) } catch { continue }
        foreach ($m in [regex]::Matches($text, '(?m)^\|\s*`(zp_[a-z0-9_]+)`\s*\|[^|]*\|\s*(.+?)\s*\|\s*$')) {
            $k = $m.Groups[1].Value
            if ($d.ContainsKey($k)) { continue }
            $d[$k] = ((($m.Groups[2].Value -replace '\[([^\]]*)\]\([^)]*\)', '$1') -replace '[`*]', '')).Trim()
        }
    }
    return $d
}

function Read-Choices($script) {
    # What a setting is documented to take. The README backticks each value
    # in the description, which is a good enough source to offer them as a
    # list -- and the script itself is the source for the combos and HUD
    # slots, which the README points at rather than listing.
    $out = @{}
    foreach ($root in @($Root, $HomeRoot)) {
        $rme = Path-Join $root 'README.md'
        if (-not (Test-Here $rme)) { continue }
        try { $text = [IO.File]::ReadAllText($rme) } catch { continue }
        foreach ($m in [regex]::Matches($text, '(?m)^\|\s*`(zp_[a-z0-9_]+)`\s*\|[^|]*\|\s*(.+?)\s*\|\s*$')) {
            $k = $m.Groups[1].Value
            if ($out.ContainsKey($k)) { continue }
            $vals = @()
            foreach ($t in [regex]::Matches($m.Groups[2].Value, '`([^`]*)`')) {
                $v = $t.Groups[1].Value
                if ($v -eq '""') { $v = '' }
                # Values only: not another dvar's name, not a number, not prose.
                if ($v -like 'zp_*') { continue }
                if ($v -notmatch '^[a-z_]*$') { continue }
                $vals += $v
            }
            if ($vals.Count -gt 0) { $out[$k] = @($vals | Select-Object -Unique) }
        }
    }

    if ($script -and (Test-Here $script)) {
        try { $body = [IO.File]::ReadAllText($script) } catch { $body = '' }
        $combos = @([regex]::Matches($body, 'combo == "([a-z_]+)"') |
                    ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        $slots = @([regex]::Matches($body, 'position == "([a-z]+)"') |
                   ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        foreach ($d in (Read-Dvars $script)) {
            if ($d.Type -ne 'str') { continue }
            $add = @()
            if ($d.Name -like '*combo*') { $add = $combos }
            elseif ($d.Name -like '*position*') { $add = $slots }
            if ($add.Count -eq 0) { continue }
            $have = @()
            if ($out.ContainsKey($d.Name)) { $have = $out[$d.Name] }
            $out[$d.Name] = @(@($have + $add + @($d.Default)) | Select-Object -Unique)
        }
    }
    return $out
}

function Show-Val($v) {
    if ("$v" -eq '') { return '""' }
    return "$v"
}

function Load-Config($game) {
    $v = @{}
    $f = Config-File $game
    if (-not (Test-Here $f)) { return $v }
    foreach ($line in (Get-Content -LiteralPath $f)) {
        if ($line -match '^\s*(?://.*)?$') { continue }
        if ($line -match '^\s*(?:set\s+|seta\s+)?(zp_[a-z0-9_]+)\s+"(.*)"\s*$') { $v[$Matches[1]] = $Matches[2]; continue }
        if ($line -match '^\s*(?:set\s+|seta\s+)?(zp_[a-z0-9_]+)\s+(\S+)\s*$') { $v[$Matches[1]] = $Matches[2] }
    }
    return $v
}

function Cfg-Text($game, $dvars, $values) {
    $lines = @(
        ('// ZPause configuration -- ' + $game.ToUpper() + '  ' + $GAME_NAMES[$game]),
        '// Written by the ZPause Manager. Safe to read, edit, copy and share.',
        '//',
        '// Only settings that differ from the default are listed, so this stays',
        '// short and keeps working when a default changes in a later version.',
        '//',
        '// On a dedicated server: exec this file, or paste the lines into your',
        '// server config.',
        ''
    )
    $any = $false
    foreach ($d in $dvars) {
        if (-not $values.ContainsKey($d.Name)) { continue }
        if ("$($values[$d.Name])" -eq "$($d.Default)") { continue }
        $lines += ('set {0} "{1}"' -f $d.Name, $values[$d.Name])
        $any = $true
    }
    if (-not $any) { $lines += '// (everything is at its default)' }
    return (($lines -join "`r`n") + "`r`n")
}

function Apply-ToScripts($game, $dvars, $values) {
    # Rewrites the default in each zp_cfg_ call of every installed text copy
    # for this game. Nothing else in the file is touched, and the file it
    # replaces is backed up first like any other write. A compiled copy has
    # no text in it to rewrite; it is reported, not silently skipped.
    $done = 0
    $script:ApplySkipped = @()
    foreach ($slot in $SLOTS) {
        if ($slot.Key -ne $game) { continue }
        if ($slot.Kind -eq 'folder') { continue }
        $f = Slot-Path $slot
        if (-not $f -or -not (Test-Here $f)) { continue }
        if ($slot.Kind -eq 'compiled' -or (Is-Compiled $f)) { $script:ApplySkipped += $slot.Game; continue }
        try { $text = [IO.File]::ReadAllText($f) } catch { continue }
        $before = $text
        foreach ($d in $dvars) {
            if (-not $values.ContainsKey($d.Name)) { continue }
            $val = "$($values[$d.Name])"
            if ($d.Type -eq 'str') { $lit = '"' + $val + '"' } else { $lit = $val }
            $name = $d.Name
            $pat = 'zp_cfg_(int|float|str)\(\s*"' + [regex]::Escape($name) + '"\s*,\s*[^)]*?\s*\)'
            $text = [regex]::Replace($text, $pat, {
                param($m)
                'zp_cfg_' + $m.Groups[1].Value + '( "' + $name + '", ' + $lit + ' )'
            })
        }
        if ($text -ne $before) {
            Backup-File $f
            [IO.File]::WriteAllText($f, $text)
            Mark-Applied $f
            Log 'configured' $f
            $done++
        }
    }
    $script:RefCache = @{}
    return $done
}

function Is-Compiled($path) {
    # Compiled GSC opens with the four bytes 80 47 53 43.
    try {
        $fs = [IO.File]::OpenRead($path)
        try {
            $head = New-Object byte[] 4
            if ($fs.Read($head, 0, 4) -lt 4) { return $false }
        } finally { $fs.Dispose() }
    } catch { return $false }
    return ($head[0] -eq 0x80 -and $head[1] -eq 0x47 -and
            $head[2] -eq 0x53 -and $head[3] -eq 0x43)
}

function Apply-How {
    $how = $Settings['config_apply']
    if ($how -ne 'script' -and $how -ne 'cfg') { $how = 'both' }
    return $how
}

function Choose-Apply {
    Head 'How should your settings be applied?'
    Blank
    Say '    1. both -- written into the installed script, and exported as a cfg'
    Say '    2. into the installed script only'
    Say '    3. exported as a cfg only'
    Blank
    Say 'Writing into the script is what makes settings stick for a normal' DarkGray
    Say 'co-op host: Plutonium rewrites its own player cfg, so dvars put there' DarkGray
    Say 'do not survive. The exported cfg is the portable one -- exec it on a' DarkGray
    Say 'dedicated server, or send it to somebody.' DarkGray
    Blank
    $c = (Read-Line '  which').Trim()
    if ($c -eq '1') { $Settings['config_apply'] = 'both' }
    elseif ($c -eq '2') { $Settings['config_apply'] = 'script' }
    elseif ($c -eq '3') { $Settings['config_apply'] = 'cfg' }
    else { Say 'Left as it was.' DarkGray; return }
    Save-Settings $Settings
    Say ('Set to: ' + $Settings['config_apply']) Green
}

function Cfg-Home($game) {
    # Where the exported cfg goes: beside the game's own scripts, so it is
    # where a dedicated server would look for it.
    $g = Game-For $game
    switch ($g.Family) {
        'pluto' { return (Path-Join (Root-Quiet 'pluto') ('storage\' + $game + '\zpause.cfg')) }
        'bo3'   { return (Path-Join (Root-Quiet 'bo3') 'zpause.cfg') }
        'bo4'   { return (Path-Join (Root-Quiet 'bo4') 'project-bo4\saved\server\zpause.cfg') }
    }
    return $null
}

<#
    Black Ops 4 reads its settings from a JSON file at load: a list of
    { name, value } objects, not one object of pairs, because Shield turns
    a JSON object into a script struct whose fields can only be read by a
    name written into the script, and a list into an array a loop can walk.

    Written without a byte-order mark. Set-Content -Encoding utf8 adds one
    on Windows PowerShell 5.1, and a BOM in front of a "[" is not JSON to
    the parser reading it -- the whole file would be ignored and every
    setting would silently stay at its default.
#>
function Json-Home {
    $base = Root-Quiet 'bo4'
    if (-not $base) { return $null }
    return (Path-Join $base 'project-bo4\saved\server\zpause.json')
}

function Write-Json-Values($dvars, $values) {
    $f = Json-Home
    if (-not $f) { return -1 }
    $parts = @()
    foreach ($d in $dvars) {
        if (-not $values.ContainsKey($d.Name)) { continue }
        $v = "$($values[$d.Name])"
        if ($v -eq "$($d.Default)") { continue }
        if ($d.Type -eq 'str') { $lit = '"' + ($v -replace '"', '\"') + '"' } else { $lit = $v }
        $parts += ('    { "name": "' + $d.Name + '", "value": ' + $lit + ' }')
    }
    try {
        if ($parts.Count -eq 0) {
            # Nothing to say. Removing it is how "everything at default" is
            # expressed -- and a file that is not there cannot be half-written.
            if (Test-Here $f) { Backup-File $f; Remove-Item -LiteralPath $f -Force; Log 'removed' $f }
            return 0
        }
        $dir = Split-Path -Parent $f
        if (-not (Test-Here $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Backup-File $f
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [IO.File]::WriteAllText($f, ("[`n" + ($parts -join ",`n") + "`n]`n"), $utf8)
        Log 'configured' $f
        return $parts.Count
    } catch {
        Say ('Could not write ' + $f + ': ' + $_.Exception.Message) Red
        return -1
    }
}

<#
    T7x runs a compiled script, so nothing can be written into it. What it
    does have is an exec that reads from disk: its patched Cmd_Exec prefers
    a file under its gamesettings folder, matched on the last two path
    components -- so this is "zpause/zpause.cfg", and that is what the
    player types. Both folders it searches are written, since which one
    exists depends on how the client was set up.

    Its own file rather than an override of a stock gamesettings one: the
    disk copy replaces the fastfile's, and zm/gamesettings_zclassic.cfg
    carries scorelimit, startRound, magic and allowdogs. A settings editor
    should not be able to change how the game plays.
#>
function T7x-Cfg-Paths {
    $out = @()
    $appdata = Path-Join $env:LOCALAPPDATA 't7x\data'
    if (Test-Here $appdata) { $out += (Path-Join $appdata 'gamesettings\zpause\zpause.cfg') }
    $bo3 = Root-Quiet 'bo3'
    if ($bo3 -and (Test-Here (Path-Join $bo3 't7x'))) {
        $out += (Path-Join $bo3 't7x\gamesettings\zpause\zpause.cfg')
    }
    return @($out)
}

function Write-T7x-Cfg($dvars, $values) {
    $written = $null
    foreach ($out in (T7x-Cfg-Paths)) {
        try {
            $dir = Split-Path -Parent $out
            if (-not (Test-Here $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [IO.File]::WriteAllText($out, (Cfg-Text 't7' $dvars $values))
            Log 'exported' $out
            if (-not $written) { $written = $out }
        } catch {
            Say ('Could not write ' + $out + ': ' + $_.Exception.Message) Red
        }
    }
    return $written
}

function Apply-Values($game, $dvars, $values, $quiet) {
    # The one place that knows how a game takes its settings. Returns the
    # number of places written; says what it did unless told not to.
    if ($game -eq 't8') {
        $n = Write-Json-Values $dvars $values
        if ($n -gt 0 -and -not $quiet) {
            Say ("Written to " + (Json-Home) + " -- it takes effect on the next match.") Green
        } elseif ($n -eq 0 -and -not $quiet) {
            Say 'Everything is at its default, so no settings file is needed.' DarkGray
        }
        return $n
    }

    $n = Apply-ToScripts $game $dvars $values
    if (-not $quiet) {
        if ($n -gt 0) {
            Say "Written into $n installed script(s) -- it takes effect on the next pause." Green
        } else {
            Say 'Nothing installed to write it into yet; it will be applied when you install.' DarkGray
        }
    }
    if ($script:ApplySkipped -and $script:ApplySkipped.Count -gt 0) {
        $cfg = $null
        if ($game -eq 't7') { $cfg = Write-T7x-Cfg $dvars $values }
        if (-not $quiet) {
            foreach ($name in $script:ApplySkipped) {
                Say ("$name runs a compiled script, so settings cannot be written into it.") Yellow
            }
            if ($cfg) {
                Say ("Written to " + $cfg + " instead.") Green
                Say 'In game, open the console and run:' DarkGray
                Say '    exec zpause/zpause.cfg' White
                Say 'Once per session, or bind it. T7x reads cfgs from that folder.' DarkGray
            } else {
                Say 'Its settings come from the console.' DarkGray
            }
        }
        if ($cfg) { $n++ }
    }
    return $n
}

function Save-Config($game, $dvars, $values) {
    $how = Apply-How
    try {
        # The profile lives a folder deeper than $ConfigDir, so create that
        # one -- not its parent.
        $dir = Config-Dir $game
        if (-not (Test-Here $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllText((Config-File $game), (Cfg-Text $game $dvars $values))
    } catch {
        Say ('Could not save: ' + $_.Exception.Message) Red
        return
    }
    Blank
    Say ('Saved to ' + (Config-File $game)) Green

    if ($how -eq 'both' -or $how -eq 'cfg') {
        $out = Cfg-Home $game
        try {
            $dir = Split-Path -Parent $out
            if (-not (Test-Here $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [IO.File]::WriteAllText($out, (Cfg-Text $game $dvars $values))
            Log 'exported' $out
            Say ('Exported to ' + $out) Green
            Say 'On a dedicated server, exec that file. It is also the one to share.' DarkGray
        } catch { Say ('Could not export: ' + $_.Exception.Message) Red }
    }

    if ($how -eq 'both' -or $how -eq 'script') {
        [void](Apply-Values $game $dvars $values $false)
    }
}

function Reapply-Config {
    # A config set once should survive an update. Called after every install,
    # so a new version never quietly puts you back to the defaults.
    if ((Apply-How) -eq 'cfg') { return }
    foreach ($g in $GAMES) {
        if (-not (Test-Here (Config-File $g.Key))) { continue }
        $values = Load-Config $g.Key
        if ($values.Count -eq 0) { continue }
        $dvars = @(Dvars-For $g.Key)
        if ($dvars.Count -eq 0) { continue }
        $n = Apply-Values $g.Key $dvars $values $true
        if ($n -gt 0) { Say ("Put your saved $($g.Tag) settings back, in $n place(s).") DarkCyan }
    }
}

function Config-Game {
    if ($Game -and (Game-For $Game.Trim().ToLower())) { return $Game.Trim().ToLower() }
    if (Game-For $Release['game']) { return $Release['game'] }

    Head 'Configure which game?'
    Blank
    $rows = @(Get-Installed)
    for ($i = 0; $i -lt $GAMES.Count; $i++) {
        $g = $GAMES[$i]
        $mine = @($rows | Where-Object { $_.Key -eq $g.Key })
        $state = 'not installed'
        if ($mine.Count -gt 0) { $state = 'installed v' + $mine[0].Version }
        $mark = ' '
        if ($Settings['config_game'] -eq $g.Key) { $mark = '*' }
        Write-Host ('   {0}{1}. {2}  {3,-14} {4}' -f $mark, ($i + 1), $g.Tag, $g.Name, $state)
    }
    Blank
    Say '     (Enter goes back)' DarkGray
    Blank
    $c = (Read-Line '  which').Trim()
    if (-not $c) { return $null }
    $n = 0
    if (-not ([int]::TryParse($c, [ref]$n)) -or $n -lt 1 -or $n -gt $GAMES.Count) {
        Say 'Not one of the choices.' Red
        return $null
    }
    $Settings['config_game'] = $GAMES[$n - 1].Key
    Save-Settings $Settings
    return $GAMES[$n - 1].Key
}

function Edit-One($d, $values) {
    Blank
    Write-Host ('  ' + $d.Name) -ForegroundColor (Tint White)
    if ($d.Desc) { Say $d.Desc DarkGray }
    $cur = $d.Default
    if ($values.ContainsKey($d.Name)) { $cur = $values[$d.Name] }
    Say ('now: ' + (Show-Val $cur) + '    default: ' + (Show-Val $d.Default)) DarkGray

    # A setting with a fixed set of values is where a typo does nothing at
    # all in game, silently. Offer the list.
    $picks = @()
    if ($script:Choices.ContainsKey($d.Name)) { $picks = @($script:Choices[$d.Name]) }
    if ($picks.Count -ge 2) {
        Blank
        Say 'It takes one of these:' DarkGray
        for ($i = 0; $i -lt $picks.Count; $i++) {
            $mark = '  '
            if ("$($picks[$i])" -eq "$cur") { $mark = '->' }
            Write-Host ('   {0} {1}. {2}' -f $mark, ($i + 1), (Show-Val $picks[$i])) -ForegroundColor (Tint Gray)
        }
    }

    Blank
    if ($picks.Count -ge 2) {
        Say 'Type a number from that list, or a value of your own.' DarkGray
        Say 'd puts it back to the default; Enter leaves it alone.' DarkGray
    } else {
        Say 'Type a new value, d for the default, or Enter to leave it alone.' DarkGray
    }
    $v = Read-Line ('  ' + $d.Name)
    if ($null -eq $v -or $v -eq '') { return }
    $v = $v.Trim()
    if ($v.ToLower() -eq 'd') {
        [void]$values.Remove($d.Name)
        $script:CfgDirty = $true
        $script:CountSettings++
        Say 'back to the default.' DarkGray
        return
    }
    $pick = 0
    if ($picks.Count -ge 2 -and [int]::TryParse($v, [ref]$pick) -and
        $pick -ge 1 -and $pick -le $picks.Count -and $d.Type -eq 'str') {
        $v = $picks[$pick - 1]
    }
    $v = $v.Trim('"')
    if ($d.Type -eq 'int') {
        $t = 0
        if (-not [int]::TryParse($v, [ref]$t)) { Say 'That one takes a whole number.' Red; return }
    } elseif ($d.Type -eq 'float') {
        $t = 0.0
        if (-not [double]::TryParse($v, [ref]$t)) { Say 'That one takes a number.' Red; return }
    }
    $values[$d.Name] = $v
    $script:CfgDirty = $true
    $script:CountSettings++
    Say ('set to ' + (Show-Val $v)) Green
}

function Edit-List($list, $values, $title) {
    if ($list.Count -eq 0) { Blank; Say 'Nothing matches.' DarkGray; return }
    for (;;) {
        Head $title
        Blank
        for ($i = 0; $i -lt $list.Count; $i++) {
            $d = $list[$i]
            $cur = $d.Default
            if ($values.ContainsKey($d.Name)) { $cur = $values[$d.Name] }
            $changed = ("$cur" -ne "$($d.Default)")
            $tail = ''
            $colour = 'Gray'
            if ($changed) {
                $tail = '   (default ' + (Show-Val $d.Default) + ')'
                $colour = 'Yellow'
            }
            Write-Host ('   {0,2}. {1,-26} {2}{3}' -f ($i + 1), $d.Name,
                        (Show-Val $cur), $tail) -ForegroundColor (Tint $colour)
            if ($d.Desc) { Write-Host ('       ' + $d.Desc) -ForegroundColor (Tint DarkGray) }
        }
        Blank
        Say '     (a number changes one, Enter goes back)' DarkGray
        Blank
        $c = (Read-Line '  >').Trim()
        if (-not $c) { return }
        $n = 0
        if ([int]::TryParse($c, [ref]$n) -and $n -ge 1 -and $n -le $list.Count) {
            Edit-One $list[$n - 1] $values
        } else {
            Say 'Type one of the numbers, or Enter to go back.' Red
        }
    }
}

function Show-DefaultMoves($key) {
    # A default that changes between versions moves the game under anyone
    # who never set that value. Worth one screen, and only for the settings
    # you are actually leaving to the default.
    if ($key -eq 't8') { return }
    $new = Payload-For $key 'file'
    if (-not $new) { return }
    $rows = @(@(Get-Installed) | Where-Object { $_.Key -eq $key -and $_.Kind -eq 'file' })
    if ($rows.Count -eq 0) { return }
    $old = Ref-For $rows[0].Version $key 'file'
    if (-not $old -or $old -eq $new) { return }

    $was = @{}
    foreach ($d in (Read-Dvars $old)) { $was[$d.Name] = $d.Default }
    $vals = Load-Config $key
    $moved = @()
    foreach ($d in (Read-Dvars $new)) {
        if (-not $was.ContainsKey($d.Name)) { continue }
        if ("$($was[$d.Name])" -eq "$($d.Default)") { continue }
        if ($vals.ContainsKey($d.Name)) { continue }
        $moved += ('{0,-26} {1} -> {2}' -f $d.Name, (Show-Val $was[$d.Name]), (Show-Val $d.Default))
    }
    if ($moved.Count -eq 0) { return }

    Head ((Game-For $key).Tag + ' -- defaults that move with this version')
    Blank
    Say 'You are on the default for these, so the update changes them:' DarkGray
    Blank
    foreach ($m in $moved) { Say ('  ' + $m) }
    Blank
    Say 'Set any of them in the config editor to pin it where it is.' DarkGray
}

function Do-Config {
    $game = Config-Game
    if (-not $game) { return }

    $dvars = @(Dvars-For $game)
    if ($dvars.Count -eq 0) {
        Head 'Configure ZPause'
        Blank
        if ($game -eq 't8') {
            Say 'No zpause.settings to read the Black Ops 4 settings from.' Yellow
        } else {
            Say ('No ' + $game.ToUpper() + ' script to read the settings from.') Yellow
        }
        Say 'Install it first, or run this from the download.' DarkGray
        return
    }
    $desc = Read-Descriptions
    foreach ($d in $dvars) { if (-not $d.Desc -and $desc.ContainsKey($d.Name)) { $d.Desc = $desc[$d.Name] } }
    $script:Choices = Read-Choices (Script-For $game)
    $values = Load-Config $game
    $script:CfgDirty = $false

    for (;;) {
        Head ('Configure ZPause -- ' + $game.ToUpper() + '  ' + $GAME_NAMES[$game] +
              '  [' + (Profile-Name $game) + ']')
        $sections = @($dvars | ForEach-Object { $_.Section } | Select-Object -Unique)
        $total = @($dvars | Where-Object {
            $values.ContainsKey($_.Name) -and "$($values[$_.Name])" -ne "$($_.Default)" }).Count
        Blank
        for ($i = 0; $i -lt $sections.Count; $i++) {
            $inSec = @($dvars | Where-Object { $_.Section -eq $sections[$i] })
            $changed = @($inSec | Where-Object {
                $values.ContainsKey($_.Name) -and "$($values[$_.Name])" -ne "$($_.Default)" }).Count
            $note = ''
            if ($changed -gt 0) { $note = "   $changed changed" }
            Write-Host ('    {0}. {1,-20} {2,2} settings{3}' -f ($i + 1), $sections[$i],
                        $inSec.Count, $note)
        }
        Blank
        if ($total -gt 0) { Say "$total setting(s) differ from the defaults." Yellow }
        if ($script:CfgDirty) { Say 'Unsaved -- w writes and applies them.' Yellow }
        Say ('applying: ' + (Apply-How)) DarkGray
        Blank
        Say '  /  find a setting by name  (or just type the name)' DarkGray
        Say '  p  profiles' DarkGray
        Say '  w  save and apply' DarkGray
        Say '  e  export a copy somewhere else' DarkGray
        Say '  i  import a config file' DarkGray
        Say '  m  change how settings are applied' DarkGray
        Say '  x  put everything back to the defaults' DarkGray
        Say '     (Enter goes back)' DarkGray
        Blank
        $c = (Read-Line '  >').Trim()

        if (-not $c) {
            if ($script:CfgDirty) {
                Blank
                if (Ask 'Save your changes first?' 'y') { Save-Config $game $dvars $values }
            }
            return
        }
        $n = 0
        if ([int]::TryParse($c, [ref]$n) -and $n -ge 1 -and $n -le $sections.Count) {
            Edit-List @($dvars | Where-Object { $_.Section -eq $sections[$n - 1] }) $values $sections[$n - 1]
            continue
        }
        # Typing a setting's name goes straight to it, with or without the
        # prefix, because that is what anyone who knows the name will try.
        $hit = $dvars | Where-Object {
            $_.Name -eq $c.ToLower() -or $_.Name -eq ('zp_' + $c.ToLower()) } | Select-Object -First 1
        if ($hit) { Edit-One $hit $values; continue }

        switch ($c.ToLower()) {
            'p' {
                if (Do-Profiles $game $dvars $values) {
                    $values = Load-Config $game
                    $script:CfgDirty = $false
                }
            }
            '/' {
                Blank
                $q = (Read-Line '  find').Trim().ToLower()
                if ($q) {
                    Edit-List @($dvars | Where-Object {
                        $_.Name.ToLower().Contains($q) -or $_.Desc.ToLower().Contains($q) }) $values "Matching '$q'"
                }
            }
            'w' { Save-Config $game $dvars $values; $script:CfgDirty = $false }
            'e' {
                Blank
                Say 'Where should the copy go? Paste a folder or a full file path.' DarkGray
                $p = (Read-Line '  path').Trim().Trim('"')
                if ($p) {
                    try {
                        if (Test-Here $p) { $p = Path-Join $p ('zpause-' + $game + '.cfg') }
                        [IO.File]::WriteAllText($p, (Cfg-Text $game $dvars $values))
                        Log 'exported' $p
                        Say ('Written to ' + $p) Green
                    } catch { Say ('Could not write it: ' + $_.Exception.Message) Red }
                }
            }
            'i' {
                Blank
                Say 'Paste the path of a zpause cfg to read in.' DarkGray
                $p = (Read-Line '  path').Trim().Trim('"')
                if ($p -and (Test-Here $p)) {
                    $add = 0
                    foreach ($line in (Get-Content -LiteralPath $p)) {
                        if ($line -match '^\s*(?:set\s+|seta\s+)?(zp_[a-z0-9_]+)\s+"?([^"]*)"?\s*$') {
                            $values[$Matches[1]] = $Matches[2]
                            $add++
                        }
                    }
                    $script:CfgDirty = $true
                    Say "Read $add setting(s). Nothing is written until you save." Green
                } elseif ($p) { Say 'No such file.' Red }
            }
            'm' { Choose-Apply }
            'x' {
                Blank
                if (Ask 'Put every setting back to its default?') {
                    $values.Clear()
                    $script:CfgDirty = $true
                    Say 'All back to the defaults. Save to apply it.' Green
                }
            }
            default { Say 'Type a section number, or one of the letters.' Red }
        }
    }
}

# ------------------------------------------------- check my setup
#
# "It is not working" is almost always one of a handful of things, and none
# of them are visible from inside the game. This looks for each of them and
# says which it found.
function Do-Doctor {
    Head 'Check my setup'
    $rows = @(Get-Installed)

    function Ok($t) { Say ("ok    " + $t) Green; $script:DocGood++ }
    function Warn($t) { Say ("check " + $t) Yellow; $script:DocBad++ }
    function Note($t) { Say ("note  " + $t) DarkGray }

    $script:DocGood = 0
    $script:DocBad = 0
    Blank

    if ($rows.Count -eq 0) {
        Warn 'ZPause is not installed on this PC at all.'
        Note 'Menu item 1 installs it.'
        Blank
        return
    }

    foreach ($game in $GAMES) {
        $g = $game.Key
        $mine = @($rows | Where-Object { $_.Key -eq $g })
        if ($mine.Count -eq 0) { continue }
        $vers = @($mine | ForEach-Object { $_.Version } | Select-Object -Unique)
        $tag = $game.Tag
        if ($vers.Count -gt 1) {
            Warn "$tag has copies at different versions: v$($vers -join ', v')."
            Note '      Installing again writes all of them at the same version.'
        } else {
            Ok "$tag is installed, v$($vers[0]), in $($mine.Count) place(s)."
        }

        # T6 reads one script path or the other depending on how old the
        # build is. The installer writes both; only a hand-install has one.
        if ($g -eq 't6') {
            $raw = @($mine | Where-Object { $_.Path -like '*\raw\scripts\zm\*' }).Count
            $plain = @($mine | Where-Object { $_.Path -like '*\storage\t6\scripts\zm\*' }).Count
            if ($raw -eq 0 -or $plain -eq 0) {
                Warn 'Only one of the two T6 script paths has ZPause in it.'
                Note '      Which one your build reads depends on its age, so both should have it.'
            }
            if (@($mine | Where-Object { $_.Path -like '*\mods\zm_pause\*' }).Count -gt 0) {
                Note 'The mod-folder copy is present. It does nothing unless zm_pause is'
                Note '      picked in the in-game Mods menu, and that takes your one mod slot.'
            }
        }
    }

    # Files that do not match the version they claim, minus the ones this
    # installer configured itself.
    $edited = @()
    foreach ($r in $rows) {
        if ($r.Kind -eq 'folder') { continue }
        $known = Ref-For $r.Version $r.Key $r.Kind
        if ($known -and -not (Same-File $known $r.Path) -and -not (Is-Applied $r.Path)) {
            $edited += $r.Path
        }
        if ($r.Version -eq '?') { Warn ('Cannot read a version out of ' + $r.Path) }
    }
    if ($edited.Count -gt 0) {
        Warn "$($edited.Count) installed file(s) do not match the version they claim."
        Note '      Something edited them after they were installed. Menu item 1 puts'
        Note '      a clean copy back; r puts your own copy back.'
    }

    # A saved config that has not reached the game.
    foreach ($game in $GAMES) {
        $g = $game.Key
        if (-not (Test-Here (Config-File $g))) { continue }
        $how = Apply-How
        if ($g -eq 't8') {
            if (@($rows | Where-Object { $_.Key -eq 't8' }).Count -eq 0) { continue }
            $vals = Load-Config 't8'
            $json = Json-Home
            if ($vals.Count -gt 0 -and $json -and -not (Test-Here $json)) {
                Warn 'T8 has saved settings that have not been written for the game to read.'
                Note '      Open the config editor and save, or install again.'
            } elseif ($vals.Count -gt 0) {
                Ok 'T8 settings are written where the game reads them.'
            }
            continue
        }
        $mine = @($rows | Where-Object { $_.Key -eq $g -and $_.Kind -eq 'file' })
        if ($mine.Count -eq 0) { continue }
        if ($how -eq 'cfg') {
            Note "$($g.ToUpper()) has saved settings, exported as a cfg only."
            Note '      Nothing was written into the script, so the game needs to exec it.'
        } elseif (@($mine | Where-Object { Is-Applied $_.Path }).Count -eq 0) {
            Warn "$($g.ToUpper()) has saved settings that are not in the installed script."
            Note '      Open the config editor and save, or install again.'
        } else {
            Ok "$($g.ToUpper()) settings are in the installed script."
        }
    }

    # The download beside the installer, against its own manifest.
    if (Is-Download $Root) {
        $sums = Verify-Sums $Root
        if ($sums -lt 0) {
            Warn 'The download this installer came from does not match its checksums.'
            Note '      Extract the zip again, or fetch it again.'
        } elseif ($sums -gt 0) {
            Ok "The download checks out: $sums file(s) match SHA256SUMS."
        }
    } else {
        Note 'Running from a source folder, not a download, so there is no'
        Note '      manifest to check it against.'
    }

    # Can it write there at all? One probe per game folder that resolved.
    foreach ($fam in @('pluto', 'bo3', 'bo4')) {
        $base = Root-Of $fam
        if (-not $base) { continue }
        $label = $FAMILIES[$fam].Label
        try {
            $probe = Path-Join $base 'zpause.probe'
            Set-Content -LiteralPath $probe -Value 'x' -ErrorAction Stop
            Remove-Item -LiteralPath $probe -Force
            Ok "The $label folder is writable."
        } catch {
            Warn "The $label folder cannot be written to from here."
            Note '      Run the installer as the same user that installed the game.'
        }
    }

    Blank
    $kept = @(Get-Library)
    if ($kept.Count -gt 0) {
        Note ("$($kept.Count) download(s) kept, " + (Fmt-Bytes (Dir-Size $CacheDir)) + '.')
    }
    if (Test-Here $BackupDir) {
        Note ('Backups: ' + (Fmt-Bytes (Dir-Size $BackupDir)) + '.')
    }
    Blank
    if ($script:DocBad -eq 0) {
        Say 'Nothing looks wrong.' Green
    } else {
        Say "$($script:DocBad) thing(s) worth looking at, above." Yellow
    }
}

function Show-Status {
    # One line that says where you are, so the menu never needs a detour
    # through "what is installed" just to check.
    $rows = @(Get-Installed)
    $seen = @($rows | ForEach-Object { $_.Version } | Select-Object -Unique)
    if ($rows.Count -eq 0) { $state = 'not installed' }
    elseif ($seen.Count -eq 1) { $state = 'installed v' + $seen[0] }
    else { $state = 'installed, mixed versions' }

    $bits = @()
    if ($Release['name']) { $bits += $Release['name'] } else { $bits += 'ZPause' }
    $bits += $state
    if ($script:LatestVersion) { $bits += 'latest v' + $script:LatestVersion }
    $kept = @(Get-Library).Count
    if ($kept -gt 0) { $bits += "$kept kept" }
    Write-Host ('  ' + ($bits -join '  |  ')) -ForegroundColor (Tint DarkCyan)
}

function Do-Farewell {
    Do-Prune
    Show-OtherMods
    Blank
    # What this run actually did, in one line, because a long session
    # scrolls the answer off the top.
    $did = @()
    if ($script:CountInstalled -gt 0) {
        $did += "installed $($script:CountInstalled) file(s)"
        if ($Release['version']) { $did[-1] += " at v$($Release['version'])" }
    }
    if ($script:CountRemoved -gt 0) { $did += "removed $($script:CountRemoved)" }
    if ($script:CountRestored -gt 0) { $did += "put back $($script:CountRestored)" }
    if ($script:CountSettings -gt 0) { $did += "changed $($script:CountSettings) setting(s)" }
    if ($script:CountDropped -gt 0) { $did += "deleted $($script:CountDropped) download(s)" }
    if ($did.Count -gt 0) { Say ('This run: ' + ($did -join ', ') + '.') DarkCyan }

    if ($script:DidInstall) {
        Say 'ZPause is installed. Have fun.' Green
    } else {
        Say 'Nothing left to do.' DarkGray
    }
    Blank
}

# ------------------------------------------------- menu
$script:LatestVersion = $null
$script:Online = $false
$script:DidInstall = $false
$script:Downloaded = $false
$script:CountInstalled = 0
$script:CountRemoved = 0
$script:CountRestored = 0
$script:CountSettings = 0
$script:CountDropped = 0

# ---- one thing, then stop -------------------------------------------
# So a support answer can be a line somebody pastes rather than a list of
# keys to press, and so a shortcut can be wired to a plain install.
if ($Install -or $Uninstall -or $List -or $Configure) {
    if ($Uninstall) { Do-Uninstall $true }
    elseif ($List) { [void](Show-Installed) }
    elseif ($Configure) { Do-Config }
    else {
        $k = $null
        if (Game-For $Release['game']) { $k = $Release['game'] }
        Do-Install $false $k
    }
    Blank
    return
}

[void](Show-Installed)

# ---- the common case, in one keystroke -------------------------------
# Most runs are somebody who downloaded the zip and wants it installed.
# That should not start with a menu.
$installedNow = @(@(Get-Installed) | ForEach-Object { $_.Version } | Select-Object -Unique)
$mine = $Release['version']
if ($Payload -and (Test-Here $Payload) -and $mine -and
    -not ($installedNow.Count -eq 1 -and $installedNow[0] -eq $mine)) {
    Blank
    Say ('Ready to install {0} v{1}.' -f $Release['name'], $mine) Green
    Say 'Press Enter to go ahead, or m for the menu.' DarkGray
    Blank
    $go = (Read-Line '  >').Trim().ToLower()
    if ($go -eq '' -or $go.StartsWith('y')) {
        $k = $null
        if (Game-For $Release['game']) { $k = $Release['game'] }
        Do-Install $true $k
    }
}

# Asked once, up front, and never assumed: answer no and this script makes
# no network connection of any kind.
Blank
if (Ask 'Check GitHub for a newer version?') { Do-Check }

for (;;) {
    Blank
    Show-Status
    Blank
    Write-Host '    1  install or update ZPause here' -ForegroundColor (Tint Gray)
    Write-Host '    2  what is installed' -ForegroundColor (Tint Gray)
    Write-Host '    3  install a different version' -ForegroundColor (Tint Gray)
    Write-Host '    4  configure ZPause' -ForegroundColor (Tint Gray)
    Write-Host '    5  remove ZPause' -ForegroundColor (Tint Gray)
    Write-Host '    6  check GitHub for the latest version' -ForegroundColor (Tint Gray)
    Write-Host '    d  check my setup' -ForegroundColor (Tint DarkGray)
    if (Test-Here (Path-Join $StateDir 'install.ps1')) {
        Write-Host '    7  remove the kept installer' -ForegroundColor (Tint Gray)
    } else {
        Write-Host '    7  keep this installer on this PC' -ForegroundColor (Tint Gray)
    }
    if ((Get-Backups).Count -gt 0) {
        Write-Host '    r  put back a file it replaced' -ForegroundColor (Tint DarkGray)
    }
    Write-Host '    p  use a different game folder' -ForegroundColor (Tint DarkGray)
    Write-Host '    q  quit' -ForegroundColor (Tint DarkGray)
    Blank
    $choice = (Read-Line '  >').Trim().ToLower()
    if ($choice -eq '1') { Do-Install $false }
    elseif ($choice -eq '2') {
        $rows = @(Show-Installed)
        if ($rows.Count -gt 0) {
            Blank
            Say 'Item 3 installs a different version; item 4 changes its settings.' DarkGray
        }
    }
    elseif ($choice -eq '3') { Do-Versions }
    elseif ($choice -eq '4') { Do-Config }
    elseif ($choice -eq '5') { Do-Uninstall $false }
    elseif ($choice -eq '6') { Do-Check }
    elseif ($choice -eq '7') { Do-Persist }
    elseif ($choice -eq 'r') { Do-Restore }
    elseif ($choice -eq 'd') { Do-Doctor }
    elseif ($choice -eq 'p') {
        Head 'Which game folder?'
        Blank
        $fams = @('pluto', 'bo3', 'bo4')
        for ($i = 0; $i -lt $fams.Count; $i++) {
            $cur = Root-Of $fams[$i]
            if (-not $cur) { $cur = '(not set)' }
            Write-Host ('    {0}. {1,-14} {2}' -f ($i + 1), $FAMILIES[$fams[$i]].Label, $cur)
        }
        Blank
        $c = (Read-Line '  which').Trim()
        $n = 0
        if ([int]::TryParse($c, [ref]$n) -and $n -ge 1 -and $n -le $fams.Count) {
            $fam = $fams[$n - 1]
            $pick = Choose-Root $fam @(Find-Roots $fam) $true
            if ($pick) {
                $script:Roots[$fam] = $pick
                if ($fam -eq 'pluto') { $PLUTO = $pick }
                $Settings[$fam] = $pick
                Save-Settings $Settings
                Head $FAMILIES[$fam].Label
                Say $pick
                [void](Show-Installed)
            }
        }
    }
    elseif ($choice -eq 'q') { Do-Farewell; return }
    elseif ($choice -ne '') { Say 'Type one of the numbers, or q to quit.' Red }
}
