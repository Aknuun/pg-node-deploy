# pg-node-deploy

نصب کاملاً خودکار **PasarGuard Node (pg-node)** + هسته سفارشی **Xray** و **افزودن خودکار نود به پنل PasarGuard**.

> Ubuntu / Debian — نیاز به دسترسی root

---

## قابلیت‌ها

- نصب غیرتعاملی `pg-node` و هسته Xray
- **نام‌گذاری نود در پنل:** `<IP سرور>-<hostname>` (مثلاً `204.168.129.199-fin2`)
- اگر روی سرور `pg-node` از قبل نصب باشد، می‌پرسد:
  - `Enter` → نصب/بازنویسی روی همان instance موجود
  - نام جدید (مثلاً `fin3`) → نصب instance جدید و نام نود در پنل `<IP>-fin3`
- اگر پورت پیش‌فرض (62050 سرویس / 62051 API) اشغال باشد، یک پورت آزاد تصادفی انتخاب می‌کند
- هسته سفارشی Xray برای هر instance جداگانه نصب می‌شود و `XRAY_EXECUTABLE_PATH` همان instance ست می‌شود
- **افزودن خودکار نود به پنل** از طریق REST API پنل (Certificate + API Key خودکار خوانده می‌شود)
- هسته سفارشی این پروژه مشکل **مصرف بی‌رویه حجم** را حل کرده؛ به‌محض تمام‌شدن حجم کاربر، کانفیگ سریع قطع می‌شود

---

## افزودن به پنل (یک‌بار تنظیم کن)

یکی از سه روش زیر را یک‌بار انجام بده؛ بعد از آن هر نصب خودکار در پنل ثبت می‌شود.

### روش ۱ (پیشنهادی) — GitHub Actions + Secrets

`Settings → Secrets and variables → Actions`:

| Secret | توضیح | اجباری |
|---|---|---|
| `SSH_PRIVATE_KEY` | کلید SSH برای اتصال به سرور | بله |
| `PANEL_URL` | آدرس پنل، مثلاً `https://panel.example.com` | بله |
| `PANEL_USERNAME` | نام کاربری ادمین پنل | بله |
| `PANEL_PASSWORD` | رمز ادمین پنل | بله |
| `PANEL_CORE_CONFIG_ID` | شناسه Core Config (پیش‌فرض `1`) | خیر |

سپس از تب **Actions** ورک‌فلو **Install PasarGuard Node** را اجرا کن و فقط `host` (و در صورت نیاز `instance`) را بده.

### روش ۲ — فایل کانفیگ روی سرور

```bash
sudo install -d -m 700 /etc/pg-node-deploy
sudo sh -c 'umask 077; cat > /etc/pg-node-deploy/panel.conf' <<'EOF'
PANEL_URL=https://panel.example.com
PANEL_USERNAME=admin
PANEL_PASSWORD=change-me
EOF
```

### روش ۳ — متغیر محیطی (برای یک اجرا)

```bash
sudo PANEL_URL="https://panel.example.com" \
     PANEL_USERNAME="admin" \
     PANEL_PASSWORD='change-me' \
     bash -c "$(curl -fsSL https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/bootstrap.sh)"
```

---

## نصب + افزودن خودکار

بعد از تنظیم یکی از روش‌های بالا:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/bootstrap.sh)"
```

اگر روی سرور نصب قبلی وجود داشته باشد، همین‌جا می‌پرسد (فقط وقتی ترمینال تعاملی باشد):

```
An existing 'pg-node' install was found at /opt/pg-node.
Press Enter to (re)install on it, or type a new instance name:
```

در حالت غیرتعاملی (Actions) به‌صورت پیش‌فرض روی `pg-node` نصب می‌کند؛ برای instance دلخواه `NODE_INSTANCE` را ست کن.

اگر هیچ اطلاعات پنلی ندهی، نصب انجام می‌شود ولی مرحله افزودن به پنل رد می‌شود. بعداً این‌طور ثبت کن:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/register-node.sh)"
# یا برای instance خاص:
sudo NODE_INSTANCE=fin3 bash -c "$(curl -fsSL https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/register-node.sh)"
```

---

## نام‌گذاری و چند نود روی یک سرور

- نام نود در پنل:
  - instance پیش‌فرض `pg-node` → `<IP>-<hostname>` (مثلاً `204.168.129.199-fin2`)
  - instance دلخواه `fin3` → `<IP>-fin3`
- هر instance مسیرهای جدا دارد: `/opt/<name>` ، `/var/lib/<name>` ، سرویس `<name>-service`
- هسته Xray هم داخل `/var/lib/<name>/xray-core` قرار می‌گیرد

---

## مشاهده اطلاعات نود

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/info.sh)"
# instance خاص:
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/info.sh) --instance fin3"
```

خروجی شامل IP، پورت سرویس، پورت API، Certificate و API Key است و در `/root/<instance>-info.txt` هم ذخیره می‌شود.

---

## فایل‌ها

| فایل | کار |
|---|---|
| `bootstrap.sh` | نصب pg-node + Xray و (اختیاری) ثبت نود در پنل |
| `register-node.sh` | فقط ثبت نود در پنل با اطلاعات موجود روی سرور |
| `info.sh` | نمایش IP، پورت‌ها، گواهی و API Key هر instance |
| `panel.conf.example` | نمونه فایل اطلاعات پنل |
| `.github/workflows/deploy.yml` | نصب از راه دور روی سرور via GitHub Actions |

---

## امنیت

- هرگز `panel.conf` یا رمز پنل را داخل ریپو commit نکن (در `.gitignore` هست).
- برای اتوماسیون از **GitHub Secrets** استفاده کن.
- فایل `/etc/pg-node-deploy/panel.conf` با دسترسی `600` و مالک root نگه داشته می‌شود.

---

## English (short)

Automated PasarGuard `pg-node` + custom Xray installer that also **registers the node in the panel**.

- Panel node name: `<server-ip>-<hostname>` (or `<server-ip>-<instance>` for a custom instance).
- If `pg-node` is already installed, it asks for Enter (reinstall) or a new instance name.
- Uses random free ports when 62050/62051 are busy.
- Custom Xray core fixes excessive config-volume usage and disconnects configs as soon as the quota is exhausted.

Configure panel credentials once (GitHub Secrets `PANEL_URL`, `PANEL_USERNAME`, `PANEL_PASSWORD`, optional `PANEL_CORE_CONFIG_ID`), or create `/etc/pg-node-deploy/panel.conf`, then run:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/bootstrap.sh)"
```

Info: `... info.sh [--instance NAME]` · Register only: `... register-node.sh [--instance NAME]`
