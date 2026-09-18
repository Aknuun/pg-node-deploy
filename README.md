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
- اگر پورت پیش‌فرض (62050 سرویس / 62051 API) اشغال باشد، در نصب تازه یک پورت آزاد تصادفی انتخاب می‌کند
- در **نصب مجدد** روی instance موجود، پورت‌ها، API Key و گواهی قبلی حفظ می‌شوند تا ورودی نود در پنل معتبر بماند
- هسته سفارشی Xray برای هر instance جداگانه نصب می‌شود و `XRAY_EXECUTABLE_PATH` همان instance ست می‌شود
- **افزودن خودکار نود به پنل** از طریق REST API پنل (Certificate + API Key خودکار خوانده می‌شود)
- هسته سفارشی این پروژه مشکل **مصرف بی‌رویه حجم** را حل کرده؛ به‌محض تمام‌شدن حجم کاربر، کانفیگ سریع قطع می‌شود

---

## تنظیم اطلاعات پنل (یک‌بار)

برای اینکه نود بعد از نصب خودکار در پنل ثبت شود، اطلاعات پنل را یک‌بار روی سرور قرار بده.

### روش ۱ (پیشنهادی) — فایل کانفیگ روی سرور

```bash
sudo install -d -m 700 /etc/pg-node-deploy
sudo sh -c 'umask 077; cat > /etc/pg-node-deploy/panel.conf' <<'EOF'
PANEL_URL=https://panel.example.com
PANEL_USERNAME=admin
PANEL_PASSWORD=change-me
EOF
```

یا نمونه را با `wget` دانلود کن و ویرایش کن:

```bash
sudo install -d -m 700 /etc/pg-node-deploy
sudo wget -qO /etc/pg-node-deploy/panel.conf \
  https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/panel.conf.example
sudo nano /etc/pg-node-deploy/panel.conf
sudo chmod 600 /etc/pg-node-deploy/panel.conf
```

### روش ۲ — متغیر محیطی (برای یک اجرا)

```bash
sudo PANEL_URL="https://panel.example.com" \
     PANEL_USERNAME="admin" \
     PANEL_PASSWORD='change-me' \
     bash -c "$(wget -qO- https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/bootstrap.sh)"
```

---

## نصب + افزودن خودکار

بعد از تنظیم اطلاعات پنل:

با **curl**:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/bootstrap.sh)"
```

با **wget**:

```bash
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/bootstrap.sh)"
```

اگر روی سرور نصب قبلی وجود داشته باشد، همین‌جا می‌پرسد (فقط وقتی ترمینال تعاملی باشد):

```
An existing 'pg-node' install was found at /opt/pg-node.
Press Enter to (re)install on it, or type a new instance name:
```

در اجرای غیرتعاملی (بدون ترمینال) به‌صورت پیش‌فرض روی `pg-node` نصب می‌کند؛ برای instance دلخواه `NODE_INSTANCE` را ست کن.

> در نصب مجدد (Enter روی instance موجود)، سرویس فعلی متوقف می‌شود و همان پورت‌ها، API Key و Certificate حفظ می‌شوند؛ پس ثبت قبلی نود در پنل دست‌نخورده می‌ماند.

اگر هیچ اطلاعات پنلی ندهی، نصب انجام می‌شود ولی مرحله افزودن به پنل رد می‌شود. بعداً این‌طور ثبت کن:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/register-node.sh)"
# یا برای instance خاص:
sudo NODE_INSTANCE=fin3 bash -c "$(curl -fsSL https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/register-node.sh)"
```

---

## راهنمای دوستان (کپی برداری)

این متن را برای دوستت بفرست؛ فقط کافیست سه مقدار پنل خودش را جایگزین کند:

```bash
# ۱) اطلاعات پنل خودت را بگذار (سه مقدار زیر را عوض کن)
sudo install -d -m 700 /etc/pg-node-deploy
sudo sh -c 'umask 077; cat > /etc/pg-node-deploy/panel.conf' <<'EOF'
PANEL_URL=https://YOUR-PANEL-URL
PANEL_USERNAME=YOUR-USERNAME
PANEL_PASSWORD=YOUR-PASSWORD
EOF

# ۲) نصب + ثبت خودکار در پنل
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/bootstrap.sh)"
```

هر نفر فقط مقادیر `PANEL_URL` / `PANEL_USERNAME` / `PANEL_PASSWORD` خودش را می‌گذارد؛ بقیه چیزها خودکار است.

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

---

## امنیت

- فایل `/etc/pg-node-deploy/panel.conf` را با دسترسی `600` و مالک root نگه دار.
- این فایل را جای عمومی آپلود یا داخل گیت‌هاب commit نکن.

---

## English (short)

Automated PasarGuard `pg-node` + custom Xray installer that also **registers the node in the panel**.

- Panel node name: `<server-ip>-<hostname>` (or `<server-ip>-<instance>` for a custom instance).
- If `pg-node` is already installed, it asks for Enter (reinstall) or a new instance name.
- Uses random free ports when 62050/62051 are busy (fresh installs only).
- Reinstalling an existing instance stops its services first and keeps the existing ports, API key and certificate, so the panel entry stays valid.
- Custom Xray core fixes excessive config-volume usage and disconnects configs as soon as the quota is exhausted.

Create the panel config once:

```bash
sudo install -d -m 700 /etc/pg-node-deploy
sudo sh -c 'umask 077; cat > /etc/pg-node-deploy/panel.conf' <<'EOF'
PANEL_URL=https://panel.example.com
PANEL_USERNAME=admin
PANEL_PASSWORD=change-me
EOF
```

Then install (curl or wget):

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/bootstrap.sh)"
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/bootstrap.sh)"
```

Info: `... info.sh [--instance NAME]` · Register only: `... register-node.sh [--instance NAME]`
