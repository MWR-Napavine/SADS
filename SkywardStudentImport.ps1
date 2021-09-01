#SkywardStudentImport.ps1 - Created/last updated by Matthew W. Ross (MWR) August 2021.
#mwross@napavineschools.org

#This file gathers the user data provided from the WSIPC students file annd makes changes to AD
# accordingly. Beware: This file MAKES CHANGES to your active directory. While it WILL NOT delete
# any users, it does enable, create and disable them.

#In order to use this, you must have Skyward EXPORT your data to a CSV file with the informatnion
#you destire. I use FileZilla on a Windows host to create an SFTP, and create a pinhole port 
#forwarding through my firewall so that the Skyward export can reach my server. There are better
#ways, but this is good enough for now.

    #####################################
    ##### User Configurable Options #####
    #####################################

#These variables are set based on your desired configuration.

# importFile is the CSV file that is created by your Skyward export. It should be formatted correctly.
$importFile = "C:\SFTP\WSIPC\Student.csv"

# exportFile is intended to create a file that will go back to Skyward. This is not implemented yet.
$exportFile ="c:\SFTP\ExportedStudnets.csv"

# We set where the Logfile is located. Logs are good. It's nice to see where something went wrong.
$logFile = "C:\SFTP\SkywardStudentImport.log"

# baseOU is where in the Active Directory we are doing all of our searches and modifications. It will
# use this to search/modify/create users, and will ignore anything oustide it's scope. Point this to
# where you student's accounts live in Active Directory.
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
$accpetableFileAge = "3"

# We setup the script so that it does not do anything if too much will be changed. Here we specify how
# large a change in persentage will be allowed without exiting. For example, if we enter a value of 15, 
# it will check for a greater than 15% difference. If we have 100 users currently, and we then import 
# file fewer than 85, then that would be more than 15% of the 100 users. Same is true if we have an 
# import file with more than 115 users... this would also be a large change. In either case, the script
# will exit. If something is wrong, like a blank or misconfigured file, this will prevent accidental
# user creation and/or changes.
$acceptablePercentChange = "10"

# Countdown timer. The script pauses to allow the user to cancel any action with a ctrl-c. This is how
# long the script should wait before executing.
$countDown = 5

    #########################################
    ##### End User Configurabel Options #####
    #########################################

# We log this all to a file.
try {Start-Transcript -LiteralPath $logFile -Append}
catch { Write-Output "Cannot start Transcript: $_.Exception,Message" }

Write-Output "*********************************************************************"
Write-Output "SkywardStudentImport script by Matthew W. Ross. Use at your own risk."
$timestamp = Get-Date -Format o
Write-Output "Script run time: $Timestamp"
Write-Output "Logging to file: $logFile"
Write-Output "*********************************************************************"`n

### Sanity Checks ###

# Sanity Check #1 - Does the import file exist?
if (Test-Path -Path $importFile) {
    Write-Output "Using the following file for import: $importFile"
} else {
    Write-Output "Could not find import file: $importFile"
    Exit 1
}

# Sanity Check #2 - How old is the import file? Is it too old?
$lastWrite = (get-item $importFile).LastWriteTime
$timespan = new-timespan -days $accpetableFileAge
if (((get-date) - $lastWrite) -gt $timespan) {
    Write-Output "Import file $importFile is more than $accpetableFileAge days old. Exiting script."
    Exit 1
    } else {
    Write-Output "Import file $importFile was last modified $lastWrite."
    }

# Sanity Check #3 - Is the import file significantly different in size from the directory?
# Gather the CSV file as an array. NOTE, this is also the import for the rest of the script.
$userID = Import-CSV $importFile
$userIDCount = $userID.count
Write-Output "Skyward Student count: $userIDCount"
$currentActive = get-aduser -Filter 'enabled -eq $true' -SearchBase $baseOU
$currentActiveCount = $currentActive.count
Write-Output "AD Active Student count: $currentActiveCount"

# We now howve our numbers, but we must calculate the percentages and differences
$acceptableChange = $currentActiveCount * ( $acceptablePercentChange / 100 )
Write-Output "Allowable change percentage set to $acceptablePercentChange. Sanity Check triggered at a differene of more than $acceptableChange students."
$aboutToChangeCount = [math]::abs( $currentActiveCount - $userIDCount )
if ($aboutToChangeCount -gt $acceptableChange) {
    #The change is too big. Stop before we break something!
    Write-Output "Change of $aboutToChangeCount is too many. Sanity Check Failed. Quiting before we break something!"
    Exit 1
    } else {
    Write-Output "Change of $aboutToChangeCount is withing sanity check paramiter. Proceding."
    }

#Okay, we passed all Sanity checks.
Write-Output "`nAll Sanity Checks passed. This script will now make changes to the directory."
Write-Output "Script begins in $countdown seconds. Press Ctrl-C now to exit."
while ($countDown -ne 0) {
    Write-Output "$countDown..."
    Start-Sleep -s 1
    $countdown = $countDown - 1
    }

# Let's enable any disabled users who already exist in AD that should now be enabled:
Write-Output `n"The Following users should be enabled:"`n
$enabledUserCount = 0
foreach ($user in $userID) {
    $otherID = $user.OtherID
    $fullName = $user.StuFullName
    $disabledUser = get-aduser -Filter {Samaccountname -eq $otherID -and Enabled -eq $false} | select -ExpandProperty SamAccountName
    if ($disabledUser.count -gt 0) {
        Write-Output "Enabling $fullname ($disabledUser)."
        Set-ADUser -Identity $disabledUser -Enabled $true
        $enabledUserCount++
    }
}
Write-Output "$enabledUserCount user(s) enabled."

# Now we create users who don't exist yet. This script uses the Skyward OtherID as the student's 
# SAMAccountID in AD. Everything is based on that OtherID value. 
Write-output `n"The Follwoing Users need to be created:"`n
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
        Write-Output "Creating $fullName ($otherID)." #Time to make the user.
        New-ADUser `
        -SamAccountName $otherID `
        -UserPrincipalName $emailAddress `
        -EmailAddress $emailAddress `
        -Name "$lastName, $firstName" `
        -GivenName $firstName `
        -Surname $lastName `
        -DisplayName "$lastName, $firstName" `
        -Description "Class of $gradYear" `
        -Enabled $True `
        -ChangePasswordAtLogon $False `
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

Write-Output "$createdUserCount user(s) created."

write-output `n"The Following Users should be disabled:"`n

#Gather the current list of students so we can see if an exist in AD where they do not show up in the
#downloaded file:
$currentStu = get-aduser -Filter 'enabled -eq $true' -SearchBase $baseOU | select -ExpandProperty SamAccountName
$disableduserCount = 0
foreach ($stu in $currentStu) {
    $otherID = $userID.OtherID
    if ($otherID -notcontains $stu) {
            #Does not Exist, so disable.
            write-output "$stu is being disabled..."
            Set-ADUser -Identity $stu -Enabled $false
            $disabledUserCount++
        } else {
            #Exists. Do nothing.
        }
}
Write-Output "$disabledUserCount user(s) disabled."

# Time to reset passwords if they had changed. We store a copy of the passwords in the AD attribute
# "Office" in order to do a comparison. This is purly for convienece. It is NOT secure. But student
# passwords are simply not secure, as teachers have access to them. I'd like to find a better solution
# for this in the future. Likely the best thing would be to set the password once, then have the
# student change it and have a mechanism to reset it. But 2nd graders are horrible at passwords...
# This is a compromise we are currently willing to accept.
Write-Output "Resetting Known Passwords..."

foreach ($user in $userID) {
    $otherID = $user.OtherID
    $fullName = $user.StuFullName
    If ($user.Student_Network_Password -eq "") {
        #The Custom form "Student_Netowrk_Password" is not set, so we're going to use the Skyward Access Password.
        $setPassword = $user.StuAccessPass
        } else {
        #Since the "Student_Network_Password is set, we'll use that here.
        $setPassword = $user.Student_Network_Password
        }
    $setInADpass = Get-ADUser $otherID -Properties PhysicalDeliveryOfficeName |select -ExpandProperty PhysicalDeliveryOfficeName
    if ($setPassword -eq $setInADpass) { 
        #Password Matches. Nothing to do.
        } else {
        #Password looks new from Skyward. Update password to AD and write it in the Office space for easy access.
        if ($setPassword -eq "") {
            Write-Output "Password from Skyward is blank for $fullname ($otherID). Doing Nothing."
                } else {
            Write-Output "Updating Password from Skyward to AD for $fullName ($otherID)."
            Set-ADUser -Identity $otherID -Office $setPassword
            Set-ADAccountPassword -Identity $otherID -NewPassword (convertto-securestring $setPassword -AsPlainText -Force)
            }
        }
}

# We need to export a CSV that can be imported back to Skyward easily. Here we create that CSV.

#All done. End logging.
Write-Output "Script Complete!"

Stop-Transcript
