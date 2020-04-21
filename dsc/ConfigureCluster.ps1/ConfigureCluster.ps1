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
        [String]$ListenerIPAddress,

        [Parameter(Mandatory)]
        [Int]$ListenerProbePort,

        [Int]$ListenerPort,

        [Int]$DataDiskSizeGB,

        [String]$WitnessStorageName,

        [System.Management.Automation.PSCredential]$WitnessStorageKey
    )

    Import-DscResource -ModuleName PSDesiredStateConfiguration, ComputerManagementDsc, ActiveDirectoryDsc

    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("$($AdminCreds.UserName)@${DomainName}", $AdminCreds.Password)

    [System.Collections.ArrayList]$Nodes = @()
    For ($count = 1; $count -lt $VMCount; $count++) {
        $Nodes.Add($NamePrefix + $Count.ToString())
    }
  
    WaitForSqlSetup

    Node localhost
    {

        WindowsFeature FC {
            Name   = "Failover-Clustering"
            Ensure = "Present"
        }

        WindowsFeature FCPS {
            Name      = "RSAT-Clustering-PowerShell"
            Ensure    = "Present"
            DependsOn = "[WindowsFeature]FC"
        }

        WindowsFeature FCCmd {
            Name      = "RSAT-Clustering-CmdInterface"
            Ensure    = "Present"
            DependsOn = "[WindowsFeature]FCPS"
        }

        WindowsFeature ADPS {
            Name      = "RSAT-AD-PowerShell"
            Ensure    = "Present"
            DependsOn = "[WindowsFeature]FCCmd"
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
            SetScript            = "New-Cluster -Name ${ClusterName} -Node ${env:COMPUTERNAME} -NoStorage "
            TestScript           = "(Get-Cluster -ErrorAction SilentlyContinue).Name -eq '${ClusterName}'"
            GetScript            = "@{Ensure = if ((Get-Cluster -ErrorAction SilentlyContinue).Name -eq '${ClusterName}') {'Present'} else {'Absent'}}"
            PsDscRunAsCredential = $DomainCreds
            DependsOn            = "[Computer]DomainJoin"
        }

        foreach ($Node in $Nodes) {
            Script "AddClusterNode_${Node}" {
                SetScript            = "Add-ClusterNode -Name ${Node} -NoStorage"
                TestScript           = "'${Node}' -in (Get-ClusterNode).Name"
                GetScript            = "@{Ensure = if ('${Node}' -in (Get-ClusterNode).Name) {'Present'} else {'Absent'}}"
                PsDscRunAsCredential = $DomainCreds
                DependsOn            = "[Script]CreateCluster"
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
            TestScript = "!(Test-Path -Path 'C:\Program Files\Microsoft SQL Server\MSSQL15.MSSQLSERVER\MSSQL\DATA\master.mdf')"
            GetScript  = "@{Ensure = if (!(Test-Path -Path 'C:\Program Files\Microsoft SQL Server\MSSQL15.MSSQLSERVER\MSSQL\DATA\master.mdf') {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]IncreaseClusterTimeouts"
        }

        Script PrepareClusterSQLRole {
            SetScript  = "C:\SQLServerFull\Setup.exe /Action=PrepareFailoverCluster /SkipRules=Cluster_VerifyForErrors /IAcceptSQLServerLicenseTerms=True /FEATURES=SQL /INSTANCENAME=MSSQLSERVER /SQLSVCACCOUNT='${DomainName}\$($SQLCreds.Username)' /SQLSVCPASSWORD='$($SQLCreds.GetNetworkCredential().Password)' /AGTSVCACCOUNT='${DomainName}\$($SQLCreds.Username)' /AGTSVCPASSWORD='$($SQLCreds.GetNetworkCredential().Password)' /Q ; `$global:DSCMachineStatus = 1"
            TestScript = "(Get-Service | Where-Object Name -eq 'MSSQLSERVER').Count -gt 0"
            GetScript  = "@{Ensure = if ((Get-Service | Where-Object Name -eq 'MSSQLSERVER').Count -gt 0) {'Present'} else {'Absent'}}"
            PsDscRunAsCredential = $DomainCreds
            DependsOn  = "[Script]UninstallSQL"
        }

        Script CompleteClusterSQLRole {
            SetScript  = "Get-ClusterGroup -ErrorAction SilentlyContinue | Move-ClusterGroup -Node ${env:COMPUTERNAME} -ErrorAction SilentlyContinue; `$Disks = (Get-ClusterGroup -Name 'Available Storage' | Get-ClusterResource | Sort-Object Name); `$DataDiskId = ((`$Disks | Select-Object -First 1 | Get-ClusterParameter -Name 'DiskIdGuid').Value); `$LogDiskId = ((`$Disks | Select-Object -Last 1 | Get-ClusterParameter -Name 'DiskIdGuid').Value); C:\SQLServerFull\Setup.exe /Action=CompleteFailoverCluster /SkipRules=Cluster_VerifyForErrors /IAcceptSQLServerLicenseTerms=True /INSTANCENAME=`"MSSQLSERVER`" /FAILOVERCLUSTERDISKS=`"`$((Get-ClusterGroup -Name 'Available Storage' | Get-ClusterResource | Where-Object ResourceType -eq 'Physical Disk')[0].Name)`" `"`$((Get-ClusterGroup -Name 'Available Storage' | Get-ClusterResource | Where-Object ResourceType -eq 'Physical Disk')[-1].Name)`"  /FAILOVERCLUSTERNETWORKNAME=`"${SQLClusterName}`" /FAILOVERCLUSTERIPADDRESSES=`"IPv4;${ListenerIPAddress};`$((Get-ClusterNetwork).Name);`$((Get-ClusterNetwork).AddressMask)`" /SQLSYSADMINACCOUNTS=`"$($DomainCreds.Username)`" /SQLUSERDBDIR=`"`$((Get-Disk | ? Guid -eq `$DataDiskId | Get-Partition | Get-Volume).DriveLetter + ':\MSSQL\DATA')`" /SQLUSERDBLOGDIR=`"`$((Get-Disk | ? Guid -eq `$DataDiskId | Get-Partition | Get-Volume).DriveLetter + ':\MSSQL\DATA')`" /Q; `$global:DSCMachineStatus = 1"
            TestScript = "(Get-ClusterGroup -Name 'SQL Server (MSSQLSERVER)' -ErrorAction SilentlyContinue).Count -gt 0"
            GetScript  = "@{Ensure = if ((Get-ClusterGroup -Name 'SQL Server (MSSQLSERVER)' -ErrorAction SilentlyContinue).Count -gt 0) {'Present'} else {'Absent'}}"
            PsDscRunAsCredential = $DomainCreds
            DependsOn  = "[Script]PrepareClusterSQLRole"
        }

        Script ClusterIPAddress {
            SetScript  = "Get-ClusterGroup -Name 'SQL Server (MSSQLSERVER)' -ErrorAction SilentlyContinue | Get-ClusterResource | Where-Object ResourceType -eq 'IP Address' -ErrorAction SilentlyContinue | Set-ClusterParameter -Name ProbePort ${ListenerProbePort}; Stop-ClusterGroup -Name 'SQL Server (MSSQLSERVER)'; Start-ClusterGroup -Name 'SQL Server (MSSQLSERVER)'"
            TestScript = "(Get-ClusterGroup -Name 'SQL Server (MSSQLSERVER)' -ErrorAction SilentlyContinue | Get-ClusterResource | Where-Object ResourceType -eq 'IP Address' -ErrorAction SilentlyContinue | Get-ClusterParameter -Name ProbePort).Value -eq ${ListenerProbePort}"
            GetScript  = "@{Ensure = if ((Get-ClusterGroup -Name 'SQL Server (MSSQLSERVER)' -ErrorAction SilentlyContinue | Get-ClusterResource | Where-Object ResourceType -eq 'IP Address' -ErrorAction SilentlyContinue | Get-ClusterParameter -Name ProbePort).Value -eq ${ListenerProbePort}) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]CompleteClusterSQLRole"
        }
        
        Script FirewallRuleProbePort {
            SetScript  = "Remove-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port' -ErrorAction SilentlyContinue; New-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port' -Profile Domain -Direction Inbound -Action Allow -Enabled True -Protocol 'tcp' -LocalPort ${ListenerProbePort}"
            TestScript = "(Get-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerProbePort}"
            GetScript  = "@{Ensure = if ((Get-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerProbePort}) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]ClusterIPAddress"
        }

        Script FirewallRuleListenerPort {
            SetScript  = "Remove-NetFirewallRule -DisplayName 'Failover Cluster - Listener Port' -ErrorAction SilentlyContinue; New-NetFirewallRule -DisplayName 'Failover Cluster - Listener Port' -Profile Domain -Direction Inbound -Action Allow -Enabled True -Protocol 'tcp' -LocalPort ${ListenerPort} ; `$global:DSCMachineStatus = 1"
            TestScript = "(Get-NetFirewallRule -DisplayName 'Failover Cluster - Listener Port' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerPort}"
            GetScript  = "@{Ensure = if ((Get-NetFirewallRule -DisplayName 'Failover Cluster - Listener Port' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerPort}) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]FirewallRuleProbePort"
        }

        LocalConfigurationManager {
            RebootNodeIfNeeded = $True
        }

    }
}
function WaitForSqlSetup
{
    # Wait for SQL Server Setup to finish before proceeding.
    while ($true)
    {
        try
        {
            Get-ScheduledTaskInfo "\ConfigureSqlImageTasks\RunConfigureImage" -ErrorAction Stop
            Start-Sleep -Seconds 5
        }
        catch
        {
            break
        }
    }
}
