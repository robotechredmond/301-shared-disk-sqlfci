#
# Copyright 2020 Microsoft Corporation. All rights reserved."
#

configuration ConfigureCluster
{
    param
    (
        [Parameter(Mandatory)]
        [String]$DomainName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$AdminCreds,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$SQLCreds,

        [Parameter(Mandatory)]
        [String]$ClusterName,

        [Parameter(Mandatory)]
        [String]$SQLClusterName,

        [Parameter(Mandatory)]
        [String]$NamePrefix,

        [Parameter(Mandatory)]
        [Int]$VMCount,

        [Parameter(Mandatory)]
        [String]$WitnessType,

        [Parameter(Mandatory)]
        [String]$ListenerIPAddress1,

        [String]$ListenerIPAddress2 = "0.0.0.0",

        [Int]$ListenerProbePort1 = 49100,

        [Int]$ListenerProbePort2 = 49101,

        [Int]$ListenerPort1 = 1433,

        [Int]$ListenerPort2 = 2383,

        [Bool]$UseDNNForSQL = $false,

        [Int]$DataDiskSizeGB,

        [String]$WitnessStorageName,

        [String]$ASServerMode = "MULTIDIMENSIONAL",

        [System.Management.Automation.PSCredential]$WitnessStorageKey
    )

    Import-DscResource -ModuleName PSDesiredStateConfiguration, ComputerManagementDsc, ActiveDirectoryDsc

    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("$($AdminCreds.UserName)@${DomainName}", $AdminCreds.Password)

    [System.Collections.ArrayList]$Nodes = @()
    For ($count = 1; $count -lt $VMCount; $count++) {
        $Nodes.Add($NamePrefix + $Count.ToString())
    }

    If ($ListenerIPAddress2 -ne "0.0.0.0") {
        $ClusterSetupOptions = "-StaticAddress ${ListenerIPAddress2} -ManagementPointNetworkType Singleton"
    } else {
        $ClusterSetupOptions = ""
    }
  
    WaitForSqlSetup

    Node localhost
    {

        WindowsFeature FC
        {
            Name = "Failover-Clustering"
            Ensure = "Present"
        }

        WindowsFeature FCPS
        {
            Name = "RSAT-Clustering-PowerShell"
            Ensure = "Present"
        }

        WindowsFeature FCCmd {
            Name = "RSAT-Clustering-CmdInterface"
            Ensure = "Present"
        }

        WindowsFeature FCMgmt {
            Name = "RSAT-Clustering-Mgmt"
            Ensure = "Present"
        }

        WindowsFeature ADPS
        {
            Name = "RSAT-AD-PowerShell"
            Ensure = "Present"
        }

        WaitForADDomain DscForestWait 
        { 
            DomainName              = $DomainName 
            Credential              = $DomainCreds
            WaitForValidCredentials = $True
            WaitTimeout             = 600
            RestartCount            = 3
            DependsOn               = "[WindowsFeature]ADPS"
        }

        Computer DomainJoin
        {
            Name       = $env:COMPUTERNAME
            DomainName = $DomainName
            Credential = $DomainCreds
            DependsOn  = "[WaitForADDomain]DscForestWait"
        }

        Script CreateCluster {
            SetScript            = "New-Cluster -Name ${ClusterName} -Node ${env:COMPUTERNAME} -NoStorage ${ClusterSetupOptions}"
            TestScript           = "(Get-Cluster -ErrorAction SilentlyContinue).Name -eq '${ClusterName}'"
            GetScript            = "@{Ensure = if ((Get-Cluster -ErrorAction SilentlyContinue).Name -eq '${ClusterName}') {'Present'} else {'Absent'}}"
            PsDscRunAsCredential = $DomainCreds
            DependsOn            = @("[Computer]DomainJoin","[WindowsFeature]FC","[WindowsFeature]FCPS")
        }

        Script ClusterIPAddress {
            SetScript  = "Get-ClusterGroup -Name 'Cluster Group' -ErrorAction SilentlyContinue | Get-ClusterResource | Where-Object ResourceType -eq 'IP Address' -ErrorAction SilentlyContinue | Set-ClusterParameter -Name ProbePort ${ListenerProbePort2}; Stop-ClusterGroup -Name 'Cluster Group'; Start-ClusterGroup -Name 'Cluster Group'"
            TestScript = "if ('${ListenerIpAddress2}' -eq '0.0.0.0') { `$true } else { (Get-ClusterGroup -Name 'Cluster Group' -ErrorAction SilentlyContinue | Get-ClusterResource | Where-Object ResourceType -eq 'IP Address' -ErrorAction SilentlyContinue | Get-ClusterParameter -Name ProbePort).Value -eq ${ListenerProbePort2}}"
            GetScript  = "@{Ensure = if ('${ListenerIpAddress2}' -eq '0.0.0.0') { 'Present' } elseif ((Get-ClusterGroup -Name 'Cluster Group' -ErrorAction SilentlyContinue | Get-ClusterResource | Where-Object ResourceType -eq 'IP Address' -ErrorAction SilentlyContinue | Get-ClusterParameter -Name ProbePort).Value -eq ${ListenerProbePort2}) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]CreateCluster"
        }

        foreach ($Node in $Nodes) {
            Script "AddClusterNode_${Node}" {
                SetScript            = "Add-ClusterNode -Name ${Node} -NoStorage"
                TestScript           = "'${Node}' -in (Get-ClusterNode).Name"
                GetScript            = "@{Ensure = if ('${Node}' -in (Get-ClusterNode).Name) {'Present'} else {'Absent'}}"
                PsDscRunAsCredential = $DomainCreds
                DependsOn            = "[Script]ClusterIPAddress"
            }
        }

        Script AddClusterDisks {
            SetScript  = "Get-Disk | Where-Object PartitionStyle -eq 'RAW' | Initialize-Disk -PartitionStyle GPT -PassThru -ErrorAction SilentlyContinue | Sort-Object -Property Number | % { New-Partition -InputObject `$_ -AssignDriveLetter -UseMaximumSize -ErrorAction SilentlyContinue } | % { `$ClusterDisk = Format-Volume -DriveLetter `$(`$_.DriveLetter) -NewFilesystemLabel Cluster_Disk_`$(`$_.DriveLetter) -FileSystem NTFS -AllocationUnitSize 65536 -UseLargeFRS -Confirm:`$false | Get-Partition | Get-Disk | Add-ClusterDisk ; `$ClusterDisk.Name=`"Cluster_Disk_`$(`$_.DriveLetter)`" ; Start-ClusterResource -Name Cluster_Disk_`$(`$_.DriveLetter) }"
            TestScript = "(Get-Disk | Where-Object PartitionStyle -eq 'RAW').Count -eq 0"
            GetScript  = "@{Ensure = if ((Get-Disk | Where-Object PartitionStyle -eq 'RAW').Count -eq 0) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]CreateCluster"
        }

        Script ClusterWitness {
            SetScript  = "if ('${WitnessType}' -eq 'Cloud') { Set-ClusterQuorum -CloudWitness -AccountName ${WitnessStorageName} -AccessKey $($WitnessStorageKey.GetNetworkCredential().Password) } else { Set-ClusterQuorum -DiskWitness `$((Get-ClusterGroup -Name 'Available Storage' | Get-ClusterResource | ? ResourceType -eq 'Physical Disk' | Sort-Object Name | Select-Object -Last 1).Name) }"
            TestScript = "((Get-ClusterQuorum).QuorumResource).Count -gt 0"
            GetScript  = "@{Ensure = if (((Get-ClusterQuorum).QuorumResource).Count -gt 0) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]AddClusterDisks"
        }

        Script IncreaseClusterTimeouts {
            SetScript  = "(Get-Cluster).SameSubnetDelay = 2000; (Get-Cluster).SameSubnetThreshold = 15; (Get-Cluster).CrossSubnetDelay = 3000; (Get-Cluster).CrossSubnetThreshold = 15"
            TestScript = "(Get-Cluster).SameSubnetDelay -eq 2000 -and (Get-Cluster).SameSubnetThreshold -eq 15 -and (Get-Cluster).CrossSubnetDelay -eq 3000 -and (Get-Cluster).CrossSubnetThreshold -eq 15"
            GetScript  = "@{Ensure = if ((Get-Cluster).SameSubnetDelay -eq 2000 -and (Get-Cluster).SameSubnetThreshold -eq 15 -and (Get-Cluster).CrossSubnetDelay -eq 3000 -and (Get-Cluster).CrossSubnetThreshold -eq 15) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]ClusterWitness"
        }
        
        Script UninstallSQL {
            SetScript  = "C:\SQLServerFull\Setup.exe /Action=Uninstall /FEATURES=SQL,AS,RS,IS /INSTANCENAME=MSSQLSERVER /Q ; `$global:DSCMachineStatus = 1"
            TestScript = "!(Test-Path -Path 'C:\Program Files\Microsoft SQL Server\MSSQL*.MSSQLSERVER\MSSQL\DATA\master.mdf')"
            GetScript  = "@{Ensure = if (!(Test-Path -Path 'C:\Program Files\Microsoft SQL Server\MSSQL*.MSSQLSERVER\MSSQL\DATA\master.mdf') {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]IncreaseClusterTimeouts"
        }

        Script PrepareClusterSQLRole {
            SetScript  = "C:\SQLServerFull\Setup.exe /Action=PrepareFailoverCluster /SkipRules=Cluster_VerifyForErrors /IAcceptSQLServerLicenseTerms=True /FEATURES=SQL,AS /INSTANCENAME=MSSQLSERVER /SQLSVCACCOUNT='${DomainName}\$($SQLCreds.Username)' /SQLSVCPASSWORD='$($SQLCreds.GetNetworkCredential().Password)' /AGTSVCACCOUNT='${DomainName}\$($SQLCreds.Username)' /AGTSVCPASSWORD='$($SQLCreds.GetNetworkCredential().Password)' /ASSVCACCOUNT='${DomainName}\$($SQLCreds.Username)' /ASSVCPASSWORD='$($SQLCreds.GetNetworkCredential().Password)' /Q ; `$global:DSCMachineStatus = 1"
            TestScript = "(Get-Service | Where-Object Name -eq 'MSSQLSERVER').Count -gt 0"
            GetScript  = "@{Ensure = if ((Get-Service | Where-Object Name -eq 'MSSQLSERVER').Count -gt 0) {'Present'} else {'Absent'}}"
            PsDscRunAsCredential = $DomainCreds
            DependsOn  = "[Script]UninstallSQL"
        }

        Script CompleteClusterSQLRole {
            SetScript  = "Get-ClusterGroup -ErrorAction SilentlyContinue | Move-ClusterGroup -Node ${env:COMPUTERNAME} -ErrorAction SilentlyContinue; `$Disks = (Get-ClusterGroup -Name 'Available Storage' | Get-ClusterResource | Sort-Object Name); `$DataDiskId = ((`$Disks | Select-Object -First 1 | Get-ClusterParameter -Name 'DiskIdGuid').Value); `$LogDiskId = ((`$Disks | Select-Object -Last 1 | Get-ClusterParameter -Name 'DiskIdGuid').Value); C:\SQLServerFull\Setup.exe /Action=CompleteFailoverCluster /SkipRules=Cluster_VerifyForErrors /IAcceptSQLServerLicenseTerms=True /INSTANCENAME=`"MSSQLSERVER`" /FAILOVERCLUSTERDISKS=`"`$((Get-ClusterGroup -Name 'Available Storage' | Get-ClusterResource | Where-Object ResourceType -eq 'Physical Disk')[0].Name)`" `"`$(@{`$true=`$null; `$false=`$((Get-ClusterGroup -Name 'Available Storage' | Get-ClusterResource | Where-Object ResourceType -eq 'Physical Disk')[-1].Name)}[`$LogDiskId -eq `$DataDiskId])`" /FAILOVERCLUSTERNETWORKNAME=`"${SQLClusterName}`" /FAILOVERCLUSTERIPADDRESSES=`"IPv4;${ListenerIPAddress1};`$((Get-ClusterNetwork).Name);`$((Get-ClusterNetwork).AddressMask)`" /SQLSYSADMINACCOUNTS=`"$($DomainCreds.Username)`" /ASSYSADMINACCOUNTS=`"$($DomainCreds.Username)`" /ASSERVERMODE=`"$($ASServerMode)`" /SQLUSERDBDIR=`"`$((Get-Disk | ? Guid -eq `$DataDiskId | Get-Partition | Get-Volume).DriveLetter + ':\MSSQL\DATA')`" /SQLBACKUPDIR=`"`$((Get-Disk | ? Guid -eq `$DataDiskId | Get-Partition | Get-Volume).DriveLetter + ':\MSSQL\BACKUP')`" /SQLUSERDBLOGDIR=`"`$((Get-Disk | ? Guid -eq `$LogDiskId | Get-Partition | Get-Volume).DriveLetter + ':\MSSQL\DATA')`" /ASDATADIR=`"`$((Get-Disk | ? Guid -eq `$DataDiskId | Get-Partition | Get-Volume).DriveLetter + ':\OLAP\DATA')`" /ASCONFIGDIR=`"`$((Get-Disk | ? Guid -eq `$DataDiskId | Get-Partition | Get-Volume).DriveLetter + ':\OLAP\CONFIG')`" /ASLOGDIR=`"`$((Get-Disk | ? Guid -eq `$LogDiskId | Get-Partition | Get-Volume).DriveLetter + ':\OLAP\LOG')`" /Q; `$global:DSCMachineStatus = 1"
            TestScript = "(Get-ClusterGroup -Name 'SQL Server (MSSQLSERVER)' -ErrorAction SilentlyContinue).Count -gt 0"
            GetScript  = "@{Ensure = if ((Get-ClusterGroup -Name 'SQL Server (MSSQLSERVER)' -ErrorAction SilentlyContinue).Count -gt 0) {'Present'} else {'Absent'}}"
            PsDscRunAsCredential = $DomainCreds
            DependsOn  = "[Script]PrepareClusterSQLRole"
        }

        Script SQLIPAddress {
            SetScript  = "Get-ClusterGroup -Name 'SQL Server (MSSQLSERVER)' -ErrorAction SilentlyContinue | Get-ClusterResource | Where-Object ResourceType -eq 'IP Address' -ErrorAction SilentlyContinue | Set-ClusterParameter -Name ProbePort ${ListenerProbePort1}; Stop-ClusterGroup -Name 'SQL Server (MSSQLSERVER)'; Start-ClusterGroup -Name 'SQL Server (MSSQLSERVER)'"
            TestScript = "(Get-ClusterGroup -Name 'SQL Server (MSSQLSERVER)' -ErrorAction SilentlyContinue | Get-ClusterResource | Where-Object ResourceType -eq 'IP Address' -ErrorAction SilentlyContinue | Get-ClusterParameter -Name ProbePort).Value -eq ${ListenerProbePort1}"
            GetScript  = "@{Ensure = if ((Get-ClusterGroup -Name 'SQL Server (MSSQLSERVER)' -ErrorAction SilentlyContinue | Get-ClusterResource | Where-Object ResourceType -eq 'IP Address' -ErrorAction SilentlyContinue | Get-ClusterParameter -Name ProbePort).Value -eq ${ListenerProbePort1}) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]CompleteClusterSQLRole"
        }
        
        Script FirewallRuleProbePort1 {
            SetScript  = "Remove-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 1' -ErrorAction SilentlyContinue; New-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 1' -Profile Domain -Direction Inbound -Action Allow -Enabled True -Protocol 'tcp' -LocalPort ${ListenerProbePort1}"
            TestScript = "(Get-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 1' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerProbePort1}"
            GetScript  = "@{Ensure = if ((Get-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 1' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerProbePort1}) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]SQLIPAddress"
        }

        Script FirewallRuleProbePort2 {
            SetScript  = "Remove-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 2' -ErrorAction SilentlyContinue; New-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 2' -Profile Domain -Direction Inbound -Action Allow -Enabled True -Protocol 'tcp' -LocalPort ${ListenerProbePort2}"
            TestScript = "(Get-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 2' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerProbePort2}"
            GetScript  = "@{Ensure = if ((Get-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 2' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerProbePort2}) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]FirewallRuleProbePort1"
        }

        Script FirewallRuleListenerPort1 {
            SetScript  = "Remove-NetFirewallRule -DisplayName 'Failover Cluster - Listener Port 1' -ErrorAction SilentlyContinue; New-NetFirewallRule -DisplayName 'Failover Cluster - Listener Port 1' -Profile Domain -Direction Inbound -Action Allow -Enabled True -Protocol 'tcp' -LocalPort ${ListenerPort1}"
            TestScript = "(Get-NetFirewallRule -DisplayName 'Failover Cluster - Listener Port 1' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerPort1}"
            GetScript  = "@{Ensure = if ((Get-NetFirewallRule -DisplayName 'Failover Cluster - Listener Port 1' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerPort1}) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]FirewallRuleProbePort2"
        }

        Script FirewallRuleListenerPort2 {
            SetScript  = "Remove-NetFirewallRule -DisplayName 'Failover Cluster - Listener Port 2' -ErrorAction SilentlyContinue; New-NetFirewallRule -DisplayName 'Failover Cluster - Listener Port 2' -Profile Domain -Direction Inbound -Action Allow -Enabled True -Protocol 'tcp' -LocalPort ${ListenerPort2}"
            TestScript = "(Get-NetFirewallRule -DisplayName 'Failover Cluster - Listener Port 2' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerPort2}"
            GetScript  = "@{Ensure = if ((Get-NetFirewallRule -DisplayName 'Failover Cluster - Listener Port 2' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerPort2}) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]FirewallRuleListenerPort1"
        }

        if ($UseDNNForSQL) {
            Script ConfigureDNNforSQL {
                SetScript = "Get-ClusterGroup -ErrorAction SilentlyContinue | Move-ClusterGroup -Node ${env:COMPUTERNAME} -ErrorAction SilentlyContinue; Add-ClusterResource -Name 'SQL DNN' -ResourceType 'Distributed Network Name' -Group 'SQL Server (MSSQLSERVER)'; Get-ClusterResource -Name 'SQL DNN' | Set-ClusterParameter -Name DnsName -Value '${SQLClusterName}dnn'; Start-ClusterResource -Name 'SQL DNN'; `$global:DSCMachineStatus = 1"
                TestScript = "(Get-ClusterResource -Name 'SQL DNN' -ErrorAction SilentlyContinue).Count -gt 0"
                GetScript = "@{Ensure = if ((Get-ClusterResource -Name 'SQL DNN' -ErrorAction SilentlyContinue).Count -gt 0) {'Present'} else {'Absent'}}"
                DependsOn = "[Script]FirewallRuleListenerPort2"
            }
        }

        LocalConfigurationManager {
            RebootNodeIfNeeded = $True
        }

    }
}
function WaitForSqlSetup
{
    # Wait for SQL Server Setup to finish before proceeding.
    $SqlSetupRunning = $false
    while ($true)
    {
        try
        {
            Get-ScheduledTaskInfo "\ConfigureSqlImageTasks\RunConfigureImage" -ErrorAction Stop
            Start-Sleep -Seconds 5
            $SqlSetupRunning = $true
        }
        catch
        {
            if ($SqlSetupRunning) { Restart-Computer -Force }
            break
        }
    }
}
