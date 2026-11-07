# RemoteDesktopHost.exe (GUI 版) と RDHost.exe (コマンドライン版) をビルドし、
# 実行に必要な Swift ランタイム DLL と一緒に dist\RDHost へまとめる。
# 使い方 (Swift for Windows をインストールした PowerShell で):
#   powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1
$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)

swift build -c release --product RDHost
if ($LASTEXITCODE -ne 0) { throw "swift build に失敗しました" }
swift build -c release --product RemoteDesktopHost
if ($LASTEXITCODE -ne 0) { throw "swift build (GUI 版) に失敗しました" }

$binDir = (swift build -c release --show-bin-path).Trim()
$dist = "dist\RDHost"
if (Test-Path $dist) { Remove-Item -Recurse -Force $dist }
New-Item -ItemType Directory -Force $dist | Out-Null
Copy-Item "$binDir\RDHost.exe" $dist
Copy-Item "$binDir\RemoteDesktopHost.exe" $dist
Copy-Item "Sources\RDHostApp\AppIcon.ico" $dist

# Swift ランタイム (swiftCore.dll などがあるフォルダ) の DLL を同梱
$core = (Get-Command swiftCore.dll -ErrorAction SilentlyContinue).Source
if (-not $core) {
    $core = Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Runtimes" -Recurse -Filter swiftCore.dll |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $core) { throw "swiftCore.dll が見つかりません" }
$runtimeDir = Split-Path -Parent $core
Write-Host "Swift runtime: $runtimeDir"
Copy-Item "$runtimeDir\*.dll" $dist

# Visual C++ ランタイム (未インストールの PC 向け)
foreach ($dll in "vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll") {
    $p = Join-Path $env:SystemRoot "System32\$dll"
    if (Test-Path $p) { Copy-Item $p $dist }
}

Compress-Archive -Path "$dist\*" -DestinationPath "dist\RDHost-windows-x64.zip" -Force

# 配布物のハッシュ (ダウンロードしたものと照合できるように)
$sums = Get-ChildItem "$dist\*" , "dist\RDHost-windows-x64.zip" -File |
    ForEach-Object { "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Name }
$sums | Set-Content -Encoding ascii "dist\SHA256SUMS.txt"
Get-Content "dist\SHA256SUMS.txt"
Write-Host "完成: $dist\RemoteDesktopHost.exe (GUI) / $dist\RDHost.exe / dist\RDHost-windows-x64.zip"
