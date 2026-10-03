# Zahar System Maintenance v2.1 Secure

نسخة تنفيذية دفاعية متقدمة لصيانة Windows وتدقيق الأمان والخصوصية. تعرض الحالة قبل التغيير، وتطلب تأكيدًا، وتنشئ نقطة استعادة قبل عمليات التقوية.

## التشغيل

فك ضغط الحزمة مع إبقاء الملفين في مجلد واحد ثم شغّل:

```text
Zahar-SystemMaintenance-Secure.bat
```

ويُفضّل اختيار **Run as administrator**.

## الإضافات الأمنية المتقدمة

- **Security Score**: تقييم إرشادي لحالة Defender وFirewall وSMBv1 وRDP/NLA وVBS وحسابات المسؤولين.
- **Advanced Security Audit**: حالة Defender وASR وVBS وRDP/NLA وSMB Signing وLLMNR والحسابات المحلية.
- **Safe Security Hardening**: تطبيق اختياري لكل من تفعيل Firewall، تعطيل SMBv1، تعطيل LLMNR، وتفعيل SMB Signing.
- **Firewall Backup**: تصدير قواعد Firewall قبل تعديلها.
- **Persistence Audit**: مراجعة Startup وScheduled Tasks وبعض WMI Consumers وأوامر PowerShell المشبوهة للمراجعة.
- **Protected Reports**: تقييد مجلد بيانات الأداة للمستخدم الحالي وSYSTEM وAdministrators.
- **Baseline**: مقارنة الخدمات والمهام والحسابات وقواعد Firewall عبر الزمن.
- **Incident Snapshot**: حفظ لقطة دفاعية للعمليات والاتصالات والأحداث والصحة.
- **AuditOnly**: تنفيذ الفحوصات والتقرير دون تغييرات.

## أرقام القائمة الجديدة

```text
[14] Security Score
[15] Advanced Security Audit
[16] Safe Security Hardening
[17] حماية السجلات والتقارير
```

## التنقل داخل الأداة

تم تنظيم القائمة إلى أقسام رئيسية بدل عرض جميع الوظائف دفعة واحدة:

```text
[1] فحص النظام والصحة
[2] الشبكة والاتصالات
[3] الخصوصية والتقارير
[4] الحسابات وتسجيل الدخول
[5] البرامج وبدء التشغيل
[6] الحماية المتقدمة
[7] التقارير وBaseline والتعافي
[0] خروج
```

داخل القوائم الفرعية استخدم `B` للرجوع. يظهر وضع التشغيل أعلى كل شاشة:

- `AUDIT ONLY`: فحص فقط دون تغييرات.
- `INTERACTIVE`: التغييرات تتطلب تأكيدًا ونقطة استعادة.

## التشغيل دون تغييرات

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Zahar-SystemMaintenance-Secure.ps1 -AuditOnly
```

## قواعد الأمان

- لا تختبر الأداة إلا على أجهزة تملكها أو لديك تصريح بإدارتها.
- لا تكسر كلمات مرور Wi-Fi ولا تحاول الدخول إلى شبكات الآخرين.
- لا تعطل الأداة Windows Update أو Microsoft Defender تلقائيًا.
- لا تحذف ملفات أو تعريفات أو سجلات أمان تلقائيًا.
- إعدادات التقوية قد تؤثر في أجهزة قديمة؛ اقرأ التحذير قبل كتابة `YES`.
- نقطة الاستعادة ليست نسخة احتياطية للملفات الشخصية.
- تقارير الشبكة والأحداث قد تحتوي IP وأسماء أجهزة ومسارات؛ لا تنشرها دون تنقيح.

## مواقع البيانات

```text
C:\ProgramData\ZaharSystemMaintenance\maintenance.log
C:\ProgramData\ZaharSystemMaintenance\Reports
C:\ProgramData\ZaharSystemMaintenance\Backups
C:\ProgramData\ZaharSystemMaintenance\Baselines
```

اختبر الإصدار أولًا على جهاز تجريبي أو بعد إنشاء نسخة احتياطية مستقلة.
