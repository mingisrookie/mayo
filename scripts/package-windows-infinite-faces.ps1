# SPDX-License-Identifier: BSD-2-Clause
# Downstream Windows test-release helper. Does not create tags or publish releases.
# Run from a configured MSVC shell after building all Release targets.
[CmdletBinding()]
param(
    [ValidateSet('Test', 'Package')][string]$Phase = 'Package',
    [Parameter(Mandatory)][string]$BuildDirectory,
    [Parameter(Mandatory)][string]$QtRoot,
    [Parameter(Mandatory)][string]$OcctRoot,
    [Parameter(Mandatory)][string]$OcctDistribution,
    [string]$MesaRoot,
    [Parameter(Mandatory)][ValidatePattern('^v\d+\.\d+\.\d+-infinite-faces\.\d+$')][string]$ReleaseTag,
    [string]$OutputDirectory = 'release-output'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$IsWindows) { throw 'This helper requires Windows and PowerShell 7.' }
$source = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$build = (Resolve-Path $BuildDirectory).Path
$bin = Join-Path $build 'Release'
$QtRoot = (Resolve-Path $QtRoot).Path
$OcctRoot = (Resolve-Path $OcctRoot).Path
$OcctDistribution = (Resolve-Path $OcctDistribution).Path
New-Item $OutputDirectory -ItemType Directory -Force | Out-Null
$output = (Resolve-Path $OutputDirectory).Path
$evidence = Join-Path $output 'evidence'
New-Item $evidence -ItemType Directory -Force | Out-Null

function Invoke-Logged([string]$Executable, [string[]]$Arguments, [string]$Log) {
    & $Executable @Arguments 2>&1 | Tee-Object -FilePath $Log
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed with exit code $LASTEXITCODE (see $Log)." }
}

function Get-CmakeString([string]$Name) {
    $text = Get-Content (Join-Path $build 'OpenCascadeWin_env.cmake') -Raw
    $match = [regex]::Match($text, '(?m)^set\(' + [regex]::Escape($Name) + ' "([^"]+)"\)\s*$')
    if (!$match.Success) { throw "Cannot read $Name from OpenCascadeWin_env.cmake." }
    return $match.Groups[1].Value
}

$resources = (Resolve-Path (Get-CmakeString 'OpenCASCADE_RESOURCE_DIR')).Path
$resourceMap = [ordered]@{
    CSF_SHMessage = 'SHMessage'
    CSF_MDTVTexturesDirectory = 'Textures'
    CSF_ShadersDirectory = 'Shaders'
    CSF_XSMessage = 'XSMessage'
    CSF_TObjMessage = 'TObj'
    CSF_StandardDefaults = 'StdResource'
    CSF_PluginDefaults = 'StdResource'
    CSF_XCAFDefaults = 'StdResource'
    CSF_TObjDefaults = 'StdResource'
    CSF_StandardLiteDefaults = 'StdResource'
    CSF_IGESDefaults = 'XSTEPResource'
    CSF_STEPDefaults = 'XSTEPResource'
    CSF_XmlOcafResource = 'XmlOcafResource'
    CSF_MIGRATION_TYPES = 'StdResource/MigrationSheet.txt'
}
foreach ($relative in $resourceMap.Values) {
    if (!(Test-Path (Join-Path $resources $relative))) { throw "OCCT resource is missing: $relative" }
}

$sampleDirectory = Join-Path $build 'tests/outputs/infinite-faces'
$kinds = @('cylinder', 'plane', 'cone')
$commit = (git -C $source rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve the build revision.' }

if ($Phase -eq 'Test') {
    if (!$MesaRoot) { throw '-MesaRoot is required for the CI graphics tests.' }
    $MesaRoot = (Resolve-Path $MesaRoot).Path
    if (!(Test-Path (Join-Path $MesaRoot 'opengl32.dll'))) { throw 'Mesa opengl32.dll is missing.' }
    $discoveryText = & ctest --test-dir $build -C Release --show-only=json-v1
    if ($LASTEXITCODE -ne 0) { throw 'CTest discovery failed.' }
    $discoveryText | Set-Content (Join-Path $evidence 'ctest-discovery.json') -Encoding utf8
    $discovery = ($discoveryText -join "`n") | ConvertFrom-Json
    $expected = @('test-app', 'test-base', 'test-graphics', 'test-infinite-face-step-roundtrip', 'test-io', 'test-measure')
    $actual = @($discovery.tests | ForEach-Object name | Sort-Object)
    if (@(Compare-Object $expected $actual).Count -ne 0) { throw 'Expected exactly the six Mayo CTest targets.' }

    # Mesa is only an overlay for tests. Restore any pre-existing DLLs afterwards;
    # deleting all same-named files could accidentally remove a real OCCT dependency.
    $backup = Join-Path $output 'mesa-overlay-backup'
    New-Item $backup -ItemType Directory -Force | Out-Null
    $overlaid = @()
    $savedEnvironment = @{}
    $environment = @{ PATH = "$MesaRoot;$bin;$env:PATH"; QT_PLUGIN_PATH = (Join-Path $bin 'plugins') }
    foreach ($key in $resourceMap.Keys) { $environment[$key] = Join-Path $resources $resourceMap[$key] }
    try {
        foreach ($key in $environment.Keys) {
            $savedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
            [Environment]::SetEnvironmentVariable($key, $environment[$key], 'Process')
        }
        foreach ($file in Get-ChildItem $MesaRoot -File) {
            $destination = Join-Path $bin $file.Name
            $existed = Test-Path $destination
            if ($existed) { Copy-Item $destination (Join-Path $backup $file.Name) }
            $overlaid += [pscustomobject]@{ Name = $file.Name; Existed = $existed }
            Copy-Item $file.FullName $destination -Force
        }
        $overlaid | ConvertTo-Json | Set-Content (Join-Path $evidence 'ci-only-mesa-files.json') -Encoding utf8
        Invoke-Logged ctest @('--test-dir', $build, '-C', 'Release', '--output-on-failure', '--timeout', '180',
            '--output-junit', (Join-Path $evidence 'ctest.xml')) (Join-Path $evidence 'ctest.log')

        foreach ($kind in $kinds) {
            $sample = Join-Path $sampleDirectory "box-with-unbounded-$kind.step"
            if (!(Test-Path $sample)) { throw "CTest did not generate $sample." }
            $captureDirectory = Join-Path $evidence "screenshots/$kind"
            New-Item $captureDirectory -ItemType Directory -Force | Out-Null
            Invoke-Logged (Join-Path $bin 'mayo-inspect-infinite-faces.exe') @($sample, $captureDirectory, 'all') `
                (Join-Path $evidence "inspect-$kind.log")
            $stats = Get-Content (Join-Path $captureDirectory 'stats.json') -Raw | ConvertFrom-Json
            if (!$stats.geometry_unchanged -or $stats.occt_version -ne '7.9.3') {
                throw "Geometry preservation or OCCT version check failed: $kind"
            }
            if (@($stats.presentations).Count -ne 5) { throw "Missing presentation captures: $kind" }
            foreach ($presentation in $stats.presentations) {
                $box = $presentation.total_graphics_box
                if ($box.void -or $box.open -or !$box.finite_dimensions -or !$presentation.fit_applied `
                    -or !$presentation.fixed_image_written -or !$presentation.fit_image_written) {
                    throw "Invalid viewport evidence: $kind/$($presentation.name)"
                }
                $expectedDimensions = @(80.0, 60.0, 40.0)
                for ($axis = 0; $axis -lt 3; ++$axis) {
                    if ([Math]::Abs($box.dimensions[$axis] - $expectedDimensions[$axis]) -gt 0.001) {
                        throw "Unexpected graphics bounds: $kind/$($presentation.name)"
                    }
                }
            }
        }
        @{
            commit = $commit; tag = $ReleaseTag; occt = '7.9.3'; qt = '5.15.2'; ctest_passed = 6
            inspected_samples = $kinds; presentation_states_per_sample = 5
            full_brep_bytes_unchanged = $true; graphics_dimensions = @(80, 60, 40)
            graphics_test_driver = 'Mesa 26.1.7 (CI only, excluded from portable package)'
        } | ConvertTo-Json | Set-Content (Join-Path $evidence 'regression-passed.json') -Encoding utf8
    }
    finally {
        foreach ($entry in $overlaid) {
            $destination = Join-Path $bin $entry.Name
            if ($entry.Existed) { Copy-Item (Join-Path $backup $entry.Name) $destination -Force }
            else { Remove-Item $destination -Force -ErrorAction SilentlyContinue }
        }
        foreach ($key in $savedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($key, $savedEnvironment[$key], 'Process')
        }
        Get-ChildItem $build -Filter 'test-*-results.txt' -File | Copy-Item -Destination $evidence
        $lastTest = Join-Path $build 'Testing/Temporary/LastTest.log'
        if (Test-Path $lastTest) { Copy-Item $lastTest $evidence }
        Remove-Item $backup -Recurse -Force
    }
    return
}

$regressionPath = Join-Path $evidence 'regression-passed.json'
if (!(Test-Path $regressionPath)) { throw 'Run the Test phase successfully before packaging.' }
$regression = Get-Content $regressionPath -Raw | ConvertFrom-Json
if ($regression.commit -ne $commit -or $regression.tag -ne $ReleaseTag -or $regression.ctest_passed -ne 6) {
    throw 'Regression evidence does not match this source revision and release tag.'
}

$packageName = "mayo-$ReleaseTag-windows-x64-portable"
$stage = Join-Path $output $packageName
if (Test-Path $stage) { throw "Stage already exists; use a fresh output directory: $stage" }
New-Item $stage -ItemType Directory | Out-Null
foreach ($name in @('mayo.exe', 'mayo-conv.exe')) { Copy-Item (Join-Path $bin $name) $stage }
Get-ChildItem $bin -Filter '*.dll' -File | Where-Object Name -NotLike 'Qt5Test*' | Copy-Item -Destination $stage
if (Test-Path (Join-Path $stage 'opengl32.dll')) { throw 'The portable package must not contain the CI Mesa OpenGL driver.' }

# Qt's deployment tool also follows plugin dependencies; do not rely solely on
# target DLL copying. The end-user package uses the installed graphics driver.
Invoke-Logged (Join-Path $QtRoot 'bin/windeployqt.exe') @('--release', '--no-opengl-sw', '--no-translations',
    '--no-compiler-runtime', '--dir', $stage, (Join-Path $stage 'mayo.exe'), (Join-Path $stage 'mayo-conv.exe')) `
    (Join-Path $evidence 'windeployqt.log')
foreach ($plugin in @('platforms/qwindows.dll', 'iconengines/qsvgicon.dll', 'imageformats/qsvg.dll')) {
    if (!(Test-Path (Join-Path $stage $plugin))) { throw "Qt deployment omitted $plugin." }
}
"[Paths]`nPrefix=.`nPlugins=.`n" | Set-Content (Join-Path $stage 'qt.conf') -Encoding ascii

$crtDirectories = @(Get-ChildItem (Join-Path $env:VCToolsRedistDir 'x64') -Directory -Filter 'Microsoft.VC*.CRT')
if ($crtDirectories.Count -ne 1) { throw 'Cannot identify the x64 MSVC redistributable CRT directory.' }
Get-ChildItem $crtDirectories[0].FullName -Filter '*.dll' -File | Copy-Item -Destination $stage -Force

$stageResources = Join-Path $stage 'resources'
New-Item $stageResources -ItemType Directory | Out-Null
# Only runtime resources, not the hundreds of source directories in OCCT's src/.
$resourceFolders = @($resourceMap.Values | ForEach-Object { ($_ -split '/')[0] } | Sort-Object -Unique)
foreach ($folder in $resourceFolders) { Copy-Item (Join-Path $resources $folder) $stageResources -Recurse }
$config = @('CSF_LANGUAGE=us', 'CSF_EXCEPTION_PROMPT=1')
foreach ($key in $resourceMap.Keys) { $config += "$key=resources/$($resourceMap[$key])" }
$config | Set-Content (Join-Path $stage 'opencascade.conf') -Encoding ascii
@'
@echo off
cd /d "%~dp0"
start "" "%~dp0mayo.exe" %*
'@ | Set-Content (Join-Path $stage 'Start-Mayo.cmd') -Encoding ascii

$samples = Join-Path $stage 'samples'
New-Item $samples -ItemType Directory | Out-Null
foreach ($kind in $kinds) {
    Copy-Item (Join-Path $sampleDirectory "box-with-unbounded-$kind.step") $samples
    Copy-Item (Join-Path $sampleDirectory "box-with-bounded-$kind.step") $samples
    Copy-Item (Join-Path $sampleDirectory "box-with-unbounded-$kind.brep") $samples
}

$licenses = Join-Path $stage 'licenses'
New-Item $licenses -ItemType Directory | Out-Null
Copy-Item (Join-Path $source 'LICENSE.txt') $stage
Copy-Item (Join-Path $source 'doc/3rdparty_licenses.md') $licenses
function Copy-LicenseFiles([string]$Root, [string]$Destination) {
    foreach ($file in Get-ChildItem $Root -File -Recurse | Where-Object { $_.Name -match '^(LICENSE|LICENCE|COPYING|COPYRIGHT|NOTICE|OCCT_LGPL_EXCEPTION)([._-]|$)' }) {
        $relative = [IO.Path]::GetRelativePath($Root, $file.FullName)
        $target = Join-Path $Destination $relative
        New-Item (Split-Path $target) -ItemType Directory -Force | Out-Null
        Copy-Item $file.FullName $target
    }
}
Copy-LicenseFiles $OcctDistribution (Join-Path $licenses 'occt-distribution')
Copy-LicenseFiles $QtRoot (Join-Path $licenses 'qt-distribution')
# aqt binary archives can omit the top-level Qt license files. Include the exact
# Qt 5.15.2 license texts explicitly, alongside the notices embedded by windeployqt.
$qtLicenses = Join-Path $licenses 'qt-5.15.2'
New-Item $qtLicenses -ItemType Directory | Out-Null
foreach ($name in @('LICENSE.LGPL3', 'LICENSE.GPL3', 'LICENSE.FDL')) {
    Invoke-WebRequest "https://raw.githubusercontent.com/qt/qtbase/v5.15.2/$name" -OutFile (Join-Path $qtLicenses $name)
}
@"
Mayo source and build scripts: https://github.com/$env:GITHUB_REPOSITORY/tree/$commit
Mayo is distributed under BSD-2-Clause. See ../LICENSE.txt.
Qt 5.15.2: https://download.qt.io/archive/qt/5.15/5.15.2/single/
Open CASCADE 7.9.3: https://github.com/Open-Cascade-SAS/OCCT/tree/V7_9_3
OCCT binary distribution: $env:OCCT_URL
OCCT distribution SHA256: $env:OCCT_SHA256
MSVC runtime DLLs: Microsoft Visual C++ Redistributable, distributed with Visual Studio 2022.
Qt and OCCT are dynamically linked. Interface-compatible replacement DLLs may be used.
Bundled third-party copyright and license notices are preserved in this directory.
Mesa is used only by CI tests and is not part of the portable application.
Optional Assimp support is not included in this testing build.
"@ | Set-Content (Join-Path $licenses 'SOURCES.txt') -Encoding utf8

@"
Mayo $ReleaseTag — Windows x64 STEP 无限面修复试用版

构建：Mayo 0.11.0 / Qt 5.15.2 / OCCT 7.9.3 / MSVC Release
源码提交：$commit

1. 完整解压 ZIP 到可写目录，运行 Start-Mayo.cmd。不要只从压缩包打开 exe。
2. 先打开 samples/box-with-unbounded-cylinder.step：应看到 80×60×40 的方块，
   不应有贯穿视口的长线。平面、圆锥 STEP 复现也应如此。
   bounded 文件是保留正常边界的对照样例；它们的附加有限面应仍然显示。
3. 打开您原来的工业装配 STEP，检查着色、带边线着色、线框及往返模式切换。
   执行“适合窗口”，确认模型大小和位置正常；切换零件显隐和颜色后再次检查。
4. 在装配树和视口中选择零件、面和边，检查高亮与拾取。请同时保留原版进行对照。
5. 导出 BREP/STEP 并重新打开，检查装配、颜色和有限几何。显示修复不删除原始面；
   导出仍采用 OCCT 原有行为，STEP writer 本身可能跳过无边界面。
6. 反馈时请注明显卡/驱动、失败的显示模式、截图和错误提示。
   不需要上传保密的工业原件；samples 中的最小复现可公开分享。

修复范围：仅抑制没有拓扑线框、没有三角网格、参数域无限的面的显示和选择。
这也会影响有意创建的此类无限参考曲面；需要显示时应为它们提供有限边界或网格。
正常有边界的面、有限自然参数域曲面、网格和普通线框对象均保留。

verification 目录包含此次 Windows 的全部 6 个 CTest 结果、三种复现的五种
显示状态/样式刷新截图、包围盒和显示前后 BREP 字节一致性记录。
CI 图形验证使用 Mesa；本便携包不含 Mesa opengl32.dll，使用机器的显卡驱动。
package-smoke-passed.json 记录独立打包目录中的 CLI 系统信息与三种 STEP→BREP 检查；
真实 Windows GUI 和原始工业模型仍请按上述步骤实际验证。

包内含 mayo-conv.exe 命令行转换器。此试用包未启用可选 Assimp 插件。
全部文件校验见 SHA256SUMS.txt；第三方许可和源码来源见 licenses 目录。
"@ | Set-Content (Join-Path $stage 'TESTING-zh-CN.txt') -Encoding utf8

@{
    tag = $ReleaseTag; commit = $commit; qt = '5.15.2'; occt = '7.9.3'
    occt_distribution_sha256 = $env:OCCT_SHA256; build_configuration = 'Release'; architecture = 'x64'
    workflow_run = "https://github.com/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
    assimp = $false; mesa_bundled = $false
} | ConvertTo-Json | Set-Content (Join-Path $stage 'BUILD-INFO.json') -Encoding utf8

# Validate the actual package with no Qt/OCCT development directories on PATH,
# and no inherited CSF/CASROOT/plugin paths to conceal missing resources or DLLs.
$savedEnvironment = @{}
$keys = @('PATH', 'CASROOT', 'QT_PLUGIN_PATH', 'QT_QPA_PLATFORM_PLUGIN_PATH', 'QTDIR', 'QT_ROOT_DIR')
$keys += @(Get-ChildItem Env: | Where-Object Name -Like 'CSF_*' | ForEach-Object Name)
foreach ($key in ($keys | Sort-Object -Unique)) {
    $savedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
    [Environment]::SetEnvironmentVariable($key, $null, 'Process')
}
$env:PATH = "$stage;$env:SystemRoot/System32;$env:SystemRoot"
$smoke = Join-Path $evidence 'package-smoke'
New-Item $smoke -ItemType Directory | Out-Null
Push-Location $stage
try {
    Invoke-Logged (Join-Path $stage 'mayo-conv.exe') @('--system-info') (Join-Path $smoke 'system-info.txt')
    foreach ($kind in $kinds) {
        $brep = Join-Path $smoke "box-with-unbounded-$kind.brep"
        Invoke-Logged (Join-Path $stage 'mayo-conv.exe') @((Join-Path $samples "box-with-unbounded-$kind.step"),
            '--export', $brep, '--no-progress') (Join-Path $smoke "convert-$kind.log")
        if (!(Test-Path $brep) -or (Get-Item $brep).Length -eq 0) { throw "Packaged conversion failed: $kind" }
    }
    @{
        commit = $commit; tag = $ReleaseTag; isolated_runtime = $true; step_to_brep_samples = $kinds
        mesa_bundled = $false; gui_rendering_verified_by = 'CTest and the CI inspector with Mesa'
    } | ConvertTo-Json | Set-Content (Join-Path $evidence 'package-smoke-passed.json') -Encoding utf8
}
finally {
    Pop-Location
    foreach ($key in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($key, $savedEnvironment[$key], 'Process')
    }
}

if (Get-ChildItem $stage -File -Recurse | Where-Object Name -In @('opengl32.dll', 'opengl32sw.dll')) {
    throw 'A software OpenGL driver leaked into the portable package.'
}
Copy-Item $evidence (Join-Path $stage 'verification') -Recurse
$checksums = @(Get-ChildItem $stage -File -Recurse | Sort-Object FullName | ForEach-Object {
    $relative = [IO.Path]::GetRelativePath($stage, $_.FullName).Replace('\', '/')
    "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $relative
})
$checksums | Set-Content (Join-Path $stage 'SHA256SUMS.txt') -Encoding utf8
$assets = Join-Path $output 'assets'
New-Item $assets -ItemType Directory | Out-Null
Compress-Archive -Path $stage -DestinationPath (Join-Path $assets "$packageName.zip") -CompressionLevel Optimal
Compress-Archive -Path $evidence -DestinationPath (Join-Path $assets "mayo-$ReleaseTag-windows-verification.zip") -CompressionLevel Optimal
Get-ChildItem $assets -File -Filter '*.zip' | Sort-Object Name | ForEach-Object {
    "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name
} | Set-Content (Join-Path $assets 'SHA256SUMS.txt') -Encoding utf8
Write-Host "Verified portable package and evidence are ready in $assets"
