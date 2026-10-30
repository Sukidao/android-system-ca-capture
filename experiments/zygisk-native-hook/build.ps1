$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ndkRoot = "$env:LOCALAPPDATA\Android\Sdk\ndk"
$ndk = Get-ChildItem $ndkRoot -Directory | Sort-Object Name | Select-Object -Last 1
$clang = Join-Path $ndk.FullName "toolchains\llvm\prebuilt\windows-x86_64\bin\aarch64-linux-android21-clang++.cmd"
if (-not (Test-Path $clang)) {
    $clang = Join-Path $ndk.FullName "toolchains\llvm\prebuilt\windows-x86_64\bin\aarch64-linux-android21-clang++"
}
Write-Output "NDK: $($ndk.FullName)"
Write-Output "CC : $clang"

$outDir = Join-Path $root "zygisk"
New-Item -ItemType Directory -Force $outDir | Out-Null
$out = Join-Path $outDir "arm64-v8a.so"

& $clang `
    -shared -fPIC -O2 -std=c++17 -fno-exceptions -fno-rtti `
    -static-libstdc++ "-Wl,-soname,libpinskip.so" "-Wl,--build-id=none" `
    -I (Join-Path $root "jni") `
    (Join-Path $root "jni\module.cpp") `
    -o $out `
    -llog -landroid

if ($LASTEXITCODE -ne 0) { throw "compile failed" }
Write-Output ("built: {0} ({1} bytes)" -f $out, (Get-Item $out).Length)
