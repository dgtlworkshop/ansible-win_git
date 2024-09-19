#!powershell

# GNU General Public License v3.0+ (see COPYING or https://www.gnu.org/licenses/gpl-3.0.txt)

# Anatoliy Ivashina <tivrobo@gmail.com>
# Pablo Estigarribia <pablodav@gmail.com>
# Michael Hay <project.hay@gmail.com>

#Requires -Module Ansible.ModuleUtils.Legacy.psm1

$RawParameters = Parse-Args -arguments $args -supports_check_mode $true
$ModuleParameters = New-Object psobject @{
    check_mode     = Get-AnsibleParam -obj $RawParameters -name "_ansible_check_mode" -default $false
    repo           = Get-AnsibleParam -obj $RawParameters -name "repo" -failifempty $true -aliases "name"
    dest           = Get-AnsibleParam -obj $RawParameters -name "dest"
    branch         = Get-AnsibleParam -obj $RawParameters -name "branch" -default "master"
    clone          = ConvertTo-Bool (Get-AnsibleParam -obj $RawParameters -name "clone" -default $true)
    update         = ConvertTo-Bool (Get-AnsibleParam -obj $RawParameters -name "update" -default $false)
    resursive      = ConvertTo-Bool (Get-AnsibleParam -obj $RawParameters -name "recursive" -default $true)
    replace_dest   = ConvertTo-Bool (Get-AnsibleParam -obj $RawParameters -name "replace_dest" -default $false)
    accept_hostkey = ConvertTo-Bool (Get-AnsibleParam -obj $RawParameters -name "accept_hostkey" -default $false)
}

$ModuleResult = New-Object psobject @{
    changed     = $false
    msg         = $null
    git_actions = @{
        clone         = $false
        checkout      = $false
        pull          = $false
        remote_update = $false
    }
    status      = @{
        branch      = $null
        has_changes = $null
    }
}

# Add Git to PATH variable
# Test with git 2.14
$env:Path += ";" + "C:\Program Files\Git\bin"
$env:Path += ";" + "C:\Program Files\Git\usr\bin"
$env:Path += ";" + "C:\Program Files (x86)\Git\bin"
$env:Path += ";" + "C:\Program Files (x86)\Git\usr\bin"

# Functions
function Find-Command {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)] [string] $Command
    )

    $installed = get-command $Command -erroraction Ignore
    write-verbose "$installed"
    if ($installed) {
        return $installed
    }
    return $null
}

function Find-Git {
    [CmdletBinding()]
    param()

    $p = Find-Command "git.exe"
    if ($null -ne $p) {
        return $p
    }

    $a = Find-Command "C:\Program Files\Git\bin\git.exe"
    if ($null -ne $a) {
        return $a
    }

    Fail-Json $ModuleResult "Git is not installed. It must be installed (use chocolatey)."
}

# Remove dest if it exests
function PrepareDestination {
    [CmdletBinding()]
    param(
        [string] $Destination
    )
    if (-Not (Test-Path $Destination)) {
        return
    }
    try {
        Remove-Item $Destination -Force -Recurse
    }
    catch {
        $ErrorMessage = $_.Exception.Message
        Fail-Json $ModuleResult "Error removing destination. $ErrorMessage"
    }
    Set-Attr $ModuleResult "msg" "Successfully removed destination."
    Set-Attr $ModuleResult "changed" $true
}

# SSH Keys
function CheckSshKnownHosts {
    [CmdletBinding()]
    param(
        [string] $RepositoryUrl,
        [Parameter(Mandatory = $false)]
        [bool] $AcceptHostkey
    )
    
    # Get the Git Hostrepo
    $Domain = $($RepositoryUrl -replace "^(\w+)\@([\w-_\.]+)\:(.*)$", '$2')
    & cmd /c ssh-keygen.exe -F $Domain

    if ($LASTEXITCODE -ne 0) {
        # Host is unknown.
        if (-Not $AcceptHostkey) {
            Fail-Json -obj $ModuleResult "Unknown host."
        }
        # Workaround for disable BOM.
        # https://github.com/tivrobo/ansible-win_git/issues/7
        $SshHostKey = & cmd /c ssh-keyscan.exe -t ecdsa-sha2-nistp256 $Domain
        $SshHostKey += "`n"
        $SshKnownHostsPath = Join-Path -Path $env:Userprofile -ChildPath \.ssh\known_hosts
        [System.IO.File]::AppendAllText($SshKnownHostsPath, $SshHostKey, $(New-Object System.Text.UTF8Encoding $False))
    }
}

function CheckSshIdentity {
    [CmdletBinding()]
    param(
        [string] $RepositoryUrl
    )

    $GitOutput = & cmd /c git.exe ls-remote $RepositoryUrl
    $GitExitCode = $LASTEXITCODE

    if ($GitExitCode -ne 0) {
        $Message = @{
            "detail" = "Failed to read remotes. Check that repository exists and you have permission."
            "output" = @{
                "command"   = "git ls-remote $RepositoryUrl"
                "exit_code" = $GitExitCode
                "output"    = $GitOutput
            }
        }
        Fail-Json $ModuleResult $Message
    }
}

function Get-Version {
    # samples the version of the git repo
    # example:  git rev-parse HEAD
    #           output: 931ec5d25bff48052afae405d600964efd5fd3da
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string] $Refs = "HEAD",
        [string] $Destination
    )
    $GitOptions = "--no-pager", "rev-parse", "$Refs"
    Set-Location $Destination; &git $GitOptions | Out-Null
}

function Get-Branch {
    [CmdletBinding()]
    param(
        [string] $Location
    )
    Set-Location $Location
    $Options = "rev-parse", "--abbrev-ref", "HEAD"
    $Branch = &git $Options
    Set-Attr $ModuleResult.status "branch" "$Branch"
    return "$Branch"
}

function Test-Branch {
    [CmdletBinding()]
    param(
        [string] $Location,
        [string] $Branch,
        [switch] $Fail
    )
    $Status = Get-Branch $Location
    $SameBranch = $Status -eq $Branch
    if ($Fail -And -Not $SameBranch) {
        Fail-Json $ModuleResult "Current branch '$Status' is not target branch '$Branch'."
    }
    return $SameBranch
}

function Set-Branch {
    [CmdletBinding()]
    param(
        [string] $Location,
        [string] $Branch
    )
    
    Set-Location $Location
    
    $GitOptions = "--no-pager", "checkout", "$Branch"
    $GitOutput = &git $GitOptions
    $GitExitCode = $LASTEXITCODE
    Set-Attr $ModuleResult.git_actions "checkout" $true

    if ($GitExitCode -ne 0) {
        $Message = @{
            "detail" = "Git checkout failed."
            "output" = @{
                "command"   = "git $GitOptions"
                "exit_code" = $GitExitCode
                "output"    = $GitOutput
            }
        }
        Fail-Json $ModuleResult $Message
    }
    
    Test-Branch $Location $Branch -Fail
}

function Test-Changes {
    [CmdletBinding()]
    param(
        [string] $Location,
        [switch] $Fail
    )
    $AreEqual = $(&git rev-parse HEAD) -eq $(&git rev-parse "@{u}")
    Set-Attr $ModuleResult.status "has_changes" (-Not $AreEqual)
    if ($Fail -And -Not $AreEqual) {
        Fail-Json $ModuleResult "Head and upstream do not match."
    }
    return -Not $AreEqual
}

function Update-Remote {
    [CmdletBinding()]
    param(
        [string] $Location
    )
    Set-Location $Location
    $GitOptions = "--no-pager", "remote", "update"
    &git $GitOptions
    $ModuleResult.git_actions.remote_update = $true
}

function Test-NeedsUpdate {
    [CmdletBinding()]
    param(
        [string] $Location,
        [string] $Branch
    )
    # Always ensure remote is downloaded.
    Update-Remote $Location
    # Test if branch matches.
    $SameBranches = Test-Branch $Location $Branch
    if (-Not $SameBranches) {
        return $true
    }
    # Test if there are new changes.
    $HasChanges = Test-Changes $Location
    if ($HasChanges) {
        return $true
    }
    # No update is required.
    return $false
}

function GitClone {
    # git clone command
    [CmdletBinding()]
    param(
        [string] $RepositoryUrl,
        [string] $Destination,
        [string] $Branch,
        [Parameter(Mandatory = $false)]
        [bool] $CheckMode
    )

    if ((Test-Path $Destination) -Or $CheckMode) {
        Set-Attr $ModuleResult "msg" "Skipping clone because destination already exists."
        return
    }

    $GitOptions = "--no-pager", "clone", $RepositoryUrl, $Destination, "--branch", $Branch
    if ($recursive) {
        $GitOptions += "--recursive"
    }
    $GitOutput = &git $GitOptions
    $GitExitCode = $LASTEXITCODE
    Set-Attr $ModuleResult.git_actions "clone" $true
    
    if ( $GitExitCode -ne 0 ) {
        $Message = @{
            "detail" = "Git clone failed."
            "output" = @{
                "command"   = "git $GitOptions"
                "exit_code" = $GitExitCode
                "output"    = $GitOutput
            }
        }
        Fail-Json $ModuleResult $Message
    }

    # Check if current branch is the correct one.
    Test-Branch $Destination $Branch -Fail
}

function GitPull {
    # git clone command
    [CmdletBinding()]
    param(
        [string] $Location,
        [string] $Branch,
        [Parameter(Mandatory = $false)]
        [bool] $CheckMode
    )
    
    # Stop if location does not exist, or in check mode.
    if ($CheckMode -Or -Not (Test-Path -Path $Location)) {
        Set-Attr $ModuleResult "msg" "Skipped update; Destination does not exist (or check mode)."
        return
    }

    # Stop if already up-to-date.
    $NeedsUpdate = Test-NeedsUpdate $ModuleParameters.dest $ModuleParameters.branch
    if (-Not $NeedsUpdate) {
        Set-Attr $ModuleResult "msg" "Skipped update; No new changes."
        return
    }
    
    # Move into correct branch.
    Set-Branch $Location $Branch
    
    # Perform git pull.
    $GitOptions = "--no-pager", "pull", "origin", "$Branch"
    Set-Location $Location
    &git $GitOptions
    Set-Attr $ModuleResult.git_actions "pull" $true

    # TODO: handle correct status change when using update
    Set-Attr $ModuleResult "msg" "Successfully updated to branch '$branch'."
    Set-Attr $ModuleResult "changed" $true
}

if ($repo -eq ($null -or "")) {
    Fail-Json $ModuleResult "Repository cannot be empty or `$null"
}

try {

    Find-Git
    $env:GIT_REDIRECT_STDERR = "2>&1"

    if ($replace_dest) {
        PrepareDestination -Destination $ModuleParameters.dest -CheckMode $ModuleParameters.check_mode
    }
    if ([system.uri]::IsWellFormedUriString($repo, [System.UriKind]::Absolute)) {
        # http/https repositories doesn't need Ssh handle
        # fix to avoid wrong usage of CheckSshKnownHosts CheckSshIdentity for http/https
        Set-Attr $ModuleResult.win_git "valid_url" "$repo is valid url"
    }
    else {
        CheckSshKnownHosts $ModuleParameters.repo -AcceptHostkey $ModuleParameters.accept_hostkey
        CheckSshIdentity $ModuleParameters.repo
    }
    if ($ModuleParameters.clone) {
        # TODO: Find better way to pass parameters later.
        GitClone $ModuleParameters.repo $ModuleParameters.dest $ModuleParameters.branch -CheckMode $ModuleParameters.check_mode
    }
    if ($ModuleParameters.update -and -Not $ModuleResult.git_actions.clone) {
        GitPull $ModuleParameters.dest $ModuleParameters.branch -CheckMode $ModuleParameters.check_mode
    }
}
catch {
    $ErrorMessage = $_.Exception.Message
    $ErrorTrace = $_.ScriptStackTrace
    Fail-Json $ModuleResult "Caught exception during PowerShell script. [$ErrorTrace] $ErrorMessage"
}

Test-NeedsUpdate $ModuleParameters.dest $ModuleParameters.branch
Exit-Json $ModuleResult
