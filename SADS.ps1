# SADS.ps1, the Skyward Active Directory Sync.
# Created/last updated by Matthew W. Ross (MWR) September 2021.
# Previously known as SkywardStudentImport.ps1 
# mwross@napavineschools.org

# This script gathers the user data provided from a Skyward staff and students file exports and makes 
# changes to AD accordingly. Beware: This file MAKES CHANGES to your active directory. While it WILL
# NOT delete any users, it does enable, create and disable them.

#In order to use this, you must have Skyward EXPORT your data to a CSV file with the information
#you destire. As part of your EXPORT configuration, you can have the created CSV sent to a server via
# SFTP. I use FileZilla Server on a Windows host to create an SFTP server, and create a pinhole port 
#forwarding through my firewall so that the Skyward export can reach my server. There are better
#ways, but this is good enough for now.

    #####################################
    ##### User Configurable Options #####
    #####################################

#These variables are set based on your desired configuration.

# importFile is the CSV file that is created by your Skyward export.
$importFile = "C:\SFTP\WSIPC\Student.csv"

# exportFile is intended to create a file that will go back to Skyward.
$exportFile ="c:\SFTP\ExportedStudnets.csv"

# We set where the Logfile is located. Logs are good. It's nice to see where something went wrong.
$logFile = "C:\SFTP\SADS.log"

# A log of only the changes made is sent to a different file. This can be useful to see what SADS
# modified.
$changesFile ="C:\SFTP\SADS-Changes.log"

# baseOU is where in the Active Directory we are doing all of our searches and modifications. It will
# use this to search/modify/create users, and will ignore anything oustide it's scope. Point this to
# where your student's accounts live in Active Directory.
$baseOU = "OU=Students,OU=Napavine,DC=Napavine,DC=local"

# We need to set both the UPN and the user's Email address, so we need to configure what the suffix of
# should be. Currently, you cannot have one different from the other in this script.
$stuEmailSuffix = "@napastudent.org"

# When creating home folders for the students, we must know where the home folder share is. This script
# also puts the students into a subfolder of thier gradyear automatically. 
$homeRootPath = "\\storage_01\Students"

# We must know the windows NT Domain so we can try to set permissions correctly.
$ntDomain = "napavine"

# We will only process the file if it's not too old. How many days is too old? Enter the number of days
# old the file is allowed to be. If the file is older than the provided number of days, the script will
# end with a warning.
$accpetableFileAge = 3

# We setup the script so that it does not do anything if too much will be changed. Here we specify how
# large a change in persentage will be allowed without exiting. For example, if we enter a value of 15, 
# it will check for a greater than 15% difference. If we have 100 users currently, and we then import 
# file fewer than 85, then that would be more than 15% of the 100 users. Same is true if we have an 
# import file with more than 115 users... this would also be a large change. In either case, the script
# will exit. If something is wrong, like a blank or misconfigured file, this will prevent accidental
# user creation and/or changes.
$acceptablePercentChange = 5

# Countdown timer. The script pauses to allow the user to cancel before any changes are made with a 
# ctrl-c. This is how #long the script should wait before executing. Set to 0 (Zero) to skip the
# countdown altogether.
$countDown = 0

# We have the option here to run Google Cloud Directory Sync. The best time to do this is after we
# created the accounts, but we have yet to change the passwords. If we have Google Password Sync on our
# domain controllers, the passwords should be changed as long as the accounts have been created before
# we try to change them. So we run this after the accoutn creation, and before we update passwords.
$runGCDS = $true
$gcdsProgLocation = "C:\Program Files\Google Cloud Directory Sync\sync-cmd.exe"
$gcdsConfig = "C:\Program Files\Google Cloud Directory Sync\MWR-WorkInProgress.xml"

    #########################################
    ##### End User Configurabel Options #####
    #########################################

Function Write-ToLog {
    # We want all our outputs to have time stamps. Also, optionally, we want to send some output
    # to the Changes log file as well. Usage: Write-ToLog "<Text to send>" [-writeToChangelog]
    Param (
        $textOutput,
        [switch]$writeToChangelog
    )
    $D="[{0:MM/dd/yy} {0:HH:mm:ss}]" -f (Get-Date)
    if ($writeToChangelog -eq $false) {
        Write-Output "$($D) - $textOutput"
        } else {
        Write-Output "$($D) - $textOutput" | Tee-Object -FilePath $changesFile -Append
        }
    }

# We log this all to a file.
try {Start-Transcript -LiteralPath $logFile -Append}
catch { Write-Output "Cannot start Transcript: $_.Exception,Message" }

Write-ToLog "************************************************"
Write-ToLog "SADS - Skyward Active Directory Sync"
Write-ToLog "Script by Matthew W. Ross. Use at your own risk."
$timestamp = Get-Date -Format o
Write-ToLog "Script run time: $Timestamp"
Write-ToLog "Logging to file: $logFile"
Write-ToLog "************************************************"

### Sanity Checks ###

# Sanity Check #1 - Does the import file exist?
if (Test-Path -Path $importFile) {
    Write-ToLog "Using the following file for import: $importFile"
} else {
    Write-ToLog "Could not find import file: $importFile"
    Exit 1
}

# Sanity Check #2 - How old is the import file? Is it too old?
$lastWrite = (get-item $importFile).LastWriteTime
$timespan = new-timespan -days $accpetableFileAge
if (((get-date) - $lastWrite) -gt $timespan) {
    Write-ToLog "Import file $importFile is more than $accpetableFileAge days old. Exiting script."
    Exit 1
    } else {
    Write-ToLog "Import file $importFile was last modified $lastWrite. That's less than $accpetableFileAge day(s). Proceeding."
    }

# Sanity Check #3 - Is the import file significantly different in size from the directory?
# Gather the CSV file as an array. NOTE, this is also the import for the rest of the script.
$userID = Import-CSV $importFile
$userIDCount = $userID.count
Write-ToLog "Skyward Student count: $userIDCount"
$currentActive = get-aduser -Filter 'enabled -eq $true' -SearchBase $baseOU
$currentActiveCount = $currentActive.count
Write-ToLog "AD Active Student count: $currentActiveCount"

# We now howve our numbers, but we must calculate the percentages and differences
$acceptableChange = $currentActiveCount * ( $acceptablePercentChange / 100 )
Write-ToLog "Allowable change percentage set to $acceptablePercentChange."
Write-ToLog "Sanity Check triggered at a differene of more than $acceptableChange students."
$aboutToChangeCount = [math]::abs( $currentActiveCount - $userIDCount )
if ($aboutToChangeCount -gt $acceptableChange) {
    #The change is too big. Stop before we break something!
    Write-ToLog "Change of $aboutToChangeCount is too many. Sanity Check Failed. Quiting before we break something!"
    Exit 1
    } else {
    Write-ToLog "Change of $aboutToChangeCount is withing sanity check paramiter. Proceding."
    }

#Okay, we passed all Sanity checks.
Write-ToLog "All Sanity Checks passed. This script will now make changes to the directory."
If ($countDown -ne 0) {
    Write-ToLog "Script begins in $countdown seconds. Press Ctrl-C now to exit."
    while ($countDown -ne 0) {
        Write-Output "$countDown..."
        Start-Sleep -s 1
        $countdown = $countDown - 1
        }
    }

# Let's enable any disabled users who already exist in AD that should now be enabled:
Write-ToLog "The Following users should be enabled:"
$enabledUserCount = 0
foreach ($user in $userID) {
    $otherID = $user.OtherID
    $fullName = $user.StuFullName
    $disabledUser = get-aduser -Filter {Samaccountname -eq $otherID -and Enabled -eq $false} | select -ExpandProperty SamAccountName
    if ($disabledUser.count -gt 0) {
        Write-ToLog "Enabling $fullname ($disabledUser)." -writeToChangelog
        Set-ADUser -Identity $disabledUser -Enabled $true
        $enabledUserCount++
    }
}
Write-ToLog "$enabledUserCount user(s) enabled."

# Now we create users who don't exist yet. This script uses the Skyward OtherID as the student's 
# SAMAccountID in AD. Everything is based on that OtherID value. 
Write-ToLog "The Follwoing Users need to be created:"
$createdUserCount = 0
foreach ($user in $userID) {
    $otherID = $user.OtherID
    $fullName = $user.StuFullName
    $gradYear = $user.StuGradYr4
    $twoYear = $gradYear.substring($gradYear.length -2,2) #We need the 2 digit version of the gradyear, so we create it here.
    $firstName = $user.StuFirstName
    $firstInit = $firstname.Substring(0,1)
    $lastName = $user.StuLastName
    $cleanLastName = $lastname.split("-")[0] -replace '[\W]', '' #First we remove all weird characters and only the "first last name" if there is a hyphenated one...
    $cleanLastName = $cleanLastName.split(" ")[0] #Then we only grab the "first last name" if there is a space. (I couldn't figure out how to combine these into a single command.)
    $cleanLastName = $cleanLastName.substring(0,[math]::min(20,$variable.length) ) #We have a hard limit of 20 characters due to a total of 25 for the username portion of Skyward. (i.e.: "12.<--20--characters-->.f" = 25 characters total)
    $finalHomeDir = "$homerootPath\$gradYear\$otherID"
    $studentUsername = "$twoYear.$cleanLastName.$firstInit"
    #Below we use the email address if it's already provided. Else, we generate the email address.
    if ($user.SchlEmailAddr -ne $null) {
        $emailAddress = $user.SchlEmailAddr
        } else {
        $emailAddress = "$studentUsername$stuEmailSuffix"
        }
    $initPassword = $($firstInit+$cleanLastName+$gradYear).ToLower()
    $setPassword = $user.Student_Network_Password
    $createUser = Get-ADUser -filter "sAMAccountName -eq '$otherID'"
    if ($createUser -eq $null) {
        Write-ToLog "Creating $fullName ($otherID)." -writeToChangelog #Time to make the user.
        New-ADUser `
        -SamAccountName $otherID `
        -UserPrincipalName $emailAddress `
        -EmailAddress $emailAddress `
        -Name "$lastName, $firstName" `
        -GivenName $firstName `
        -Surname $lastName `
        -DisplayName "$lastName, $firstName" `
        -Description "Class of $gradYear" `
        -Department "$gradYear" `
        -Enabled $True `
        -CannotChangePassword $True `
        -ChangePasswordAtLogon $False `
        -PasswordNeverExpires $True `
        -path "OU=$gradYear,$baseOU" `
        -HomeDrive "Z:" `
        -HomeDirectory $finalHomeDir `
        -AccountPassword (convertto-securestring $initPassword -AsPlainText -Force)

        # After user is created, the home folder must be created manually, as New-ADUser doesn't
        # actually make the folder:
        New-Item -Path "$homeRootPath\$gradYear\" -name $otherID -ItemType Directory -Erroraction SilentlyContinue
        
        # Directory created, but needs the appropriate permissions added. Powershell permssions are 
        # cryptic to understand, but this works:
        $domainFomratedUsername = "$ntDomain\$otherID" #It needs the usernname in 'domain\usernanme' format.
        $permissions = Get-ACL $finalHomeDir #This picks up the currennt permissions.

        #The lines below actually defines the new permissions.
        $userpermissions = New-Object System.Security.AccessControl.FileSystemAccessRule("$domainFomratedUsername", "FullControl", "ContainerInherit, ObjectInherit", "None", "Allow")
        $permissions.AddAccessRule($userpermissions) #This tells Powershell to appennd the above permissions to the existinng permissions.
        Set-ACL $finalHomeDir $permissions #This actually applies the BIG HAMMER permissions to the directory.

        #Let's put the student into the correct groups. This could be scripted better in the future.
        Add-ADGroupMember -Identity students -members $otherID
        Add-ADGroupMember -Identity "ClassOf$gradYear" -members $otherID

        $createdUserCount++
        }
    
}

Write-ToLog "$createdUserCount user(s) created."

Write-ToLog "The Following Users should be disabled:"

#Gather the current list of students so we can see if an exist in AD where they do not show up in the
#downloaded file:
$currentStu = get-aduser -Filter 'enabled -eq $true' -SearchBase $baseOU | select -ExpandProperty SamAccountName
$disableduserCount = 0
foreach ($stu in $currentStu) {
    $otherID = $userID.OtherID
    if ($otherID -notcontains $stu) {
            #Does not Exist, so disable.
            $disableUserName = get-aduser $stu | select -ExpandProperty Name
            Write-ToLog "$disableUserName ($stu) is being disabled..." -writeToChangelog
            Set-ADUser -Identity $stu -Enabled $false
            $disabledUserCount++
        } else {
            #Exists. Do nothing.
        }
}
Write-ToLog "$disabledUserCount user(s) disabled."

if ($runGCDS = $true) {
    #We are going to update Google's accounts with the GCDS utility now.
    Write-ToLog "Running GCDS..."
    try { 
        start-process $gcdsProgLocation -argumentlist "-a -c `"$gcdsConfig`"" -Wait -NoNewWindow   
        Write-ToLog "GCDS utility finished!"
        #Let's give Google a few seconds to absorb the changes before we try to update passwords...
        start-sleep -s 5
        }
    catch { Write-ToLog "Error running GCDS: $_.Exception,Message" }
}    

# Time to reset passwords if they had changed. We store a copy of the passwords in the AD attribute
# "Office" in order to do a comparison. This is purly for convienece. It is NOT secure. But student
# passwords are simply not secure, as teachers have access to them. I'd like to find a better solution
# for this in the future. Likely the best thing would be to set the password once, then have the
# student change it and have a mechanism to reset it. But 2nd graders are horrible at passwords...
# This is a compromise we are currently willing to accept.
Write-ToLog "Resetting Known Passwords..."

foreach ($user in $userID) {
    $otherID = $user.OtherID
    $fullName = $user.StuFullName
    If ($user.Student_Network_Password -eq "") {
        #The Custom form Student_Netowrk_Password is not set, so we're going to use the Skyward Access Password.
        $setPassword = $user.StuAccessPass
        } else {
        #Since the Student_Network_Password is set, we'll use that here.
        $setPassword = $user.Student_Network_Password
        }
    $setInADpass = Get-ADUser $otherID -Properties PhysicalDeliveryOfficeName |select -ExpandProperty PhysicalDeliveryOfficeName
    if ($setPassword -eq $setInADpass) { 
        #Password Matches. Nothing to do.
        } else {
        #Password looks new from Skyward. Update password to AD and write it in the Office space for easy access.
        if ($setPassword -eq "") {
            Write-ToLog "Password from Skyward is blank for $fullname ($otherID). Doing Nothing."
                } else {
            Write-ToLog "Updating Password from Skyward to AD for $fullName ($otherID)." -writeToChangelog
            Set-ADUser -Identity $otherID -Office $setPassword
            Set-ADAccountPassword -Identity $otherID -NewPassword (convertto-securestring $setPassword -AsPlainText -Force)
            }
        }
}

# We need to export a CSV that can be imported back to Skyward easily. Here we create that CSV.
Write-ToLog "Generating Export File..."
try { get-aduser -Filter 'enabled -eq $true' -properties * -SearchBase $baseOU | Select-Object SAMaccountname, mail, office |export-csv -path $exportFile }
catch { Write-ToLog "Cannot create generate export file: $_.Exception,Message" }

#All done. End logging.
Write-ToLog "Script Complete!"

Stop-Transcript
