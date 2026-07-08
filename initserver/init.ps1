param (
  [string]$ListenAddress = "",
  [int]$ListenPort = 55555,
  [int]$ConnectPort = 55555,
  [string]$ConnectAddress = "127.0.0.1",
  [switch]$UsePasswordLogon
)

# 确保以管理员权限运行
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Warning "请以管理员权限运行此脚本！"
  exit
}

Write-Host "===================================================="
Write-Host "初始化 VMware REST API 服务及相关网络配置"
Write-Host "===================================================="
Write-Host ""

# 1. 搜索 VMware Workstation Pro 的安装路径
Write-Host "[1/5] 搜索 VMware Workstation Pro 安装路径..."
$registryPath = "HKLM:\SOFTWARE\VMware, Inc.\VMware Workstation"
$vmwareInstallPath = (Get-ItemProperty -Path $registryPath -Name "InstallPath" -ErrorAction SilentlyContinue).InstallPath

if (-not $vmwareInstallPath) {
  Write-Error "在注册表中未找到 VMware Workstation Pro 的安装路径。"
  exit
}

$vmrestPath = Join-Path $vmwareInstallPath "vmrest.exe"
if (-not (Test-Path $vmrestPath)) {
  Write-Error "未找到 vmrest.exe，路径为: $vmrestPath"
  exit
}

Write-Host "找到 vmrest.exe 位于: $vmrestPath"
Write-Host ""

# 2. 调用 vmrest -C，配置用户名、密码
Write-Host "[2/5] 配置 VMware REST API 用户名和密码..."
Write-Host "注意: 请在接下来的提示中输入您想要设置的用户名和密码。"
& $vmrestPath -C
Write-Host ""

# 3. 配置端口转发
Write-Host "[3/5] 配置端口转发 (netsh portproxy)..."

if ([string]::IsNullOrWhiteSpace($ListenAddress)) {
  # 自动获取本机 IPv4 地址，排除回环地址
  $ipAddresses = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -notmatch "Loopback" }).IPAddress
  # 优先使用 192.168.62 段的 IP
  $ListenAddress = $ipAddresses | Where-Object { $_ -like "192.168.62.*" } | Select-Object -First 1
  if (-not $ListenAddress) { $ListenAddress = $ipAddresses | Where-Object { $_ -like "192.168.*" } | Select-Object -First 1 }
  if (-not $ListenAddress) { $ListenAddress = $ipAddresses | Where-Object { $_ -like "172.16.*" } | Select-Object -First 1 }
  if (-not $ListenAddress) { $ListenAddress = $ipAddresses | Where-Object { $_ -like "10.*" } | Select-Object -First 1 }
    
  # 兜底
  if (-not $ListenAddress) {
    $ListenAddress = "0.0.0.0"
  }
}

$userInputListenAddr = Read-Host "请输入监听地址 (ListenAddress) [默认: $ListenAddress]"
if (-not [string]::IsNullOrWhiteSpace($userInputListenAddr)) {
  $ListenAddress = $userInputListenAddr
}

Write-Host "执行命令: netsh interface portproxy add v4tov4 listenport=$ListenPort listenaddress=$ListenAddress connectport=$ConnectPort connectaddress=$ConnectAddress"
netsh interface portproxy add v4tov4 listenport=$ListenPort listenaddress=$ListenAddress connectport=$ConnectPort connectaddress=$ConnectAddress
Write-Host ""

# 4. 配置防火墙
Write-Host "[4/5] 配置防火墙规则..."
$firewallRuleName = "VMware REST API"
$existingRule = Get-NetFirewallRule -DisplayName $firewallRuleName -ErrorAction SilentlyContinue

if ($existingRule) {
  Write-Host "防火墙规则 '$firewallRuleName' 已存在，正在删除旧规则..."
  Remove-NetFirewallRule -DisplayName $firewallRuleName
}

Write-Host "添加允许入站规则 (TCP 端口: $ListenPort)..."
New-NetFirewallRule -DisplayName $firewallRuleName -Direction Inbound -LocalPort $ListenPort -Protocol TCP -Action Allow | Out-Null
Write-Host "防火墙规则配置完成。"
Write-Host ""

# 5. 创建计划任务
Write-Host "[5/5] 创建计划任务..."
$taskName = "VMware REST API Background Service"
$domainUser = "$env:USERDOMAIN\$env:USERNAME"
$userSid = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
$currentDate = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffffff")
$logonTypeStr = if ($UsePasswordLogon) { "Password" } else { "InteractiveToken" }

$vbsPath = Join-Path $env:USERPROFILE "run_vmrest.vbs"
$vbsContent = @"
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run """$vmrestPath"" -p $ListenPort", 0, False
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
    </Exec>
  </Actions>
</Task>
"@

$xmlPath = Join-Path $env:TEMP "vmrest_task.xml"
$xmlContent | Out-File -FilePath $xmlPath -Encoding Unicode

Write-Host "VBScript 及 计划任务 XML 配置已生成，正在注册任务..."

if ($UsePasswordLogon) {
  $password = Read-Host "由于启用了 UsePasswordLogon，请输入当前用户 ($domainUser) 的密码" -AsSecureString
  $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
  $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)

  schtasks.exe /create /tn $taskName /xml $xmlPath /ru $domainUser /rp $plainPassword /f

  [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  $plainPassword = ""
} else {
  schtasks.exe /create /tn $taskName /xml $xmlPath /f
}

if ($LASTEXITCODE -eq 0) {
  Write-Host "计划任务创建成功！"
  Write-Host "正在按需启动计划任务..."
  Start-ScheduledTask -TaskName $taskName
  
  Write-Host "等待服务启动 (3秒)..."
  Start-Sleep -Seconds 3
  
  Write-Host "正在测试服务连通性 (TCP 端口 $ListenPort)..."
  $testResult = Test-NetConnection -ComputerName $ListenAddress -Port $ListenPort -InformationLevel Quiet
  if ($testResult) {
    Write-Host "连通性测试成功！服务已在 $ListenAddress`:$ListenPort 响应。"
  } else {
    Write-Warning "连通性测试失败！未能连接到 $ListenAddress`:$ListenPort，请检查服务是否正常启动。"
  }
}
else {
  Write-Warning "计划任务创建失败。请检查错误信息或尝试手动导入 $xmlPath。"
}

# 清理 XML 文件
Remove-Item -Path $xmlPath -ErrorAction SilentlyContinue

Write-Host "===================================================="
Write-Host "初始化脚本执行完毕。"
Write-Host "===================================================="
