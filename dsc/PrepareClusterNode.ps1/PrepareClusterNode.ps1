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
        [System.Management.Automation.PSCredential]$SQLCreds,

        [Int]$ListenerProbePort1 = 49100,

        [Int]$ListenerProbePort2 = 49101,

        [Int]$ListenerPort1 = 1433,

        [Int]$ListenerPort2 = 2383
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

        Script UninstallSQL {
            SetScript  = "C:\SQLServerFull\Setup.exe /Action=Uninstall /FEATURES=SQL,AS,RS,IS /INSTANCENAME=MSSQLSERVER /Q ; `$global:DSCMachineStatus = 1"
            TestScript = "!(Test-Path -Path 'C:\Program Files\Microsoft SQL Server\MSSQL*.MSSQLSERVER\MSSQL\DATA\master.mdf')"
            GetScript  = "@{Ensure = if (!(Test-Path -Path 'C:\Program Files\Microsoft SQL Server\MSSQL*.MSSQLSERVER\MSSQL\DATA\master.mdf') {'Present'} else {'Absent'}}"
            DependsOn  = "[Computer]DomainJoin"
        }

        Script PrepareClusterSQLRole {
            SetScript  = "C:\SQLServerFull\Setup.exe /Action=PrepareFailoverCluster /SkipRules=Cluster_VerifyForErrors /IAcceptSQLServerLicenseTerms=True /FEATURES=SQL,AS /INSTANCENAME=MSSQLSERVER /SQLSVCACCOUNT='${DomainName}\$($SQLCreds.Username)' /SQLSVCPASSWORD='$($SQLCreds.GetNetworkCredential().Password)' /AGTSVCACCOUNT='${DomainName}\$($SQLCreds.Username)' /AGTSVCPASSWORD='$($SQLCreds.GetNetworkCredential().Password)' /ASSVCACCOUNT='${DomainName}\$($SQLCreds.Username)' /ASSVCPASSWORD='$($SQLCreds.GetNetworkCredential().Password)' /Q ; `$global:DSCMachineStatus = 1"
            TestScript = "(Get-Service | Where-Object Name -eq 'MSSQLSERVER').Count -gt 0"
            GetScript  = "@{Ensure = if ((Get-Service | Where-Object Name -eq 'MSSQLSERVER').Count -gt 0) {'Present'} else {'Absent'}}"
            PsDscRunAsCredential = $DomainCreds
            DependsOn  = "[Script]UninstallSQL"
        }

        Script FirewallRuleProbePort1 {
            SetScript  = "Remove-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 1' -ErrorAction SilentlyContinue; New-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 1' -Profile Domain -Direction Inbound -Action Allow -Enabled True -Protocol 'tcp' -LocalPort ${ListenerProbePort1}"
            TestScript = "(Get-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 1' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerProbePort1}"
            GetScript  = "@{Ensure = if ((Get-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 1' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerProbePort1}) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]PrepareClusterSQLRole"
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
            SetScript  = "Remove-NetFirewallRule -DisplayName 'Failover Cluster - Listener Port 2' -ErrorAction SilentlyContinue; New-NetFirewallRule -DisplayName 'Failover Cluster - Listener Port 2' -Profile Domain -Direction Inbound -Action Allow -Enabled True -Protocol 'tcp' -LocalPort ${ListenerPort2} ; `$global:DSCMachineStatus = 1"
            TestScript = "(Get-NetFirewallRule -DisplayName 'Failover Cluster - Listener Port 2' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerPort2}"
            GetScript  = "@{Ensure = if ((Get-NetFirewallRule -DisplayName 'Failover Cluster - Listener Port 2' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerPort2}) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]FirewallRuleListenerPort1"
        }

        LocalConfigurationManager 
        {
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