<#
.SYNOPSIS
VMRest-Commander
Copyright (C) 2026 Xianglong He

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
#>
param (
  [string]$ListenAddress = "",
  [int]$ListenPort = 55555,
  [int]$ConnectPort = 55555,
  [string]$ConnectAddress = "127.0.0.1",
  [switch]$UsePasswordLogon,
  [switch]$ResetPassword
)

# Ensure running with Administrator privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Warning "Please run this script with Administrator privileges!"
  exit
}

Write-Host "===================================================="
Write-Host "Initializing VMware REST API Service & Network Configuration"
Write-Host "===================================================="
Write-Host ""

# 1. Search for VMware Workstation Pro installation path
Write-Host "[1/5] Searching for VMware Workstation Pro installation path..."
$registryPath = "HKLM:\SOFTWARE\VMware, Inc.\VMware Workstation"
$vmwareInstallPath = (Get-ItemProperty -Path $registryPath -Name "InstallPath" -ErrorAction SilentlyContinue).InstallPath

if (-not $vmwareInstallPath) {
  Write-Host "Path not found in registry. Searching all drives for standard directories..."
  $drives = Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Root
  $relativePaths = @("Program Files\VMware\VMware Workstation", "Program Files (x86)\VMware\VMware Workstation")
  
  foreach ($drive in $drives) {
    foreach ($relPath in $relativePaths) {
      $testPath = Join-Path $drive $relPath
      if (Test-Path (Join-Path $testPath "vmrest.exe")) {
        $vmwareInstallPath = $testPath
        break
      }
    }
    if ($vmwareInstallPath) { break }
  }
}

if (-not $vmwareInstallPath) {
  Write-Error "VMware Workstation Pro installation path not found."
  exit
}

$vmrestPath = Join-Path $vmwareInstallPath "vmrest.exe"
if (-not (Test-Path $vmrestPath)) {
  Write-Error "vmrest.exe not found at: $vmrestPath"
  exit
}

Write-Host "Found vmrest.exe at: $vmrestPath"
Write-Host ""

# 2. Call vmrest -C to configure username and password
$cfgPath = Join-Path $env:USERPROFILE "vmrest.cfg"
$skipPasswordSetup = (Test-Path $cfgPath) -and -not $ResetPassword

if ($skipPasswordSetup) {
  Write-Host "[2/5] VMware REST API configuration already exists. Skipping password setup."
  Write-Host "Hint: Run with -ResetPassword switch to force password reset."
}
else {
  Write-Host "[2/5] Configuring VMware REST API username and password..."
  Write-Host "Note: Please enter the desired username and password in the following prompt."
  $originalPath = (Get-Location).Path
  Set-Location -Path $env:USERPROFILE
  & $vmrestPath -C
  Set-Location -Path $originalPath
}

if (Test-Path $cfgPath) {
  (Get-Content $cfgPath) -replace "^port=.*", "port=$ConnectPort" | Set-Content $cfgPath
}
Write-Host ""

# 3. Configure port forwarding
Write-Host "[3/5] Configuring port forwarding (netsh portproxy)..."

if ([string]::IsNullOrWhiteSpace($ListenAddress)) {
  # Auto-get local IPv4 addresses, excluding loopback
  $ipAddresses = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -notmatch "Loopback" }).IPAddress
  # Prioritize specific internal IP subnets
  $ListenAddress = $ipAddresses | Where-Object { $_ -like "192.168.62.*" } | Select-Object -First 1
  if (-not $ListenAddress) { $ListenAddress = $ipAddresses | Where-Object { $_ -like "192.168.*" } | Select-Object -First 1 }
  if (-not $ListenAddress) { $ListenAddress = $ipAddresses | Where-Object { $_ -like "172.16.*" } | Select-Object -First 1 }
  if (-not $ListenAddress) { $ListenAddress = $ipAddresses | Where-Object { $_ -like "10.*" } | Select-Object -First 1 }
    
  # Fallback
  if (-not $ListenAddress) {
    $ListenAddress = "0.0.0.0"
  }
}

$userInputListenAddr = Read-Host "Please enter ListenAddress [Default: $ListenAddress]"
if (-not [string]::IsNullOrWhiteSpace($userInputListenAddr)) {
  $ListenAddress = $userInputListenAddr
}

Write-Host "Executing command: netsh interface portproxy add v4tov4 listenport=$ListenPort listenaddress=$ListenAddress connectport=$ConnectPort connectaddress=$ConnectAddress"
netsh interface portproxy add v4tov4 listenport=$ListenPort listenaddress=$ListenAddress connectport=$ConnectPort connectaddress=$ConnectAddress

Write-Host "Restarting IP Helper service to ensure port proxy rule takes effect..."
Restart-Service iphlpsvc -ErrorAction SilentlyContinue
Write-Host ""

# 4. Configure firewall
Write-Host "[4/5] Configuring firewall rules..."
$firewallRuleName = "VMware REST API"
$existingRule = Get-NetFirewallRule -DisplayName $firewallRuleName -ErrorAction SilentlyContinue

if ($existingRule) {
  Write-Host "Firewall rule '$firewallRuleName' already exists, removing old rule..."
  Remove-NetFirewallRule -DisplayName $firewallRuleName
}

Write-Host "Adding inbound allow rule (TCP Port: $ListenPort)..."
New-NetFirewallRule -DisplayName $firewallRuleName -Direction Inbound -LocalPort $ListenPort -Protocol TCP -Action Allow | Out-Null
Write-Host "Firewall rule configured."
Write-Host ""

# 5. Create scheduled task
Write-Host "[5/5] Creating scheduled task..."
$taskName = "VMware REST API Background Service"
$domainUser = "$env:USERDOMAIN\$env:USERNAME"
$userSid = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
$currentDate = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffffff")
$logonTypeStr = if ($UsePasswordLogon) { "Password" } else { "InteractiveToken" }

# Generate VBScript for silent execution
$vbsPath = Join-Path $env:USERPROFILE "run_vmrest.vbs"
$vbsContent = @"
Set WshShell = CreateObject("WScript.Shell")
WScript.Sleep 5000
WshShell.Run "powershell.exe -WindowStyle Hidden -Command ""Restart-Service iphlpsvc -ErrorAction SilentlyContinue""", 0, True
WshShell.CurrentDirectory = "$env:USERPROFILE"
WshShell.Run """$vmrestPath"" -p $ConnectPort", 0, False
"@
$vbsContent | Out-File -FilePath $vbsPath -Encoding Unicode

$xmlContent = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Date>$currentDate</Date>
    <Author>$domainUser</Author>
    <URI>\$taskName</URI>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger>
      <Enabled>true</Enabled>
    </BootTrigger>
    <LogonTrigger>
      <Repetition>
        <Interval>PT1H</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <Enabled>true</Enabled>
      <UserId>$domainUser</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$userSid</UserId>
      <LogonType>$logonTypeStr</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>StopExisting</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>true</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>true</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <DisallowStartOnRemoteAppSession>false</DisallowStartOnRemoteAppSession>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>wscript.exe</Command>
      <Arguments>"$vbsPath"</Arguments>
      <WorkingDirectory>$env:USERPROFILE</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

$xmlPath = Join-Path $env:TEMP "vmrest_task.xml"
$xmlContent | Out-File -FilePath $xmlPath -Encoding Unicode

Write-Host "VBScript & Scheduled Task XML generated, registering task..."

if ($UsePasswordLogon) {
  $password = Read-Host "UsePasswordLogon is enabled, please enter password for ($domainUser)" -AsSecureString
  $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
  $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)

  schtasks.exe /create /tn $taskName /xml $xmlPath /ru $domainUser /rp $plainPassword /f

  [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  $plainPassword = ""
}
else {
  schtasks.exe /create /tn $taskName /xml $xmlPath /f
}

if ($LASTEXITCODE -eq 0) {
  Write-Host "Scheduled task created successfully!"
  Write-Host "Starting scheduled task on demand..."
  Start-ScheduledTask -TaskName $taskName
  
  Write-Host "Waiting for service to start (3s)..."
  Start-Sleep -Seconds 3
  
  Write-Host "Testing service connectivity (TCP Port: $ListenPort)..."
  $testResult = Test-NetConnection -ComputerName $ListenAddress -Port $ListenPort -InformationLevel Quiet
  if ($testResult) {
    Write-Host "Connectivity test successful! Service responding at $ListenAddress`:$ListenPort."
  }
  else {
    Write-Warning "Connectivity test failed! Cannot connect to $ListenAddress`:$ListenPort, please check if service started normally."
  }
}
else {
  Write-Warning "Scheduled task creation failed. Please check the error or try manually importing $xmlPath."
}

# Clean up XML file
Remove-Item -Path $xmlPath -ErrorAction SilentlyContinue

Write-Host "===================================================="
Write-Host "Initialization script completed."
Write-Host "===================================================="
