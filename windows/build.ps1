param(
    [string]$Python = "python",
    [string]$DistributionDirectory = (Join-Path $PSScriptRoot "dist"),
    [switch]$SkipInstaller
)

$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $true
}
Set-Location $PSScriptRoot

function Assert-LastExit($step) {
    if ($LASTEXITCODE -ne 0) {
        throw "$step failed with exit code $LASTEXITCODE"
    }
}

$buildDir = Join-Path $PSScriptRoot "build"
$dependencies = Join-Path $buildDir "release-deps"
$src = Join-Path $PSScriptRoot "src"
$assets = Join-Path $src "gaojixu\assets"
$macAssets = Join-Path (Split-Path $PSScriptRoot -Parent) "Resources"
$dist = [IO.Path]::GetFullPath($DistributionDirectory)
$payloads = if ($SkipInstaller) { $dist } else { Join-Path $buildDir "release-payload" }
New-Item -ItemType Directory -Path $buildDir, $dist, $payloads -Force | Out-Null

& $Python -c "import platform, struct, sys; sys.exit(0 if sys.platform == 'win32' and struct.calcsize('P') == 8 and platform.machine().upper() in ('AMD64', 'X86_64') else 'Build requires x64 CPython on Windows')"
Assert-LastExit "Python architecture"

$oldPythonPath = $env:PYTHONPATH
$oldPytestPlugins = $env:PYTEST_DISABLE_PLUGIN_AUTOLOAD
$oldPyInstallerCache = $env:PYINSTALLER_CONFIG_DIR
$oldBytecode = $env:PYTHONDONTWRITEBYTECODE
try {
    $env:PYTHONPATH = "$src;$dependencies"
    $env:PYTEST_DISABLE_PLUGIN_AUTOLOAD = "1"
    $env:PYINSTALLER_CONFIG_DIR = Join-Path $buildDir "pyinstaller-cache"
    $env:PYTHONDONTWRITEBYTECODE = "1"
    if (-not (Test-Path -LiteralPath (Join-Path $dependencies "PyInstaller")) -or
        -not (Test-Path -LiteralPath (Join-Path $dependencies "tzdata")) -or
        -not (Test-Path -LiteralPath (Join-Path $dependencies "PIL"))) {
        & $Python -m pip install --disable-pip-version-check --no-cache-dir --target $dependencies -r requirements-dev.txt
        Assert-LastExit "pip install"
    }
    & $Python -S -m pytest -q -p no:cacheprovider --basetemp (Join-Path $buildDir "pytest-release")
    Assert-LastExit "pytest"

    $json = & $Python -c "import json; from gaojixu import version as v; print(json.dumps({key: getattr(v, key) for key in ('APP_NAME', 'MARKETING_VERSION', 'VERSION_LABEL', 'WINDOWS_BUILD')}))"
    Assert-LastExit "read Windows release version"
    $version = $json | ConvertFrom-Json
    $segments = $version.MARKETING_VERSION.Split(".")
    if ($segments.Count -ne 2 -or $version.WINDOWS_BUILD -notmatch '^\d+$') {
        throw "Expected a two-part product version and a numeric Windows build number"
    }
    $major = [int]$segments[0]
    $minor = [int]$segments[1]
    $build = [int]$version.WINDOWS_BUILD
    $productVersion = "$($version.MARKETING_VERSION).$build"

    if (-not (Test-Path -LiteralPath (Join-Path $assets "index.html"))) {
        throw "UI assets were not found at $assets"
    }
    $icon = Join-Path $buildDir "GaoJiXu.ico"
    & $Python -S -c "from PIL import Image; import sys; Image.open(sys.argv[1]).save(sys.argv[2], sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])" (Join-Path $macAssets "GaoJiXuIcon.png") $icon
    Assert-LastExit "convert application icon"

    foreach ($executable in @("GaoJiXu-cli", "GaoJiXu")) {
        $work = Join-Path $buildDir $executable
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $metadata = Join-Path $work "version.txt"
        $versionInfo = @"
VSVersionInfo(
  ffi=FixedFileInfo(filevers=($major, $minor, $build, 0), prodvers=($major, $minor, $build, 0), mask=0x3f, flags=0, OS=0x40004, fileType=1, subtype=0, date=(0, 0)),
  kids=[StringFileInfo([StringTable('080404b0', [
    StringStruct('FileDescription', '$($version.APP_NAME)'),
    StringStruct('FileVersion', '$($version.VERSION_LABEL)'),
    StringStruct('OriginalFilename', '$executable.exe'),
    StringStruct('ProductName', '$($version.APP_NAME)'),
    StringStruct('ProductVersion', '$($version.MARKETING_VERSION)'),
  ])]), VarFileInfo([VarStruct('Translation', [2052, 1200])])]
)
"@
        [IO.File]::WriteAllText($metadata, $versionInfo, [Text.UTF8Encoding]::new($false))
        $mode = if ($executable.EndsWith("-cli")) { "--console" } else { "--windowed" }
        & $Python -S -m PyInstaller --noconfirm --clean --name $executable $mode --onefile --paths $src `
            --add-data "$assets;gaojixu_assets" --add-data "$macAssets;gaojixu_mac_assets" --hidden-import tzdata `
            --icon $icon --version-file $metadata --distpath $payloads --workpath $work --specpath $work launch.py
        Assert-LastExit "PyInstaller $executable"
    }

    if (-not $SkipInstaller) {
        & (Join-Path $PSScriptRoot "installer\build-msi.ps1") -WorkDirectory $buildDir -DistributionDirectory $dist -PayloadDirectory $payloads `
            -DisplayVersion $version.MARKETING_VERSION -ProductVersion $productVersion -IconFile $icon
    }
} finally {
    $env:PYTHONPATH = $oldPythonPath
    $env:PYTEST_DISABLE_PLUGIN_AUTOLOAD = $oldPytestPlugins
    $env:PYINSTALLER_CONFIG_DIR = $oldPyInstallerCache
    $env:PYTHONDONTWRITEBYTECODE = $oldBytecode
}
