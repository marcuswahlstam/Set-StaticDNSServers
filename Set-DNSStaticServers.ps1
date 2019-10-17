#Requires -Version 3

# Registry entry to manage if script should run
$regKey = "HKLM:\SOFTWARE\Advitum\Scripts"
$regName = "SetStaticDNSVersion"
$regValue = "2" # Change this if you want the script to run again on all servers

# IP of old DNS that should be replaced in DNS settings
$DNSServerToRemove = "10.0.0.1"
# IP of new and active DNS the script should change to
$ActiveDNSServers = "10.0.0.2","10.105.0.1","10.1.1.1"


if ((Get-ItemProperty $regKey -ErrorAction Ignore).$regName -eq $regValue)
{
    exit 0
}

$ipConfig = Get-NetIPAddress | where {$_.IPv4Address -like "10.105*" -or $_.IPv4Address -like "10.238*"}
$dhcpEnabled = $ipConfig.PrefixOrigin
$ipAddress = $ipConfig.IPv4Address

if ($dhcpEnabled -ne "Dhcp")
{
    # Get interfaces that use old DNS
    $InterfacesWithOldDNS = Get-DnsClientServerAddress | where {$_.ServerAddresses -eq "$DNSServerToRemove" -and $_.InterfaceAlias -notlike "*isatap*" -and $_.InterfaceAlias -notlike "*loopback*" -and $_.InterfaceAlias -notlike "vEthernet*"}

    if ($InterfacesWithOldDNS -eq $null)
    {
        $LogText = "Correct DNS servers already set"
        $result = "Success"
    }

    # Get which interfaces are up
    $OnlineInterfaces = @()
    foreach ($Interface in $InterfacesWithOldDNS)
    {
        $OnlineInterfaces += Get-NetAdapter -ifIndex $($Interface.InterfaceIndex) | where {$_.status -eq "Up"}
    }

    if ($OnlineInterfaces -eq $null)
    {
        $LogText = "No online interfaces found"
        $result = "NoInterfaces"
    }

    foreach ($OnlineInterface in $OnlineInterfaces)
    {
        $ifIndex = $OnlineInterface.ifindex
        Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses ($ActiveDNSServers)
        if ($?)
        {
            $LogText = "Successfully set DNS Servers"
        
            $result = "Success"
        }
        else
        {
            $LogText = "Something went wrong for interface $ifIndex"
            $result = "Failure"
        }
    }
}
else
{
    $LogText = "Host has no static IP"
    $result = "Failure"
}


# Send result to DB
$DBServer = "sqlserver.corp.org"
$DBName = "LogDB"
$DBTable = "StaticDNSServers"
$sqlConnection = New-Object System.Data.SqlClient.SqlConnection
$sqlConnection.ConnectionString = "Server=$DBServer;Database=$DBName;Integrated Security=True;"
$sqlConnection.Open()

$query= "begin tran
        if exists (SELECT * FROM $DBTable WITH (updlock,serializable) WHERE Computername='"+$env:COMPUTERNAME+"')
        begin
            UPDATE $DBTable SET Computername='"+$env:COMPUTERNAME+"', ScriptOutput='"+$LogText+"', ScriptSuccessful='"+$result+"'
            WHERE Computername = '"+$env:COMPUTERNAME+"'
        end
        else
        begin
            INSERT INTO $DBTable (Computername, ScriptOutput, ScriptSuccessful)
            VALUES ('"+$env:COMPUTERNAME+"', '"+$LogText+"', '"+$result+"')
        end
        commit tran"

$sqlCommand = New-Object System.Data.SqlClient.SqlCommand($query,$sqlConnection)
$sqlDS = New-Object System.Data.DataSet
$sqlDA = New-Object System.Data.SqlClient.SqlDataAdapter($sqlCommand)
[void]$sqlDA.Fill($sqlDS)

$sqlConnection.Close()

# Log to reg
if (Test-Path $regKey)
{
    if ((Get-Item $regKey -EA Ignore).Property -contains $regName)
    {
        Set-ItemProperty -Path $regKey -Name $regName -Value $regValue -Force | Out-Null
    }
    else
    {
        New-ItemProperty $regKey -Name $regName -Value $regValue -PropertyType DWORD -Force | Out-Null
    }
}
else
{
    New-Item -Path $regKey -Force | Out-Null
    New-ItemProperty $regKey -Name $regName -Value $regValue -PropertyType DWORD -Force | Out-Null
}
