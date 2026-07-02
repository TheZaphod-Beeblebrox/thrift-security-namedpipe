<#
This script checks all pre-requisite installs are present, in PATH, and at the
minimum version. If everything is set correctly, it builds the .NET thrift
library for this repository.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# If these script variables are left blank, environment variables are used.
# If script variables are populated, they override environment variables.
$THRIFT_REPOSITORY_LOC = "D:\AnsysDevs\src\thrift-security-namedpipe"

function Resolve-PathSetting([string]$ScriptValue, [string]$EnvironmentValue, [string]$FallbackValue) {
	if (-not [string]::IsNullOrWhiteSpace($ScriptValue)) {
		return $ScriptValue
	}

	if (-not [string]::IsNullOrWhiteSpace($EnvironmentValue)) {
		return $EnvironmentValue
	}

	return $FallbackValue
}

$THRIFT_REPOSITORY_LOC = Resolve-PathSetting $THRIFT_REPOSITORY_LOC $env:THRIFT_REPOSITORY_LOC "D:\AnsysDevs\src\thrift-security-namedpipe"

$MIN_DOTNET_SDK = [Version]"10.0.0"
$MIN_CMAKE = [Version]"3.20.0"
$MIN_WIN_FLEX = [Version]"2.6.0"
$MIN_WIN_BISON = [Version]"3.7.0"

function Write-Pass([string]$Message) {
	Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Fail([string]$Message) {
	Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Quit-On-Fail([string]$Message) {
	Write-Fail $Message
	exit 1
}

function Invoke-External([string]$Description, [scriptblock]$Action) {
	& $Action
	if ($LASTEXITCODE -ne 0) {
		Quit-On-Fail "$Description failed with exit code $LASTEXITCODE."
	}
}

function Get-CommandPathOrNull([string]$Name) {
	$cmd = Get-Command $Name -ErrorAction SilentlyContinue
	if ($null -eq $cmd) {
		return $null
	}
	return $cmd.Source
}

function Parse-VersionOrNull([string]$Raw) {
	if ($Raw -match '(\d+\.\d+(?:\.\d+)?)') {
		return [Version]$Matches[1]
	}
	return $null
}

function Ensure-Versioned-Command(
	[string]$Name,
	[Version]$Minimum,
	[scriptblock]$VersionGetter
) {
	$path = Get-CommandPathOrNull $Name
	if ([string]::IsNullOrWhiteSpace($path)) {
		Quit-On-Fail "$Name is not in PATH."
	}

	$verText = & $VersionGetter
	if ([string]::IsNullOrWhiteSpace($verText)) {
		Quit-On-Fail "$Name is in PATH at '$path' but its version could not be determined."
	}

	$ver = Parse-VersionOrNull $verText
	if ($null -eq $ver) {
		Quit-On-Fail "$Name is in PATH at '$path' but its version string was not parseable: $verText"
	}

	if ($ver -lt $Minimum) {
		Quit-On-Fail "$Name version $ver is below required minimum $Minimum (PATH: $path)."
	}

	Write-Pass "$Name version $ver found in PATH ($path)."
}

function Run-Step([string]$Title, [scriptblock]$Action) {
	Write-Host "`n==> $Title" -ForegroundColor Cyan
	& $Action
}

if (-not (Test-Path $THRIFT_REPOSITORY_LOC -PathType Container)) {
	Quit-On-Fail "Repository folder not found: $THRIFT_REPOSITORY_LOC"
}

Write-Host "Checking prerequisites..." -ForegroundColor Cyan

Ensure-Versioned-Command "dotnet" $MIN_DOTNET_SDK { (& dotnet --version).Trim() }
Ensure-Versioned-Command "cmake" $MIN_CMAKE { ((& cmake --version | Select-Object -First 1)).Trim() }
Ensure-Versioned-Command "win_flex" $MIN_WIN_FLEX { ((& win_flex --version | Select-Object -First 1)).Trim() }
Ensure-Versioned-Command "win_bison" $MIN_WIN_BISON { ((& win_bison --version | Select-Object -First 1)).Trim() }

Write-Pass "All prerequisite checks passed."

$buildDir = Join-Path $THRIFT_REPOSITORY_LOC "out\build"
$netstdDir = Join-Path $THRIFT_REPOSITORY_LOC "lib\netstd"
$sln = Join-Path $netstdDir "Thrift.sln"
$compilerOutputDirCandidates = @(
	(Join-Path $buildDir "compiler\cpp\bin\Release"),
	(Join-Path $buildDir "compiler\cpp\Release\bin"),
	(Join-Path $buildDir "compiler\cpp\Release")
)

Run-Step "Configure CMake" {
	Invoke-External "CMake configure" {
		cmake -S $THRIFT_REPOSITORY_LOC -B $buildDir -G "Visual Studio 17 2022" -A x64 `
			-DBUILD_COMPILER=ON `
			-DBUILD_CPP=OFF `
			-DBUILD_C_GLIB=OFF `
			-DBUILD_TESTING=OFF
	}
}

Run-Step "Build thrift compiler" {
	Invoke-External "Compiler build" {
		cmake --build $buildDir --config Release --target thrift-compiler copy-thrift-compiler
	}
}

$thriftExe = $null
foreach ($candidateDir in $compilerOutputDirCandidates) {
	$candidateExe = Join-Path $candidateDir "thrift.exe"
	if (Test-Path $candidateExe -PathType Leaf) {
		$thriftExe = $candidateExe
		break
	}
}

if ($null -eq $thriftExe) {
	$thriftExe = Get-ChildItem -Path $buildDir -Filter "thrift.exe" -Recurse -File -ErrorAction SilentlyContinue |
		Select-Object -First 1 -ExpandProperty FullName
}

if (-not (Test-Path $thriftExe -PathType Leaf)) {
	Quit-On-Fail "Compiler build completed but thrift.exe was not found under: $buildDir"
}

$compilerOutputDir = Split-Path -Path $thriftExe -Parent
$env:PATH = "$compilerOutputDir;$env:PATH"
Write-Pass "thrift.exe is ready: $thriftExe"

if (-not (Test-Path $sln -PathType Leaf)) {
	Quit-On-Fail "Solution file not found: $sln"
}

Run-Step "Build .NET thrift (netstd)" {
	Invoke-External ".NET build" {
		dotnet build $sln
	}
}

Write-Pass "Done. .NET thrift build completed successfully."

