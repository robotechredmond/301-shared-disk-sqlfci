#
# Copyright 2020 Microsoft Corporation. All rights reserved."
#

configuration PrepareClusterNode
{
    param
    (
        [Parameter(Mandatory)]
        [String]$DomainName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$AdminCreds,

        [Parameter(Mandatory)]
        [Int]$ListenerProbePort,

        [Parameter(Mandatory)]
        [Int]$ListenerPort
    )

    Import-DscResource -ModuleName PSDesiredStateConfiguration, ComputerManagementDsc, ActiveDirectoryDsc

    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("$($Admincreds.UserName)@${DomainName}", $Admincreds.Password)
   
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
            Name      = "RSAT-Clustering-CmdInterface"
            Ensure    = "Present"
        }

        WindowsFeature ADPS
        {
            Name = "RSAT-AD-PowerShell"
            Ensure = "Present"
        }

        WindowsFeature FS
        {
            Name = "FS-FileServer"
            Ensure = "Present"
        }

        WaitForADDomain DscForestWait 
        { 
            DomainName = $DomainName 
            Credential= $DomainCreds
            WaitForValidCredentials = $True
            WaitTimeout = 600
            RestartCount = 3
            DependsOn = "[WindowsFeature]ADPS"
        }

        Computer DomainJoin
        {
            Name = $env:COMPUTERNAME
            DomainName = $DomainName
            Credential = $DomainCreds
            DependsOn = "[WaitForADDomain]DscForestWait"
        }

        <#

        Script UninstallSQL {
            SetScript  = "C:\SQLServerFull\Setup.exe /Action=Uninstall /FEATURES=SQL,AS,RS,IS /INSTANCENAME=MSSQLSERVER /Q"
            TestScript = "!(Test-Path -Path 'C:\Program Files\Microsoft SQL Server\MSSQL13.MSSQLSERVER\MSSQL\DATA\master.mdf')"
            GetScript  = "@{Ensure = if (!(Test-Path -Path 'C:\Program Files\Microsoft SQL Server\MSSQL13.MSSQLSERVER\MSSQL\DATA\master.mdf') {'Present'} else {'Absent'}}"
            DependsOn  = "[Computer]DomainJoin"
        }

        Script Reboot1 {
            SetScript  = ""
            TestScript = ""
            GetScript  = "@{Ensure = if () {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]UninstallSQL"
        }

        Script PrepareClusterSQLRole {
            SetScript  = ""
            TestScript = ""
            GetScript  = "@{Ensure = if () {'Present'} else {'Absent'}}"
            PsDscRunAsCredential = $DomainCreds
            DependsOn  = "[Script]Reboot1"
        }

        Script Reboot2 {
            SetScript  = ""
            TestScript = ""
            GetScript  = "@{Ensure = if () {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]PrepareClusterSQLRole"
        }

        Script FirewallRuleProbePort {
            SetScript  = "Remove-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port' -ErrorAction SilentlyContinue; New-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port' -Profile Domain -Direction Inbound -Action Allow -Enabled True -Protocol 'tcp' -LocalPort ${ListenerProbePort}"
            TestScript = "(Get-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerProbePort}"
            GetScript  = "@{Ensure = if ((Get-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerProbePort}) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]Reboot2"
        }

        Script FirewallRuleListenerPort {
            SetScript  = "Remove-NetFirewallRule -DisplayName 'Failover Cluster - Listener Port' -ErrorAction SilentlyContinue; New-NetFirewallRule -DisplayName 'Failover Cluster - Listener Port' -Profile Domain -Direction Inbound -Action Allow -Enabled True -Protocol 'tcp' -LocalPort ${ListenerPort}"
            TestScript = "(Get-NetFirewallRule -DisplayName 'Failover Cluster - Listener Port' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerPort}"
            GetScript  = "@{Ensure = if ((Get-NetFirewallRule -DisplayName 'Failover Cluster - Listener Port' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerPort}) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]FirewallRuleProbePort"
        }

        #>

        LocalConfigurationManager 
        {
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