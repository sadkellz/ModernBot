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

# Copy lua scripts
Copy-Item "$src\main.lua" -Destination "$dst\main.lua" -Force
Write-Host "Deployed main.lua to $dst"

# # Copy plugin DLL
# if (Test-Path $pluginSrc) {
#     Copy-Item $pluginSrc -Destination "$pluginDst\input_plugin.dll" -Force
#     Write-Host "Deployed input_plugin.dll to $pluginDst"
# } else {
#     Write-Host "WARNING: input_plugin.dll not found at $pluginSrc - build it first"
# }
