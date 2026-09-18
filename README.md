# pg-node-deploy

نصب کاملاً خودکار **PasarGuard Node (pg-node)** + هسته **Xray** و افزودن خودکار نود به پنل.

> Supported OS: Ubuntu / Debian (root access required)

---

## نصب یک‌خطی

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/bootstrap.sh)"
```

اسکریپت این کارها را انجام می‌دهد:

1. `apt update`
2. تنظیم و قفل‌کردن `/etc/resolv.conf`
3. نصب غیرتعاملی `pg-node` (اگر پورت 62050 اشغال باشد، یک پورت آزاد انتخاب می‌کند)
4. دانلود هسته Xray
5. نصب Xray، اتصال pg-node به آن و ری‌استارت سرویس

در پایان، **آی‌پی سرور، پورت، گواهی (Certificate) و API Key** چاپ می‌شود و نسخه‌ای هم در `/root/pg-node-info.txt` ذخیره می‌شود.

### نمایش دوباره اطلاعات نود

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/info.sh)"
```

---

## افزودن خودکار نود به پنل

اگر اطلاعات پنل مشخص شده باشد، بعد از نصب، نود به‌صورت خودکار در پنل ساخته می‌شود
(`POST /api/node` روی پنل PasarGuard). سه راه برای دادن اطلاعات پنل وجود دارد:

### روش ۱ (پیشنهادی) — GitHub Actions + Secrets

فقط یک‌بار مقادیر را در تنظیمات ریپو وارد کنید:
`Settings → Secrets and variables → Actions → New repository secret`

| Secret | توضیح | اجباری |
|---|---|---|
| `SSH_PRIVATE_KEY` | کلید SSH برای اتصال به سرور | بله |
| `PANEL_URL` | آدرس پنل، مثلاً `https://panel.example.com` | بله |
| `PANEL_USERNAME` | نام کاربری ادمین پنل | بله |
| `PANEL_PASSWORD` | رمز ادمین پنل | بله |
| `PANEL_CORE_CONFIG_ID` | شناسه Core Config در پنل (پیش‌فرض `1`) | خیر |

سپس از تب **Actions** ورک‌فلو **Install PasarGuard Node** را اجرا کنید و فقط
`host` سرور را بدهید. نصب و افزودن نود با هم انجام می‌شود.

> امن: پسوردها داخل ریپو ذخیره نمی‌شوند و در لاگ‌ها هم چاپ نمی‌شوند.

### روش ۲ — فایل کانفیگ روی سرور

یک‌بار فایل زیر را بسازید؛ از این به بعد هر اجرای `bootstrap.sh` نود را هم به پنل اضافه می‌کند.

```bash
sudo install -d -m 700 /etc/pg-node-deploy
sudo sh -c 'umask 077; cat > /etc/pg-node-deploy/panel.conf' <<'EOF'
PANEL_URL=https://panel.example.com
PANEL_USERNAME=admin
PANEL_PASSWORD=change-me
EOF
```

سپس نصب عادی:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/bootstrap.sh)"
```

برای افزودن دستی بعد از نصب هم:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/register-node.sh)"
```

### روش ۳ — متغیرهای محیطی (برای یک اجرا)

```bash
sudo PANEL_URL="https://panel.example.com" \
     PANEL_USERNAME="admin" \
     PANEL_PASSWORD="change-me" \
     bash -c "$(curl -fsSL https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/bootstrap.sh)"
```

> در این روش پسورد در history شل ذخیره می‌شود؛ ترجیحاً از روش ۱ یا ۲ استفاده کنید.

### اگر اطلاعات پنل داده نشود

نصب بدون هیچ مشکلی انجام می‌شود و فقط مرحله افزودن به پنل رد می‌شود. هر زمان خواستید:
`register-node.sh` را با یکی از سه روش بالا اجرا کنید.

---

## فایل‌ها

| فایل | کار |
|---|---|
| `bootstrap.sh` | نصب pg-node + Xray و (اختیاری) ثبت نود در پنل |
| `register-node.sh` | فقط ثبت نود در پنل با استفاده از اطلاعات موجود روی سرور |
| `info.sh` | نمایش IP، پورت، گواهی و API Key نود |
| `panel.conf.example` | نمونه فایل اطلاعات پنل |
| `.github/workflows/deploy.yml` | نصب از راه دور روی سرور via GitHub Actions |

---

## امنیت

- هرگز فایل `panel.conf` یا رمز پنل را داخل ریپو commit نکنید (در `.gitignore` هست).
- برای اتوماسیون از **GitHub Secrets** استفاده کنید.
- فایل `/etc/pg-node-deploy/panel.conf` با دسترسی `600` و مالک root نگه داشته می‌شود.

---

## English (short)

One-line install:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/bootstrap.sh)"
```

Auto-register the node in a PasarGuard panel by either:

- adding repo secrets `PANEL_URL`, `PANEL_USERNAME`, `PANEL_PASSWORD` (and optional `PANEL_CORE_CONFIG_ID`) and running the **Install PasarGuard Node** workflow, or
- creating `/etc/pg-node-deploy/panel.conf` (see `panel.conf.example`, `chmod 600`), or
- passing `PANEL_URL`, `PANEL_USERNAME`, `PANEL_PASSWORD` as environment variables.

Show node info: `sudo bash -c "$(curl -fsSL .../info.sh)"`
Register manually: `sudo bash -c "$(curl -fsSL .../register-node.sh)"`
