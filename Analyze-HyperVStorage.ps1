#region: script parameters
    #VMM Server Name (or cluster name)
    $VMMServerName = "SCVMM.Domain.Com"

    #CSV Roles, here you should define the naming convention of your CSVs
    $CSVRoles = @{
        "*OS*"       = "Operating System"
        "*FileData*" = "File Data"
        "*Citrix*"   = "Citrix"
    }
#endregion: script parameters

#region: Prepare Environment
    #Import Modules
    #The prefixes are to avoid issues with aliases.
    Import-Module -Name Hyper-V -Prefix HyperV
    Import-Module -Name virtualmachinemanager -Prefix VMM

    #Connect to VMM service
    Get-VMMSCVMMServer -ComputerName $VMMServerName | Out-Null

    #Important variables
    $GUIDPattern = "^[{(]?[0-9A-F]{8}[-]?([0-9A-F]{4}[-]?){3}[0-9A-F]{12}[)}]?$"
    $SupportedExtensions = @('.avhdx','.mrt','.rct','.vhds','.VHDX','.vmcx','.VMRS','.VMGS')

#endregion: Prepare Environment


#Collect clusters Info
    $HVClusters = Get-VMMSCVMHostCluster | Where-Object {$_.VirtualizationPlatform -eq 'HyperV'}
    $HVClusterNodes = $HVClusters.Nodes.Name

#Collect all VMs
    $VMsProblems = @()
    $VMs = foreach ($VM in (Get-VMMSCVirtualMachine | Where-Object {$_.IsHighlyAvailable -eq $true -and $_.HostName -in $HVClusterNodes})){
        #VM does not have Boot Disk
        if($VM.VirtualDiskDrives.Count -ne 0 -and $VM.VirtualDiskDrives.VolumeType -notcontains "BootAndSystem"){
            $VMsProblems += [PSCustomObject]@{
                VMID = $VM.VMID
                Issue = "NO OS Disk"
            }
        }
        #VM does not have any disks configured
        elseif ($VM.VirtualDiskDrives.Count -eq 0){
            $VMsProblems += [PSCustomObject]@{
                VMID = $VM.VMID
                Issue = "No disks attached"
            }
        }


        [PSCustomObject]@{
            ClusterName        = $VM.VMHost.HostCluster.Name
            HostName           = $VM.HostName
            VMID               = $VM.VMId
            Name               = $VM.Name
            VMState            = $VM.VirtualMachineState
            TotalSize          = $VM.TotalSize/1gb
            StopAction         = $VM.StopAction
            Location           = $VM.Location
            VirtualDisks       = $VM.VirtualDiskDrives
            HDDs               = $VM.VirtualHardDisks
            VMCPath            = $VM.VMCPath
            CheckPointLocation = $VM.CheckpointLocation

            DynamicMemory      = $VM.DynamicMemoryEnabled
            MemoryAssigned     = $VM.MemoryAssignedMB /1kb
            MemoryMax          = if($VM.DynamicMemoryEnabled) {$VM.DynamicMemoryMaximumMB/1kb} else {$VM.Memory/1kb}
        }

    }

#Collect Checkpoints using Hyper-V to show recovery CPs
    $CheckPoints = foreach ($VM in $VMs){
        foreach ($CP in (Get-HyperVVMSnapshot -ComputerName $VM.HostName -VMName $VM.Name)){
            [PSCustomObject]@{
                CheckPointID = $CP.Id
                ParentCPID   = $CP.ParentSnapshotId
                ClusterName  = $VM.ClusterName
                VMID         = $VM.VMID
                Location     = $CP.Path
                Name         = $CP.Name
                Type         = $CP.CheckpointType
                HDDs         = $CP.HardDrives

            }
        }
    }

#Collect all CSVs
    $CSVs = foreach($Cluster in $HVClusters){
        foreach($CSV in $Cluster.SharedVolumes){
            $CSVNetworkPath = $CSV.Name -replace ("C:\\","\\$($CSV.VMHost)\C$\") #So we can access it over network
            $Role = $CSVRoles.Keys | Where-Object{$CSV.VolumeLabel -like $_}
            if($Role){
                $Role = $CSVRoles.$Role
            }
            else{
                $Role = "Other"
            }

            [PSCustomObject]@{
                ClusterName     = $Cluster.Name
                CSVID           = $CSV.ID
                Name            = $CSV.VolumeLabel
                Role            = $Role
                LocalPath       = $CSV.Name
                NetworkPath     = $CSVNetworkPath
                Capacity        = $CSV.Capacity/1GB
                FreeSpace       = $CSV.FreeSpace/1GB
                AllocationUnit  = $CSV.AllocationUnitSize

                VMHost          = $CSV.VMHost.Name
            }
        }
    }

#Collect all disks
    #From VMs
    $DiskProblems = @()
    $Disks = foreach ($VM in $VMs){
    foreach ($Disk in $VM.HDDs){
        $CSV = $CSVs | Where-Object{$_.ClusterName -eq $VM.ClusterName -and $Disk.Location -like "$($_.LocalPath)*"}
        $VirtualDisk = $VM.VirtualDisks | Where-Object{$_.VirtualHardDiskID -eq $Disk.ID}
        if ($VirtualDisk) {
            if ( $VirtualDisk.VolumeType -eq "BootAndSystem" -and $CSV.Role -ne "Operating System"){
                $DiskProblems +=    [PSCustomObject]@{
                    HDDID = $Disk.ID
                    Problem = "OS Disk on Non-OS Storage"
                }
            }
            if ( $VirtualDisk.VolumeType -ne "BootAndSystem" -and $CSV.Role -eq "Operating System"){
                $DiskProblems +=    [PSCustomObject]@{
                    HDDID = $Disk.ID
                    Problem = "Data Disk on OS Storage"
                }
            }
            $VirtualDisk = $VirtualDisk.VolumeType
        }

        [PSCustomObject]@{
            HDDID       = $Disk.ID
            Cluster     = $VM.ClusterName
            CSVID       = $CSV.CSVID
            LocalPath   = $Disk.Location
            NetworkPath = $Disk.Location -replace ("C:\\","\\$($CSV.VMHost)\C$\")

            RelatedVM = $VM.VMID
            RelatedCP = $null
            RelatedDisk = $null

            IsParent = $false
            Parent = if($Disk.ParentDisk) {$disk.ParentDisk} else {$null}
            ParentQueried = $false

            Type = $Disk.VHDType
            Format = $Disk.VHDFormatType
            Capacity = $Disk.MaximumSize / 1gb
            CurrentSize = $disk.Size / 1gb

            VolumeType = $VirtualDisk
        }
    }
}
    #From parents
    $PendingParent = $Disks | Where-Object {$_.Parent -ne $null -and $_.ParentQueried -eq $false}
    while ($PendingParent){
        $Disks += foreach($Disk in $PendingParent){
        $Parent = $Disk.Parent
        $CSV = $CSVs | ?{$_.CSVID -eq $Disk.CSVID}
        $VirtualDisk = $VM.VirtualDisks | ?{$_.VirtualHardDiskID -eq $Disk.ID}
        if ($VirtualDisk) {
            if ( $VirtualDisk.VolumeType -eq "BootAndSystem" -and $CSV.Role -ne "Operating System"){
                $DiskProblems +=    [PSCustomObject]@{
                    HDDID = $Disk.ID
                    Problem = "OS Disk on Non-OS Storage"
                }
            }
            if ( $VirtualDisk.VolumeType -ne "BootAndSystem" -and $CSV.Role -eq "Operating System"){
                $DiskProblems +=    [PSCustomObject]@{
                    HDDID = $Disk.ID
                    Problem = "Data Disk on OS Storage"
                }
            }
            $VirtualDisk = $VirtualDisk.VolumeType
        }
        $RelatedCP = $CheckPoints |?{$Parent.Location -in $_.HDDs.Path}
        $Disk.ParentQueried = $true
        [PSCustomObject]@{
            HDDID       = $Parent.ID
            Cluster     = $Disk.Cluster
            CSVID       = $Disk.CSVID
            LocalPath   = $Parent.Location
            NetworkPath = $Parent.Location -replace ("C:\\","\\$($CSV.VMHost)\C$\")

            RelatedVM = $Disk.RelatedVM
            RelatedCP = if($RelatedCP) {$RelatedCP.CheckPointID} else {$null}
            RelatedDisk = $Disk.HDDID

            IsParent  = $true
            Parent = if($Parent.ParentDisk) {$Parent.ParentDisk} else {$null}
            ParentQueried = $false

            Type = $Parent.VHDType
            Format = $Parent.VHDFormatType
            Capacity = $Parent.MaximumSize / 1gb
            CurrentSize = $Parent.Size / 1gb
        }
    }
    $PendingParent = $Disks | Where-Object {$_.Parent -ne $null -and $_.ParentQueried -eq $false}
    }

#Collect all files

$FileProblems = @()

$Files = foreach ($CSV in $CSVs){
    $CSVFiles = Get-ChildItem -Path $CSV.NetworkPath -Recurse

    foreach ($File in $CSVFiles){
        $SubFileCount = 0
        $FileSizeGB   = 0
        $RelatedVM    = $null
        $RelatedCP    = $null
        $RelatedDisk  = $null


        if ($File.GetType().Name -eq 'FileInfo'){
            $FileType = $File.Extension
            $FileSizeGB = $File.Length/1GB


        }
        else {
            $FileType     = 'Folder'

            $SubFileCount = @() + ($CSVFiles |Where-Object {$_.FullName -like "$($file.FullName)\*"})
            #if($SubFileCount) {
                $SubFileCount = $SubFileCount.count
            #}


            if(($CSVFiles |Where-Object {$_.Gettype().Name -eq 'FileInfo' -and $_.FullName -like "$($file.FullName)\*"})){
                $FileSizeGB = ($CSVFiles |Where-Object {$_.Gettype().Name -eq 'FileInfo' -and $_.FullName -like "$($file.FullName)\*"}| Measure-Object -Sum -Property Length).sum / 1GB
            }


        }

        $LocalPath   = ($File.FullName).Remove(0,$file.FullName.IndexOf('$')+1).insert(0,'C:')

        $Depth = ($LocalPath -split "\\").Count

        #Check files at root
        if ($Depth -le 4 -and $FileType -ne 'Folder'){
            $FileProblems += [PSCustomObject]@{
                NetworkPath = $File.FullName
                Issue       = "File at Root"
            }
        }

        #Check Unknown File Types
        if ($FileType -ne 'Folder' -and  $FileType -notin $SupportedExtensions){
            $FileProblems += [PSCustomObject]@{
                NetworkPath = $File.FullName
                Issue       = "Unknown File Type"
            }
        }

        #Check Disk Files
        if($FileType -in @('.avhdx','.VHDX','.vhds','.mrt','.rct')){
            if($FileType -in @('.avhdx','.VHDX','.vhds')){
                $CheckingFile = $File
                $RelatedDisk = $Disks | ?{$_.NetworkPath -eq $CheckingFile.FullName} | select -First 1 #Do not support shared disks.
            }
            elseif ($FileType -in @('.mrt','.rct')){
                $ParentFile = $CSVFiles | where {$_.FullName -eq "$($File.DirectoryName)\$($File.BaseName)"}
                if($ParentFile){
                    $CheckingFile = $ParentFile
                    $FileType = $CheckingFile.Extension
                }
            }


            $RelatedDisk = $Disks | ?{$_.NetworkPath -eq $CheckingFile.FullName} | select -First 1 #Do not support shared disks.
            if($RelatedDisk){
                $RelatedVM = $RelatedDisk.RelatedVM
                $RelatedCP = $RelatedDisk.RelatedCP
                $RelatedDisk = $RelatedDisk.HDDID
            }
            elseif($FileType -eq '.avhdx' `
                    -and $CheckingFile.BaseName.Split("_")[-1] -match $GUIDPattern `
                    -and (Test-Path -Path "$($File.Directory)\$($CheckingFile.BaseName.Remove($CheckingFile.BaseName.Length-37)).vhds")
                  ){
                $RelatedDisk = $Disks | ?{$_.NetworkPath -eq "$($CheckingFile.Directory)\$($CheckingFile.BaseName.Remove($CheckingFile.BaseName.Length-37)).vhds"} | select -First 1
                $RelatedVM = $RelatedDisk.RelatedVM
                $RelatedCP = $RelatedDisk.RelatedCP
                $RelatedDisk = $RelatedDisk.HDDID
            }
            else{
                $FileProblems += [PSCustomObject]@{
                    NetworkPath = $File.FullName
                    Issue       = "Orphan"
                }
            }
            $FileType = $File.Extension

        }

        ### Check VM Anatomy ###
        #Check VMCX and VMRS File
        if ($FileType -in '.vmcx','.vmrs','.vmgs'){
            $RelatedVM = $VMs | Where-Object {$_.vmid -eq $File.BaseName -and $_.Location -eq "$($File.Directory.Parent.FullName.Remove(0,$file.FullName.IndexOf('$')+1).insert(0,'C:'))"}
            $RelatedCP = $CheckPoints | Where-Object {$_.CheckPointID -eq $File.BaseName -and $_.Location -eq "$($File.Directory.Parent.FullName.Remove(0,$file.FullName.IndexOf('$')+1).insert(0,'C:'))"}

            if ($RelatedVM) {
                $RelatedVM = $RelatedVM.vmid
            }
            elseif ($RelatedCP){
                $RelatedVM = $RelatedCP.VMID
                $RelatedCP = $RelatedCP.CheckPointID

            }
            else{
                $FileProblems += [PSCustomObject]@{
                    NetworkPath = $File.FullName
                    Issue       = "Orphan"
                }
            }
        }

        ### Folders ###

        if($FileType -eq 'Folder'){

            # VM Main folder #
            if($LocalPath -in $VMs.Location){
                $RelatedVM = $VMs | Where-Object {$_.ClusterName -eq $CSV.ClusterName -and $_.Location -eq $LocalPath}
                if ($RelatedVM) {$RelatedVM = $RelatedVM.vmid}
            }
            # 'Virtual Machines' folder #
            elseif ($LocalPath -in ($VMs.location | foreach {"$_\Virtual Machines"})){
                $RelatedVM = $VMs | ?{$_.ClusterName -eq $CSV.ClusterName -and ("$($_.Location)\Virtual Machines" -eq $LocalPath)}
                if ($RelatedVM) {$RelatedVM = $RelatedVM.vmid}
            }
            # VM GUID Folder #
            elseif($LocalPath -in ($VMs | foreach {"$($_.Location)\Virtual Machines\$($_.VMID)"})){
                $RelatedVM = $VMs | ?{$_.ClusterName -eq $CSV.ClusterName -and ("$($_.Location)\Virtual Machines\$($_.VMID)" -eq $LocalPath)}
                if ($RelatedVM) {$RelatedVM = $RelatedVM.vmid}
            }
            # VM Checkpoints folder (snapshots)
            elseif($LocalPath -in ($VMs | foreach {"$($_.CheckPointLocation)\Snapshots"})){
                $RelatedVM = $VMs | ?{$_.ClusterName -eq $CSV.ClusterName -and ("$($_.CheckPointLocation)\Snapshots" -eq $LocalPath)}
                if ($RelatedVM) {$RelatedVM = $RelatedVM.vmid}
            }
            # VM 'UndoLog Configuration' folder
            elseif($LocalPath -in ($VMs | foreach {"$($_.CheckPointLocation)\UndoLog Configuration"})){
                $RelatedVM = $VMs | ?{$_.ClusterName -eq $CSV.ClusterName -and ("$($_.CheckPointLocation)\UndoLog Configuration" -eq $LocalPath)}
                if ($RelatedVM) {$RelatedVM = $RelatedVM.vmid}
            }
            # Checkpoint folder
            elseif ($LocalPath -in ($CheckPoints | foreach {"$($_.Location)\Snapshots\$($_.CheckPointID)"})){
                $RelatedCP = $CheckPoints | ?{$_.ClusterName -eq $CSV.ClusterName -and ("$($_.Location)\Snapshots\$($_.CheckPointID)" -eq $LocalPath)}
                if ($RelatedCP) {
                    $RelatedVM = $RelatedCP.VMID
                    $RelatedCP = $RelatedCP.CheckPointID
                }
            }
            else {
                $FileProblems += [PSCustomObject]@{
                    NetworkPath = $File.FullName
                    Issue       = "Orphan"
                }
            }

        }



        [PSCustomObject]@{
            NetworkPath = $File.FullName
            LocalPath   = $LocalPath
            CSVID       = $CSV.CSVID
            ClusterName = $CSV.ClusterName


            Type         = $FileType
            SubFileCount = $SubFileCount
            Size         = $FileSizeGB
            BaseName     = $File.BaseName
            Depth        = $Depth

            RelatedVM    = $RelatedVM
            RelatedCP    = $RelatedCP
            RelatedDisk  = $RelatedDisk
        }
    }
}

#Find Orphan Folders that belong to VMs
$FilesParents = $Files | Where-Object {$_.Type -ne "Folder" -and $_.RelatedVM -ne $null} | foreach {($_.LocalPath -split "\\")[0..(($disks[0].LocalPath -split "\\").Count-2)] -join "\"}
$OrphanFolders = ($FileProblems | Where {$_.Issue -eq "Orphan"}).NetworkPath
$RelatedFolders = $Files | Where-Object {($_.Type -eq "Folder" -and $_.NetworkPath -in $OrphanFolders -and $_.LocalPath -in $FilesParents)}

$FileProblems = $FileProblems | Where{$_.NetworkPath -notin $RelatedFolders.NetworkPath}

#Find Disks without a match in Files
$DiskProblems += foreach ($Disk in $Disks){
    $MatchInFiles = $Files | ?{$_.RelatedDisk -eq $Disk.HDDID}
    if(!($MatchInFiles)){
        [PSCustomObject]@{
            HDDID = $Disk.HDDID
            Problem = "No Match in Files"
        }
    }
}



$VMs          | Export-Csv -Path .\VMs.csv          -NoTypeInformation -Delimiter "`t"
$CheckPoints  | Export-Csv -Path .\CheckPoints.csv  -NoTypeInformation -Delimiter "`t"
$CSVs         | Export-Csv -Path .\CSVs.csv         -NoTypeInformation -Delimiter "`t"
$Disks        | Export-Csv -Path .\Disks.csv        -NoTypeInformation -Delimiter "`t"
$Files        | Export-Csv -Path .\AllFiles.csv     -NoTypeInformation -Delimiter "`t"
$FileProblems | Export-Csv -Path .\FileProblems.csv -NoTypeInformation -Delimiter "`t"
$DiskProblems | Export-Csv -Path .\DiskProblems.csv -NoTypeInformation -Delimiter "`t"
$VMsProblems  | Export-Csv -Path .\VMsProblems.csv  -NoTypeInformation -Delimiter "`t"