param(
    [Parameter(Mandatory = $true)][string]$WorkDirectory,
    [Parameter(Mandatory = $true)][string]$DistributionDirectory,
    [Parameter(Mandatory = $true)][string]$PayloadDirectory,
    [Parameter(Mandatory = $true)][string]$DisplayVersion,
    [Parameter(Mandatory = $true)][string]$ProductVersion,
    [Parameter(Mandatory = $true)][string]$IconFile,
    [Parameter(Mandatory = $true)][string]$AppUserModelId
)

$ErrorActionPreference = "Stop"
$wix = Join-Path $WorkDirectory "wix3141"
$archive = Join-Path $WorkDirectory "wix314-binaries.zip"
$uri = "https://github.com/wixtoolset/wix3/releases/download/wix3141rtm/wix314-binaries.zip"
$expectedHash = "6AC824E1642D6F7277D0ED7EA09411A508F6116BA6FAE0AA5F2C7DAA2FF43D31"
if (-not (Test-Path -LiteralPath $archive)) {
    Invoke-WebRequest -Uri $uri -UseBasicParsing -OutFile $archive
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expectedHash) {
    throw "The WiX binary archive failed its SHA-256 check. Remove $archive and rebuild."
}
$candle = Join-Path $wix "candle.exe"
if (-not (Test-Path -LiteralPath $candle)) {
    Expand-Archive -LiteralPath $archive -DestinationPath $wix -Force
}
$light = Join-Path $wix "light.exe"
$ui = Join-Path $wix "WixUIExtension.dll"
$installerSource = Join-Path $PSScriptRoot "GaoJiXu.wxs"
$object = Join-Path $WorkDirectory "GaoJiXu.wixobj"
$fileName = "GaoJiXu-Windows-$DisplayVersion-x64.msi"
$output = Join-Path $DistributionDirectory $fileName
$identifier = [Text.Encoding]::ASCII.GetBytes("com.gaojixu.savings/windows-x64/$ProductVersion")
$identityHasher = [Security.Cryptography.MD5]::Create()
try {
    $productCode = [Guid]::new($identityHasher.ComputeHash($identifier))
} finally {
    $identityHasher.Dispose()
}

& $candle -nologo -arch x64 -out $object "-dPayloadDir=$PayloadDirectory" "-dIconFile=$IconFile" `
    "-dAppUserModelId=$AppUserModelId" "-dDisplayVersion=$DisplayVersion" "-dProductVersion=$ProductVersion" "-dProductCode=$productCode" $installerSource
if ($LASTEXITCODE -ne 0) { throw "WiX candle failed with exit code $LASTEXITCODE" }

& $light -nologo -cultures:zh-cn -ext $ui -spdb -out $output $object
if ($LASTEXITCODE -ne 0) { throw "WiX light failed with exit code $LASTEXITCODE" }

$sha = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
"$sha  $fileName" | Set-Content -LiteralPath "$output.sha256" -Encoding ASCII
Write-Output "$output"
Write-Output "$output.sha256"
