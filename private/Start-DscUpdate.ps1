function Start-DscUpdate {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [psobject]$ComputerName,
        [PSCredential]$Credential,
        [PSCredential]$PSDscRunAsCredential,
        [Parameter(ValueFromPipelineByPropertyName)]
        [Alias("Name", "KBUpdate", "Id")]
        [string]$HotfixId,
        [Alias("Path")]
        [string]$FilePath,
        [string]$RepositoryPath,
        [Parameter(ValueFromPipelineByPropertyName)]
        [Alias("UpdateId")]
        [string]$Guid,
        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Title,
        [string]$ArgumentList,
        [Parameter(ValueFromPipeline)]
        [pscustomobject[]]$InputObject,
        [switch]$AllNeeded,
        [switch]$NoMultithreading,
        [switch]$EnableException,
        [bool]$IsLocalHost,
        [string]$VerbosePreference,
        [string]$ScanFilePath,
        [string[]]$ModulePath
    )
    begin {
        if ($PSVersionTable.PSVersion.Major -gt 5) {
            $null = Import-Module -UseWindowsPowerShell PSDesiredStateConfiguration -MaximumVersion 1.1 *>$null
        }
        # No idea why this sometimes happens
        if ($ComputerName -is [hashtable]) {
            $hashtable = $ComputerName.PsObject.Copy()
            $null = Remove-Variable -Name ComputerName
            foreach ($key in $hashtable.keys) {
                Set-Variable -Name $key -Value $hashtable[$key]
            }
        }

        # load up if a job
        foreach ($path in $ModulePath) {
            $null = Import-Module $path 4>$null
        }

        if ($EnableException) {
            $PSDefaultParameterValues["*:EnableException"] = $true
        } else {
            $PSDefaultParameterValues["*:EnableException"] = $false
        }

        if ($ComputerName.ComputerName) {
            $hostname = $ComputerName.ComputerName
        } else {
            $hostname = $ComputerName
        }

        if ($AllNeeded) {
            if ($ScanFilePath) {
                $InputObject = Get-KbNeededUpdate -ComputerName $ComputerName -ScanFilePath $ScanFilePath -Force
            } else {
                $InputObject = Get-KbNeededUpdate -ComputerName $ComputerName
            }
        }

        if ($HotfixId -and -not $InputObject.Link) {
            Write-PSFMessage -Level Verbose -Message "Hotfix detected without InputObject, getting info"
            $InputObject += Get-KbUpdate -HotfixId $HotfixId -ComputerName $ComputerName
        }

        $script:ModuleRoot = Split-Path -Path $($ModulePath | Select-Object -Last 1)

        # null out a couple things to be safe
        $remotefileexists = $programhome = $remotesession = $null
        # Method is DSC
        if ($PSDefaultParameterValues["Invoke-KbCommand:ComputerName"]) {
            $null = $PSDefaultParameterValues.Remove("Invoke-KbCommand:ComputerName")
        }
        $PSDefaultParameterValues["Invoke-KbCommand:ComputerName"] = $ComputerName

        if ($Credential) {
            $PSDefaultParameterValues["Invoke-KbCommand:Credential"] = $Credential
        }

        if ($FilePath) {
            if ($ComputerName.IsLocalHost) {
                $InputObject += Get-ChildItem -Path $FilePath
            } else {
                $InputObject += Invoke-KbCommand -ScriptBlock { Get-ChildItem -Path $FilePath }
            }
        }

        if ($IsLocalHost) {
            # a lot of the file copy work will be done in the $home dir
            $programhome = Invoke-KbCommand -ScriptBlock { $home }
        } else {
            Write-PSFMessage -Level Verbose -Message "Adding $hostname to PSDefaultParameterValues for Invoke-KbCommand:ComputerName"
            $PSDefaultParameterValues["Invoke-KbCommand:ComputerName"] = $ComputerName

            Write-PSFMessage -Level Verbose -Message "Initializing remote session to $hostname and also getting the remote home directory"
            $programhome = Invoke-KbCommand -ScriptBlock { $home }

            if (-not $remotesession) {
                $remotesession = Get-PSSession -ComputerName $ComputerName -Verbose | Where-Object { $PsItem.Availability -eq 'Available' -and ($PsItem.Name -match 'WinRM' -or $PsItem.Name -match 'Runspace') } | Select-Object -First 1
            }

            if (-not $remotesession) {
                $remotesession = Get-PSSession -ComputerName $ComputerName | Where-Object { $PsItem.Availability -eq 'Available' } | Select-Object -First 1
            }

            if (-not $remotesession) {
                Stop-PSFFunction -Message "Session for $hostname can't be found or no runspaces are available. Please file an issue on the GitHub repo at https://github.com/potatoqualitee/kbupdate/issues" -Continue
            }
        }

        # fix for SYSTEM which doesn't have a downloads directory by default
        Write-PSFMessage -Level Verbose -Message "Checking for home downloads directory"
        Invoke-KbCommand -ScriptBlock {
            if (-not (Test-Path -Path "$home\Downloads")) {
                Write-Warning "Creating Downloads directory at $home\Downloads"
                $null = New-Item -ItemType Directory -Force -Path "$home\Downloads"
            }
        }

        $hasxhotfix = Invoke-KbCommand -ScriptBlock {
            Get-Module -Name xWindowsUpdate -ListAvailable -ErrorAction Ignore | Where-Object { $PSItem.Path -match "3.0.0" -and $PSItem.Path -like "$env:ProgramFiles*" }
        }

        if (-not $hasxhotfix) {
            try {
                # Copy xWindowsUpdate to Program Files. The module is pretty much required to be in the PS Modules directory.
                $oldpref = $ProgressPreference
                $ProgressPreference = "SilentlyContinue"
                $programfiles = Invoke-KbCommand -ScriptBlock {
                    $env:ProgramFiles
                }
                if ($IsLocalHost) {
                    Write-PSFMessage -Level Verbose -Message "Copying xWindowsUpdate to $hostname (local to $programfiles\WindowsPowerShell\Modules\xWindowsUpdate)"
                    $null = Copy-Item -Path "$script:ModuleRoot\library\xWindowsUpdate" -Destination "$programfiles\WindowsPowerShell\Modules" -Recurse -Force -ErrorAction Stop
                } else {
                    Write-PSFMessage -Level Verbose -Message "Copying xWindowsUpdate to $hostname (remote to $programfiles\WindowsPowerShell\Modules\xWindowsUpdate)"
                    $null = Copy-Item -Path "$script:ModuleRoot\library\xWindowsUpdate" -Destination "$programfiles\WindowsPowerShell\Modules" -ToSession $remotesession -Recurse -Force -ErrorAction Stop
                }

                $ProgressPreference = $oldpref
            } catch {
                Stop-PSFFunction -Message "Couldn't auto-install xHotfix on $hostname. Please Install-Module xWindowsUpdate on $hostname to continue." -Continue
            }
        }

        $hasxdsc = Invoke-KbCommand -ScriptBlock {
            Get-Module -Name xPSDesiredStateConfiguration -ListAvailable -ErrorAction Ignore | Where-Object { $PSItem.Path -match "9.2.0" -and $PSItem.Path -like "$env:ProgramFiles*" }
        }

        if (-not $hasxdsc) {
            try {
                Write-PSFMessage -Level Verbose -Message "Adding xPSDesiredStateConfiguration to $hostname"
                # Copy xWindowsUpdate to Program Files. The module is pretty much required to be in the PS Modules directory.
                $oldpref = $ProgressPreference
                $ProgressPreference = "SilentlyContinue"
                $programfiles = Invoke-KbCommand -ScriptBlock {
                    $env:ProgramFiles
                }
                if ($IsLocalHost) {
                    Write-PSFMessage -Level Verbose -Message "Copying xPSDesiredStateConfiguration to $hostname (local to $programfiles\WindowsPowerShell\Modules\xPSDesiredStateConfiguration)"
                    $null = Copy-Item -Path "$script:ModuleRoot\library\xPSDesiredStateConfiguration" -Destination "$programfiles\WindowsPowerShell\Modules" -Recurse -Force -ErrorAction Stop
                } else {
                    Write-PSFMessage -Level Verbose -Message "Copying xPSDesiredStateConfiguration to $hostname (remote)"
                    $null = Copy-Item -Path "$script:ModuleRoot\library\xPSDesiredStateConfiguration" -Destination "$programfiles\WindowsPowerShell\Modules" -ToSession $remotesession -Recurse -Force -ErrorAction Stop
                }

                $ProgressPreference = $oldpref
            } catch {
                Stop-PSFFunction -Message "Couldn't auto-install newer DSC resources on $hostname. Please Install-Module xPSDesiredStateConfiguration version 9.2.0 on $hostname to continue." -Continue
            }
        }
    }
    process {
        if ($FilePath -and -not $InputObject) {
            Write-PSFMessage -Level Verbose -Message "Setting InputObject to $FilePath"
            $InputObject = $FilePath
        }
        if (-not $InputObject) {
            Write-PSFMessage -Level Verbose -Message "Nothing to install on $hostname, moving on"
        }
        foreach ($object in $InputObject) {
            if ($object.Link -and $RepositoryPath) {
                try {
                    foreach ($item in $object.Link) {
                        $filename = Split-Path -Path $item -Leaf
                        Write-PSFMessage -Level Verbose -Message "Adding $filename to $RepositoryPath"
                        $repofile = Join-Path -Path $RepositoryPath -ChildPath $filename
                        if (-not (Test-Path -Path $repofile)) {
                            Write-PSFMessage -Level Verbose -Message "File does not exist, trying to download $item to $repofile"
                            $null = Save-KbUpdate -Link $item -Path $RepositoryPath
                        }
                        if ($remotehome) {
                            $null = Copy-Item -Path $repofile -Destination "$remotehome\Downloads\$filename" -ToSession $remotesession -Recurse -Force -ErrorAction Stop
                        } else {
                            $null = Copy-Item -Path $repofile -Destination "$home\Downloads" -Recurse -Force -ErrorAction Stop
                        }
                    }
                } catch {
                    if (-not $hostname) {
                        $hostname = $object.ComputerName
                    }
                    Stop-PSFFunction -Message "Couldn't copy $filename from repo to $hostname." -ErrorRecord $PSItem -Continue
                }
            }

            if (-not $remotefileexists) {
                if ($FilePath) {
                    # try really hard to find it locally
                    $updatefile = Get-ChildItem -Path $FilePath -ErrorAction SilentlyContinue
                    if (-not $updatefile) {
                        Write-PSFMessage -Level Verbose -Message "Update file not found, try in Downloads"
                        $filename = Split-Path -Path $FilePath -Leaf
                        $updatefile = Get-ChildItem -Path "$home\Downloads\$filename" -ErrorAction SilentlyContinue
                    }
                }

                if (-not $updatefile) {
                    if ($HotfixId) {
                        $Pattern = $HotfixId
                    } elseif ($Guid) {
                        $Pattern = $Guid
                    } elseif ($object.UpdateId) {
                        $Pattern = $object.UpdateId
                    } elseif ($object.Id) {
                        $Pattern = $object.Id
                    } elseif ($object.Id) {
                        $Pattern = $object.Id
                    } elseif ($filename) {
                        $number = "$filename".Split('KB') | Select-Object -Last 1
                        $number = $number.Split(" ") | Select-Object -First 1
                        $Pattern = "KB$number".Trim().Replace(")", "")
                    } elseif ($FilePath) {
                        $number = "$(Split-Path $FilePath -Leaf)".Split('KB') | Select-Object -Last 1
                        $number = $number.Split(" ") | Select-Object -First 1
                        $Pattern = "KB$number".Trim().Replace(")", "")
                    }

                    # try to automatically download it for them
                    if (-not $object -and $Pattern) {
                        Write-Message -Level Verbose -Message "No object and a pattern"
                        $object = Get-KbUpdate -ComputerName $ComputerName -Pattern $Pattern | Where-Object { $PSItem.Link -and $PSItem.Title -match $Pattern }
                    }

                    # note to reader: if this picks the wrong one, please download the required file manually.
                    if ($object.Link) {
                        if ($object.Link -match 'x64') {
                            $file = $object | Where-Object Link -match 'x64' | Select-Object -ExpandProperty Link -Last 1 | Split-Path -Leaf
                        } else {
                            $file = Split-Path $object.Link -Leaf | Select-Object -Last 1
                        }
                    } else {
                        Stop-PSFFunction -Message "Could not find file on $hostname and couldn't find it online. Try piping in exactly what you'd like from Get-KbUpdate." -Continue
                    }

                    if ((Test-Path -Path "$home\Downloads\$file")) {
                        $updatefile = Get-ChildItem -Path "$home\Downloads\$file"
                    } else {
                        Write-PSFMessage -Level Verbose -Message "File not detected on $hostname, downloading now to $home\Downloads and copying to remote computer"

                        $warnatbottom = $true

                        # fix for SYSTEM which doesn't have a downloads directory by default
                        Write-PSFMessage -Level Verbose -Message "Checking for home downloads directory"
                        if (-not (Test-Path -Path "$home\Downloads")) {
                            Write-PSFMessage -Level Warning -Message "Creating Downloads directory at $home\Downloads"
                            $null = New-Item -ItemType Directory -Force -Path "$home\Downloads"
                        }

                        $updatefile = $object | Select-Object -First 1 | Save-KbUpdate -Path "$home\Downloads"
                    }
                }

                if (-not $FilePath) {
                    $FilePath = "$programhome\Downloads\$(Split-Path -Leaf $updateFile)"
                }

                if ($IsLocalHost) {
                    $remotefile = $updatefile
                } else {
                    $remotefile = "$programhome\Downloads\$(Split-Path -Leaf $updateFile)"
                }

                # copy over to destination server unless
                # it's local or it's on a network share
                if (-not "$($FilePath)".StartsWith("\\") -and -not $IsLocalHost) {
                    Write-PSFMessage -Level Verbose -Message "Update is not located on a file server and not local, copying over the remote server"
                    try {
                        $exists = Invoke-KbCommand -ComputerName $ComputerName -ArgumentList $remotefile -ScriptBlock {
                            Get-ChildItem -Path $args -ErrorAction SilentlyContinue
                        }
                        if (-not $exists) {
                            $null = Copy-Item -Path $updatefile -Destination $remotefile -ToSession $remotesession -ErrorAction Stop
                            $deleteremotefile = $remotefile
                        }
                    } catch {
                        $null = Invoke-KbCommand -ComputerName $ComputerName -ArgumentList $remotefile -ScriptBlock {
                            Remove-Item $args -Force -ErrorAction SilentlyContinue
                        }
                        try {
                            Write-PSFMessage -Level Warning -Message "Copy failed, trying again"
                            $null = Copy-Item -Path $updatefile -Destination $remotefile -ToSession $remotesession -ErrorAction Stop
                            $deleteremotefile = $remotefile
                        } catch {
                            $null = Invoke-KbCommand -ComputerName $ComputerName -ArgumentList $remotefile -ScriptBlock {
                                Remove-Item $args -Force -ErrorAction SilentlyContinue
                            }
                            Stop-PSFFunction -Message "Could not copy $updatefile to $remotefile" -ErrorRecord $PSItem -Continue
                        }
                    }
                }
            }

            # if user doesnt add kb, try to find it for them from the provided filename
            if (-not $HotfixId) {
                $HotfixId = $FilePath.ToUpper() -split "\-" | Where-Object { $psitem.Startswith("KB") }
            }

            # i probably need to fix some logic but until then, check a few things
            if ($IsLocalHost) {
                if ($updatefile) {
                    $FilePath = $updatefile
                } else {
                    $updatefile = Get-ChildItem -Path $FilePath
                }
                if (-not $Title) {
                    Write-PSFMessage -Level Verbose -Message "Trying to get Title from $($updatefile.FullName)"
                    $Title = $updatefile.VersionInfo.ProductName
                }
            } elseif ($remotefile) {
                $FilePath = $remotefile
            }


            if ("$FilePath".EndsWith("msi")) {
                Write-PSFMessage -Level Verbose -Message "It's an msi"
                if ($ComputerName.IsLocalhost) {
                    try {
                        $msi = New-Object -ComObject WindowsInstaller.Installer
                        $info = $msi.SummaryInformation($FilePath)
                        $title = $info.Property(2)
                        $guid = "$guid".TrimStart("{").TrimEnd("}")
                    } catch {
                        # don't care
                    }
                } else {
                    $installerinfo = Invoke-KbCommand -ScriptBlock {
                            $FilePath = $args[0]
                            $msi = New-Object -ComObject WindowsInstaller.Installer
                            $info = $msi.SummaryInformation($FilePath)
                            [pscustombject]@{
                                Title = $info.Property(2)
                            }
                      } -ArgumentList $FilePath -ErrorAction Ignore
                      $title = $installerinfo.Title
                }
                Write-PSFMessage -Level Verbose -Message "FilePath $FilePath"
                Write-PSFMessage -Level Verbose -Message "Guid $guid"
                Write-PSFMessage -Level Verbose -Message "Title $title"
            }

            if ("$FilePath".EndsWith("exe") -or $PSBoundParameters.ArgumentList) {
                if ($PSBoundParameters.ArgumentList) {
                    Write-PSFMessage -Level Verbose -Message "ArgumentList is $ArgumentList"
                }
                if ("$FilePath".EndsWith("exe")) {
                    Write-PSFMessage -Level Verbose -Message "It's an exe"
                }

                if (-not $ArgumentList -and $FilePath -match "sql") {
                    $ArgumentList = "/action=patch /AllInstances /quiet /IAcceptSQLServerLicenseTerms"
                } elseif (-not $ArgumentList) {
                    # Setting a default argumentlist that hopefully works for most things?
                    $ArgumentList = "/install /quiet /notrestart"
                }

                if (-not $Guid) {
                    if ($object) {
                        if ($object.UpdateId) {
                            $Guid = $object.UpdateId
                        } else {
                            $Guid = $object.Guid
                        }
                        if (-not $Title) {
                            $Title = $object.Title
                        }
                    } else {
                        try {
                            $hotfixid = $guid = $null
                            Write-PSFMessage -Level Verbose -Message "Trying to get Title from $($updatefile.FullName)"
                            $updatefile = Get-ChildItem -Path $updatefile.FullName -ErrorAction SilentlyContinue
                            if (-not $Title) {
                                $Title = $updatefile.VersionInfo.ProductName
                            }
                            Write-PSFMessage -Level Verbose -Message "Trying to get GUID from $($updatefile.FullName)"

                            <#
                            The reason you want to find the GUID is to save time, mostly, I guess?

                            It saves time because it won't even attempt the install if there are GUID matches
                            in the registry. If you pass a fake but compliant GUID, it attempts the install and
                            fails, no big deal.

                            Overall, it just seems like a good idea to get a GUID if it's required.
                            #>

                            <#
                            It's better to just read from memory but I can't get this to work
                            $cab = New-Object Microsoft.Deployment.Compression.Cab.Cabinfo "C:\path\path.exe"
                            $file = New-Object Microsoft.Deployment.Compression.Cab.CabFileInfo($cab, "0")
                            $content = $file.OpenRead()
                            #>

                            $cab = New-Object Microsoft.Deployment.Compression.Cab.Cabinfo $updatefile.FullName
                            $files = $cab.GetFiles("*")
                            $index = $files | Where-Object Name -eq 0
                            if (-not $index) {
                                $index = $files | Where-Object Name -match "none.xml| ParameterInfo.xml"
                            }
                            $temp = Get-PSFPath -Name Temp
                            $indexfilename = $index.Name
                            $xmlfile = Join-Path -Path $temp -ChildPath "$($updatefile.BaseName).xml"
                            $null = $cab.UnpackFile($indexfilename, $xmlfile)
                            if ((Test-Path -Path $xmlfile)) {
                                $xml = [xml](Get-Content -Path $xmlfile)
                                $tempguid = $xml.BurnManifest.Registration.Id
                            }

                            if (-not $tempguid -and $xml.MsiPatch.PatchGUID) {
                                $tempguid = $xml.MsiPatch.PatchGUID
                            }
                            if (-not $tempguid -and $xml.Setup.Items.Patches.MSP.PatchCode) {
                                $tempguid = $xml.Setup.Items.Patches.MSP.PatchCode
                            }

                            Get-ChildItem -Path $xmlfile -ErrorAction SilentlyContinue | Remove-Item -Confirm:$false -ErrorAction SilentlyContinue

                            # if we can't find the guid, use one that we know
                            # is valid but not associated with any hotfix
                            if (-not $tempguid) {
                                $tempguid = "DAADB00F-DAAD-B00F-B00F-DAADB00FB00F"
                            }

                            $guid = ([guid]$tempguid).Guid
                        } catch {
                            $guid = "DAADB00F-DAAD-B00F-B00F-DAADB00FB00F"
                        }

                        Write-PSFMessage -Level Verbose -Message "GUID is $guid"
                        Write-PSFMessage -Level Verbose -Message "Title is $title"

                    }
                }

                # this takes care of things like SQL Server updates
                $hotfix = @{
                    Name       = "xPackage"
                    ModuleName = @{
                        ModuleName    = "xPSDesiredStateConfiguration"
                        ModuleVersion = "9.2.0"
                    }
                    Property   = @{
                        Ensure     = "Present"
                        ProductId  = $Guid
                        Name       = $Title
                        Path       = $FilePath
                        Arguments  = $ArgumentList
                        ReturnCode = 0, 3010
                    }
                }

                $scriptblock = @"
                    Configuration DscWithoutWinRm {
                            Import-DscResource -ModuleName PSDesiredStateConfiguration
                            Import-DscResource -ModuleName xPSDesiredStateConfiguration -ModuleVersion 9.2.0
                            node localhost {
                                xPackage "xPackage" {
                                    Ensure     = "Present"
                                    ProductId  = "$guid"
                                    Name       = "$title"
                                    Path       = "$FilePath"
                                    Arguments  = "$ArgumentList"
                                    ReturnCode = 0, 3010
                                }
                            }
                        }
                        DscWithoutWinRm
"@
                $dsc = [scriptblock]::Create($scriptblock)


            } elseif ("$FilePath".EndsWith("cab")) {
                Write-PSFMessage -Level Verbose -Message "It's a cab file"
                Write-PSFMessage -Level Verbose -Message "ArgumentList is $ArgumentList"
                $basename = Split-Path -Path $FilePath -Leaf
                $logfile = Join-Path -Path $env:windir -ChildPath ($basename + ".log")

                $hotfix = @{
                    Name       = "xWindowsPackageCab"
                    ModuleName = @{
                        ModuleName    = "xPSDesiredStateConfiguration"
                        ModuleVersion = "9.2.0"
                    }
                    Property   = @{
                        Ensure     = "Present"
                        Name       = $basename
                        SourcePath = $FilePath # adding a directory will add other msus in the dir
                        LogPath    = $logfile
                    }
                }

                $scriptblock = @"
                    Configuration DscWithoutWinRm {
                        Import-DscResource -ModuleName PSDesiredStateConfiguration
                        Import-DscResource -ModuleName xPSDesiredStateConfiguration -ModuleVersion 9.2.0
                        node localhost {
                            xWindowsPackageCab xWindowsPackageCab {
                                Ensure     = "Present"
                                Name       = "$basename"
                                SourcePath = "$FilePath" # adding a directory will add other msus in the dir
                                LogPath    = "$logfile"
                            }
                        }
                    }
                    DscWithoutWinRm
"@

                $dsc = [scriptblock]::Create($scriptblock)
            } else {
                Write-PSFMessage -Level Verbose -Message "It's a WSU file"
                Write-PSFMessage -Level Verbose -Message "ArgumentList is $ArgumentList"

                # this takes care of WSU files
                $hotfix = @{
                    Name       = "xHotFix"
                    ModuleName = @{
                        ModuleName    = "xWindowsUpdate"
                        ModuleVersion = "3.0.0"
                    }
                    Property   = @{
                        Ensure = "Present"
                        Id     = $HotfixId
                        Path   = $FilePath
                    }
                }

                if ($PSDscRunAsCredential) {
                    $hotfix.Property.PSDscRunAsCredential = $PSDscRunAsCredential

                    $scriptblock = @"
                        Configuration DscWithoutWinRm {
                            Import-DscResource -ModuleName PSDesiredStateConfiguration
                            Import-DscResource -ModuleName xWindowsUpdate -ModuleVersion 3.0.0

                            node localhost {
                                xHotFix xHotFix {
                                    Ensure               = "Present"
                                    Id                   = "$HotfixId"
                                    Path                 = "$FilePath"
                                    PSDscRunAsCredential = $PSDscRunAsCredential
                                }
                            }
                        }
                        DscWithoutWinRm
"@

                    $dsc = [scriptblock]::Create($scriptblock)
                } else {
                     $scriptblock = @"
                            Configuration DscWithoutWinRm {
                            Import-DscResource -ModuleName PSDesiredStateConfiguration
                            Import-DscResource -ModuleName xWindowsUpdate -ModuleVersion 3.0.0

                            node localhost {
                                xHotFix xHotFix {
                                    Ensure               = "Present"
                                    Id                   = "$HotfixId"
                                    Path                 = "$FilePath"
                                }
                            }
                        }
                        DscWithoutWinRm
"@

                    $dsc = [scriptblock]::Create($scriptblock)
                }
            }
            try {
                $parms = @{
                    ArgumentList    = $hotfix, $VerbosePreference, $FileName
                    EnableException = $true
                    WarningAction   = "SilentlyContinue"
                    WarningVariable = "dscwarnings"
                }
                $null = Invoke-KbCommand @parms -ScriptBlock {
                    param (
                        $Hotfix,
                        $VerbosePreference,
                        $ManualFileName
                    )

                    if ($PSVersionTable.PSVersion.Major -gt 5) {
                        Import-Module -UseWindowsPowerShell PSDesiredStateConfiguration -MaximumVersion 1.1 *>$null
                    } else {
                        Import-Module PSDesiredStateConfiguration 4>$null
                    }
                    Import-Module xPSDesiredStateConfiguration -RequiredVersion 9.2.0 4>$null
                    Import-Module xWindowsUpdate -RequiredVersion 3.0.0 4>$null
                    $PSDefaultParameterValues.Remove("Invoke-WebRequest:ErrorAction")
                    $PSDefaultParameterValues['*:ErrorAction'] = 'SilentlyContinue'
                    $PSDefaultParameterValues['Invoke-DscResource:WarningAction'] = 'SilentlyContinue'
                    $ErrorActionPreference = "Stop"
                    $oldpref = $ProgressPreference
                    $ProgressPreference = "SilentlyContinue"
                    if (-not (Get-Command Invoke-DscResource)) {
                        throw "Invoke-DscResource not found on $env:ComputerName"
                    }
                    $null = Import-Module xWindowsUpdate -Force 4>$null

                    $hotfixpath = $hotfix.property.path
                    if (-not $hotfixpath) {
                        $hotfixpath = $hotfix.property.sourcepath
                    }
                    $hotfixnameid = $hotfix.property.name
                    if (-not $hotfixnameid) {
                        $hotfixnameid = $hotfix.property.id
                    }

                    Write-Verbose -Message "Installing $hotfixpath"
                    # https://martin77s.wordpress.com/2017/03/01/using-dsc-with-the-winrm-service-disabled/
                    if (-not (Test-WSMan -ErrorAction Ignore)) {
                        Write-Verbose -Message "Invoke-DscResource is not available on this system because remoting isn't enabled. Using Invoke-CimMethod."
                        $workaround = $true
                        Push-Location -Path $env:temp
                        $null = Invoke-Command -ScriptBlock $dsc
                        $mofpath = Resolve-Path -Path ".\DscWithoutWinRm\localhost.mof"
                        $configData = [byte[]][System.IO.File]::ReadAllBytes($mofpath)
                        Pop-Location
                    } else {
                         Write-Verbose -Message "DSC appears to be available on this system. Using Invoke-DscResource."
                        $workaround = $false
                    }

                    try {
                        $ProgressPreference = "SilentlyContinue"

                        if ($workaround) {
                            $parms = @{
                                Namespace    = "root/Microsoft/Windows/DesiredStateConfiguration"
                                ClassName    = "MSFT_DSCLocalConfigurationManager"
                                Method       = "TestConfiguration"
                                Arguments    = @{
                                    ConfigurationData = $configData
                                    Force             = $true
                                }
                            }
                            $testresource = Invoke-CimMethod @parms 4>$null
                        } else {
                            $testresource = Invoke-DscResource @hotfix -Method Test 4>$null
                        }

                        if (-not $testresource) {
                            if ($workaround) {
                                $parms = @{
                                    Namespace    = "root/Microsoft/Windows/DesiredStateConfiguration"
                                    ClassName    = "MSFT_DSCLocalConfigurationManager"
                                    Method       = "SendConfigurationApply"
                                    Arguments    = @{
                                        ConfigurationData = $configData
                                        Force             = $true
                                    }
                                }
                                $msgs = Invoke-CimMethod @parms 4>&1
                            } else {
                                $msgs = Invoke-DscResource @hotfix -Method Set -ErrorAction Stop 4>&1
                            }
                        }

                        if ($msgs) {
                            foreach ($msg in $msgs) {
                                # too many extra spaces, baw
                                while ("$msg" -match "  ") {
                                    $msg = "$msg" -replace "  ", " "
                                }
                                $msg | Write-Verbose
                            }
                        }

                        $ProgressPreference = $oldpref
                    } catch {
                        $message = "$_".TrimStart().TrimEnd().Trim()

                        # Unsure how to figure out params, try another way
                        if ($message -match "The return code 1 was not expected.") {
                            try {
                                if (-not $workaround) {
                                    Write-Verbose -Message "Retrying install with /quit parameter"
                                    $hotfix.Property.Arguments = "/quiet"
                                    $msgs = Invoke-DscResource @hotfix -Method Set -ErrorAction Stop 4>&1
                                }

                                if ($msgs) {
                                    foreach ($msg in $msgs) {
                                        # too many extra spaces, baw
                                        while ("$msg" -match "  ") {
                                            $msg = "$msg" -replace "  ", " "
                                        }
                                        $msg | Write-Verbose
                                    }
                                }
                            } catch {
                                $message = "$_".TrimStart().TrimEnd().Trim()
                            }
                        }

                        switch ($message) {
                            # some things can be ignored
                            { $message -match "Serialized XML is nested too deeply" -or $message -match "Name does not match package details" } {
                                $null = 1
                            }
                            { $message -match "2359302" } {
                                throw "Error 2359302: update is already installed on $env:ComputerName"
                            }
                            { $message -match "could not be started" } {
                                throw "The install coult not initiate. The $($hotfix.Property.Path) on $env:ComputerName may be corrupt or only partially downloaded. Delete it and try again."
                            }
                            { $message -match "2042429437" } {
                                throw "Error -2042429437. Configuration is likely not correct. The requested features may not be installed or features are already at a higher patch level."
                            }
                            { $message -match "2068709375" } {
                                throw "Error -2068709375. The exit code suggests that something is corrupt. See if this tutorial helps: http://www.sqlcoffee.com/Tips0026.htm"
                            }
                            { $message -match "2067919934" } {
                                throw "Error -2067919934 You likely need to reboot $env:ComputerName."
                            }
                            { $message -match "2147942402" } {
                                throw "System can't find the file specified for some reason."
                            }
                            { $message -match "2149842967" } {
                                throw "Error 2149842967 - Update is probably not applicable or already installed. $message"
                            }
                            default {
                                throw $message
                            }
                        }
                    }
                }

                if ($dscwarnings) {
                    foreach ($warning in $dscwarnings) {
                        # too many extra spaces, baw
                        while ("$warning" -match "  ") {
                            $warning = "$warning" -replace "  ", " "
                        }
                        Write-PSFMessage -Level Warning -Message $warning
                    }
                }

                if ($deleteremotefile) {
                    Write-PSFMessage -Level Verbose -Message "Deleting $deleteremotefile"
                    $null = Invoke-KbCommand -ComputerName $ComputerName -ArgumentList $deleteremotefile -ScriptBlock {
                        Get-ChildItem -ErrorAction SilentlyContinue $args | Remove-Item -Force -ErrorAction SilentlyContinue -Confirm:$false
                    }
                }

                Write-PSFMessage -Level Verbose -Message "Finished installing, checking status"
                if ($hotfix.property.id) {
                    $exists = Get-KbInstalledSoftware -ComputerName $ComputerName -Pattern $hotfix.property.id -IncludeHidden
                }

                if ($exists.Summary -match "restart") {
                    # The summary is just too long
                    $status = "Install successful. This update requires a restart."
                } else {
                    $status = "Install successful"
                }

                if ($HotfixId) {
                    $id = $HotfixId
                } else {
                    $id = $guid
                }
                if ($id -eq "DAADB00F-DAAD-B00F-B00F-DAADB00FB00F") {
                    $id = $null
                }

                if ($object.Title) {
                    $filetitle = $object.Title
                } elseif ($exists.Title) {
                    $filetitle = $exists.Title
                } else {
                    $filetitle = $updatefile.VersionInfo.ProductName
                }

                if (-not $filetitle) {
                    $filetitle = $Title
                }

                if ($message) {
                    $status = "sucks"
                }
                [pscustomobject]@{
                    ComputerName = $hostname
                    Title        = $filetitle
                    ID           = $id
                    Status       = $status
                    FileName     = $updatefile.Name
                }
            } catch {
                if ("$PSItem" -match "Serialized XML is nested too deeply") {
                    Write-PSFMessage -Level Verbose -Message "Serialized XML is nested too deeply. Forcing output."

                    if ($hotfix.property.id) {
                        $exists = Get-KbInstalledSoftware -ComputerName $ComputerName -Pattern $hotfix.property.id -IncludeHidden
                    }

                    if ($exists.Summary -match "restart") {
                        $status = "This update requires a restart"
                    } else {
                        $status = "Install successful"
                    }
                    if ($HotfixId) {
                        $id = $HotfixId
                    } else {
                        $id = $guid
                    }

                    if ($id -eq "DAADB00F-DAAD-B00F-B00F-DAADB00FB00F") {
                        $id = $null
                    }

                    if ($object.Title) {
                        $filetitle = $object.Title
                    } elseif ($exists.Title) {
                        $filetitle = $exists.Title
                    } else {
                        $filetitle = $updatefile.VersionInfo.ProductName
                    }

                    if (-not $filetitle) {
                        $filetitle = $Title
                    }

                    [pscustomobject]@{
                        ComputerName = $hostname
                        Title        = $filetitle
                        ID           = $id
                        Status       = $Status
                        FileName     = $updatefile.Name
                    }
                } elseif ("$PSItem" -match "find message text") {
                    Write-PSFMessage -Level Verbose -Message "The system cannot find message text for message number 0x%1 in the message file for %2. Checking to see if it was actually installed."

                    if ($hotfix.property.id) {
                        $exists = Get-KbInstalledSoftware -ComputerName $ComputerName -Pattern $hotfix.property.id -IncludeHidden
                    }

                    if (-not $exists) {
                        Stop-PSFFunction -Message "Failure on $hostname" -ErrorRecord $PSitem -Continue -EnableException:$EnableException
                    } else {
                        $status = "This update requires a restart"
                    }

                    if ($HotfixId) {
                        $id = $HotfixId
                    } else {
                        $id = $guid
                    }

                    if ($id -eq "DAADB00F-DAAD-B00F-B00F-DAADB00FB00F") {
                        $id = $null
                    }

                    if ($object.Title) {
                        $filetitle = $object.Title
                    } else {
                        $filetitle = $updatefile.VersionInfo.ProductName
                    }

                    if (-not $filetitle) {
                        $filetitle = $Title
                    }

                    [pscustomobject]@{
                        ComputerName = $hostname
                        Title        = $filetitle
                        ID           = $id
                        Status       = $Status
                        FileName     = $updatefile.Name
                    }
                } else {
                    Pop-Location
                    Stop-PSFFunction -Message "Failure on $hostname" -ErrorRecord $PSitem -Continue -EnableException:$EnableException
                }
            }
        }
        if ($warnatbottom) {
            Write-PSFMessage -Level Output -Message "Downloaded files may still exist on your local drive and other servers as well, in the Downloads directory."
            Write-PSFMessage -Level Output -Message "If you ran this as SYSTEM, the downloads will be in windows\system32\config\systemprofile."
        }
    }
}