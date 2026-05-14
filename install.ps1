[CmdletBinding()]
param(
    # Optional release tag to install (e.g. "v0.15.0" or "zvm-v0.15.0").
    # When omitted, the latest release is installed. Falls back to $env:ZVM_VERSION
    # so users piping through `iex` can still pin a version via an env var.
    [string]$Version = $env:ZVM_VERSION
)

# Resolve version. Strip any "zvm-" prefix so both "v0.15.0" and "zvm-v0.15.0" work.
$useLatest = [string]::IsNullOrWhiteSpace($Version)
if (-not $useLatest) {
    $Version = $Version -replace '^zvm-', ''
}

$zvmRepoUrl = "https://github.com/hendriknielaender/zvm"
$zvmInstallDir = "$HOME\.zm"
$zvmBinDir = "$zvmInstallDir\bin"
$architecture = if ([Environment]::Is64BitOperatingSystem) { "x86_64" } else { "x86" }
$zvmFileName = "$architecture-windows-zvm.zip"
$zvmExeFileName = "$architecture-windows-zvm.exe"
$zvmZipPath = "$zvmInstallDir\$zvmFileName"
$zvmExePath = "$zvmInstallDir\$zvmExeFileName"
$zvmRenamedExePath = "$zvmBinDir\zvm.exe"
$zvmLegacyExePath = "$zvmInstallDir\zvm.exe"

if ($useLatest) {
    $zvmUrl = "$zvmRepoUrl/releases/latest/download/$zvmFileName"
    $versionLabel = "zvm"
} else {
    $zvmUrl = "$zvmRepoUrl/releases/download/$Version/$zvmFileName"
    $versionLabel = "zvm $Version"
    Write-Output "Installing $versionLabel (rollback/specific version)..."
}

# Create the installation directories if they don't exist
if (-not (Test-Path -Path $zvmInstallDir)) {
    Write-Output "Creating installation directory at $zvmInstallDir..."
    New-Item -Path $zvmInstallDir -ItemType Directory | Out-Null
}

if (-not (Test-Path -Path $zvmBinDir)) {
    Write-Output "Creating binary directory at $zvmBinDir..."
    New-Item -Path $zvmBinDir -ItemType Directory | Out-Null
}

# Download the requested release
Write-Output "Downloading $versionLabel from $zvmUrl..."
try {
    Invoke-WebRequest -Uri $zvmUrl -OutFile $zvmZipPath
    Write-Output "Download complete."
} catch {
    Write-Output "Error: Failed to download $versionLabel. Verify the version tag and your internet connection."
    exit 1
}

# Unzip the downloaded file
Write-Output "Extracting zvm..."
try {
    Expand-Archive -Path $zvmZipPath -DestinationPath $zvmInstallDir -Force
    Write-Output "Extraction complete."
} catch {
    Write-Output "Error: Failed to extract $zvmFileName. Please check the file and try again."
    Remove-Item -Path $zvmZipPath
    exit 1
}

# Remove the downloaded zip file
Remove-Item -Path $zvmZipPath

# Check if the existing zvm.exe exists and remove it
if (Test-Path -Path $zvmRenamedExePath) {
    Remove-Item -Path $zvmRenamedExePath -Force
    Write-Output "Removed existing zvm.exe."
}

# Move the new executable into bin
if (Test-Path -Path $zvmExePath) {
    Move-Item -Path $zvmExePath -Destination $zvmRenamedExePath
    Write-Output "Moved $zvmExeFileName to bin\zvm.exe"

    Copy-Item -Path $zvmRenamedExePath -Destination "$zvmBinDir\zig.exe" -Force
    Copy-Item -Path $zvmRenamedExePath -Destination "$zvmBinDir\zls.exe" -Force
    Write-Output "Created zig.exe and zls.exe shims."

    if (Test-Path -Path $zvmLegacyExePath) {
        try {
            Remove-Item -Path $zvmLegacyExePath -Force
            Write-Output "Removed legacy zvm.exe from $zvmInstallDir."
        } catch {
            Write-Output "Warning: Could not remove legacy $zvmLegacyExePath. Remove it manually if it appears before $zvmBinDir in PATH."
        }
    }

    try {
        # Set the user environment variable
        Write-Output "Setting ZVM_HOME environment variable..."
        [System.Environment]::SetEnvironmentVariable("ZVM_HOME", $zvmInstallDir, [System.EnvironmentVariableTarget]::User)
        Write-Output "ZVM_HOME has been set to $zvmInstallDir for the current user."

        # Add the zvm bin directory to the user PATH
        $currentPath = [System.Environment]::GetEnvironmentVariable("Path", [System.EnvironmentVariableTarget]::User)
        $pathEntries = if ([string]::IsNullOrEmpty($currentPath)) { @() } else { $currentPath -split ';' }
        $hasPath = $false
        foreach ($pathEntry in $pathEntries) {
            if ($pathEntry.TrimEnd('\') -ieq $zvmBinDir.TrimEnd('\')) {
                $hasPath = $true
                break
            }
        }

        if (-not $hasPath) {
            $newPath = if ([string]::IsNullOrEmpty($currentPath)) { $zvmBinDir } else { "$currentPath;$zvmBinDir" }
            [System.Environment]::SetEnvironmentVariable("Path", $newPath, [System.EnvironmentVariableTarget]::User)
            Write-Output "Added $zvmBinDir to PATH for the current user."
        } else {
            Write-Output "$zvmBinDir is already in the user PATH."
        }
    } catch {
        Write-Output "Error: Unable to set environment variable or update PATH. Please run the script as an administrator."
    }
} else {
    Write-Output "Error: zvm executable not found after extraction. Please check the downloaded files."
    exit 1
}

Write-Output "$versionLabel installation complete. Please restart your terminal or computer to apply changes."
