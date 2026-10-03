$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'
$root = Join-Path $env:TEMP ('wsl-copilot-' + [guid]::NewGuid().ToString())
New-Item -ItemType Directory $root | Out-Null
$lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
$archive = (Get-ChildItem packages -Recurse -Filter test_distro.tar.xz | Where-Object FullName -Match '\\x64\\' | Select-Object -First 1).FullName
if (-not $archive) { throw 'Test distribution archive missing' }
$names = @()
$failures = @()
try {
    foreach ($option in @('/unregister', '/u')) {
        $name = 'copilot-legacy-' + [guid]::NewGuid().ToString()
        $names += $name
        $install = Join-Path $root $name
        & wsl.exe --import $name $install $archive --version 2
        if ($LASTEXITCODE -ne 0) { throw 'Import failed' }
        & wslconfig.exe $option $name
        if ($LASTEXITCODE -ne 0) { throw 'Legacy unregister failed' }
        $retained = @(Get-ChildItem $lxss | Where-Object { (Get-ItemProperty $_.PSPath).DistributionName -eq $name })
        if ($retained.Count -ne 0) {
            $failures += "FAIL: wslconfig $option retained a distribution instead of permanently deleting it"
        }
    }
    $name = 'copilot-reparse-' + [guid]::NewGuid().ToString()
    $names += $name
    & wsl.exe --import $name (Join-Path $root $name) $archive --version 2
    if ($LASTEXITCODE -ne 0) { throw 'Import failed' }
    & wsl.exe --unregister $name
    if ($LASTEXITCODE -ne 0) { throw 'Unregister failed' }
    $entry = Get-ChildItem $lxss | Where-Object { (Get-ItemProperty $_.PSPath).DistributionName -eq $name }
    if (-not $entry -or $entry.PSChildName -notlike 'Deleted-*') { throw 'Recovery entry missing before test' }
    $disk = (Get-ItemProperty $entry.PSPath).RecoveryPath.Replace('\\?\', '')
    $parent = Split-Path $disk
    $saved = Join-Path $root 'saved-disk'
    $target = Join-Path $root 'unrelated'
    Move-Item -LiteralPath $parent -Destination $saved
    New-Item -ItemType Directory $target | Out-Null
    Set-Content (Join-Path $target 'keep.txt') 'unrelated contents'
    New-Item -ItemType Junction -Path $parent -Target $target | Out-Null
    Set-ItemProperty $entry.PSPath -Name DeletedAt -Value ([DateTime]::UtcNow.AddHours(-25).ToFileTimeUtc())
    & wsl.exe --list --deleted
    if ($LASTEXITCODE -ne 0) { throw 'Deleted-list cleanup failed' }
    if (-not (Test-Path -LiteralPath $parent)) { $failures += 'FAIL: missing-disk cleanup removed the replacement directory junction' }
    if (-not (Test-Path $entry.PSPath)) { $failures += 'FAIL: missing-disk cleanup discarded the recovery record behind a directory junction' }
    if (-not (Test-Path (Join-Path $saved 'ext4.vhdx'))) { throw 'Original disk unexpectedly lost' }
    if ((Get-Content (Join-Path $target 'keep.txt')) -ne 'unrelated contents') { throw 'Unrelated target changed' }
    if (Test-Path -LiteralPath $parent) { cmd /c rmdir $parent }
}
finally {
    foreach ($entry in @(Get-ChildItem $lxss)) {
        if ((Get-ItemProperty $entry.PSPath).DistributionName -in $names) {
            if ($entry.PSChildName -like 'Deleted-*') { Remove-Item $entry.PSPath -Recurse -Force }
            else { & wsl.exe --unregister (Get-ItemProperty $entry.PSPath).DistributionName --force }
        }
    }
    Remove-Item $root -Recurse -Force
}
$failures | Write-Host
if ($failures.Count) { exit 1 }
Write-Host 'PASS: legacy unregister and missing-disk directory protection'
