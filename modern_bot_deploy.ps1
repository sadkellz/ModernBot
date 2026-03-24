$src = "$PSScriptRoot\modern_bot"
$dst = "Q:\SteamLibrary\steamapps\common\Street Fighter 6\reframework\autorun"
$pluginDst = "Q:\SteamLibrary\steamapps\common\Street Fighter 6\reframework\plugins"
$pluginSrc = "$src\native\build\Release\input_plugin.dll"

if (-not (Test-Path $dst)) {
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
}
if (-not (Test-Path $pluginDst)) {
    New-Item -ItemType Directory -Path $pluginDst -Force | Out-Null
}

# Copy entire modern_bot folder contents to autorun
Copy-Item "$src\*" -Destination $dst -Recurse -Force
Write-Host "Deployed modern_bot to $dst"
