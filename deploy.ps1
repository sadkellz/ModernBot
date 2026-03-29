# Copies ModernBot into Street Fighter 6's REFramework autorun folder.

# game path
$gamePath = "Q:\SteamLibrary\steamapps\common\Street Fighter 6"

$src = "$PSScriptRoot\modern_bot"
$dst = "$gamePath\reframework\autorun"

# Create autorun folder if it doesn't exist
if (-not (Test-Path $dst)) {
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
}

# Copy folder
Copy-Item "$src\*" -Destination $dst -Recurse -Force
Write-Host "Deployed modern_bot to $dst"
