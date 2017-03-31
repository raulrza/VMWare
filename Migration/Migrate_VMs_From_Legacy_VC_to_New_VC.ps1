<#

Purpose: 

    * Connect to existing legacy vCenter instance for VM migration using an ESXi swing host (Phase 1).
    * Add an ESXi swing host to the VCenter instance and attach it to a Distributed Port Group (DVS). 
    * Add the ESXi swing host to the appropriate Data Center or Host cluster, then migrate VMs to the host.
    * Move the VMs network from a DVS to a local VSS on the same VLAN contained on the transport host in the new vCenter.
    * The VSS on the ESXi transport host is the same legacy version as the DVS in the legacy VCenter instance.
    * Ensure VMs remain online after the network move, and then disconnect the ESXi swing host.
    * Once the ESXi host has been disconnected, it can be connected to a new VC instance to migrate VMs off (Phase 2).
    * An ESXi transport host on the new VC has a VSS compatible with the newer DVS. 
	* This will allow for transport of VMs to the new VCenter instance.
    
    * Phase 2 will connect to the new VC and will take ESXi receiving host out of maintenance mode.
    * Connect the swing host holding the VMs to the new VC and place the host into maintenance mode so VMs migrate off.
    * Once VMs are on the receiving host, check connectivity and switch the VM network adapters to new DVS same VLAN.
    * Check connectivity of the VMs and then place receiving host into maintenance mode so the VMs migrate to the cluster.
    * Once the VMs have migrated to the new cluster or folder, the receiving host is placed in maintenance mode. 
                
#>

<# Variable Declarations for Automated Runs #>
$OldVCHostName = “legacyvc.example.com”
$NewVCHostName = “newvc.example”
$ESXiSwingHost = “ESXiSwingHost.example.com”
$ESXiReceivingHost = “ESXiReceivingHost.example.com”
$ESXiLocationOldVC = “Existing_VM_Cluster”
$ESXiLocationNewVC = “New_VM_Cluster”
$VSwitch = "vSwitch1"
$VDSwitch = "dvSwitch-Old”
$NewVDSwitch =  “dvSwitch-New”

# Log Files
$FailLog = “C:\VMs_Failed_to_ping.txt"
$ClusHosVMCountLog = “C:\Cluster-Host-VM-Count.txt"

<# Function Declarations #>
Function PrintVars() {
    
        Write-Host -ForegroundColor Yellow "`nThe script will run automatically with the following variables: "
    Write-Host -ForegroundColor Green -BackgroundColor Black " 'Legacy' VCenter Host Name: '$OldVCHostName'"
	Write-Host -ForegroundColor Green -BackgroundColor Black " 'New' VCenter Host Name: '$NewVCHostName'"
    Write-Host -ForegroundColor Green -BackgroundColor Black "ESXi 'Swing' Host Name: '$ESXiSwingHost'"
    Write-Host -ForegroundColor Green -BackgroundColor Black "ESXi 'Receiving/Transport' Host Name: '$ESXiReceivingHost'"
	Write-Host -ForegroundColor Green -BackgroundColor Black "Swing Host Location (Phase1): '$ESXiSwingHost' will be added to '$ESXiLocationOldVC'"
	Write-Host -ForegroundColor Green -BackgroundColor Black "Swing Host Location (Phase2): '$ESXiSwingHost' will be added to '$ESXiLocationNewVC'"
    Write-Host -ForegroundColor Green -BackgroundColor Black "Local Port Group (VSS): '$VSwitch'"
    Write-Host -ForegroundColor Green -BackgroundColor Black "Distributed Port Group (DVS) on legacy VC: '$VDSwitch'`n"
    Write-Host -ForegroundColor Green -BackgroundColor Black "Distributed Port Group (DVS) on new VC: '$NewVDSwitch'`n"
    Write-Host -ForegroundColor Green -BackgroundColor Black "Location of the text file with non-responding VMs: '$FailLog'`n"
    Write-Host -ForegroundColor Green -BackgroundColor Black "Location of the text file with Cluster,Host, and VM counts: '$ClusHosVMCountLog'`n"
            
}

Function CollectVars() {

    $OldVCHostName = Read-Host "Enter 'Legacy' VCenter Host Name"
    $NewVCHostName = Read-Host "Enter ‘New’ VCenter Host Name"

    $ESXiSwingHost = Read-Host "Enter ESXi 'Swing' Host Name"
    $ESXiReceivingHost = Read-Host "Enter ESXi ‘Receiving’ Host Name"

    $ESXiLocationOldVC = Read-Host "Enter ESXi Swing Host Destination on Old VC (Folder or Cluster Name)"
    $ESXiLocationNewVC = Read-Host "Enter ESXi Swing Host Destination on New VC (Folder or Cluster Name)"

    $VSwitch = Read-Host "Enter Local Port Group (VSS) Name"
    $VDSwitch = Read-Host "Enter Distributed Port Group (DVS) on legacy VC Name"
    $NewVDSwitch = Read-Host "Enter Distributed Port Group (DVS) on New VC Name"
    
    # Log Files
    $FailLog = Read-Host "Enter a filename to save VMs that are not responding (C:\VMs_Failed_to_ping.txt)"
    $ClusHosVMCountLog = Read-Host "Enter a filename to save Cluster\Host\VM Count (C:\Cluster_Host_VM.txt)"

    # Check the response from the user whether or not the entered values are correct
    $VarCheck = Read-Host -ForegroundColor Red "IF THESE VALUES ARE NOT CORRECT PRESS 'I' then ENTER, OTHERWISE PRESS ENTER TO CONTINUE!"
    
        If ($VarCheck -like "I"){         

            # Call CollectVars to collect variables again
            CollectVars
                                          
        } Else {
                
                # Pause if the user does not press I to re-enter variables
                Pause

            }

}

# CALLS: PrintVars, CollectVars
Function ScriptMode($Run_Mode) {
    # Check if the script will be run interactively
    If ($Run_Mode -like "A"){         

        PrintVars                                              
        Write-Host -ForegroundColor Red "IF THESE VALUES ARE INCORRECT, PRESS Ctrl-C TO EXIT AND EDIT THE VARIABLES MANUALLY!"
        Pause
                                          
    } Else {
                
                Write-Host -ForegroundColor Yellow "`nThe script will run interactively, please follow the prompts."
                CollectVars

            }    
}

Function ConnectToVC($Host_Name) {
    # Check if the host is responding to ICMP requests
    If (Test-Connection -ComputerName $Host_Name -Count 2 -Quiet){
            
        Write-Host -ForegroundColor Green $Host_Name is online
            
        Try {
                # Attempt to connect to the VC instance
                Connect-viserver -server $Host_Name
                Write-Host -ForegroundColor Yellow "Connected to $Host_Name ..."
      
            }
                            
        Catch {
    
                # Unable to connect to VC instance
                Write-Output -ForegroundColor Red  "Unable to connect to $Host_Name`n"
                $VC_Host_Name = Read-Host "Enter a valid VCenter server host name or IP"
                ConnectToVC $VC_Host_Name

              }

                                      
     } Else {
                
        Write-Host -ForegroundColor Red $Host_Name is not available
        $VC_Host_Name = Read-Host "Enter a valid VCenter server host name or IP"
        ConnectToVC $VC_Host_Name
     }    

}

Function AddESXiHost ($ESXi_Host, $ESXi_Location, $VC_Host_Name) {
    
    $UserCredentials = Get-Credential -UserName root -Message "Enter the ESXi root password"
    Add-VMHost -Name $ESXi_Host -Location $ESXi_Location -User $UserCredentials.UserName -Password $$UserCredentials.GetNetworkCredential().Password -RunAsync -force

    Write-Host -ForegroundColor GREEN "Adding ESXi host $ESXi_Host to $VC_Host_Name"
       
    Write-Host -ForegroundColor yellow " Enter to connect $ESXi_Host to $VC_Host_Name VDS"
    Pause

}

Function SetESXiHostState ($ESXi_Host, $Host_State) {

    # Sets the host state: connected, disconnected, maintenance, etc.
    Set-VMHost -VMHost $ESXi_Host -State $Host_State -Confirm:$False
    
}

Function AddHostToDVS ($VD_Switch, $ESXi_Host) {

    # Add ESXi host to VDS
    Get-VDSwitch -Name $VD_Switch | Add-VDSwitchVMHost -VMHost $ESXi_Host
	
    # Connect the host's physical adapter vmnic3 to the VDS
    $VMHostNetworkAdapter = Get-VMhost $ESXi_Host | Get-VMHostNetworkAdapter -Physical -Name vmnic3
    Get-VDSwitch $VD_Switch | Add-VDSwitchPhysicalNetworkAdapter -VMHostPhysicalNic $VMHostNetworkAdapter -Confirm:$False
    
    # Exiting maintenance mode so the VMs can be migrated over to the ESXi swing host
    #Get-VMHost -Name $ESXi_Host | Set-VMHost -State Connected
    SetESXiHostState $ESXi_Host "Connected"
	
    # Pausing so the user can manually migrate VMs over to the ESXi swing host
    Write-Host -ForegroundColor Green "Host $ESXi_Host successfully connected to DVS on $VC_Host_Name"
    
}

Function SwitchVMtoVSS ($ESXi_Host) {
	
    Write-Host -ForegroundColor Green "Press Enter to continue and Change VMs to local VSS" 
    Pause   

    # Get VMhost object data
    $VMHostObj = Get-VMHost $ESXi_Host
    
    # Create a list of VM objects
    $VMList = $VMHostObj | Get-VM

    # Loop through guests and set their network adapters to local port group (VSS)
    ForEach ($VM in $VMList) {
        Get-NetworkAdapter $VM | %{
            Write-Host "Setting adapter" $_.NetworkName on $VM
            $_ | Set-NetworkAdapter -PortGroup (Get-VirtualPortGroup -VMhost $ESXi_Host -Standard -Name $_.NetworkName) -Confirm:$False
        }
    }
	
	Write-Host -ForegroundColor Green "All VM port groups changed from VDS to VSS, testing VM network connectivity."
	
}

Function SwitchVMtoVDS ($ESXi_Host, $VD_Switch) {
              
    Write-Host -ForegroundColor Green "Press Enter to continue and Change VMs from VSS to VDS" 
    Pause   

    # Get VMhost object data
    $VMHostObj = Get-VMHost $ESXi_Host
    
    # Create a list of VM objects
    $VMList = $VMHostObj | Get-VM

    # Loop through guests and set their network adapters to distributed port group (VDS)
    ForEach ($VM in $VMList) {
        Get-NetworkAdapter $VM | %{
            Write-Host "Setting adapter" $_.NetworkName on $VM
            $_ | Set-NetworkAdapter -PortGroup (Get-VDPortGroup -Name $_.NetworkName -VDSwitch $VD_Switch) -Confirm:$False
        }
    }
    
    Write-Host -ForegroundColor green "ALL VMs port group changed from VSS to DVS, testing VMs network connection"
	
}

Function CheckVMConnectivity ($VC_Host_Name, $ESXi_Host, $Fail_Log) {
    
    # Allow enough time for the network interfaces to normalize
    Sleep 30

    Write-Host -ForegroundColor Green "Port Group converted from DVS to VSS testing VMs network connectivity."
    "**********************$VC_Host_Name*****************************" >> $Fail_Log 
    Get-Date >> $Fail_Log
    Get-VMhost $ESXi_Host  | Get-VM | foreach {if(!($_.guest.hostname) -or !(Test-Connection $_.guest.hostname -count 3 -quiet)){echo "$($_.name) failed to ping"}} | Out-File $Fail_Log -Append
    Write-Host -ForegroundColor Yellow "*** Pinging All modified VMs on $ESXi_Host Check $Fail_Log now for failed VMs before continuing ***"
    Pause

}

Function DisconnectHostDVS ($ESXi_Host, $VD_Switch, $VC_Host_Name) {

    Write-Host -ForegroundColor Yellow "Enter to continue and Disconnect $ESXi_Host from DVS."
    Pause
    
    # Remove ESXi host from DVS
    Get-VDSwitch -Name $VD_Switch | Remove-VDSwitchVMHost -VMHost $ESXi_Host -Confirm:$False
    Write-Host -ForegroundColor Green "Successfully disconnected Host $ESXi_Host from DVS on $VC_Host_Name."

}

Function GetClusHosVMCount ($Clus_Hos_VM_Count_Log, $VC_Host_Name) {
    
    Write-Host -ForegroundColor Yellow "Collecting Cluster -> Host -> VM information and saving it to $Clus_Hos_VM_Count_Log."

    "**********************************  $VC_Host_Name  **********************************" >> $Clus_Hos_VM_Count_Log
    # Time stamp
    Get-Date >> $Clus_Hos_VM_Count_Log

    # Get Host and VM count.
    Get-Cluster | Select Name, @{N="Host Count"; E={($_ | Get-VMHost).Count}},
                           @{N="VM Count"; E={($_ | Get-VM).Count}} | FT -autosize >> $Clus_Hos_VM_Count_Log
                                                                                    
    "*****************************************************************************************" >> $Clus_Hos_VM_Count_Log
                                                                                    
}

Function RemoveESXiHost ($ESXi_Host, $VC_Host_Name) {

    Write-Host -ForegroundColor Red "Enter to disconnect $ESXi_Host From $VC_Host_Name and close this session."
    Pause

    # Disconnect swing host from VC without confirmation
	SetESXiHostState $ESXi_Host "Disconnected"
    
	
    # Remove swing host from VC inventory without confirmation
    Remove-VMHost $ESXi_Host -Confirm:$False
    
}

<# Main #>

##############################################################################################################################################################################
# Phase 1 - Migrate VMs to swing host on legacy VC        																													 #  
##############################################################################################################################################################################

# Welcome message and prompt user for script run-mode
Write-Host -ForegroundColor Yellow "Welcome to the VMWare Migration Script: Phase 1 - Migrate VMs from legacy vCenter to ESXi swing host`n"
$RunMode = Read-Host "How would you like to run the script? `nA - Automated`nI - Interactive`n"

# This function determines if the script is run automatically or interactively
# CALLS: PrintVars function if the user chooses automated mode
# CALLS: CollectVars function if the user chooses interactive mode
ScriptMode $RunMode

##########################################################
# 1 - Connect to Existing VC                             #  
##########################################################

ConnectToVC $OldVCHostName
 
##########################################################
# 2 - Add ESXi Swing Host to Existing VC                 #  
##########################################################

AddESXiHost $ESXiSwingHost $ESXiLocation $OldVCHostName
    
##########################################################
# 3 - Connect Swing Host to DVS and manually migrate VMs #  
##########################################################

AddHostToDVS $VDSwitch $ESXiSwingHost

# Pause to allow user time to migrate VMs manually to swing host.
Write-Host -ForegroundColor Yellow "Migrate VMs on to $ESXiSwingHost now!"
Pause
 
##########################################################
# 4 - Change VMs to local port group VSS                 #  
##########################################################

# This step is only necessary when moving from legacy DVS not compatible with the newer DVS (ex. DVS 5.1 to 6.5).
# It can be commented out when moving between compatible DVS.
SwitchVMtoVSS $ESXiSwingHost

##########################################################
# 5 - Pinging VMs to validate network connectivity       #
##########################################################

CheckVMConnectivity $OldVCHostName $ESXiSwingHost $FailLog

##########################################################
# 6 - Disconnect ESXi Swing Host from DVS                #  
##########################################################

DisconnectHostDVS $ESXiSwingHost $VDSwitch $OldVCHostName
    
##########################################################
# 7 - Collect Cluster, Host, and VM Count                #  
##########################################################

GetClusHosVMCount $ClusHosVMCountLog $OldVCHostName

##########################################################
# 8 - Disconnect ESXi Swing Host from legacy VC          #  
##########################################################

DisconnectESXiHost $ESXiSwingHost $OldVCHostName

# Disconnect from VC and close the session
Write-Host -ForegroundColor Yellow "Disconnecting from $OldVCHostName and closing session."
Disconnect-VIServer -Confirm:$False

##############################################################################################################################################################################
# Phase 2 - Move VMs from swing host to new VC           																													 #  
##############################################################################################################################################################################

# Welcome message and preparation for Phase 2
Write-Host -ForegroundColor Yellow "VMWare Migration Script: Phase 2 - Migrate VMs from ESXi swing host to new vCenter.`n"
Write-Host -ForegroundColor Green -BackgroundColor Black "Make sure that the receiving host '$ESXiReceivingHost' has been added to '$ESXiLocationNewVC' before proceeding"
Pause

Write-Host -ForegroundColor Green -BackgroundColor Black "Swing Host Location (Phase2): '$ESXiSwingHost' will be added to '$ESXiLocationNewVC'"

##########################################################
# 1 - Connect to New VC                                  #  
##########################################################

ConnectToVC $NewVCHostName

##########################################################
# 2 - Take ESXi receiving host out of maintenance mode   # 
##########################################################
    
SetESXiHostState $ESXiReceivingHost "Connected"

##########################################################
# 3 - Connect the ESXi swing host to the new VCenter     # 
##########################################################

AddESXiHost $ESXiSwingHost $ESXiLocationNewVC

##########################################################
# 4 - Removing ESXi Swing Host from new VC & migrate VMs #  
##########################################################

Write-Host -ForegroundColor Red "Press Enter to place $ESXiSwingHost in Maintenance Mode and remove from VC. "
Pause

# Place the swing host into maintenance mode so the VMs start to migrate to the receiving host $ESXiReceivingHost    
SetESXiHostState $ESXiSwingHost "Maintenance"

# Remove the swing host from inventory
Remove-VMHost $ESXiSwingHost -Confirm:$False

##########################################################
# 5 - Change VMs to distributed port group VDS           #  
##########################################################

# This step is only necessary when moving from legacy DVS not compatible with the newer DVS (ex. DVS 5.1 to 6.5).
# It can be commented out when moving between compatible DVS.
SwitchVMtoVDS $ESXiHost $NewVDSwitch

##########################################################
# 6 - Pinging VMs to validate network connectivity       #
##########################################################

CheckVMConnectivity $NewVCHostName $ESXiReceivingHost $FailLog
        
##########################################################
# 7 - Place ESXi Receiving host into maintenance mode    #
##########################################################

# Host entering maintenance mode to move VMs into the cluster
Write-Host -ForegroundColor Yellow "Press Enter to set $ESXiReceivingHost to Maintenance mode to move Vms in to cluster."
Pause

Set-VMHost -VMHost $ESXiReceivingHost -State "Maintenance"

##########################################################
# 8 - Disconnect from the VC and close the session       #
##########################################################

# Disconnect from VC and close the session
Write-Host -ForegroundColor Yellow "Disconnecting from $NewVCHostName and closing session."
Disconnect-VIServer -Confirm:$False