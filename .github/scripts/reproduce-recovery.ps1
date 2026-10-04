$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'
$root = Join-Path $env:TEMP ('wsl-recovery-review-' + [guid]::NewGuid().ToString())
New-Item -ItemType Directory $root | Out-Null
$lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
$archive = (Get-ChildItem packages -Recurse -Filter test_distro.tar.xz | Where-Object FullName -Match '\\x64\\' | Select-Object -First 1).FullName
if (-not $archive) { throw 'Test archive missing' }
$names = @()
$failures = @()
try {
    foreach ($scenario in @('restore', 'directory')) {
        $name = 'review-' + $scenario + '-' + [guid]::NewGuid().ToString()
        $names += $name
        & wsl.exe --import $name (Join-Path $root $name) $archive --version 2
        if ($LASTEXITCODE -ne 0) { throw 'Import failed' }
        & wsl.exe --unregister $name
        if ($LASTEXITCODE -ne 0) { throw 'Unregister failed' }
        $entry = Get-ChildItem $lxss | Where-Object { (Get-ItemProperty $_.PSPath).DistributionName -eq $name }
        if (-not $entry -or $entry.PSChildName -notlike 'Deleted-*') { throw 'Recovery record missing' }
        $disk = (Get-ItemProperty $entry.PSPath).RecoveryPath.Replace('\\?\', '')
        $parent = Split-Path $disk
        if ($scenario -eq 'restore') {
            # Durable restore journal just before the Deleted-{id} key rename.
            Set-ItemProperty $entry.PSPath -Name BasePath -Value $parent
            New-ItemProperty $entry.PSPath -Name RecoveryRestored -PropertyType DWord -Value 1 -Force | Out-Null
            $active = Join-Path $lxss $entry.PSChildName.Substring(8)
        } else {
            $saved = Join-Path $root 'saved-directory'
            Move-Item -LiteralPath $parent -Destination $saved
            New-Item -ItemType Directory $parent | Out-Null
        }
        Set-ItemProperty $entry.PSPath -Name DeletedAt -Value ([DateTime]::UtcNow.AddHours(-25).ToFileTimeUtc())
        & wsl.exe --list --deleted
        if ($LASTEXITCODE -ne 0) { throw 'Recovery/cleanup failed' }
        if ($scenario -eq 'restore') {
            if (-not (Test-Path $active)) { $failures += 'FAIL: pending restore was not committed to its active registration' }
            if (-not (Test-Path -LiteralPath $disk)) { $failures += 'FAIL: expired cleanup deleted the pending restore disk' }
        } else {
            if (-not (Test-Path -LiteralPath $parent)) { $failures += 'FAIL: cleanup removed an unrelated ordinary replacement directory' }
            if (-not (Test-Path $entry.PSPath)) { $failures += 'FAIL: cleanup discarded the original disk recovery record' }
            if (-not (Test-Path (Join-Path $saved 'ext4.vhdx'))) { throw 'Original disk unexpectedly lost' }
        }
    }
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
Write-Host 'PASS: pending restore survives expiry and replacement directory survives cleanup'
