[CmdletBinding()]
param([string]$OutputDirectory = (Join-Path $PSScriptRoot 'output'))
# Read-only system inspection. Only inventory reports are written; existing reports are retained.
$ErrorActionPreference = 'Stop'
$issues = [System.Collections.Generic.List[string]]::new()
function Query([string]$Label, [scriptblock]$Action) {
    try { & $Action } catch { $issues.Add("${Label}: $($_.Exception.Message)"); return $null }
}
function Native([string]$Path, [string[]]$Arguments) {
    try {
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $Path
        $psi.Arguments = $Arguments -join ' '
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [Diagnostics.Process]::new(); $p.StartInfo = $psi
        [void]$p.Start()
        $stdout = $p.StandardOutput.ReadToEndAsync(); $stderr = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(20000)) { $p.Kill(); return @{ status='unknown'; error='Read-only query timed out after 20 seconds' } }
        return @{ exit_code=$p.ExitCode; stdout=($stdout.Result -replace "`0",'').Trim(); stderr=($stderr.Result -replace "`0",'').Trim() }
    } catch { return @{ status='unknown'; error=$_.Exception.Message } }
}
$cs = Query 'Win32_ComputerSystem' { Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer,Model,TotalPhysicalMemory,HypervisorPresent,SystemType }
$cpu = Query 'Win32_Processor' { @(Get-CimInstance Win32_Processor | Select-Object Name,Architecture,NumberOfCores,NumberOfLogicalProcessors,VirtualizationFirmwareEnabled,SecondLevelAddressTranslationExtensions,VMMonitorModeExtensions) }
$os = Query 'Win32_OperatingSystem' { Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,OSArchitecture,FreePhysicalMemory,TotalVisibleMemorySize }
$windows = Query 'Windows version registry' { Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' | Select-Object ProductName,EditionID,DisplayVersion,CurrentBuild,UBR }
$disk = Query 'Win32_LogicalDisk' { @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Select-Object DeviceID,Size,FreeSpace,FileSystem) }
$board = Query 'Win32_BaseBoard' { Get-CimInstance Win32_BaseBoard | Select-Object Manufacturer,Product,Version }
$bios = Query 'Win32_BIOS' { Get-CimInstance Win32_BIOS | Select-Object Manufacturer,SMBIOSBIOSVersion,ReleaseDate }
$firmware = Query 'GetFirmwareType Windows API' {
    if (-not ('MiniPcFirmware' -as [type])) {
        Add-Type 'using System; using System.Runtime.InteropServices; public static class MiniPcFirmware { [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetFirmwareType(out uint firmwareType); }'
    }
    [uint32]$kind=0
    if (-not [MiniPcFirmware]::GetFirmwareType([ref]$kind)) { throw "Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
    switch ($kind) { 1 {'Legacy BIOS'} 2 {'UEFI'} default {'unknown'} }
}
$features = Query 'Windows optional features' {
    @(Get-WindowsOptionalFeature -Online | Where-Object FeatureName -in @('Microsoft-Windows-Subsystem-Linux','VirtualMachinePlatform','HypervisorPlatform','Microsoft-Hyper-V-All') | Select-Object FeatureName,@{n='State';e={$_.State.ToString()}})
}
$uninstall = @()
foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
    $uninstall += @(Get-ItemProperty $key -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'QEMU|Git($| version)|Python|Node.js|Codex|Windows Subsystem for Linux' } | Select-Object DisplayName,DisplayVersion,InstallLocation)
}
$specs = @(
    @{name='QEMU'; commands=@('qemu-system-x86_64.exe','qemu-system-aarch64.exe'); paths=@("$env:ProgramFiles\qemu\qemu-system-x86_64.exe","${env:ProgramFiles(x86)}\qemu\qemu-system-x86_64.exe"); pattern='QEMU'},
    @{name='Git'; commands=@('git.exe'); paths=@("$env:ProgramFiles\Git\cmd\git.exe","$env:LOCALAPPDATA\Programs\Git\cmd\git.exe"); pattern='^Git'},
    @{name='Codex CLI'; commands=@('codex.exe','codex.cmd','codex.ps1'); paths=@("$env:APPDATA\npm\codex.cmd","$env:USERPROFILE\.cargo\bin\codex.exe"); pattern='Codex'},
    @{name='Python'; commands=@('python.exe','python3.exe','py.exe'); paths=@("$env:LOCALAPPDATA\Programs\Python\Python*\python.exe","$env:ProgramFiles\Python*\python.exe","$env:LOCALAPPDATA\Python\pythoncore-*\python.exe","$env:USERPROFILE\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"); pattern='Python'},
    @{name='Node.js'; commands=@('node.exe'); paths=@("$env:ProgramFiles\nodejs\node.exe","$env:LOCALAPPDATA\Programs\nodejs\node.exe"); pattern='Node.js'}
)
$toolResults = foreach ($spec in $specs) {
    $onPath = @($spec.commands | ForEach-Object { Get-Command $_ -CommandType Application,ExternalScript -All -ErrorAction SilentlyContinue } | Select-Object -ExpandProperty Source -Unique)
    $found = @($spec.paths | ForEach-Object { Get-Item -Path $_ -ErrorAction SilentlyContinue } | Select-Object -ExpandProperty FullName -Unique)
    $entries = @($uninstall | Where-Object DisplayName -match $spec.pattern)
    $realPaths = @(@($onPath + $found) | Where-Object { $_ -notlike '*\Microsoft\WindowsApps\*' } | Select-Object -Unique)
    $versions = foreach ($path in $realPaths) {
        if ($path -match '\.(cmd|ps1)$') {
            # Inspect launcher file presence without starting shell scripts or logging their contents.
            @{path=$path; result=@{status='present; CLI execution unverified'}}
        } else { @{path=$path; result=(Native $path @('--version'))} }
    }
    $status = if ($onPath.Count -gt 0) { 'found on PATH; see version probe (WindowsApps paths may be aliases)' } elseif ($found.Count -gt 0 -or $entries.Count -gt 0) { 'not on PATH; installation evidence found' } else { 'not on PATH; installation unknown (not found in scoped locations)' }
    [ordered]@{name=$spec.name;status=$status;on_path=$onPath;standard_location_files=$found;registered_installations=$entries;version_probes=@($versions)}
}
$wslPath = Join-Path $env:WINDIR 'System32\wsl.exe'
$wsl = if (Test-Path $wslPath) { @{path=$wslPath;status=(Native $wslPath @('--status'));distributions=(Native $wslPath @('--list','--verbose'));version=(Native $wslPath @('--version'))} } else { @{status='wsl.exe absent from System32; installation unknown'} }
$wsl.current_account_registry = Query 'Current-account WSL registration' {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (Test-Path $key) {
        @{key_present=$true; distributions=@(Get-ChildItem $key | ForEach-Object { Get-ItemProperty $_.PSPath | Select-Object DistributionName,Version })}
    } else { @{key_present=$false; interpretation='No WSL registration key found for this account; CLI listing failed, so distribution availability remains unverified.'} }
}
$inventory = [ordered]@{
    schema_version='1.0'; captured_at=(Get-Date).ToString('o'); inspection='Read-only, existing Windows account; no OS/boot/account/security changes';
    computer=$cs; cpu=$cpu; architecture_codes=@{'9'='x64';'12'='ARM64';'0'='x86'}; operating_system=$os; windows_registry=$windows;
    disks=$disk; baseboard=$board; bios=$bios; firmware_boot_mode=$(if($firmware){$firmware}else{'unknown'});
    optional_features=$features; wsl=$wsl; tools=@($toolResults); issues=@($issues);
    limitations=@('Null or inaccessible fields are unknown. SMBIOS placeholder strings do not identify a manufacturer/model.','Tool discovery checks PATH, selected common locations and scoped uninstall entries; absence is not proof that a tool is not installed. WindowsApps aliases are not proof of installed runtimes.','No serial numbers, credentials, account inventory, source publication, or external services are queried. Inventory is local/private.')
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$suffix = ''
$archiveTag = (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
foreach ($ext in @('json','md')) {
    $prior = Join-Path $OutputDirectory "MINI_PC_INVENTORY.$ext"
    if (Test-Path $prior) { Copy-Item -LiteralPath $prior -Destination (Join-Path $OutputDirectory "MINI_PC_INVENTORY.prior-$archiveTag.$ext") -ErrorAction Stop }
}
$jsonPath = Join-Path $OutputDirectory "MINI_PC_INVENTORY$suffix.json"
$mdPath = Join-Path $OutputDirectory "MINI_PC_INVENTORY$suffix.md"
$json = $inventory | ConvertTo-Json -Depth 12
$json | Set-Content -LiteralPath $jsonPath -Encoding utf8
$ramText = if ($null -ne $cs.TotalPhysicalMemory) { "$([math]::Round($cs.TotalPhysicalMemory / 1GB,2)) GiB" } else { 'unknown' }
$lines = @('# Mini-PC inventory', '', "Captured: $($inventory.captured_at)", '', 'Local/private. Read-only inspection; null or blank fields mean unknown.', '', '## Hardware', '', "- Manufacturer / model (raw SMBIOS): $($cs.Manufacturer) / $($cs.Model). Placeholder strings mean unknown.", "- CPU: $(@($cpu.Name) -join ', '); architecture code: $(@($cpu.Architecture) -join ', ') (9=x64, 12=ARM64, 0=x86).", "- RAM visible to system: $ramText.", "- Windows: $($os.Caption), version $($os.Version), build $($windows.CurrentBuild).$($windows.UBR), $($os.OSArchitecture).", "- Firmware boot mode: $($inventory.firmware_boot_mode).", "- Firmware virtualization enabled: $(@($cpu.VirtualizationFirmwareEnabled) -join ', '); SLAT: $(@($cpu.SecondLevelAddressTranslationExtensions) -join ', '); hypervisor present: $($cs.HypervisorPresent).", '', '## Fixed disks', '')
foreach ($d in $disk) { $lines += "- $($d.DeviceID) $([math]::Round($d.FreeSpace / 1GB,2)) GiB free / $([math]::Round($d.Size / 1GB,2)) GiB total ($($d.FileSystem))." }
$lines += @('', '## Tools', '')
foreach ($t in $toolResults) { $lines += "- $($t.name): $($t.status)." }
$lines += @('', '## Complete observations and command outcomes', '', '```json', $json, '```')
$lines | Set-Content -LiteralPath $mdPath -Encoding utf8
Write-Output "Saved $jsonPath"
Write-Output "Saved $mdPath"
Write-Output $json
