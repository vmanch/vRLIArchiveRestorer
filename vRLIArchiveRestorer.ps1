#This script is used to automagically restore vRLI archives from NFS to vRLI or to another instance of vRLI for review. 
#v1.0 vMan.ch, 09.12.2018 - Initial Version
#v1.1 vMan.ch, 19.12.2018 - Added more mail notifications
<#

    .SYNOPSIS

    You have been asked to restore logs rolled to NFS archive for some kind of audit, SR, or have nothing better to do on a weekend.... 
    this script takes the leg work out of the process and allows you to restore locally to the same instance or to a remote instance.

    Script requires posh-ssh module --> Find-Module Posh-SSH | Install-Module

    Run the command below to store root user and pass in secure credential XML for each vRLI environment

        $cred = Get-Credential
        $cred | Export-Clixml -Path "D:\vRLIArchiveRestorer\config\VRLI.xml"

#>
[CmdletBinding()]
param
(
    [String]$RestoreType = 'REMOTE',
    [String]$vRLI = 'vrli.vman.ch',
    [String]$vRLICreds = 'VRLI',
    [String]$vRLIRemote = 'vrli2.vman.ch',
    [String]$vRLIRemoteCreds = 'vRLI',
    [DateTime]$StartDate = '2018/12/17 20:30',
    [DateTime]$EndDate = '2018/12/17 21:00',
    [String]$Email = ''
)


#Logging Function
Function Log([String]$message, [String]$LogType, [String]$LogFile){
    $date = Get-Date -UFormat '%m-%d-%Y %H:%M:%S'
    $message = $date + "`t" + $LogType + "`t" + $message
    $message >> $LogFile
}

#Log rotation function --> https://gist.github.com/barsv
function Reset-Log 
{ 
    #function checks to see if file in question is larger than the parameter specified if it is it will roll a log and delete the oldest log if there are more than x logs. 
    param([string]$fileName, [int64]$filesize = 1mb , [int] $logcount = 5) 
     
    $logRollStatus = $true 
    if(test-path $filename) 
    { 
        $file = Get-ChildItem $filename 
        if((($file).length) -ige $filesize) #this starts the log roll 
        { 
            $fileDir = $file.Directory 
            $fn = $file.name #this gets the name of the file we started with 
            $files = Get-ChildItem $filedir | ?{$_.name -like "$fn*"} | Sort-Object lastwritetime 
            $filefullname = $file.fullname #this gets the fullname of the file we started with 
            #$logcount +=1 #add one to the count as the base file is one more than the count 
            for ($i = ($files.count); $i -gt 0; $i--) 
            {  
                #[int]$fileNumber = ($f).name.Trim($file.name) #gets the current number of the file we are on 
                $files = Get-ChildItem $filedir | ?{$_.name -like "$fn*"} | Sort-Object lastwritetime 
                $operatingFile = $files | ?{($_.name).trim($fn) -eq $i} 
                if ($operatingfile) 
                 {$operatingFilenumber = ($files | ?{($_.name).trim($fn) -eq $i}).name.trim($fn)} 
                else 
                {$operatingFilenumber = $null} 
 
                if(($operatingFilenumber -eq $null) -and ($i -ne 1) -and ($i -lt $logcount)) 
                { 
                    $operatingFilenumber = $i 
                    $newfilename = "$filefullname.$operatingFilenumber" 
                    $operatingFile = $files | ?{($_.name).trim($fn) -eq ($i-1)} 
                    write-host "moving to $newfilename" 
                    move-item ($operatingFile.FullName) -Destination $newfilename -Force 
                } 
                elseif($i -ge $logcount) 
                { 
                    if($operatingFilenumber -eq $null) 
                    {  
                        $operatingFilenumber = $i - 1 
                        $operatingFile = $files | ?{($_.name).trim($fn) -eq $operatingFilenumber} 
                        
                    } 
                    write-host "deleting " ($operatingFile.FullName) 
                    remove-item ($operatingFile.FullName) -Force 
                } 
                elseif($i -eq 1) 
                { 
                    $operatingFilenumber = 1 
                    $newfilename = "$filefullname.$operatingFilenumber" 
                    write-host "moving to $newfilename" 
                    move-item $filefullname -Destination $newfilename -Force 
                } 
                else 
                { 
                    $operatingFilenumber = $i +1  
                    $newfilename = "$filefullname.$operatingFilenumber" 
                    $operatingFile = $files | ?{($_.name).trim($fn) -eq ($i-1)} 
                    write-host "moving to $newfilename" 
                    move-item ($operatingFile.FullName) -Destination $newfilename -Force    
                } 
                     
            } 
 
                     
          } 
         else 
         { $logRollStatus = $false} 
    } 
    else 
    { 
        $logrollStatus = $false 
    } 
    $LogRollStatus 
} 


#Send Email Function
Function SS64Mail($SMTPServer, $SMTPPort, $SMTPuser, $SMTPPass, $strSubject, $strBody, $strSenderemail, $strRecipientemail, $AttachFile)
   {
   [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { return $true }
      $MailMessage = New-Object System.Net.Mail.MailMessage
      $SMTPClient = New-Object System.Net.Mail.smtpClient ($SMTPServer, $SMTPPort)
	  $SMTPClient.EnableSsl = $true
	  $SMTPClient.Credentials = New-Object System.Net.NetworkCredential($SMTPuser, $SMTPPass)
      $Recipient = New-Object System.Net.Mail.MailAddress($strRecipientemail, "Recipient")
      $Sender = New-Object System.Net.Mail.MailAddress($strSenderemail, "vRLI NFS Archive Restorer")
     
      $MailMessage.Sender = $Sender
      $MailMessage.From = $Sender
      $MailMessage.Subject = $strSubject
      $MailMessage.To.add($Recipient)
      $MailMessage.Body = $strBody
      if ($AttachFile -ne $null) {$MailMessage.attachments.add($AttachFile) }
      $SMTPClient.Send($MailMessage)
   }

#Get Stored Credentials

$ScriptPath = (Get-Item -Path ".\" -Verbose).FullName

#vars
$RunDateTime = (Get-date)
$RunDateTime = $RunDateTime.tostring("yyyyMMddHHmmss")
$vRLIRestoreList = @()
$mailserver = 'mail.vman.ch'
$mailport = 25
$mailSender = 'vrli@vman.ch'

#clean up Log File
$LogFilePath = $ScriptPath + '\log\Logfile.log'
Reset-Log -fileName $LogFilePath -filesize 10mb -logcount 5


#Get Stored Credentials

if($vRLICreds -gt ""){

    $vRLICred = Import-Clixml -Path "$ScriptPath\config\$vRLICreds.xml"

    }
    else
    {
    echo "Primary vRLI Credentails not supplied, stop hammer time!"
    Exit
    }

if($Email -imatch '^.*@vman\.ch$'){

    Log -Message "$email matches the vman.ch domain" -LogType "JOB-$RunDateTime" -LogFile $LogFileLoc
    Echo "$email matches the vman.ch  domain"

    $cred = Import-Clixml -Path "$ScriptPath\config\smtp.xml"

    $SMTPUser = $cred.GetNetworkCredential().Username
    $SMTPPassword = $cred.GetNetworkCredential().Password
    }
    else
    {
    Log -Message "$email is not in the vman.ch domain, will not send mail but report generation will continue" -LogType "JOB-$RunDateTime" -LogFile $LogFileLoc
    Echo "$email is not in the vman.ch domain, will not send mail but report generation will continue"
	$Email = ''
    }

#Script begins here

Log -Message "Starting Super Epic vRLI Powershell Archive Restore script" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

#Convert to Universal Time and doing date stuff.

[string]$StartYear = ($StartDate.ToUniversalTime()).tostring("yyyy")
[string]$StartMonth = ($StartDate.ToUniversalTime()).tostring("MM")
[string]$StartDay = ($StartDate.ToUniversalTime()).tostring("dd")
[string]$StartHour = ($StartDate.ToUniversalTime()).tostring("HH")

[string]$EndYear = ($EndDate.ToUniversalTime()).tostring("yyyy")
[string]$EndMonth = ($EndDate.ToUniversalTime()).tostring("MM")
[string]$EndDay = ($EndDate.ToUniversalTime()).tostring("dd")
[string]$EndHour = ($EndDate.ToUniversalTime()).tostring("HH")

#Initiate connection to vRLI 

Log -Message "Initiate connection to $vRLI" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

$vRLISession = New-SSHSession -ComputerName $vRLI -Credential $vRLICred -AcceptKey -Force -KeepAliveInterval 60

If ($vRLISession.Connected -eq 'True'){

    #Get the NFS Mount

    $NFSMount = Invoke-SSHCommand -SessionId $vRLISession.SessionId -Command "mount | grep nfs"

    If ($NFSMount.Output -gt ''){

        $NFSPath = $NFSMount.Output | Select-String -Pattern '(:?\/storage\/core\/loginsight\/nfsmount\/\b[0-9a-f]{8}\b-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-\b[0-9a-f]{12}\b)(?:\stype nfs\s)'  | % {"$($_.matches.groups[1])"}

        If ($NFSPath.count -eq 0){

        $NFSPath = $NFSMount.Output | Select-String -Pattern '(:?\/storage\/core\/loginsight\/nfsmount\/\w*)(?:\stype nfs\s)'  | % {"$($_.matches.groups[1])"}

        }

        Write-host -ForegroundColor Green 'NFS mount found, meh continue the script'
        Log -Message "NFS mount $NFSPath found, meh continue the script" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath
    } 
    else {

        Write-host -ForegroundColor Yellow 'Hawdawg NO NFS MOUNT FOUND, lets search the config and create a temp mount'
        Log -Message "Hawdawg NO NFS MOUNT FOUND, lets search the config and create a temp mount" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

        #SearchforCurrentvRLIConfigXMLCommand Could have been a 1 liner... bloody escape chars didnt work: nfspathoutput=$(ls -at /storage/core/loginsight/config/loginsight-config.xml#* | head -1) | grep -oP 'nfs:?[\s\S]*?[^\\"]*' $nfspathoutput

        $SearchforCurrentvRLIConfigXMLCommand = 'ls -at /storage/core/loginsight/config/loginsight-config.xml#* | head -1'
                            
        $NFSArchiveConfigPath = Invoke-SSHCommand -SessionId $vRLISession.SessionId -Command $SearchforCurrentvRLIConfigXMLCommand

        If ($NFSArchiveConfigPath.ExitStatus -eq 0 -and $NFSArchiveConfigPath.Output -gt ''){

            $NFSArchiveConfigXMLGrep = 'grep -oP ''nfs:?[\s\S]*?[^\\"]*'' ' + $NFSArchiveConfigPath.Output 
    
            $NFSArchiveConfigXMLPath = Invoke-SSHCommand -SessionId $vRLISession.SessionId -Command $NFSArchiveConfigXMLGrep

             If ($NFSArchiveConfigXMLPath.ExitStatus -eq 0 -and $NFSArchiveConfigXMLPath.Output -cmatch 'nfs*'){

                $NFSArchiveConfigXMLPath = $NFSArchiveConfigXMLPath.Output -replace 'nfs://',''

                $NFSServer = $NFSArchiveConfigXMLPath | select-string '(:?[^\/]*)' | % {"$($_.matches.groups[0])"}

                $NFSServerMountable = $NFSServer + ':'

                $NFSArchiveConfigXMLPath = $NFSArchiveConfigXMLPath -replace $NFSServer,$NFSServerMountable

                Write-host -ForegroundColor Green 'Found a valid config with an NFS Archive path, mounting $NFSArchiveConfigXMLPathit manually'
                Log -Message "Found a valid config with an NFS Archive path, mounting $NFSArchiveConfigXMLPath manually" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

                $mkdirOutput = Invoke-SSHCommand -SessionId $vRLISession.SessionId -Command 'mkdir /storage/core/loginsight/nfsmount/tmprestoremnt'

                If ($mkdirOutput.ExitStatus -eq 0){

                Write-host -ForegroundColor Green 'Created /storage/core/loginsight/nfsmount/tmprestoremnt, now mounting the NFS path to it'
                Log -Message "Created /storage/core/loginsight/nfsmount/tmprestoremnt, now mounting $NFSArchiveConfigXMLPath to it" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

                $MountCommand = "mount -t nfs $NFSArchiveConfigXMLPath /storage/core/loginsight/nfsmount/tmprestoremnt"

                $Mountoutput  = Invoke-SSHCommand -SessionId $vRLISession.SessionId -Command $MountCommand

                $NFSPath = '/storage/core/loginsight/nfsmount/tmprestoremnt'

                    If ($Mountoutput.ExitStatus -gt 0){

                    Write-host -ForegroundColor Red 'ERROR: Epic fail on mounting the NFS share, tired... giving up.'
                    Log -Message "Epic fail on mounting the NFS share, tired... giving up." -LogType "ERROR-$RunDateTime" -LogFile $LogFilePath

                    Remove-SSHSession -SessionId $vRLISession.SessionId
                    Remove-SSHSession -SessionId $vRLIRemoteSession.SessionId
                    EXIT
                    }

                }
             }
        }
    }

    $CommandCheckNFSPathStartYear = "ls " + $NFSPath + "/" + $StartYear

    [array]$NFSArchiveYearContents = (Invoke-SSHCommand -SessionId $vRLISession.SessionId -Command $CommandCheckNFSPathStartYear).Output

    If ($NFSArchiveYearContents -gt ''){

        Log -Message "Found the following months $NFSArchiveYearContents in $StartYear" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

        If ($NFSArchiveYearContents -match $StartMonth){

            Write-host -ForegroundColor Green "Off to a good start... found the start month $StartMonth in $StartYear on the NFS share so we are continuing"
            Log -Message "Off to a good start... found the start month $StartMonth in $StartYear on the NFS share so we are continuing" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

            $CommandCheckNFSPathStartMonth = "ls " + $NFSPath + "/" + $StartYear + "/" + $StartMonth

            [array]$NFSArchiveMonthContents = (Invoke-SSHCommand -SessionId $vRLISession.SessionId -Command $CommandCheckNFSPathStartMonth).Output

            Log -Message "Found the following days $NFSArchiveMonthContents in month $StartMonth on the NFS share so we are continuing" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

            If ($NFSArchiveMonthContents -match $StartDay){

                Write-host -ForegroundColor Green "Ohh soo far so good... found the start day $StartDay on the NFS share so we are continuing"
                Log -Message "Ohh soo far so good... found the start day $StartDay on the NFS share so we are continuing" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

                $CommandCheckNFSPathStartDay = "ls " + $NFSPath + "/" + $StartYear + "/" + $StartMonth + "/" + $StartDay 

                [array]$NFSArchiveDayContents = (Invoke-SSHCommand -SessionId $vRLISession.SessionId -Command $CommandCheckNFSPathStartDay).Output

                Log -Message "Found the following hours $NFSArchiveDayContents in day $StartDay" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

                    If ($NFSArchiveDayContents -match $StartHour){
            
                        Write-host -ForegroundColor Green "Boom! found the start hour $StartHour on the NFS share, good to go let's build the NFS path list"
                        Log -Message "Boom! found the start hour $StartHour on the NFS share, good to go let's build the NFS path list" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

                        #OK we have a starting point, Script will start building the paths to import later.

                        $currentdate = $StartDate

                        }

                        While ($currentdate -lt $EndDate){

                        [string]$CurrentYear = ($CurrentDate).tostring("yyyy")
                        [string]$CurrentMonth = ($CurrentDate).tostring("MM")
                        [string]$CurrentDay = ($CurrentDate).tostring("dd")
                        [string]$CurrentHour = ($CurrentDate).tostring("HH")

                        $NFSArchiveCurrentContents = "ls " + $NFSPath + "/" + $CurrentYear + "/" + $CurrentMonth + "/" + $CurrentDay + "/" + $CurrentHour

                        [array]$ArchiveFolderArray = (Invoke-SSHCommand -SessionId $vRLISession.SessionId -Command $NFSArchiveCurrentContents).Output

                        $NFSArchivePath = $NFSPath + "/" + $CurrentYear + "/" + $CurrentMonth + "/" + $CurrentDay + "/" + $CurrentHour

                        Foreach ($vRLIArchive in $ArchiveFolderArray){

                        Log -Message "Blobs to restore: $NFSArchivePath/$vRLIArchive" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

                        $vRLIRestoreList += New-Object PSObject -Property @{
                    
                        Folder = $vRLIArchive
                        Path = $NFSArchivePath + "/" + $vRLIArchive
                    
                        }

                        }

                    clear-variable NFSArchiveCurrentContents,ArchiveFolderArray,NFSArchivePath  
                
                    $currentdate = $currentdate.AddHours(1)

                    }
            }

        }

    } else {
        Write-host -ForegroundColor Red "Couldn't find the $StartDate in the NFS share please check the StartDate provided and try again, killing SSH session and ending script."
        Log -Message "Couldn't find the $StartDate in the NFS share please check the StartDate provided and try again, killing SSH session and ending script." -LogType "INFO-$RunDateTime" -LogFile $LogFilePath
        SS64Mail $mailserver $mailport $SMTPUser $SMTPPassword "vRLI Automated NFS Archive Restore failed on $vRLI" "The restored period was $StartDate to $EndDate, Couldn't find the $StartDate in the NFS share please check the StartDate provided and try again" $mailSender $email
        Remove-SSHSession -SessionId $vRLISession.SessionId
        Exit
    }



    switch($RestoreType)
    {

        Local  {
    
                Write-host -ForegroundColor DarkYellow 'Performing restore to the same vRLI Instance'
                Log -Message "Performing restore to the same vRLI Instance" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

                $vRLIRestorePathCount = $vRLIRestoreList.Count
                $vRLIRestorePathRemainingCount = $vRLIRestoreList.Count

                Foreach ($vRLIArchivePath in $vRLIRestoreList.path){

                    $LocalRestoreCommand = "/usr/lib/loginsight/application/bin/loginsight repository import $vRLIArchivePath"

                    Write-host -ForegroundColor Magenta "Restoring blob $vRLIRestorePathRemainingCount of $vRLIRestorePathCount Path $vRLIArchivePath"
                    Log -Message "Restoring blob $vRLIRestorePathRemainingCount of $vRLIRestorePathCount Path $vRLIArchivePath" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

                    $RestoreOutput = Invoke-SSHCommand -SessionId $vRLISession.SessionId -Command $LocalRestoreCommand -TimeOut 300

                    $vRLIRestorePathRemainingCount = $vRLIRestorePathRemainingCount - 1

                        If ($RestoreOutput.ExitStatus -gt 0){

                            Write-host -ForegroundColor Red "ERROR: Blob $vRLIArchivePath might have failed to restore"
                            Log -Message "Blob $vRLIArchivePath might have failed to restore" -LogType "ERROR-$RunDateTime" -LogFile $LogFilePath

                        }

                       If ($RestoreOutput.Output -gt ''){
            
                            Write-host -ForegroundColor Green "Blob $vRLIArchivePath restore"
                            Log -Message "Blob $vRLIArchivePath restores" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

                        } else {

                            Write-host -ForegroundColor Red "ERROR: Something smells fishy, Blob $vRLIArchivePath might have failed to restore"
                            Log -Message "Something smells fishy, Blob $vRLIArchivePath might have failed to restore" -LogType "ERROR-$RunDateTime" -LogFile $LogFilePath


                        }


                    }

                Write-host -ForegroundColor DarkYellow "Done, All blobs restored"
                Log -Message "Done, All blobs restored" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath


                If ($NFSPath -eq '/storage/core/loginsight/nfsmount/tmprestoremnt'){

                Write-host -ForegroundColor DarkYellow "Trying to unmount $NFSPath"
                Log -Message "Trying to unmount $NFSPath" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

                    $UnmountPathCommand = 'umount ' +  $NFSPath

                    $UnmountOutput = Invoke-SSHCommand -SessionId $vRLISession.SessionId -Command $UnmountPathCommand

                    $NFSUnmountCheck = Invoke-SSHCommand -SessionId $vRLISession.SessionId -Command "mount | grep /storage/core/loginsight/nfsmount/tmprestoremnt"

                        If($NFSUnmountCheck.ExitStatus -eq 1 -or $NFSUnmountCheck.Output -eq ''){

                            Write-host -ForegroundColor DarkYellow "Unmounted the temp NFS share /storage/core/loginsight/nfsmount/tmprestoremnt"
                            Log -Message "Unmounted the temp NFS share /storage/core/loginsight/nfsmount/tmprestoremnt" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

                            $CheckEmptyNFSMountFolder = Invoke-SSHCommand -SessionId $vRLISession.SessionId -Command "ls /storage/core/loginsight/nfsmount/tmprestoremnt"

                                If($CheckEmptyNFSMountFolder.Output -gt ''){

                                    Write-host -ForegroundColor Red "Appears that /storage/core/loginsight/nfsmount/tmprestoremnt contains folders, might not be unmounted, Terminating here"
                                    Log -Message "Appears that /storage/core/loginsight/nfsmount/tmprestoremnt contains folders, might not be unmounted, Terminating here" -LogType "ERROR-$RunDateTime" -LogFile $LogFilePath
                                    SS64Mail $mailserver $mailport $SMTPUser $SMTPPassword "vRLI Automated NFS Archive Restore Completed with ERROR's on $vRLIRemote" "The restored period was $StartDate to $EndDate, it appears that /storage/core/loginsight/nfsmount/tmprestoremnt contains folders, might not be unmounted, Terminated script" $mailSender $email
                                    Remove-SSHSession -SessionId $vRLISession.SessionId
                                    Exit

                                } else {
                            
                                    Write-host -ForegroundColor DarkYellow "Remove the temp NFS share folder /storage/core/loginsight/nfsmount/tmprestoremnt"
                                    Log -Message "Remove the temp NFS share folder /storage/core/loginsight/nfsmount/tmprestoremnt" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

                                    $RemoveTempNFSMountFolder = Invoke-SSHCommand -SessionId $vRLISession.SessionId -Command "rmdir /storage/core/loginsight/nfsmount/tmprestoremnt"                            
                            
                                }

                            } else 
                            {
                            
                                Write-host -ForegroundColor DarkYellow "Unable to unmount /storage/core/loginsight/nfsmount/tmprestoremnt, terminating script"
                                Log -Message "Unable to unmount /storage/core/loginsight/nfsmount/tmprestoremnt, terminating script" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath
                                SS64Mail $mailserver $mailport $SMTPUser $SMTPPassword "vRLI Automated NFS Archive Restore Completed with ERROR's on $vRLI" "The restored period was $StartDate to $EndDate, it failed to unmount /storage/core/loginsight/nfsmount/tmprestoremnt." $mailSender $email
                                Remove-SSHSession -SessionId $vRLISession.SessionId
                                Exit
                            }
                }

                Write-host -ForegroundColor Green "Done, Cleaned up NFS mount, deleted temp folder, terminating sessions and ending script"
                Log -Message "Done, Cleaned up NFS mount, deleted temp folder, terminating sessions and ending script" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

                SS64Mail $mailserver $mailport $SMTPUser $SMTPPassword "vRLI Automated NFS Archive Restore Completed on $vRLI" "The restored period was $StartDate to $EndDate, now search for your logs in vRLI" $mailSender $email

                Remove-SSHSession -SessionId $vRLISession.SessionId
                Exit
                }


        REMOTE {

                Write-host -ForegroundColor DarkCyan 'Disconnect from $vRLI before continuing'
                Log -Message "Disconnect from $vRLI before continuing" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

                Remove-SSHSession -SessionId $vRLISession.SessionId
       
                Write-host -ForegroundColor DarkCyan 'Performing restore to a Remote vRLI Instance with SCP'
                Log -Message "Performing restore to a Remote vRLI Instance with SCP" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

                $vRLIRestorePathCount = $vRLIRestoreList.Count
                $vRLIRestorePathRemainingCount = $vRLIRestoreList.Count
            
                #Import vRLI Remote credentails from the creds file.
        
                if($vRLIRemoteCreds -gt ""){

                    $vRLIRemoteCred = Import-Clixml -Path "$ScriptPath\config\$vRLIRemoteCreds.xml"

                    }
                    else
                    {
                    echo "Remote vRLI Credentials not supplied, stop hammer time!"
                    Exit
                    }

                #Initiate session to Remote vRLI instance
            
                $vRLIRemoteSession = New-SSHSession -ComputerName $vRLIRemote -Credential $vRLIRemoteCred -AcceptKey -Force -KeepAliveInterval 60

                If ($vRLIRemoteSession.Connected -eq 'True'){

                    Foreach ($vRLIArchivePath in $vRLIRestoreList){

                    $vRLIArchivePathL = $vRLIArchivePath.Path

                    Write-host -ForegroundColor Magenta "Restoring blob $vRLIRestorePathRemainingCount of $vRLIRestorePathCount Path $vRLIArchivePathL"
                    Log -Message "Restoring blob $vRLIRestorePathRemainingCount of $vRLIRestorePathCount Path $vRLIArchivePathL" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

                    #Create the archiveimport folder

                    $Createarchiveimportfolder = Invoke-SSHCommand -SessionId $vRLIRemoteSession.SessionId -Command "mkdir /storage/core/loginsight/archiveimport"

                        #Download local cache of files in batches of 10

                        $LocalCacheFolder = $ScriptPath + '\RemoteCache\' + $vRLIArchivePath.Folder
                        $RemoteFolder = $vRLIArchivePath.Path
                        $RemoteTempFolder = '/storage/core/loginsight/archiveimport/' + $vRLIArchivePath.Folder

                        #Download blobs from Primary vRLI environment over SSH to a local cache

                        If (test-path $LocalCacheFolder){

                            Write-host -ForegroundColor Green "Folder and blob in $RemoteFolder already exist, skipping the redownload."
                            Log -Message "Folder and blob in $RemoteFolder already exist, skipping the redownload." -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

                        } else {

                            $CreateLocalCacheFolder = New-Item -ItemType directory -Path $LocalCacheFolder
            
                            $GetSCP = Get-SCPFolder -LocalFolder $LocalCacheFolder -RemoteFolder $RemoteFolder -ComputerName $vRLI -Credential $vRLICred -AcceptKey

                            Write-host -ForegroundColor Green "Download of blob $RemoteFolder to $LocalCacheFolder from $vRLI"
                            Log -Message "Download of blob $RemoteFolder to $LocalCacheFolder from $vRLI" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

                        }

                    #Upload blob from local cache to Remote vRLI instance.

                    $SetSCP = Set-SCPFolder -LocalFolder $LocalCacheFolder -RemoteFolder $RemoteTempFolder -ComputerName $vRLIRemote -Credential $vRLIRemoteCred  -AcceptKey

                    Write-host -ForegroundColor Green "Upload of blob $RemoteFolder to $RemoteTempFolder on $vRLIRemote complete"
                    Log -Message "Upload of blob $RemoteFolder to $RemoteTempFolder on $vRLIRemote complete" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

                    Write-host -ForegroundColor Green "Removing blob / $LocalCacheFolder from local cache"
                    Log -Message "Removing blob / $LocalCacheFolder from local cache" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

                    Remove-Item -Path $LocalCacheFolder -Recurse -Force

                    #Run the import to the remote vRLI instance

                    Write-host -ForegroundColor Green "Blob $RemoteTempFolder being restored on $vRLIRemote"
                    Log -Message "Blob $RemoteTempFolder being restored on $vRLIRemote" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

                    $RemoteRestoreCommand = "/usr/lib/loginsight/application/bin/loginsight repository import $RemoteTempFolder"

                    $RestoreOutput = Invoke-SSHCommand -SessionId $vRLIRemoteSession.SessionId -Command $RemoteRestoreCommand -TimeOut 300

                    $CheckImportProcessState = Invoke-SSHCommand -SessionId $vRLIRemoteSession.SessionId -Command 'ps -ef | grep [^]]"loginsight repository import"'

                    Write-host -ForegroundColor DarkMagenta "Removing $RemoteTempFolder from $vRLIRemote"
                    Log -Message "Removing $RemoteTempFolder from $vRLIRemote" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

                    $RemoveRemoteTempFolderCommand = "rm -rf $RemoteTempFolder"

                    $RemoveRemoteTempFolder = Invoke-SSHCommand -SessionId $vRLIRemoteSession.SessionId -Command $RemoveRemoteTempFolderCommand

                    $vRLIRestorePathRemainingCount = $vRLIRestorePathRemainingCount - 1

                        If ($RestoreOutput.ExitStatus -ne 0){
            
                            Write-host -ForegroundColor Red "ERROR: Blob $RemoteTempFolder might have failed to restore on $vRLIRemote"
                            Log -Message "Blob $RemoteTempFolder might have failed to restore on $vRLIRemote" -LogType "ERROR-$RunDateTime" -LogFile $LogFilePath

                        } else {
            
                            Write-host -ForegroundColor Green "Blob $RemoteTempFolder restore on $vRLIRemote"
                            Log -Message "Blob $RemoteTempFolder restore on $vRLIRemote" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath
                        
                            $RemoteRestoreRemoveBlob = "rm $RemoteTempFolder/data.blob"
                            $RemoteRestoreRemoveBlobOutput = Invoke-SSHCommand -SessionId $vRLIRemoteSession.SessionId -Command $RemoteRestoreRemoveBlob

                            $RemoteRestoreRemoveBlobFolder = "rmdir $RemoteTempFolder"
                            $RemoteRestoreRemoveBlobFolderOutput = Invoke-SSHCommand -SessionId $vRLIRemoteSession.SessionId -Command $RemoteRestoreRemoveBlobFolder

                        }

                }

                #Cleanup & unmount /storage/core/loginsight/nfsmount/tmprestoremnt

                If ($NFSPath -eq '/storage/core/loginsight/nfsmount/tmprestoremnt'){

                Write-host -ForegroundColor DarkYellow "Trying to unmount $NFSPath"
                Log -Message "Trying to unmount $NFSPath" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

                    $UnmountPathCommand = 'umount ' +  $NFSPath

                    $UnmountOutput = Invoke-SSHCommand -SessionId $vRLIRemoteSession.SessionId -Command $UnmountPathCommand

                    $NFSUnmountCheck = Invoke-SSHCommand -SessionId $vRLIRemoteSession.SessionId -Command "mount | grep /storage/core/loginsight/nfsmount/tmprestoremnt"

                        If($NFSUnmountCheck.ExitStatus -eq 1 -or $NFSUnmountCheck.Output -eq ''){

                            Write-host -ForegroundColor DarkYellow "Unmounted the temp NFS share /storage/core/loginsight/nfsmount/tmprestoremnt"
                            Log -Message "Unmounted the temp NFS share /storage/core/loginsight/nfsmount/tmprestoremnt" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

                            $CheckEmptyNFSMountFolder = Invoke-SSHCommand -SessionId $vRLIRemoteSession.SessionId -Command "ls /storage/core/loginsight/nfsmount/tmprestoremnt"

                                If($CheckEmptyNFSMountFolder.Output -gt ''){

                                    Write-host -ForegroundColor Red "Appears that /storage/core/loginsight/nfsmount/tmprestoremnt contains folders, might not be unmounted, Terminating here"
                                    Log -Message "Appears that /storage/core/loginsight/nfsmount/tmprestoremnt contains folders, might not be unmounted, Terminating here" -LogType "ERROR-$RunDateTime" -LogFile $LogFilePath
                                    Remove-SSHSession -SessionId $vRLIRemoteSession.SessionId
                                    Exit

                                } else {
                            
                                    Write-host -ForegroundColor DarkYellow "Remove the temp NFS share folder /storage/core/loginsight/nfsmount/tmprestoremnt"
                                    Log -Message "Remove the temp NFS share folder /storage/core/loginsight/nfsmount/tmprestoremnt" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

                                    $RemoveTempNFSMountFolder = Invoke-SSHCommand -SessionId $vRLIRemoteSession.SessionId -Command "rmdir /storage/core/loginsight/nfsmount/tmprestoremnt"                            
                            
                                }

                            } else 
                            {
                            
                                Write-host -ForegroundColor DarkYellow "Unable to unmount /storage/core/loginsight/nfsmount/tmprestoremnt, terminating script"
                                Log -Message "Unable to unmount /storage/core/loginsight/nfsmount/tmprestoremnt, terminating script" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath
                                SS64Mail $mailserver $mailport $SMTPUser $SMTPPassword "vRLI Automated NFS Archive Restore Completed with ERROR's on $vRLIRemote" "The restored period was $StartDate to $EndDate, it failed to unmount /storage/core/loginsight/nfsmount/tmprestoremnt." $mailSender $email
                                Remove-SSHSession -SessionId $vRLIRemoteSession.SessionId
                                Exit
                            }
                }

                Write-host -ForegroundColor DarkYellow "Done, All blobs restored"
                Log -Message "Done, All blobs restored, disconnecting from $vRLI and $vRLIRemote" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath

                SS64Mail $mailserver $mailport $SMTPUser $SMTPPassword "vRLI Automated NFS Archive Restore Completed on $vRLIRemote" "The restored period was $StartDate to $EndDate, now search for your logs in vRLI" $mailSender $email

                Remove-SSHSession -SessionId $vRLIRemoteSession.SessionId
                Exit

        } 
        else
        { 
        Write-host -ForegroundColor RED "ERROR: Couldn't SSH to $vRLIRemote, aborting script"
        SS64Mail $mailserver $mailport $SMTPUser $SMTPPassword "vRLI Automated NFS Archive Restore Completed with ERROR's on $vRLIRemote" "Couldn't SSH to $vRLIRemote, aborting script" $mailSender $email
        Log -Message "Couldnt SSH to $vRLIRemote, aborting script" -LogType "ERROR-$RunDateTime" -LogFile $LogFilePath
        Exit 
        }

    }


        REMOTENFSMOUNT {
        

            <#
            
            Sepcify NFS mount as param and have vRLI mount it and import the required data
            
            Coming Soon

            #> 
        }

        LOCALSMBMOUNT {
        

            <#
            
            Sepcify SMB mount as param and SCP data to vRLI to import the required data
            
            Coming Soon

            #> 
        }

    }
}
else {

Write-host -ForegroundColor DarkYellow "Couldnt SSH to $vRLI, aborting script"
Log -Message "Couldnt SSH to $vRLI, aborting script" -LogType "INFO-$RunDateTime" -LogFile $LogFilePath
SS64Mail $mailserver $mailport $SMTPUser $SMTPPassword "vRLI Automated NFS Archive Restore Failed on $vRLI" "Couldn't SSH to $vRLI, aborting script" $mailSender $email
}
