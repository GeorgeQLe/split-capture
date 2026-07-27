[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string] $Target = 'x64',
    [ValidateSet('Debug', 'RelWithDebInfo', 'Release', 'MinSizeRel')]
    [string] $Configuration = 'RelWithDebInfo',
    [switch] $DualCaptureQualification,
    [switch] $DualCaptureTestHooks
)

$ErrorActionPreference = 'Stop'

if ( $DebugPreference -eq 'Continue' ) {
    $VerbosePreference = 'Continue'
    $InformationPreference = 'Continue'
}

if ( $env:CI -eq $null ) {
    throw "Build-Windows.ps1 requires CI environment"
}

if ( ! ( [System.Environment]::Is64BitOperatingSystem ) ) {
    throw "obs-studio requires a 64-bit system to build and run."
}

if ( $PSVersionTable.PSVersion -lt '7.2.0' ) {
    Write-Warning 'The obs-studio PowerShell build script requires PowerShell Core 7. Install or upgrade your PowerShell version: https://aka.ms/pscore6'
    exit 2
}

function Build {
    trap {
        Pop-Location -Stack BuildTemp -ErrorAction 'SilentlyContinue'
        Write-Error $_
        Log-Group
        exit 2
    }

    $ScriptHome = $PSScriptRoot
    $ProjectRoot = Resolve-Path -Path "$PSScriptRoot/../.."

    $UtilityFunctions = Get-ChildItem -Path $PSScriptRoot/utils.pwsh/*.ps1 -Recurse

    foreach($Utility in $UtilityFunctions) {
        Write-Debug "Loading $($Utility.FullName)"
        . $Utility.FullName
    }

    Install-BuildDependencies -WingetFile "${ScriptHome}/.Wingetfile"

    Push-Location -Stack BuildTemp
    Ensure-Location $ProjectRoot

    $CmakeArgs = @('--preset', "windows-ci-${Target}")

    $CmakeBuildArgs = @('--build')
    $CmakeInstallArgs = @()

    if ( $DebugPreference -eq 'Continue' ) {
        $CmakeArgs += ('--debug-output')
        $CmakeBuildArgs += ('--verbose')
        $CmakeInstallArgs += ('--verbose')
    }

    if ( $DualCaptureQualification ) {
        if ( $Target -ne 'x64' ) {
            throw 'Dual Capture qualification is supported only for Windows x64.'
        }

        if ( $Configuration -ne 'Debug' ) {
            throw 'Dual Capture qualification requires the Debug configuration.'
        }

        $CmakeArgs += @(
            '-DCMAKE_COMPILE_WARNING_AS_ERROR=ON'
            '-DENABLE_TESTS=ON'
            '-DENABLE_DUAL_CAPTURE_TESTS=ON'
            '-DENABLE_DUAL_CAPTURE_TEST_HOOKS=ON'
        )
    } elseif ( $DualCaptureTestHooks ) {
        if ( $Configuration -ne 'Debug' ) {
            throw 'Dual Capture test hooks are available only in Debug builds.'
        }

        $CmakeArgs += '-DENABLE_DUAL_CAPTURE_TEST_HOOKS=ON'
    }

    $CmakeBuildArgs += @(
        '--preset', "windows-${Target}"
        '--config', $Configuration
        '--parallel'
        '--', '/consoleLoggerParameters:Summary', '/noLogo'
    )

    $CmakeInstallArgs += @(
        '--install', "build_${Target}"
        '--prefix', "${ProjectRoot}/build_${Target}/install"
        '--config', $Configuration
    )

    Log-Group "Configuring obs-studio..."
    Invoke-External cmake @CmakeArgs

    Log-Group "Building obs-studio..."
    if ( $DualCaptureQualification ) {
        $QualificationBuildArgs = $CmakeBuildArgs[0..($CmakeBuildArgs.IndexOf('--parallel') - 1)]
        $QualificationBuildArgs += @(
            '--target', 'obs-studio', 'dual-capture-logic-test'
            '--parallel'
            '--', '/consoleLoggerParameters:Summary', '/noLogo'
        )
        Invoke-External cmake @QualificationBuildArgs

        Log-Group "Running Dual Capture tests..."
        Invoke-External ctest --test-dir "build_${Target}" --build-config $Configuration --output-on-failure -R '^dual-capture-'
    } else {
        Invoke-External cmake @CmakeBuildArgs
    }

    if ( ! $DualCaptureQualification ) {
        Log-Group "Installing obs-studio..."
        Invoke-External cmake @CmakeInstallArgs
    }

    Pop-Location -Stack BuildTemp
    Log-Group
}

Build
