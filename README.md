# Zaher System Maintenance v3.1.0 🛡️

أداة دفاعية مفتوحة المصدر لصيانة وتدقيق أمان Windows.
مكتوبة بالكامل بـ **PowerShell** و **Batch** — بدون تثبيت، بدون مكتبات خارجية، بدون اتصال بأي خادم.

![Version](https://img.shields.io/badge/version-3.1.0-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-lightgrey)

---

## ✨ الميزات

| الميزة | الوصف |
|---|---|
| 🎯 **Security Score** | تقييم 0-100 لحالة الجهاز |
| 🔍 **Advanced Audit** | Defender, ASR, VBS, RDP, SMB, LSASS, UAC |
| 🛠️ **Safe Hardening** | تفعيل Firewall، تعطيل SMBv1/LLMNR، تفعيل SMB Signing و LSASS Protection |
| 💾 **Backup + Rollback** | كل تغيير يُحفظ، ويمكن التراجع عنه |
| 📸 **Incident Snapshot** | لقطة فورية عند الشك باختراق |
| 📊 **Baseline** | مقارنة دورية لكشف التغيرات |
| 🔐 **Secure Boot / TPM / BitLocker** | فحص شامل لأمان العتاد |
| 🕵️ **Hosts & Shares Audit** | كشف التلاعب والاتصالات المفتوحة |

---

## 🆕 جديد في v3.1.0

### 🔧 أدوات الصيانة السريعة (قسم 8)
- تنظيف كاش DNS
- إصلاح ملفات النظام (SFC)
- إصلاح صورة Windows (DISM)
- إعادة ضبط Winsock
- إعادة ضبط TCP/IP
- مسح ARP Cache
- تحديث Group Policy

### 🔍 تدقيق أمني موسّع (قسم 9)
- **Windows Update Audit** — فحص التحديثات الناقصة
- **Autoruns Deep Scan** — كشف Registry Run, Winlogon, IFEO, Winsock LSP
- **Certificate Audit** — كشف الشهادات المنتهية
- **Firewall Rule Audit** — كشف القواعد الخطرة
- **Wi-Fi Security Audit** — فحص WPA2/WPA3
- **Suspicious Files Scan** — فحص ملفات تنفيذية حديثة
- **DNS Security Check** — هل تستخدم DNS آمن؟
- **Password Policy Audit** — سياسة كلمات المرور
- **BitLocker Key Audit** — حالة مفاتيح BitLocker

---

## 📥 التحميل

[آخر إصدار](https://github.com/AcademyF6Team/zaher-system-maintenance/releases/latest)

---

## 🚀 التشغيل

1. حمّل الحزمة وفك ضغطها.
2. شغّل `Zaher-SystemMaintenance-Secure.bat` (سيطلب صلاحيات admin).
3. اختر من القائمة.

### وضع AuditOnly (بدون تغييرات)

```powershell
.\Zaher-SystemMaintenance-Secure.ps1 -AuditOnly
```
