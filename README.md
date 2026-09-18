# pg-node-deploy

نصب کاملاً خودکار **PasarGuard Node (pg-node)** + هسته سفارشی **Xray** و **افزودن خودکار نود به پنل PasarGuard**.

> Ubuntu / Debian — نیاز به دسترسی root

---

## قابلیت‌ها

- نصب خودکار `pg-node` + هسته سفارشی Xray و نصب `nload`
- افزودن خودکار نود به پنل با نام `<IP>-<hostname>` (و چند instance روی یک سرور)
- نگه‌داشتن پورت/API Key/گواهی در نصب مجدد، و انتخاب پورت آزاد در نصب تازه
- هسته سفارشی این پروژه مصرف بی‌رویه حجم را حل کرده و با تمام‌شدن حجم، کانفیگ سریع قطع می‌شود

---

## تنظیم اطلاعات پنل (یک‌بار)

برای اینکه نود بعد از نصب خودکار در پنل ثبت شود، اطلاعات پنل را یک‌بار در یکی از این دو جا بگذار.

> دستورها با `wget` نوشته شده‌اند. اگر `curl` داری، هرجا `$(wget -qO- URL)` بود بگذار `$(curl -fsSL URL)`.

### روش ۱ — متغیر محیطی (سریع، برای یک اجرا)

```bash
sudo PANEL_URL="https://panel.example.com" \
     PANEL_USERNAME="admin" \
     PANEL_PASSWORD='change-me' \
     bash -c "$(wget -qO- https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/bootstrap.sh)"
```

### روش ۲ — فایل کانفیگ روی سرور (دائمی)

یک‌بار فایل را بساز:

```bash
sudo install -d -m 700 /etc/pg-node-deploy
sudo sh -c 'umask 077; cat > /etc/pg-node-deploy/panel.conf' <<'EOF'
PANEL_URL=https://panel.example.com
PANEL_USERNAME=admin
PANEL_PASSWORD=change-me
EOF
```

بعد نصب کن:

```bash
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/bootstrap.sh)"
```

از این به بعد روی همان سرور فقط همین خط آخر لازم است.

---

## نکته‌های نصب

اگر روی سرور نصب قبلی وجود داشته باشد، همین‌جا می‌پرسد (فقط وقتی ترمینال تعاملی باشد):

```
An existing 'pg-node' install was found at /opt/pg-node.
Press Enter to (re)install on it, or type a new instance name:
```

- `Enter` → همان instance با همان پورت/API Key/گواهی قبلی بازنویسی می‌شود (ثبت قبلی در پنل معتبر می‌ماند).
- نام جدید → instance جدا ساخته می‌شود و نام نود در پنل `<IP>-<نام>` می‌شود.
- در اجرای غیرتعاملی (بدون ترمینال) به‌صورت پیش‌فرض روی `pg-node` نصب می‌کند؛ برای instance دلخواه `NODE_INSTANCE` را ست کن.

اگر بدون اطلاعات پنل نصب کنی، مرحله افزودن به پنل رد می‌شود و بعداً می‌توانی این‌طور ثبت کنی:

```bash
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/register-node.sh)"
# یا برای instance خاص:
sudo NODE_INSTANCE=fin3 bash -c "$(wget -qO- https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/register-node.sh)"
```

---

## راهنمای دوستان

این متن را برای دوستت بفرست؛ فقط مقادیر پنل خودش را عوض کند:

```bash
sudo install -d -m 700 /etc/pg-node-deploy
sudo sh -c 'umask 077; cat > /etc/pg-node-deploy/panel.conf' <<'EOF'
PANEL_URL=https://YOUR-PANEL-URL
PANEL_USERNAME=YOUR-USERNAME
PANEL_PASSWORD=YOUR-PASSWORD
EOF

sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/bootstrap.sh)"
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
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/info.sh)"
# instance خاص:
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/info.sh) --instance fin3"
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
- برای امنیت بیشتر می‌توانی از روش متغیر محیطی استفاده کنی تا فایل ذخیره نشود (ولی رمز در history می‌ماند).

---

## English (short)

Automated PasarGuard `pg-node` + custom Xray installer that also **registers the node in the panel**.

- Panel node name: `<server-ip>-<hostname>` (or `<server-ip>-<instance>` for a custom instance).
- If `pg-node` is already installed, it asks for Enter (reinstall) or a new instance name.
- Uses random free ports when 62050/62051 are busy (fresh installs only).
- Reinstalling an existing instance stops its services first and keeps the existing ports, API key and certificate, so the panel entry stays valid.
- Custom Xray core fixes excessive config-volume usage and disconnects configs as soon as the quota is exhausted.

**Method 1 — env vars (one run):**

```bash
sudo PANEL_URL="https://panel.example.com" PANEL_USERNAME="admin" PANEL_PASSWORD='change-me' \
  bash -c "$(wget -qO- https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/bootstrap.sh)"
```

**Method 2 — config file on the server:**

```bash
sudo install -d -m 700 /etc/pg-node-deploy
sudo sh -c 'umask 077; cat > /etc/pg-node-deploy/panel.conf' <<'EOF'
PANEL_URL=https://panel.example.com
PANEL_USERNAME=admin
PANEL_PASSWORD=change-me
EOF

sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/bootstrap.sh)"
```

Info: `... info.sh [--instance NAME]` · Register only: `... register-node.sh [--instance NAME]`
