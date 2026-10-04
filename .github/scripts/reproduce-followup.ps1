$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'
$root = Join-Path $env:TEMP ('wsl-followup-' + [guid]::NewGuid())
New-Item -ItemType Directory $root | Out-Null
$lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
$archive = (Get-ChildItem packages -Recurse -Filter test_distro.tar.xz | Where-Object FullName -Match '\\x64\\' | Select-Object -First 1).FullName
if (-not $archive) { throw 'Test archive missing' }
$names = @()
$failures = @()
try {
    foreach ($scenario in @('unavailable', 'nonempty')) {
        $name = 'followup-' + $scenario + '-' + [guid]::NewGuid()
        $names += $name
        $install = Join-Path $root $name
        & wsl.exe --import $name $install $archive --version 2
        if ($LASTEXITCODE -ne 0) { throw 'Import failed' }
        $registration = Get-ChildItem $lxss | Where-Object { (Get-ItemProperty $_.PSPath).DistributionName -eq $name }
        if ($scenario -eq 'unavailable') {
            & wsl.exe --shutdown
            if ($LASTEXITCODE -ne 0) { throw 'Shutdown failed' }
            Move-Item $install ($install + '-offline')
            & wsl.exe --unregister $name
            if ($LASTEXITCODE -eq 0 -or -not (Test-Path $registration.PSPath)) {
                $failures += 'FAIL: unavailable install path lost its registration'
            }
            Move-Item ($install + '-offline') $install
        } else {
            & wsl.exe --unregister $name
            if ($LASTEXITCODE -ne 0) { throw 'Unregister failed' }
            $entry = Get-ChildItem $lxss | Where-Object { (Get-ItemProperty $_.PSPath).DistributionName -eq $name }
            $disk = (Get-ItemProperty $entry.PSPath).RecoveryPath.Replace('\\?\', '')
            $parent = Split-Path $disk
            Remove-Item -LiteralPath $disk
            $extra = Join-Path $parent 'keep.txt'
            Set-Content $extra 'unrelated contents'
            Set-ItemProperty $entry.PSPath -Name DeletedAt -Value ([DateTime]::UtcNow.AddHours(-25).ToFileTimeUtc())
            & wsl.exe --list --deleted
            if ($LASTEXITCODE -ne 0) { throw 'Cleanup failed' }
            if (-not (Test-Path $entry.PSPath)) { $failures += 'FAIL: failed directory cleanup discarded its retry record' }
            if ((Get-Content $extra) -ne 'unrelated contents') { throw 'Unrelated file changed' }
            Remove-Item $extra
            & wsl.exe --list --deleted
            if (Test-Path -LiteralPath $parent) { $failures += 'FAIL: directory cleanup could not retry after obstruction removal' }
        }
    }
} finally {
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
Write-Host 'PASS: unavailable paths preserve registration and directory cleanup retries'
