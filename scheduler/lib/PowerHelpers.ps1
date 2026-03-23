Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-OnBatteryPower {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
        if (-not $battery) { return $false }
        # BatteryStatus 1 = Discharging (on battery)
        return ($battery.BatteryStatus -eq 1)
    }
    catch {
        return $false
    }
}
