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
        [String]$WorkloadType,

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

    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("$($Admincreds.UserName)@${DomainName}", $Admincreds.Password)

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

        Script FormatSharedDisks {
            SetScript  = "Get-Disk | Where-Object PartitionStyle -eq 'RAW' | Initialize-Disk -PartitionStyle GPT -PassThru -ErrorAction SilentlyContinue | New-Partition -AssignDriveLetter -UseMaximumSize -ErrorAction SilentlyContinue | Format-Volume -FileSystem NTFS -Confirm:`$false"
            TestScript = "(Get-Disk | Where-Object PartitionStyle -eq 'RAW').Count -eq 0"
            GetScript  = "@{Ensure = if ((Get-Disk | Where-Object PartitionStyle -eq 'RAW').Count -eq 0) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]CreateCluster"
        }

        Script AddClusterDisks {
            SetScript  = "Get-ClusterAvailableDisk | Add-ClusterDisk"
            TestScript = "(Get-ClusterAvailableDisk).Count -eq 0"
            GetScript  = "@{Ensure = if ((Get-ClusterAvailableDisk).Count -eq 0) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]FormatSharedDisks"
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

        <#
        
        Script UninstallSQL {
            SetScript  = "C:\SQLServerFull\Setup.exe /Action=Uninstall /FEATURES=SQL,AS,RS,IS /INSTANCENAME=MSSQLSERVER /Q"
            TestScript = "!(Test-Path -Path 'C:\Program Files\Microsoft SQL Server\MSSQL13.MSSQLSERVER\MSSQL\DATA\master.mdf')"
            GetScript  = "@{Ensure = if (!(Test-Path -Path 'C:\Program Files\Microsoft SQL Server\MSSQL13.MSSQLSERVER\MSSQL\DATA\master.mdf') {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]IncreaseClusterTimeouts"
        }

        Script Reboot1 {
            SetScript  = ""
            TestScript = ""
            GetScript  = "@{Ensure = if () {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]UninstallSQL"
        }

        Script MoveClusterGroup1 {
            SetScript  = ""
            TestScript = ""
            GetScript  = "@{Ensure = if () {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]Reboot1"
        }

        Script PrepareClusterSQLRole {
            SetScript  = ""
            TestScript = ""
            GetScript  = "@{Ensure = if () {'Present'} else {'Absent'}}"
            PsDscRunAsCredential = $DomainCreds
            DependsOn  = "[Script]MoveClusterGroup1"
        }

        Script Reboot2 {
            SetScript  = ""
            TestScript = ""
            GetScript  = "@{Ensure = if () {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]PrepareClusterSQLRole"
        }

        Script MoveClusterGroup2 {
            SetScript  = ""
            TestScript = ""
            GetScript  = "@{Ensure = if () {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]Reboot2"
        }

        Script CompleteClusterSQLRole {
            SetScript  = ""
            TestScript = ""
            GetScript  = "@{Ensure = if () {'Present'} else {'Absent'}}"
            PsDscRunAsCredential = $DomainCreds
            DependsOn  = "[Script]MoveClusterGroup2"
        }

        Script ClusterIPAddress {
            SetScript  = "Get-ClusterResource -Name 'IP Address ${ListenerIPAddress}' | Set-ClusterParameter -Name ProbePort ${ListenerProbePort}; Stop-ClusterGroup -Name ${FSName}; Start-ClusterGroup -Name ${FSName}"
            TestScript = "(Get-ClusterResource -Name 'IP Address ${ListenerIPAddress}' -ErrorAction SilentlyContinue | Get-ClusterParameter -Name ProbePort).Value -eq ${ListenerProbePort}"
            GetScript  = "@{Ensure = if ((Get-ClusterResource -Name 'IP Address ${ListenerIPAddress}' -ErrorAction SilentlyContinue | Get-ClusterParameter -Name ProbePort).Value -eq ${ListenerProbePort}) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]CompleteClusterSQLRole"
        }
        
        Script FirewallRuleProbePort {
            SetScript  = "Remove-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port' -ErrorAction SilentlyContinue; New-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port' -Profile Domain -Direction Inbound -Action Allow -Enabled True -Protocol 'tcp' -LocalPort ${ListenerProbePort}"
            TestScript = "(Get-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerProbePort}"
            GetScript  = "@{Ensure = if ((Get-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerProbePort}) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]ClusterIPAddress"
        }

        Script FirewallRuleListenerPort {
            SetScript  = "Remove-NetFirewallRule -DisplayName 'Failover Cluster - Listener Port' -ErrorAction SilentlyContinue; New-NetFirewallRule -DisplayName 'Failover Cluster - Listener Port' -Profile Domain -Direction Inbound -Action Allow -Enabled True -Protocol 'tcp' -LocalPort ${ListenerPort}"
            TestScript = "(Get-NetFirewallRule -DisplayName 'Failover Cluster - Listener Port' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerPort}"
            GetScript  = "@{Ensure = if ((Get-NetFirewallRule -DisplayName 'Failover Cluster - Listener Port' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerPort}) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]FirewallRuleProbePort"
        }

        Script Reboot3 {
            SetScript  = ""
            TestScript = ""
            GetScript  = "@{Ensure = if () {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]FirewallRuleListenerPort"
        }

        #>

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
