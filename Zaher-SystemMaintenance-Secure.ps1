#requires -Version 5.1
<#
.SYNOPSIS
    Zaher System Maintenance v3.1 — Complete Defensive Edition
.DESCRIPTION
    أداة دفاعية مفتوحة المصدر لصيانة Windows وتدقيق الأمان والخصوصية.
    لا تنفذ اختراقاً، ولا تكسر كلمات مرور، ولا تتصل بأي خادم خارجي.
    كل تغيير حساس يمر عبر: معاينة → YES → Backup → Restore Point → تنفيذ → Rollback.
.PARAMETER AuditOnly
    فحص فقط دون تغييرات.
.PARAMETER NoPause
    تعطيل انتظار Enter.
.PARAMETER Redact
    تنقيح البيانات الحساسة من التقارير.
.PARAMETER SkipRestorePointIfRecent
    تخطي حد 24 ساعة.
.PARAMETER DataRoot
    مجلد البيانات.
.PARAMETER Version
    عرض الإصدار.
.NOTES
    Author  : Zaher
    License : MIT
    Repo    : https://github.com/AcademyF6Team/zaher-system-maintenance
#>
[CmdletBinding()]
param(
    [switch]$AuditOnly,
    [switch]$NoPause,
    [switch]$Redact,
    [switch]$SkipRestorePointIfRecent,
    [string]$DataRoot,
    [switch]$Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Version   = '3.1.0-secure'
$script:StartedAt = Get-Date
$script:OwnsLock  = $false
$script:IsAdmin   = $false
$script:AuditLog  = $null

if ($Version) {
    Write-Host "Zaher System Maintenance v$script:Version"
    exit 0
}

# ============================================================
# 1) الصلاحيات ومسار البيانات
# ============================================================
function Test-Admin {
    $p = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$script:IsAdmin = Test-Admin

if ([string]::IsNullOrWhiteSpace($DataRoot)) {
    if ($script:IsAdmin) {
        $DataRoot = Join-Path $env:ProgramData 'ZaherSystemMaintenance'
    } else {
        $DataRoot = Join-Path $env:LOCALAPPDATA 'ZaherSystemMaintenance'
    }
}

$script:DataRoot     = $DataRoot
$script:LogPath      = Join-Path $DataRoot 'maintenance.log'
$script:AuditLog     = Join-Path $DataRoot 'audit.log'
$script:ReportRoot   = Join-Path $DataRoot 'Reports'
$script:BackupRoot   = Join-Path $DataRoot 'Backups'
$script:BaselineRoot = Join-Path $DataRoot 'Baselines'
$script:LockPath     = Join-Path $DataRoot 'running.lock'

# ============================================================
# 2) التهيئة
# ============================================================
function Initialize-App {
    try {
        New-Item -ItemType Directory -Path $script:DataRoot,$script:ReportRoot,$script:BackupRoot,$script:BaselineRoot -Force -ErrorAction Stop | Out-Null
        foreach ($f in @($script:LogPath, $script:AuditLog)) {
            if (-not (Test-Path $f)) { New-Item -ItemType File -Path $f -Force | Out-Null }
        }
        $lines = @(Get-Content $script:LogPath -ErrorAction SilentlyContinue)
        if ($lines.Count -gt 5000) {
            $lines | Select-Object -Last 2500 | Set-Content $script:LogPath -Encoding UTF8
        }
        if (Test-Path $script:LockPath) {
            $old = Get-Item $script:LockPath -ErrorAction SilentlyContinue
            if ($old -and ((Get-Date) - $old.LastWriteTime).TotalHours -lt 12) {
                throw "يبدو أن نسخة أخرى من الأداة تعمل حالياً (قفل أقل من 12 ساعة)."
            }
            Remove-Item $script:LockPath -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType File -Path $script:LockPath -Force | Out-Null
        $script:OwnsLock = $true
        Add-Content -Path $script:LockPath -Value "PID=$PID; User=$env:USERNAME; Started=$(Get-Date -Format s)" -Encoding UTF8
    }
    catch {
        throw "فشل تهيئة الأداة: $($_.Exception.Message)"
    }
}

# ============================================================
# 3) أدوات مساعدة
# ============================================================
function Sanitize-LogText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return ($Text -replace "[\r\n]+", ' ')
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS')][string]$Level = 'INFO'
    )
    $safe = Sanitize-LogText $Message
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $safe"
    try { Add-Content $script:LogPath $line -Encoding UTF8 } catch {}
    $c = @{INFO='Gray';WARN='Yellow';ERROR='Red';SUCCESS='Green'}[$Level]
    Write-Host $line -ForegroundColor $c
}

function Write-Audit {
    param([string]$Action, [string]$Details)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Action | User=$env:USERNAME | Computer=$env:COMPUTERNAME | $Details"
    try { Add-Content $script:AuditLog $line -Encoding UTF8 } catch {}
}

function Confirm-Action {
    param([string]$Text)
    Write-Host "`n$Text" -ForegroundColor Yellow
    $r = Read-Host 'اكتب YES للمتابعة أو أي شيء للإلغاء'
    return ($r -ceq 'YES')
}

function Invoke-Safe {
    param([string]$Name, [scriptblock]$Action)
    Write-Log "بدء: $Name"
    try {
        & $Action
        Write-Log "اكتملت: $Name" 'SUCCESS'
        return $true
    }
    catch {
        Write-Log "فشل '$Name': $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Get-Prop { param($Object, [string]$Name); try { $Object.$Name } catch { $null } }
function Get-ProcessPathSafe { param([int]$Id); try { (Get-Process -Id $Id -ErrorAction Stop).Path } catch { $null } }
function Write-Progress-Safe { param([string]$Activity, [int]$Percent); try { Write-Progress -Activity $Activity -PercentComplete $Percent } catch {} }
function Clear-Progress-Safe { try { Write-Progress -Activity 'Zaher' -Completed } catch {} }

# ============================================================
# 4) نقطة الاستعادة
# ============================================================
function Test-RecentRestorePoint {
    param([int]$WithinHours = 24)
    try {
        $rps = Get-ComputerRestorePoint -ErrorAction SilentlyContinue
        if (-not $rps) { return $false }
        $cut = (Get-Date).AddHours(-$WithinHours)
        foreach ($rp in $rps) {
            $t = $null
            try { $t = [Management.ManagementDateTimeConverter]::ToDateTime($rp.CreationTime) } catch {}
            if ($t -and $t -gt $cut) { return $true }
        }
    } catch {}
    return $false
}

function New-AutoRestorePoint {
    if (-not $script:IsAdmin) { Write-Log 'يلزم Administrator لنقطة الاستعادة.' 'WARN'; return $false }
    if (Test-RecentRestorePoint -WithinHours 24) {
        Write-Log 'توجد نقطة استعادة خلال 24 ساعة (حد Windows).' 'WARN'
        if ($SkipRestorePointIfRecent) { Write-Log 'تخطي إنشاء نقطة الاستعادة.' 'WARN'; return $true }
        return $false
    }
    try {
        Checkpoint-Computer -Description "Zaher_Auto_$(Get-Date -Format yyyyMMdd_HHmmss)" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Log 'تم إنشاء نقطة استعادة.' 'SUCCESS'
        return $true
    }
    catch {
        Write-Log "فشل إنشاء نقطة الاستعادة: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

# ============================================================
# 5) Backup + Rollback
# ============================================================
function Save-Before {
    param([string]$Dest, [string]$Name, [scriptblock]$Capture)
    try {
        $data = & $Capture
        if ($null -ne $data) {
            $data | Export-Clixml (Join-Path $Dest "$Name.clixml") -Depth 5
            Write-Log "حفظ الحالة الأصلية: $Name"
        } else {
            Set-Content -Path (Join-Path $Dest "$Name.absent") -Value 'Property/Feature was absent.' -Encoding UTF8
            Write-Log "الحالة الأصلية لـ $Name غير موجودة." 'WARN'
        }
    }
    catch { Write-Log "تعذر حفظ $Name : $($_.Exception.Message)" 'WARN' }
}

function Invoke-ProtectedChange {
    param(
        [string]$Name,
        [string]$Description,
        [scriptblock]$Action,
        [scriptblock]$CaptureBefore
    )
    if ($AuditOnly) { Write-Log "AuditOnly: معاينة '$Name' دون تغيير." 'WARN'; return $false }
    if (-not (Confirm-Action $Description)) { return $false }
    if (-not (New-AutoRestorePoint)) { Write-Log 'أُوقفت العملية: نقطة الاستعادة لم تُنشأ.' 'ERROR'; return $false }

    $stamp = Get-Date -Format yyyyMMdd_HHmmss
    $safe  = $Name -replace '[^a-zA-Z0-9_-]', '_'
    $dest  = Join-Path $script:BackupRoot "$stamp-$safe"
    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    if ($CaptureBefore) { Save-Before -Dest $dest -Name 'before' -Capture $CaptureBefore }

    @(
        "Name=$Name"
        "Applied=$(Get-Date -Format s)"
        "User=$env:USERNAME"
        "Computer=$env:COMPUTERNAME"
        "Version=$script:Version"
    ) | Set-Content -Path (Join-Path $dest 'meta.txt') -Encoding UTF8

    Write-Log "مجلد النسخ الاحتياطي: $dest"
    Write-Audit -Action $Name -Details "Applied; Backup=$dest"

    $ok = Invoke-Safe $Name $Action
    if ($ok) { Write-Host "[OK] تم '$Name'. للتراجع: [7] > [6] Rollback." -ForegroundColor Green }
    return $ok
}

function Get-BackupFolders {
    if (-not (Test-Path $script:BackupRoot)) { return @() }
    Get-ChildItem $script:BackupRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
}

function Show-RollbackMenu {
    $folders = @(Get-BackupFolders)
    if ($folders.Count -eq 0) { Write-Host 'لا توجد نسخ احتياطية للتراجع.' -ForegroundColor Yellow; return }
    for ($i = 0; $i -lt $folders.Count; $i++) {
        $f = $folders[$i]
        Write-Host ("[{0}] {1}   ({2})" -f ($i+1), $f.Name, $f.LastWriteTime)
    }
    Write-Host '[B] رجوع'
    $c = Read-Host 'اختر رقم النسخة للتراجع'
    if ($c.ToUpper() -eq 'B') { return }
    $idx = 0
    if (-not [int]::TryParse($c, [ref]$idx) -or $idx -lt 1 -or $idx -gt $folders.Count) {
        Write-Log 'اختيار غير صالح.' 'WARN'; return
    }
    Invoke-Rollback -BackupFolder $folders[$idx-1]
}

function Invoke-Rollback {
    param([IO.DirectoryInfo]$BackupFolder)
    $meta = Join-Path $BackupFolder.FullName 'meta.txt'
    if (-not (Test-Path $meta)) { Write-Log 'ملف meta غير موجود.' 'ERROR'; return }
    $kv = @{}
    Get-Content $meta | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$') { $kv[$matches[1]] = $matches[2] }
    }
    $name = $kv['Name']
    Write-Host "`nسيتم التراجع عن: $name" -ForegroundColor Yellow
    if (-not (Confirm-Action 'اكتب YES للتراجع.')) { return }
    if (-not (New-AutoRestorePoint)) { Write-Log 'التراجع متوقف: لا نقطة استعادة.' 'ERROR'; return }

    $beforeFile = Join-Path $BackupFolder.FullName 'before.clixml'
    $absentFile = Join-Path $BackupFolder.FullName 'before.absent'
    $before = $null
    if (Test-Path $beforeFile) {
        try { $before = Import-Clixml $beforeFile } catch { Write-Log "تعذر قراءة before.clixml: $($_.Exception.Message)" 'ERROR'; return }
    }

    switch ($name) {
        'EnableFirewall' {
            if (-not $before) { Write-Log 'لا توجد بيانات Firewall.' 'ERROR'; return }
            foreach ($p in $before) {
                try { Set-NetFirewallProfile -Name $p.Name -Enabled $p.Enabled } catch { Write-Log $_ 'WARN' }
            }
            Write-Log 'تم استرجاع Firewall.' 'SUCCESS'
        }
        'DisableSMB1' {
            if (-not $before) { return }
            if ($before.State -eq 'Enabled') {
                Enable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction Stop | Out-Null
                Write-Log 'تمت إعادة تفعيل SMB1.' 'SUCCESS'
            }
        }
        'DisableLLMNR' {
            if (Test-Path $absentFile) {
                Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Name EnableMulticast -ErrorAction SilentlyContinue
                Write-Log 'تم إزالة سياسة LLMNR.' 'SUCCESS'
            } elseif ($before) {
                New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Name EnableMulticast -PropertyType DWord -Value $before -Force | Out-Null
                Write-Log 'تم استرجاع LLMNR.' 'SUCCESS'
            }
        }
        'EnableSMBSigning' {
            if ($before) {
                try {
                    Set-SmbServerConfiguration -RequireSecuritySignature ([bool]$before.RequireSecuritySignature) `
                                               -EnableSecuritySignature  ([bool]$before.EnableSecuritySignature) -Force | Out-Null
                    Write-Log 'تم استرجاع SMB Signing.' 'SUCCESS'
                } catch { Write-Log $_ 'ERROR' }
            }
        }
        'AdvertisingID' {
            if ($before) {
                New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' -Name Enabled -PropertyType DWord -Value $before -Force | Out-Null
                Write-Log 'تم استرجاع Advertising ID.' 'SUCCESS'
            }
        }
        'LSASS-Protection' {
            if ($before) {
                New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name RunAsPPL -PropertyType DWord -Value $before -Force | Out-Null
                Write-Log 'تم استرجاع LSASS Protection.' 'SUCCESS'
            } else {
                Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name RunAsPPL -ErrorAction SilentlyContinue
                Write-Log 'تم إزالة LSASS Protection.' 'SUCCESS'
            }
        }
        'ProtectReports' { Write-Log 'تراجع ACL غير آلي.' 'WARN' }
        default { Write-Log "لا توجد دالة تراجع لـ '$name'." 'WARN' }
    }
    Write-Audit -Action "Rollback:$name" -Details "From $($BackupFolder.Name)"
}

# ============================================================
# 6) فحوصات النظام والشبكة
# ============================================================
function Get-SystemHealth {
    Write-Progress-Safe 'جمع معلومات النظام' 10
    $r = [ordered]@{ Generated = Get-Date; Computer = $env:COMPUTERNAME; Version = $script:Version }
    try { $r.OS      = Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,LastBootUpTime,FreePhysicalMemory,TotalVisibleMemorySize } catch { Write-Log $_ 'WARN' }
    try { $r.CPU     = Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,LoadPercentage } catch { Write-Log $_ 'WARN' }
    try { $r.Disks   = Get-PSDrive -PSProvider FileSystem | Select-Object Name,@{N='FreeGB';E={[math]::Round($_.Free/1GB,2)}},@{N='UsedGB';E={[math]::Round($_.Used/1GB,2)}} } catch { Write-Log $_ 'WARN' }
    try { $r.PhysicalDisks = Get-PhysicalDisk | Select-Object FriendlyName,MediaType,HealthStatus,OperationalStatus,Size } catch { Write-Log 'PhysicalDisk غير متاح.' 'WARN' }
    try { $r.Defender = Get-MpComputerStatus | Select-Object AntivirusEnabled,RealTimeProtectionEnabled,AntivirusSignatureLastUpdated,QuickScanAge,FullScanAge } catch { Write-Log 'Defender غير متاح.' 'WARN' }
    try { $r.Firewall = Get-NetFirewallProfile | Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction } catch { Write-Log 'Firewall غير متاح.' 'WARN' }
    try { $r.Updates  = Get-CimInstance Win32_QuickFixEngineering | Sort-Object InstalledOn -Descending | Select-Object -First 10 HotFixID,InstalledOn,Description } catch { Write-Log 'التحديثات غير متاحة.' 'WARN' }
    try { $r.Errors   = Get-WinEvent -FilterHashtable @{LogName='System';Level=1,2;StartTime=(Get-Date).AddDays(-7)} -MaxEvents 30 | Select-Object TimeCreated,ProviderName,Id,LevelDisplayName,Message } catch { Write-Log 'أحداث النظام غير متاحة.' 'WARN' }
    try { $r.SecureBoot = [pscustomobject]@{ Enabled = try { Confirm-SecureBootUEFI -ErrorAction Stop } catch { 'N/A' } } } catch { $r.SecureBoot = $null }
    try { $tpm = Get-Tpm -ErrorAction Stop; $r.TPM = [pscustomobject]@{ Present=$tpm.TpmPresent; Ready=$tpm.TpmReady; Enabled=$tpm.TpmEnabled } } catch { $r.TPM = $null }
    try { $r.BitLocker = Get-BitLockerVolume -ErrorAction Stop | Select-Object MountPoint,VolumeStatus,ProtectionStatus,EncryptionPercentage } catch { $r.BitLocker = $null }
    Clear-Progress-Safe
    return [pscustomobject]$r
}

function Show-Health {
    $r = Get-SystemHealth
    Write-Host "`n=== System Health ===" -ForegroundColor Cyan
    $r.OS | Format-List | Out-Host
    $r.CPU | Format-Table | Out-Host
    $r.Disks | Format-Table | Out-Host
    $r.PhysicalDisks | Format-Table | Out-Host
    $r.Defender | Format-List | Out-Host
    $r.Firewall | Format-Table | Out-Host
    Write-Host 'Secure Boot / TPM:' -ForegroundColor Cyan
    $r.SecureBoot | Format-List | Out-Host
    $r.TPM | Format-List | Out-Host
    if ($r.BitLocker) { Write-Host 'BitLocker:' -ForegroundColor Cyan; $r.BitLocker | Format-Table | Out-Host }
    Write-Host 'آخر التحديثات:'; $r.Updates | Format-Table | Out-Host
    Write-Host 'أخطاء النظام الحديثة:'; $r.Errors | Select-Object TimeCreated,ProviderName,Id,LevelDisplayName | Format-Table | Out-Host
}

function Get-NetworkAudit {
    $r = [ordered]@{ Generated = Get-Date }
    try { $r.Wifi = (netsh wlan show interfaces 2>&1 | Out-String).Trim() } catch {}
    try { $r.IP = Get-NetIPConfiguration } catch {}
    try { $r.DNS = Get-DnsClientServerAddress | Select-Object InterfaceAlias,ServerAddresses } catch {}
    try { $r.Proxy = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' | Select-Object ProxyEnable,ProxyServer,AutoConfigURL } catch {}
    try { $r.Firewall = Get-NetFirewallProfile | Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction } catch {}
    try {
        $r.Connections = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
            [pscustomobject]@{
                Local   = "$($_.LocalAddress):$($_.LocalPort)"
                Remote  = "$($_.RemoteAddress):$($_.RemotePort)"
                PID     = $_.OwningProcess
                Process = $p.ProcessName
                Path    = Get-ProcessPathSafe -Id $_.OwningProcess
            }
        }
    } catch {}
    try { $r.Shares = Get-SmbShare -ErrorAction SilentlyContinue | Select-Object Name,Path,Description,CurrentUsers } catch {}
    try {
        $r.OpenPorts = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
            [pscustomobject]@{ LocalAddress = $_.LocalAddress; LocalPort = $_.LocalPort; Process = $p.ProcessName; PID = $_.OwningProcess }
        }
    } catch {}
    return [pscustomobject]$r
}

function Show-Network {
    $r = Get-NetworkAudit
    Write-Host $r.Wifi
    Write-Host "`nDNS/Proxy/Firewall:"
    $r.DNS | Format-Table | Out-Host
    $r.Proxy | Format-List | Out-Host
    $r.Firewall | Format-Table | Out-Host
    Write-Host 'الاتصالات:'; $r.Connections | Format-Table -Wrap | Out-Host
    Write-Host 'SMB Shares:' -ForegroundColor Cyan; $r.Shares | Format-Table | Out-Host
    Write-Host 'المنافذ المفتوحة (أول 30):' -ForegroundColor Cyan; $r.OpenPorts | Select-Object -First 30 | Format-Table | Out-Host
}

function Show-WifiProfiles {
    Write-Host (netsh wlan show profiles | Out-String)
    Write-Log 'تم عرض أسماء الشبكات المحفوظة دون كلمات المرور.'
}

function Show-WifiPassword {
    $n = Read-Host 'اسم شبكة محفوظة على جهازك'
    if ([string]::IsNullOrWhiteSpace($n)) { return }
    if ($n -notmatch '^[\w\s\u0600-\u06FF\-\.\:]+$') { Write-Log 'اسم الشبكة يحتوي رموزاً غير مسموحة.' 'ERROR'; return }
    if (-not (Confirm-Action 'سيتم عرض كلمة المرور على الشاشة فقط. تأكد أنك تملك الشبكة.')) { return }
    $x = netsh wlan show profile name="$n" key=clear 2>&1 | Out-String
    if ($x -match 'Key Content\s*:\s*(.+)') {
        Write-Host "كلمة المرور: $($matches[1].Trim())" -ForegroundColor Yellow
        Write-Host '[تنبيه] لا تصوّر الشاشة.' -ForegroundColor Red
    } else { Write-Log 'لم توجد كلمة مرور محفوظة.' 'WARN' }
}

# ============================================================
# 7) Startup / Tasks / Signatures
# ============================================================
function Get-StartupAudit {
    $r = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($x in (Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue)) {
            $r.Add([pscustomobject]@{ Name=$x.Name; Command=$x.Command; Location=$x.Location; User=$x.User; Type='Startup' })
        }
    } catch { Write-Log $_ 'WARN' }
    try {
        foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Disabled' })) {
            $a = $null
            try { $a = $t.Actions | Select-Object -First 1 } catch {}
            if ($null -eq $a) { continue }
            $r.Add([pscustomobject]@{ Name=$t.TaskName; Command=$a.Execute; Location=$t.TaskPath; User='ScheduledTask'; Type='ScheduledTask'; Arguments=$a.Arguments })
        }
    } catch { Write-Log $_ 'WARN' }
    return $r
}

function Show-StartupAudit {
    $r = Get-StartupAudit
    $r | Format-Table -Wrap | Out-Host
    $sus = $r | Where-Object { ($_.Command -match '\\Temp\\|\\AppData\\') -or ($_.Command -match '\.vbs$|\.js$|powershell') }
    if ($sus) { Write-Host 'عناصر تحتاج مراجعة:' -ForegroundColor Yellow; $sus | Format-Table -Wrap | Out-Host }
}

function Test-Signatures {
    $files = @()
    foreach ($x in (Get-StartupAudit)) {
        if ($x.Command -and (Test-Path $x.Command -ErrorAction SilentlyContinue)) {
            try {
                $s = Get-AuthenticodeSignature $x.Command
                $files += [pscustomobject]@{ Path=$x.Command; Status=$s.Status; Signer=$s.SignerCertificate.Subject }
            } catch {}
        }
    }
    if ($files) { $files | Format-Table -Wrap | Out-Host } else { Write-Host 'لا ملفات قابلة للفحص.' }
}

function Show-RestorePoints {
    try { Get-ComputerRestorePoint | Select-Object SequenceNumber,Description,CreationTime | Format-Table | Out-Host } catch { Write-Log $_ 'ERROR' }
}

function Manage-Restore {
    Write-Host '[1] عرض نقاط الاستعادة'
    Write-Host '[2] إنشاء نقطة مخصصة'
    Write-Host '[3] فتح واجهة System Restore'
    $c = Read-Host 'اختر'
    switch ($c) {
        '1' { Show-RestorePoints }
        '2' { if (Confirm-Action 'إنشاء نقطة استعادة؟') { New-AutoRestorePoint | Out-Null } }
        '3' { Start-Process rstrui.exe }
    }
}

function Invoke-SafeCleanup {
    $paths = @($env:TEMP, "$env:WINDIR\Temp") | Where-Object { Test-Path $_ }
    $cutoff = (Get-Date).AddDays(-3)
    $items = foreach ($p in $paths) {
        Get-ChildItem $p -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cutoff }
    }
    $items = @($items)
    Write-Host "تم العثور على $($items.Count) ملفاً مؤقتاً أقدم من 3 أيام."
    if ($items.Count -eq 0) { return }
    $items | Select-Object -First 20 FullName,LastWriteTime,Length | Format-Table | Out-Host
    if (-not (Confirm-Action 'حذف هذه الملفات المؤقتة؟')) { return }
    Invoke-ProtectedChange 'SafeCleanup' 'حذف الملفات المؤقتة فقط.' {
        foreach ($i in $items) { Remove-Item $i.FullName -Force -ErrorAction SilentlyContinue }
    } | Out-Null
}

function Show-Updates {
    Get-CimInstance Win32_QuickFixEngineering | Sort-Object InstalledOn -Descending | Select-Object -First 30 | Format-Table | Out-Host
    Start-Process 'ms-settings:windowsupdate' -ErrorAction SilentlyContinue
}

function Show-UsersAudit {
    try {
        Get-LocalUser | Select-Object Name,Enabled,LastLogon,PasswordRequired | Format-Table | Out-Host
        Write-Host 'Administrators:'
        Get-LocalGroupMember -SID 'S-1-5-32-544' | Select-Object Name,ObjectClass,PrincipalSource | Format-Table | Out-Host
    } catch { Write-Log $_ 'ERROR' }
}

# ============================================================
# 8) Baseline
# ============================================================
function Get-Baseline {
    [ordered]@{
        Generated = Get-Date
        Services  = @(Get-Service | Select-Object Name,Status,StartType)
        Startup   = @(Get-StartupAudit)
        Firewall  = @(Get-NetFirewallRule | Where-Object Enabled -eq True | Select-Object DisplayName,Direction,Action,Profile)
        Users     = @(Get-LocalUser | Select-Object Name,Enabled)
        Tasks     = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Select-Object TaskName,TaskPath,State)
    }
}

function Save-Baseline {
    $b = Get-Baseline
    $p = Join-Path $script:BaselineRoot "baseline_$(Get-Date -Format yyyyMMdd_HHmmss).clixml"
    $b | Export-Clixml $p
    Write-Log "Baseline: $p" 'SUCCESS'
    Write-Host $p
}

function Compare-Baseline {
    $p = Get-ChildItem $script:BaselineRoot -Filter '*.clixml' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $p) { Write-Log 'لا توجد Baseline.' 'WARN'; return }
    $old = Import-Clixml $p.FullName
    $new = Get-Baseline
    Write-Host "مقارنة مع $($p.Name)"

    Write-Host 'الخدمات:'
    Compare-Object ($old.Services | ForEach-Object { "$($_.Name)|$($_.Status)|$($_.StartType)" }) ($new.Services | ForEach-Object { "$($_.Name)|$($_.Status)|$($_.StartType)" }) | Format-Table | Out-Host
    Write-Host 'المستخدمون:'
    Compare-Object ($old.Users | ForEach-Object { "$($_.Name)|$($_.Enabled)" }) ($new.Users | ForEach-Object { "$($_.Name)|$($_.Enabled)" }) | Format-Table | Out-Host
    Write-Host 'المهام:'
    Compare-Object ($old.Tasks | ForEach-Object { "$($_.TaskName)|$($_.State)" }) ($new.Tasks | ForEach-Object { "$($_.TaskName)|$($_.State)" }) | Format-Table | Out-Host
    Write-Host 'قواعد Firewall:'
    Compare-Object ($old.Firewall | ForEach-Object { "$($_.DisplayName)|$($_.Direction)|$($_.Action)" }) ($new.Firewall | ForEach-Object { "$($_.DisplayName)|$($_.Direction)|$($_.Action)" }) | Format-Table | Out-Host
}

# ============================================================
# 9) Incident + Reports
# ============================================================
function Invoke-Redact {
    param([string]$Text)
    if (-not $Redact -or [string]::IsNullOrEmpty($Text)) { return $Text }
    $Text = $Text -replace [regex]::Escape($env:COMPUTERNAME), '<HOST>'
    $Text = $Text -replace [regex]::Escape($env:USERNAME), '<USER>'
    $Text = $Text -replace [regex]::Escape($env:USERPROFILE), '<PROFILE>'
    return $Text
}

function Export-IncidentSnapshot {
    $stamp = Get-Date -Format yyyyMMdd_HHmmss
    $p = Join-Path $script:ReportRoot "Incident_$stamp"
    New-Item $p -ItemType Directory -Force | Out-Null
    Get-Process | Select-Object Name,Id,Path | Export-Csv "$p\Processes.csv" -NoTypeInformation -Encoding UTF8
    Get-StartupAudit | Export-Csv "$p\Startup.csv" -NoTypeInformation -Encoding UTF8
    Get-NetworkAudit | ConvertTo-Json -Depth 5 | Set-Content "$p\Network.json" -Encoding UTF8
    Get-SystemHealth | ConvertTo-Json -Depth 6 | Set-Content "$p\Health.json" -Encoding UTF8
    Get-WinEvent -FilterHashtable @{LogName='System';StartTime=(Get-Date).AddDays(-1)} -MaxEvents 200 | Select-Object TimeCreated,ProviderName,Id,LevelDisplayName,Message | Export-Csv "$p\Events.csv" -NoTypeInformation -Encoding UTF8
    Write-Log "Incident Snapshot: $p" 'SUCCESS'
    Write-Host $p
}

function Export-AuditReport {
    $stamp = Get-Date -Format yyyyMMdd_HHmmss
    $base  = Join-Path $script:ReportRoot "Audit_$stamp"
    $h = @()
    $h += '<h1>Zaher System Maintenance Audit v' + $script:Version + '</h1>'
    $h += '<p>Generated: ' + (Get-Date) + '</p>'
    $h += Invoke-Redact ((Get-SystemHealth  | ConvertTo-Html -Fragment -Depth 5) -join "`n")
    $h += Invoke-Redact ((Get-NetworkAudit | ConvertTo-Html -Fragment -Depth 5) -join "`n")
    $h += Invoke-Redact ((Get-StartupAudit | ConvertTo-Html -Fragment) -join "`n")
    ConvertTo-Html -Title 'Zaher Audit' -Body $h | Set-Content "$base.html" -Encoding UTF8

    $json = [ordered]@{
        Version   = $script:Version
        Generated = (Get-Date).ToString('s')
        Health    = Get-SystemHealth
        Network   = Get-NetworkAudit
        Startup   = Get-StartupAudit
    }
    ($json | ConvertTo-Json -Depth 6) | Set-Content "$base.json" -Encoding UTF8

    Write-Log "تقرير HTML: $base.html" 'SUCCESS'
    Write-Log "تقرير JSON: $base.json" 'SUCCESS'
    Write-Host "HTML: $base.html"
    Write-Host "JSON: $base.json"
}
# ============================================================
# 10) Privacy + Hardening + Advanced Audit
# ============================================================
function Invoke-PrivacyChange {
    Invoke-ProtectedChange 'AdvertisingID' 'سيتم تعطيل Advertising ID للمستخدم الحالي.' {
        $p = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'
        New-Item $p -Force | Out-Null
        New-ItemProperty $p -Name Enabled -PropertyType DWord -Value 0 -Force | Out-Null
    } -CaptureBefore {
        (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' -Name Enabled -ErrorAction SilentlyContinue).Enabled
    } | Out-Null
}

function Get-AdvancedSecurityAudit {
    $r = [ordered]@{ Generated = Get-Date; Computer = $env:COMPUTERNAME }
    try { $r.Defender = Get-MpComputerStatus | Select-Object AntivirusEnabled,RealTimeProtectionEnabled,BehaviorMonitorEnabled,IOAVProtectionEnabled,CloudBlockLevel,AntivirusSignatureLastUpdated } catch {}
    try { $r.ASR      = Get-MpPreference | Select-Object AttackSurfaceReductionRules_Actions,AttackSurfaceReductionRules_Ids } catch {}
    try { $r.VBS      = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard | Select-Object SecurityServicesRunning,VirtualizationBasedSecurityStatus,CodeIntegrityPolicyEnforcementStatus } catch {}
    try { $r.RDP      = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' | Select-Object fDenyTSConnections } catch {}
    try { $r.NLA      = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' | Select-Object UserAuthentication } catch {}
    try { $r.SMB      = Get-SmbServerConfiguration | Select-Object EnableSMB1Protocol,EnableSMB2Protocol,RequireSecuritySignature,EnableSecuritySignature } catch {}
    try { $r.LLMNR    = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Name EnableMulticast -ErrorAction SilentlyContinue } catch { $r.LLMNR = $null }
    try { $r.Accounts = Get-LocalUser | Select-Object Name,Enabled,PasswordRequired,LastLogon } catch {}
    try {
        $uac = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name ConsentPromptBehaviorAdmin -ErrorAction SilentlyContinue).ConsentPromptBehaviorAdmin
        $r.UAC = [pscustomobject]@{ ConsentPromptBehaviorAdmin = $uac }
    } catch { $r.UAC = $null }
    try {
        $lsass = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -ErrorAction SilentlyContinue)
        $r.LSASS = [pscustomobject]@{ RunAsPPL = $lsass.RunAsPPL; LimitBlankPassword = $lsass.LimitBlankPasswordUse }
    } catch { $r.LSASS = $null }
    try {
        $pref = Get-MpPreference -ErrorAction Stop
        $r.DefenderExclusions = [pscustomobject]@{ Paths = $pref.ExclusionPath; Extensions = $pref.ExclusionExtension; Processes = $pref.ExclusionProcess }
    } catch { $r.DefenderExclusions = $null }
    try {
        $hosts = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'
        if (Test-Path $hosts) {
            $active = Get-Content $hosts -ErrorAction SilentlyContinue | Where-Object { $_ -and $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*$' }
            $r.Hosts = [pscustomobject]@{ Path=$hosts; ActiveEntries=@($active) }
        }
    } catch { $r.Hosts = $null }
    try { $r.PasswordPolicy = Get-CimInstance -ClassName Win32_AccountPolicy -ErrorAction SilentlyContinue } catch { $r.PasswordPolicy = $null }
    try { $r.ExecutionPolicy = Get-ExecutionPolicy -List | Out-String } catch { $r.ExecutionPolicy = $null }
    return [pscustomobject]$r
}

function Get-SecurityScore {
    $r = Get-AdvancedSecurityAudit
    $score = 0
    $checks = @()

    if ((Get-Prop $r.Defender 'RealTimeProtectionEnabled') -eq $true) { $score += 15; $checks += '[OK] Defender Real-time Protection' }
    else { $checks += '[WARN] Defender Real-time Protection' }

    try {
        $fw = @(Get-NetFirewallProfile | Where-Object Enabled)
        if ($fw.Count -eq 3) { $score += 15; $checks += '[OK] Firewall مفعّل للجميع' }
        else { $checks += '[WARN] Firewall غير مفعّل للجميع' }
    } catch { $checks += '[WARN] تعذر قراءة Firewall' }

    if ((Get-Prop $r.SMB 'EnableSMB1Protocol') -ne $true) { $score += 10; $checks += '[OK] SMBv1 غير مفعّل' }
    else { $checks += '[WARN] SMBv1 مفعّل' }

    $rdpDeny = Get-Prop $r.RDP 'fDenyTSConnections'
    $nla     = Get-Prop $r.NLA 'UserAuthentication'
    if ($rdpDeny -eq 1) { $score += 10; $checks += '[OK] RDP مغلق' }
    elseif ($nla -eq 1) { $score += 5;  $checks += '[INFO] RDP مفتوح لكن NLA مفعّل' }
    else { $checks += '[WARN] RDP مفتوح بدون NLA' }

    if ((Get-Prop $r.VBS 'VirtualizationBasedSecurityStatus') -eq 2) { $score += 10; $checks += '[OK] VBS يعمل' }
    else { $checks += '[INFO] VBS غير مفعّل' }

    try {
        if (@(Get-LocalGroupMember -SID 'S-1-5-32-544').Count -le 2) { $score += 10; $checks += '[OK] عدد المسؤولين محدود' }
        else { $checks += '[WARN] راجع Administrators' }
    } catch { $checks += '[WARN] تعذر قراءة المسؤولين' }

    if ((Get-Prop $r.LSASS 'RunAsPPL') -eq 1 -or (Get-Prop $r.LSASS 'RunAsPPL') -eq 2) {
        $score += 10; $checks += '[OK] LSASS Protection مفعّل'
    } else { $checks += '[WARN] LSASS Protection غير مفعّل' }

    $exclusions = Get-Prop $r.DefenderExclusions 'Paths'
    if ($exclusions -and @($exclusions).Count -gt 0) {
        $checks += "[WARN] يوجد $($exclusions.Count) استثناء في Defender — راجعها"
    } else {
        $score += 10; $checks += '[OK] لا استثناءات في Defender'
    }

    try {
        $sb = Confirm-SecureBootUEFI -ErrorAction Stop
        if ($sb) { $score += 10; $checks += '[OK] Secure Boot مفعّل' }
        else { $checks += '[WARN] Secure Boot معطّل' }
    } catch { $checks += '[INFO] Secure Boot غير متاح' }

    [pscustomobject]@{ Score = $score; Max = 100; Checks = $checks; Details = $r }
}

function Show-SecurityScore {
    $s = Get-SecurityScore
    Write-Host "`nSecurity Score: $($s.Score)/$($s.Max)" -ForegroundColor Cyan
    $s.Checks | ForEach-Object { Write-Host $_ }
    Write-Host 'التقييم إرشادي وليس ضماناً للأمان.' -ForegroundColor Yellow
}

function Export-FirewallBackup {
    param([string]$Folder = $script:BackupRoot)
    $p = Join-Path $Folder "Firewall_$(Get-Date -Format yyyyMMdd_HHmmss).clixml"
    try { Get-NetFirewallRule | Export-Clixml $p; Write-Log "نسخة Firewall: $p" 'SUCCESS' }
    catch { Write-Log "فشل: $($_.Exception.Message)" 'ERROR' }
}

function Invoke-SafeHardening {
    Write-Host '[1] تفعيل Windows Firewall'
    Write-Host '[2] تعطيل SMBv1'
    Write-Host '[3] تعطيل LLMNR'
    Write-Host '[4] تفعيل SMB Signing'
    Write-Host '[5] تفعيل LSASS Protection (RunAsPPL)'
    Write-Host '[6] عرض تقرير Defender/ASR فقط'
    $c = Read-Host 'اختر'
    switch ($c) {
        '1' {
            Invoke-ProtectedChange 'EnableFirewall' 'تفعيل Firewall وحفظ نسخة القواعد.' {
                Export-FirewallBackup
                Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True
            } -CaptureBefore { Get-NetFirewallProfile | Select-Object Name,Enabled } | Out-Null
        }
        '2' {
            Invoke-ProtectedChange 'DisableSMB1' 'تعطيل SMBv1 قد يمنع أجهزة قديمة.' {
                Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction Stop | Out-Host
            } -CaptureBefore { Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol | Select-Object FeatureName,State } | Out-Null
        }
        '3' {
            Invoke-ProtectedChange 'DisableLLMNR' 'تعطيل LLMNR قد يؤثر على اكتشاف الأجهزة القديمة.' {
                $p = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'
                New-Item $p -Force | Out-Null
                New-ItemProperty $p -Name EnableMulticast -PropertyType DWord -Value 0 -Force | Out-Null
            } -CaptureBefore {
                (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Name EnableMulticast -ErrorAction SilentlyContinue).EnableMulticast
            } | Out-Null
        }
        '4' {
            Invoke-ProtectedChange 'EnableSMBSigning' 'تفعيل SMB Signing قد يؤثر على عملاء قدامى.' {
                Set-SmbServerConfiguration -RequireSecuritySignature $true -EnableSecuritySignature $true -Force
            } -CaptureBefore { Get-SmbServerConfiguration | Select-Object RequireSecuritySignature,EnableSecuritySignature } | Out-Null
        }
        '5' {
            Invoke-ProtectedChange 'LSASS-Protection' 'تفعيل RunAsPPL لحماية LSASS. يتطلب إعادة تشغيل.' {
                New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name RunAsPPL -PropertyType DWord -Value 1 -Force | Out-Null
                Write-Host '[تنبيه] يلزم إعادة تشغيل لتفعيل الحماية.' -ForegroundColor Yellow
            } -CaptureBefore {
                (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name RunAsPPL -ErrorAction SilentlyContinue).RunAsPPL
            } | Out-Null
        }
        '6' { Get-AdvancedSecurityAudit | Format-List | Out-Host }
    }
}

function Show-AdvancedAudit {
    $r = Get-AdvancedSecurityAudit
    $r | Format-List | Out-Host
    Write-Host 'قواعد Firewall الواردة:'
    try { Get-NetFirewallRule -Direction Inbound -Enabled True | Select-Object DisplayName,Action,Profile | Format-Table -Wrap | Out-Host } catch {}
    Write-Host 'Persistence review:'
    Get-StartupAudit | Where-Object { $_.Command -match 'powershell|wscript|cscript|mshta|wmic|-enc|encoded' } | Format-Table -Wrap | Out-Host
    try { Get-CimInstance -Namespace root\subscription -Class __EventConsumer -ErrorAction Stop | Select-Object Name,__CLASS | Format-Table | Out-Host }
    catch { Write-Log 'تعذر قراءة WMI consumers.' 'WARN' }
}

function Protect-Reports {
    if ($AuditOnly) { Write-Log 'AuditOnly: لم تتغير الصلاحيات.' 'WARN'; return }
    if (-not $script:IsAdmin) { Write-Log 'يلزم Administrator.' 'ERROR'; return }
    Invoke-ProtectedChange 'ProtectReports' 'تقييد مجلد التقارير.' {
        $sysSid  = '*S-1-5-18'
        $admSid  = '*S-1-5-32-544'
        $userSid = (New-Object Security.Principal.NTAccount($env:USERNAME)).Translate([Security.Principal.SecurityIdentifier]).Value
        & icacls $script:DataRoot /inheritance:r /t /c /q | Out-Null
        & icacls $script:DataRoot /grant:r "${admSid}:(OI)(CI)F" "${sysSid}:(OI)(CI)F" "${userSid}:(OI)(CI)F" /t /c /q | Out-Null
    } -CaptureBefore { & icacls $script:DataRoot } | Out-Null
}

# ============================================================
# 11) Tools Module — أدوات الصيانة السريعة
# ============================================================
function Invoke-DNSFlush {
    Write-Host 'تنظيف كاش DNS...' -ForegroundColor Cyan
    try { ipconfig /flushdns | Out-Host; Write-Log 'تم تنظيف كاش DNS.' 'SUCCESS' }
    catch { Write-Log "فشل: $($_.Exception.Message)" 'ERROR' }
}

function Invoke-SFCScan {
    Write-Host 'فحص ملفات النظام (5-15 دقيقة)...' -ForegroundColor Cyan
    if (-not (Confirm-Action 'ستبدأ عملية SFC. لا تغلق النافذة.')) { return }
    try { sfc /scannow | Out-Host; Write-Log 'انتهى SFC.' 'SUCCESS' }
    catch { Write-Log "فشل: $($_.Exception.Message)" 'ERROR' }
}

function Invoke-DISMRepair {
    Write-Host 'إصلاح صورة Windows (10-20 دقيقة)...' -ForegroundColor Cyan
    if (-not (Confirm-Action 'ستبدأ عملية DISM. لا تغلق النافذة.')) { return }
    try { DISM /Online /Cleanup-Image /RestoreHealth | Out-Host; Write-Log 'انتهى DISM.' 'SUCCESS' }
    catch { Write-Log "فشل: $($_.Exception.Message)" 'ERROR' }
}

function Invoke-WinsockReset {
    if (-not (Confirm-Action 'إعادة ضبط Winsock؟ قد يحتاج إعادة تشغيل.')) { return }
    try { netsh winsock reset | Out-Host; Write-Log 'تمت إعادة ضبط Winsock.' 'SUCCESS' }
    catch { Write-Log "فشل: $($_.Exception.Message)" 'ERROR' }
}

function Invoke-TCPIPReset {
    if (-not (Confirm-Action 'إعادة ضبط TCP/IP؟ قد يحتاج إعادة تشغيل.')) { return }
    try { netsh int ip reset | Out-Host; Write-Log 'تمت إعادة ضبط TCP/IP.' 'SUCCESS' }
    catch { Write-Log "فشل: $($_.Exception.Message)" 'ERROR' }
}

function Invoke-ARPFlush {
    try { netsh interface ip delete arpcache | Out-Host; Write-Log 'تم مسح ARP Cache.' 'SUCCESS' }
    catch { Write-Log "فشل: $($_.Exception.Message)" 'ERROR' }
}

function Invoke-GPUpdate {
    try { gpupdate /force | Out-Host; Write-Log 'تم تحديث Group Policy.' 'SUCCESS' }
    catch { Write-Log "فشل: $($_.Exception.Message)" 'ERROR' }
}

function Invoke-ToolsMenu {
    $r = $true
    while ($r) {
        Show-Header 'أدوات الصيانة السريعة'
        @(
            '[1] تنظيف كاش DNS',
            '[2] إصلاح ملفات النظام (SFC)',
            '[3] إصلاح صورة Windows (DISM)',
            '[4] إعادة ضبط Winsock',
            '[5] إعادة ضبط TCP/IP',
            '[6] مسح ARP Cache',
            '[7] تحديث Group Policy',
            '[B] رجوع'
        ) | ForEach-Object { Write-Host $_ }
        $c = Read-Host 'اختر'
        try {
            switch ($c.ToUpper()) {
                '1' { Invoke-DNSFlush }
                '2' { Invoke-SFCScan }
                '3' { Invoke-DISMRepair }
                '4' { Invoke-WinsockReset }
                '5' { Invoke-TCPIPReset }
                '6' { Invoke-ARPFlush }
                '7' { Invoke-GPUpdate }
                'B' { $r = $false; continue }
                default { Write-Log 'اختيار غير صالح.' 'WARN' }
            }
        } catch { Write-Log "خطأ: $($_.Exception.Message)" 'ERROR' }
        if ($r) { Pause-Menu }
    }
}

# ============================================================
# 12) Extended Security Audits
# ============================================================
function Show-WindowsUpdateAudit {
    Write-Host "`n=== Windows Update Audit ===" -ForegroundColor Cyan
    try {
        Get-CimInstance Win32_QuickFixEngineering | Sort-Object InstalledOn -Descending |
            Select-Object -First 20 HotFixID,InstalledOn,Description | Format-Table | Out-Host
    } catch { Write-Log 'تعذر قراءة التحديثات.' 'WARN' }
    try {
        $au = (New-Object -ComObject Microsoft.Update.AutoUpdate).Settings
        Write-Host "حالة التحديث التلقائي: $($au.NotificationLevel)"
    } catch {}
}

function Show-AutorunsDeepScan {
    Write-Host 'فحص Autoruns العميق...' -ForegroundColor Cyan
    $results = New-Object System.Collections.Generic.List[object]

    $runKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run'
    )
    foreach ($k in $runKeys) {
        if (Test-Path $k) {
            try {
                $props = Get-ItemProperty $k -ErrorAction SilentlyContinue
                foreach ($p in $props.PSObject.Properties) {
                    if ($p.Name -notlike 'PS*') {
                        $results.Add([pscustomobject]@{ Type='RunKey'; Location=$k; Name=$p.Name; Value=$p.Value })
                    }
                }
            } catch {}
        }
    }

    try {
        $wl = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction Stop
        if ($wl.Shell)    { $results.Add([pscustomobject]@{ Type='Winlogon'; Location='Shell'; Name='Shell'; Value=$wl.Shell }) }
        if ($wl.Userinit) { $results.Add([pscustomobject]@{ Type='Winlogon'; Location='Userinit'; Name='Userinit'; Value=$wl.Userinit }) }
    } catch {}

    try {
        $ifeoPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
        Get-ChildItem $ifeoPath -ErrorAction SilentlyContinue | ForEach-Object {
            $dbg = (Get-ItemProperty $_.PSPath -Name Debugger -ErrorAction SilentlyContinue).Debugger
            if ($dbg) { $results.Add([pscustomobject]@{ Type='IFEO-Hijack'; Location=$_.PSChildName; Name='Debugger'; Value=$dbg }) }
        }
    } catch {}

    if ($results.Count -eq 0) { Write-Host 'لم يتم العثور على عناصر.' -ForegroundColor Green; return }
    $results | Format-Table -Wrap | Out-Host

    $sus = $results | Where-Object { $_.Value -match '\\Temp\\|\\AppData\\|\\Users\\Public\\|\.vbs|\.js|powershell|-enc' }
    if ($sus) { Write-Host '⚠️ عناصر مشبوهة:' -ForegroundColor Red; $sus | Format-Table -Wrap | Out-Host }
}

function Show-CertificateAudit {
    Write-Host 'فحص الشهادات...' -ForegroundColor Cyan
    $results = @()
    foreach ($s in @('Cert:\LocalMachine\Root','Cert:\LocalMachine\CA')) {
        try {
            foreach ($c in (Get-ChildItem $s -ErrorAction SilentlyContinue)) {
                $expired = $c.NotAfter -lt (Get-Date)
                $soon = ($c.NotAfter -gt (Get-Date)) -and ($c.NotAfter -lt (Get-Date).AddDays(30))
                if ($expired -or $soon) {
                    $results += [pscustomobject]@{ Store=$s; Subject=$c.Subject; NotAfter=$c.NotAfter; Status= if($expired){'Expired'}else{'Expiring'} }
                }
            }
        } catch {}
    }
    if ($results.Count -eq 0) { Write-Host '✅ لا شهادات منتهية.' -ForegroundColor Green; return }
    $results | Format-Table -Wrap | Out-Host
}

function Show-FirewallRuleAudit {
    Write-Host 'فحص قواعد Firewall الخطرة...' -ForegroundColor Cyan
    $risky = @()
    try {
        $rules = Get-NetFirewallRule -Enabled True -ErrorAction SilentlyContinue | Where-Object { $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' }
        foreach ($rule in $rules) {
            try {
                $port = $rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
                $addr = $rule | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue
                if ($port.LocalPort -eq 'Any' -and $port.Protocol -eq 'Any') {
                    $risky += [pscustomobject]@{ Name=$rule.DisplayName; Profile=$rule.Profile; Reason='كل المنافذ مفتوحة' }
                }
            } catch {}
        }
    } catch {}
    if ($risky.Count -eq 0) { Write-Host '✅ لا قواعد خطرة واضحة.' -ForegroundColor Green; return }
    Write-Host "⚠️ قواعد خطرة ($($risky.Count)):" -ForegroundColor Yellow
    $risky | Format-Table -Wrap | Out-Host
}

function Show-WifiSecurityAudit {
    Write-Host "`n=== Wi-Fi Security Audit ===" -ForegroundColor Cyan
    try {
        $iface = netsh wlan show interfaces 2>&1 | Out-String
        $auth = if ($iface -match 'Authentication\s*:\s*(.+)') { $matches[1].Trim() } else { 'Unknown' }
        $ssid = if ($iface -match 'SSID\s*:\s*(.+)') { $matches[1].Trim() } else { 'Unknown' }
        Write-Host "SSID: $ssid"
        Write-Host "Authentication: $auth"
        if ($auth -match 'WPA3')     { Write-Host '✅ WPA3 — أفضل تشفير.' -ForegroundColor Green }
        elseif ($auth -match 'WPA2') { Write-Host '✅ WPA2 — تشفير جيد.' -ForegroundColor Green }
        elseif ($auth -match 'WPA|WEP') { Write-Host '⚠️ تشفير ضعيف!' -ForegroundColor Red }
    } catch { Write-Log 'تعذر قراءة Wi-Fi.' 'WARN' }
}

function Show-SuspiciousFilesScan {
    Write-Host 'فحص ملفات تنفيذية حديثة في مجلدات مؤقتة...' -ForegroundColor Cyan
    $paths = @("$env:TEMP", "$env:APPDATA", "$env:LOCALAPPDATA\Temp", "$env:USERPROFILE\Downloads")
    $exts = @('.exe','.dll','.bat','.ps1','.vbs','.js','.scr','.hta')
    $cutoff = (Get-Date).AddDays(-7)
    $results = @()
    foreach ($p in $paths) {
        if (-not (Test-Path $p)) { continue }
        try {
            $files = Get-ChildItem $p -File -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { $exts -contains $_.Extension.ToLower() -and $_.LastWriteTime -gt $cutoff } |
                Select-Object -First 30
            foreach ($f in $files) {
                $results += [pscustomobject]@{ Path=$f.FullName; Size=[math]::Round($f.Length/1KB,1); Modified=$f.LastWriteTime }
            }
        } catch {}
    }
    if ($results.Count -eq 0) { Write-Host '✅ لا ملفات مشبوهة حديثة.' -ForegroundColor Green; return }
    Write-Host "⚠️ $($results.Count) ملفاً — راجعها بحذر:" -ForegroundColor Yellow
    $results | Select-Object -First 30 | Format-Table -Wrap | Out-Host
}

function Show-DNSSecurityCheck {
    Write-Host 'فحص DNS Security...' -ForegroundColor Cyan
    try {
        $adapters = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue
        foreach ($a in $adapters) {
            foreach ($server in $a.ServerAddresses) {
                $provider = switch -Regex ($server) {
                    '^1\.(1|0)\.(1|0)\.1$' { 'Cloudflare (آمن)' }
                    '^8\.8\.(8|4)\.(8|4)$' { 'Google (آمن)' }
                    '^9\.9\.9\.9$'         { 'Quad9 (آمن)' }
                    default                { 'مزود الإنترنت أو آخر' }
                }
                Write-Host "  $($a.InterfaceAlias) → $server [$provider]"
            }
        }
    } catch {}
}

function Show-PasswordPolicyAudit {
    Write-Host "`n=== Password Policy Audit ===" -ForegroundColor Cyan
    try {
        $pol = net accounts 2>&1 | Out-String
        $pol -split "`n" | Where-Object { $_ -match ':' } | ForEach-Object { Write-Host $_.Trim() }
    } catch { Write-Log $_ 'WARN' }
}

function Show-BitLockerKeyAudit {
    Write-Host "`n=== BitLocker Key Audit ===" -ForegroundColor Cyan
    try {
        $volumes = Get-BitLockerVolume -ErrorAction Stop
        $volumes | Select-Object MountPoint,VolumeStatus,ProtectionStatus,EncryptionPercentage | Format-Table | Out-Host
    } catch { Write-Host 'BitLocker غير مفعّل أو غير متاح.' -ForegroundColor Yellow }
}

function Invoke-SecurityExtendedMenu {
    $r = $true
    while ($r) {
        Show-Header 'تدقيق أمني موسّع'
        @(
            '[1] Windows Update Audit',
            '[2] Autoruns Deep Scan',
            '[3] Certificate Audit',
            '[4] Firewall Rule Audit',
            '[5] Wi-Fi Security Audit',
            '[6] Suspicious Files Scan',
            '[7] DNS Security Check',
            '[8] Password Policy Audit',
            '[9] BitLocker Key Audit',
            '[B] رجوع'
        ) | ForEach-Object { Write-Host $_ }
        $c = Read-Host 'اختر'
        try {
            switch ($c.ToUpper()) {
                '1' { Show-WindowsUpdateAudit }
                '2' { Show-AutorunsDeepScan }
                '3' { Show-CertificateAudit }
                '4' { Show-FirewallRuleAudit }
                '5' { Show-WifiSecurityAudit }
                '6' { Show-SuspiciousFilesScan }
                '7' { Show-DNSSecurityCheck }
                '8' { Show-PasswordPolicyAudit }
                '9' { Show-BitLockerKeyAudit }
                'B' { $r = $false; continue }
                default { Write-Log 'اختيار غير صالح.' 'WARN' }
            }
        } catch { Write-Log "خطأ: $($_.Exception.Message)" 'ERROR' }
        if ($r) { Pause-Menu }
    }
}

# ============================================================
# 13) القوائم
# ============================================================
function Show-Header {
    param([string]$Title = 'القائمة الرئيسية')
    Clear-Host
    Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
    Write-Host "║  ZAHER SYSTEM MAINTENANCE v$script:Version" -ForegroundColor Cyan
    Write-Host "║  $Title" -ForegroundColor Cyan
    Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
    if ($AuditOnly) { Write-Host 'MODE: AUDIT ONLY — لا توجد تغييرات' -ForegroundColor Yellow }
    else            { Write-Host 'MODE: INTERACTIVE — YES + Restore Point + Backup مطلوبان' -ForegroundColor Green }
    if ($Redact)    { Write-Host 'REDACT: ON' -ForegroundColor Magenta }
    Write-Host ''
}

function Pause-Menu { if (-not $NoPause) { Read-Host "`nاضغط Enter للمتابعة" | Out-Null } }

function Invoke-SystemMenu {
    $r = $true
    while ($r) {
        Show-Header 'فحص النظام والصحة'
        @('[1] System Health Check','[2] Safe Cleanup','[3] Windows Update Audit','[4] Restore Point Manager','[B] رجوع') | ForEach-Object { Write-Host $_ }
        $c = Read-Host 'اختر'
        try {
            switch ($c.ToUpper()) {
                '1' { Show-Health }
                '2' { Invoke-SafeCleanup }
                '3' { Show-Updates }
                '4' { Manage-Restore }
                'B' { $r = $false; continue }
                default { Write-Log 'اختيار غير صالح.' 'WARN' }
            }
        } catch { Write-Log "خطأ: $($_.Exception.Message)" 'ERROR' }
        if ($r) { Pause-Menu }
    }
}

function Invoke-NetworkMenu {
    $r = $true
    while ($r) {
        Show-Header 'الشبكة والاتصالات'
        @('[1] Network & Privacy Audit','[2] الشبكات المحفوظة','[3] عرض كلمة مرور شبكة','[4] Network Security Audit','[5] Safe Network Hardening','[B] رجوع') | ForEach-Object { Write-Host $_ }
        $c = Read-Host 'اختر'
        try {
            switch ($c.ToUpper()) {
                '1' { Show-Network }
                '2' { Show-WifiProfiles }
                '3' { Show-WifiPassword }
                '4' { Show-AdvancedAudit }
                '5' { Invoke-SafeHardening }
                'B' { $r = $false; continue }
                default { Write-Log 'اختيار غير صالح.' 'WARN' }
            }
        } catch { Write-Log "خطأ: $($_.Exception.Message)" 'ERROR' }
        if ($r) { Pause-Menu }
    }
}

function Invoke-PrivacyMenu {
    $r = $true
    while ($r) {
        Show-Header 'الخصوصية والتقارير'
        @('[1] تقليل Advertising ID','[2] تصدير تقرير HTML+JSON','[3] حماية السجلات','[B] رجوع') | ForEach-Object { Write-Host $_ }
        $c = Read-Host 'اختر'
        try {
            switch ($c.ToUpper()) {
                '1' { Invoke-PrivacyChange }
                '2' { Export-AuditReport }
                '3' { Protect-Reports }
                'B' { $r = $false; continue }
                default { Write-Log 'اختيار غير صالح.' 'WARN' }
            }
        } catch { Write-Log "خطأ: $($_.Exception.Message)" 'ERROR' }
        if ($r) { Pause-Menu }
    }
}

function Invoke-AccountsMenu {
    $r = $true
    while ($r) {
        Show-Header 'الحسابات وتسجيل الدخول'
        @('[1] Local Users Audit','[2] Security Score','[3] Advanced Security Audit','[B] رجوع') | ForEach-Object { Write-Host $_ }
        $c = Read-Host 'اختر'
        try {
            switch ($c.ToUpper()) {
                '1' { Show-UsersAudit }
                '2' { Show-SecurityScore }
                '3' { Show-AdvancedAudit }
                'B' { $r = $false; continue }
                default { Write-Log 'اختيار غير صالح.' 'WARN' }
            }
        } catch { Write-Log "خطأ: $($_.Exception.Message)" 'ERROR' }
        if ($r) { Pause-Menu }
    }
}

function Invoke-AppsMenu {
    $r = $true
    while ($r) {
        Show-Header 'البرامج وبدء التشغيل'
        @('[1] Startup & Tasks Audit','[2] Digital Signature Audit','[3] Incident Snapshot','[B] رجوع') | ForEach-Object { Write-Host $_ }
        $c = Read-Host 'اختر'
        try {
            switch ($c.ToUpper()) {
                '1' { Show-StartupAudit }
                '2' { Test-Signatures }
                '3' { Export-IncidentSnapshot }
                'B' { $r = $false; continue }
                default { Write-Log 'اختيار غير صالح.' 'WARN' }
            }
        } catch { Write-Log "خطأ: $($_.Exception.Message)" 'ERROR' }
        if ($r) { Pause-Menu }
    }
}

function Invoke-AdvancedMenu {
    $r = $true
    while ($r) {
        Show-Header 'الحماية المتقدمة'
        @('[1] Security Score','[2] Advanced Security Audit','[3] Safe Security Hardening','[4] حماية السجلات','[B] رجوع') | ForEach-Object { Write-Host $_ }
        $c = Read-Host 'اختر'
        try {
            switch ($c.ToUpper()) {
                '1' { Show-SecurityScore }
                '2' { Show-AdvancedAudit }
                '3' { Invoke-SafeHardening }
                '4' { Protect-Reports }
                'B' { $r = $false; continue }
                default { Write-Log 'اختيار غير صالح.' 'WARN' }
            }
        } catch { Write-Log "خطأ: $($_.Exception.Message)" 'ERROR' }
        if ($r) { Pause-Menu }
    }
}

function Invoke-RecoveryMenu {
    $r = $true
    while ($r) {
        Show-Header 'التقارير وBaseline والتعافي'
        @(
            '[1] Restore Point Manager',
            '[2] Baseline: حفظ',
            '[3] Baseline: مقارنة',
            '[4] Incident Snapshot',
            '[5] تصدير تقرير HTML+JSON',
            '[6] Rollback من نسخة سابقة',
            '[7] عرض مجلد النسخ الاحتياطية',
            '[B] رجوع'
        ) | ForEach-Object { Write-Host $_ }
        $c = Read-Host 'اختر'
        try {
            switch ($c.ToUpper()) {
                '1' { Manage-Restore }
                '2' { Save-Baseline }
                '3' { Compare-Baseline }
                '4' { Export-IncidentSnapshot }
                '5' { Export-AuditReport }
                '6' { Show-RollbackMenu }
                '7' { Start-Process explorer.exe $script:BackupRoot -ErrorAction SilentlyContinue }
                'B' { $r = $false; continue }
                default { Write-Log 'اختيار غير صالح.' 'WARN' }
            }
        } catch { Write-Log "خطأ: $($_.Exception.Message)" 'ERROR' }
        if ($r) { Pause-Menu }
    }
}

function Invoke-Menu {
    $run = $true
    while ($run) {
        Show-Header 'القائمة الرئيسية'
        @(
            '[1] فحص النظام والصحة',
            '[2] الشبكة والاتصالات',
            '[3] الخصوصية والتقارير',
            '[4] الحسابات وتسجيل الدخول',
            '[5] البرامج وبدء التشغيل',
            '[6] الحماية المتقدمة',
            '[7] التقارير وBaseline والتعافي',
            '[8] أدوات الصيانة السريعة',
            '[9] تدقيق أمني موسّع',
            '[0] خروج'
        ) | ForEach-Object { Write-Host $_ }
        $c = Read-Host 'اختر رقم القسم'
        try {
            switch ($c.ToUpper()) {
                '1' { Invoke-SystemMenu }
                '2' { Invoke-NetworkMenu }
                '3' { Invoke-PrivacyMenu }
                '4' { Invoke-AccountsMenu }
                '5' { Invoke-AppsMenu }
                '6' { Invoke-AdvancedMenu }
                '7' { Invoke-RecoveryMenu }
                '8' { Invoke-ToolsMenu }
                '9' { Invoke-SecurityExtendedMenu }
                '0' { $run = $false; continue }
                default { Write-Log 'اختيار غير صالح.' 'WARN' }
            }
        } catch { Write-Log "خطأ غير متوقع: $($_.Exception.Message)" 'ERROR' }
        if ($run) { Pause-Menu }
    }
}

# ============================================================
# 14) نقطة الدخول
# ============================================================
$exitCode = 0
try {
    Initialize-App
    Write-Log "بدأت الأداة v$script:Version (Admin=$script:IsAdmin, AuditOnly=$AuditOnly, Redact=$Redact)"
    if (-not $script:IsAdmin) { Write-Log 'بدون admin — التغييرات الحساسة ستُرفض.' 'WARN' }
    if ($AuditOnly) {
        Show-Health
        Show-Network
        Show-StartupAudit
        Export-AuditReport
    } else {
        Invoke-Menu
    }
}
catch {
    Write-Host "FATAL: $($_.Exception.Message)" -ForegroundColor Red
    try { Write-Log $_ 'ERROR' } catch {}
    $exitCode = 1
}
finally {
    if ($script:OwnsLock -and (Test-Path $script:LockPath)) {
        Remove-Item $script:LockPath -Force -ErrorAction SilentlyContinue
    }
    try { Write-Log 'انتهت الأداة.' } catch {}
}
exit $exitCode
