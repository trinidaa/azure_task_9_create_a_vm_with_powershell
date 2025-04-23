$linuxUser = "azur1"
$linuxPassword = "YourSecurePassword123!" | ConvertTo-SecureString -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential ($linuxUser, $linuxPassword)
$location = "uksouth"
$resourceGroupName = "mate-azure-task-9"
$networkSecurityGroupName = "defaultnsg"
$virtualNetworkName = "vnet"
$subnetName = "default"
$vnetAddressPrefix = "10.0.0.0/16"
$subnetAddressPrefix = "10.0.0.0/24"
$publicIpAddressName = "linuxboxpip"  # Имя Public IP , которое нельзя созадавать, почемуто Azure выдает ошибку даже когда префиксом использовать
$sshKeyName = "linuxboxsshkey"
$vmName = "matebox"
$vmSize = "Standard_B1s"
$dnsNameLabel = "matebox-$((Get-Random -Maximum 9999).ToString('0000'))" # Генерируем уникальное DNS-имя
$pubKeyPath = (Get-Content "$HOME\.ssh\$linuxUser.pub" -Raw).Trim()
$keyPath = "$HOME\.ssh\$linuxUser"

# Проверка наличия SSH-ключа
if (-not (Test-Path "$HOME\.ssh\$linuxUser.pub")) {
    Write-Host "SSH-ключ не найден. Генерируем новый..." -ForegroundColor Cyan
    ssh-keygen -t rsa -b 4096 -f $keyPath -N "" | Out-Null
    $pubKeyPath = (Get-Content "$HOME\.ssh\$linuxUser.pub" -Raw).Trim()
}

# 1. Создаем Resource Group
Write-Host "Creating resource group..." -ForegroundColor Cyan
New-AzResourceGroup -Name $resourceGroupName -Location $location

# 2. Создаем NSG с правилами для SSH и HTTP
Write-Host "Creating network security group..." -ForegroundColor Cyan
$nsgRuleSSH = New-AzNetworkSecurityRuleConfig -Name SSH -Protocol Tcp -Direction Inbound -Priority 1001 `
    -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 22 -Access Allow
$nsgRuleHTTP = New-AzNetworkSecurityRuleConfig -Name HTTP -Protocol Tcp -Direction Inbound -Priority 1002 `
    -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 8080 -Access Allow
$nsg = New-AzNetworkSecurityGroup -Name $networkSecurityGroupName -ResourceGroupName $resourceGroupName `
    -Location $location -SecurityRules $nsgRuleSSH, $nsgRuleHTTP

# 3. Создаем Virtual Network с подсетью
Write-Host "Creating virtual network..." -ForegroundColor Cyan
$subnetConfig = New-AzVirtualNetworkSubnetConfig -Name $subnetName -AddressPrefix $subnetAddressPrefix `
    -NetworkSecurityGroup $nsg
$vnet = New-AzVirtualNetwork -ResourceGroupName $resourceGroupName -Location $location -Name $virtualNetworkName `
    -AddressPrefix $vnetAddressPrefix -Subnet $subnetConfig

# 4. Создаем Public IP с DNS-меткой
Write-Host "Creating public IP address with DNS name..." -ForegroundColor Cyan
$pip = New-AzPublicIpAddress -ResourceGroupName $resourceGroupName -Location $location `
    -Name $publicIpAddressName -AllocationMethod Dynamic -Sku Basic -DomainNameLabel $dnsNameLabel

# 5. Создаем сетевой интерфейс (NIC)
Write-Host "Creating network interface..." -ForegroundColor Cyan
$subnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name $subnetName
$nic = New-AzNetworkInterface -Name "$vmName-nic-1" -ResourceGroupName $resourceGroupName `
    -Location $location -SubnetId $subnet.Id -PublicIpAddressId $pip.Id -NetworkSecurityGroupId $nsg.Id

# 6. Создаем SSH Key в Azure
Write-Host "Uploading SSH key..." -ForegroundColor Cyan
New-AzSshKey -ResourceGroupName $resourceGroupName -Name $sshKeyName -PublicKey $pubKeyPath | Out-Null

# 7. Создаем виртуальную машину
Write-Host "Creating virtual machine..." -ForegroundColor Cyan
$vmConfig = New-AzVMConfig -VMName $vmName -VMSize $vmSize
$vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Linux -ComputerName $vmName -Credential $credential -DisablePasswordAuthentication $true
$vmConfig = Set-AzVMSourceImage -VM $vmConfig -PublisherName "Canonical" -Offer "0001-com-ubuntu-server-jammy" -Skus "22_04-lts-gen2" -Version "latest"
$vmConfig = Add-AzVMSshPublicKey -VM $vmConfig -KeyData $pubKeyPath -Path "/home/$linuxUser/.ssh/authorized_keys"
$vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id

New-AzVM -ResourceGroupName $resourceGroupName -Location $location -VM $vmConfig

# Получаем полное DNS-имя
$fqdn = $pip.DnsSettings.Fqdn

Write-Host "Waiting for SSH port (22) to be available..." -ForegroundColor Cyan
for ($i = 1; $i -le 15; $i++) {
    try {
        $connection = Test-NetConnection -ComputerName $fqdn -Port 22 -ErrorAction Stop
        if ($connection.TcpTestSucceeded) {
            Write-Host "SSH port is open."
            break
        }
        else {
            Write-Host "Attempt $i/15 : SSH port not yet available. Retrying in 5 seconds..."
            Start-Sleep -Seconds 5
        }
    }
    catch {
        Write-Host "Attempt $i/15 : Error testing SSH port: $_"
        Start-Sleep -Seconds 5
    }
}

try {
    ssh -i $keyPath -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -t $linuxUser@$fqdn "sudo mkdir -p /app && sudo chown $linuxUser`:$linuxUser /app && sudo chmod 755 /app"
    if ($LASTEXITCODE -eq 0) {
        scp -i $keyPath -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -r app\* $linuxUser@$fqdn`:/app
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Скрипт успешно выполнен: директория создана, файлы скопированы." -ForegroundColor Cyan
        }
        else {
            Write-Host "Ошибка при копировании файлов с помощью scp." -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "Ошибка при выполнении SSH-команды." -ForegroundColor Yellow
    }
}
catch {
    Write-Host "Ошибка: $_"
    }

try {
    ssh -i $keyPath -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -t $linuxUser@$fqdn "export DEBIAN_FRONTEND=noninteractive && sudo -E apt update -yqq && sudo -E apt install -yqq --no-install-recommends python3-pip && sudo rm -rf /var/lib/apt/lists/*"
    if ($LASTEXITCODE -eq 0) {
            Write-Host "Requirements installed" -ForegroundColor Cyan
        }
        else {
            Write-Host "Error installing requirements." -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "Error: $_"
    }

try {
    ssh -i $keyPath -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -t $linuxUser@$fqdn "sudo chmod +x /app/start.sh && sudo cp /app/todoapp.service /etc/systemd/system/ && sudo chmod 644 /etc/systemd/system/todoapp.service && sudo chown root:root /etc/systemd/system/todoapp.service && sudo systemctl daemon-reload && sudo systemctl enable todoapp && sudo systemctl start todoapp && sudo systemctl status todoapp --no-pager"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Rules and Service installed" -ForegroundColor Cyan
    }
    else {
        Write-Host "Error installing rules and service." -ForegroundColor Yellow
    }}
    catch {
            Write-Host "Error: $_"
        }

Write-Host "`nDeployment completed successfully!" -ForegroundColor Green
Write-Host "SSH connection command:" -ForegroundColor Yellow
Write-Host "ssh $linuxUser@$fqdn" -ForegroundColor White
Write-Host "`nYou can also access your VM at:" -ForegroundColor Yellow
Write-Host ("http://{0}:8080" -f $fqdn)
