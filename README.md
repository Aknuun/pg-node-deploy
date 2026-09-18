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

برای اینکه نود بعد از نصب خودکار در پنل ثبت شود، اطلاعات پنل را یک‌بار در یکی از این سه جا بگذار.

### روش ۱ (پیشنهادی) — ریپوی خصوصی گیت‌هاب + توکن

> ⚠️ **فورک خصوصی از ریپوی عمومی ممکن نیست.** طبق قوانین گیت‌هاب، visibility یک فورک همیشه همان visibility ریپوی اصلی است؛ از یک ریپوی پابلیک فقط فورک پابلیک ساخته می‌شود. پس به‌جای فورک، یک **ریپوی خصوصی جدید** بساز.

**۱) در گیت‌هاب یک ریپوی خصوصی بساز** (مثلاً `pg-node-config`) و در آن فایل `panel.conf` را با این محتوا ایجاد کن:

```ini
PANEL_URL=https://panel.example.com
PANEL_USERNAME=admin
PANEL_PASSWORD=change-me
```

**۲) یک توکن بساز** از مسیر:
`Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token`
- Repository access: فقط همان ریپوی `pg-node-config`
- Permissions → **Contents: Read-only**
- Expiration: کوتاه (مثلاً ۷ روز)

**۳) روی سرور، کانفیگ را دانلود کن و نصب را اجرا کن:**

```bash
# این دو مقدار را عوض کن
REPO="USERNAME/pg-node-config"
TOKEN="github_pat_xxxxxxxxxxxx"

sudo install -d -m 700 /etc/pg-node-deploy
sudo curl -fsSL \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.github.raw" \
  "https://api.github.com/repos/${REPO}/contents/panel.conf" \
  -o /etc/pg-node-deploy/panel.conf
sudo chmod 600 /etc/pg-node-deploy/panel.conf

sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/bootstrap.sh)"
```

بعد از دانلود می‌توانی توکن را از گیت‌هاب **Revoke** کنی. اگر می‌خواهی برای سرورهای بعدی هم راحت باشد، توکن را روی سرور نگه دار (مثلاً `/etc/pg-node-deploy/.token` با `chmod 600`).

### روش ۲ — فایل کانفیگ مستقیم روی سرور

بدون هیچ گیت‌هاب و توکنی:

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
     bash -c "$(wget -qO- https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/bootstrap.sh)"
```

---

## نصب + افزودن خودکار

بعد از تنظیم اطلاعات پنل (هر یک از سه روش بالا):

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

این متن را برای دوستت بفرست. فقط کافیست طبق مراحل، اطلاعات پنل خودش را در یک ریپوی خصوصی بگذارد و خط آخر را اجرا کند.

**الف) یک‌بار در گیت‌هاب:**

1. یک ریپوی **خصوصی** بساز، مثلاً `pg-node-config`.
2. فایل `panel.conf` را با اطلاعات پنل خودت بساز:

```ini
PANEL_URL=https://panel.example.com
PANEL_USERNAME=admin
PANEL_PASSWORD=change-me
```

3. یک **Fine-grained token** بساز با دسترسی فقط روی همین ریپو و `Contents: Read-only`.

**ب) روی سرور:**

```bash
# مقادیر زیر را عوض کن
REPO="USERNAME/pg-node-config"
TOKEN="github_pat_xxxxxxxxxxxx"

sudo install -d -m 700 /etc/pg-node-deploy
sudo curl -fsSL \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.github.raw" \
  "https://api.github.com/repos/${REPO}/contents/panel.conf" \
  -o /etc/pg-node-deploy/panel.conf
sudo chmod 600 /etc/pg-node-deploy/panel.conf

sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main/bootstrap.sh)"
```

اگر ریپوی خصوصی نمی‌خواهی، جای مرحله «الف» همین دستور را بزن:

```bash
sudo install -d -m 700 /etc/pg-node-deploy
sudo sh -c 'umask 077; cat > /etc/pg-node-deploy/panel.conf' <<'EOF'
PANEL_URL=https://YOUR-PANEL
PANEL_USERNAME=YOUR-USER
PANEL_PASSWORD=YOUR-PASS
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
- این فایل و توکن گیت‌هاب را جای عمومی آپلود یا commit نکن.
- ریپوی نگه‌داری اطلاعات پنل را **خصوصی** بساز؛ ریپوی عمومی یعنی لو رفتن رمز پنل.
- توکن را با کمترین دسترسی (`Contents: Read-only`) و کوتاه‌ترین انقضا بساز و در صورت امکان بعد از دانلود Revoke کن.

---

## English (short)

Automated PasarGuard `pg-node` + custom Xray installer that also **registers the node in the panel**.

- Panel node name: `<server-ip>-<hostname>` (or `<server-ip>-<instance>` for a custom instance).
- If `pg-node` is already installed, it asks for Enter (reinstall) or a new instance name.
- Uses random free ports when 62050/62051 are busy (fresh installs only).
- Reinstalling an existing instance stops its services first and keeps the existing ports, API key and certificate, so the panel entry stays valid.
- Custom Xray core fixes excessive config-volume usage and disconnects configs as soon as the quota is exhausted.

Panel credentials can live in a **private** GitHub repo (note: a private fork of a public repo is not possible — create a new private repo) and be fetched with a fine-grained token:

```bash
REPO="USERNAME/pg-node-config"; TOKEN="github_pat_xxx"
sudo install -d -m 700 /etc/pg-node-deploy
sudo curl -fsSL -H "Authorization: Bearer ${TOKEN}" -H "Accept: application/vnd.github.raw" \
  "https://api.github.com/repos/${REPO}/contents/panel.conf" -o /etc/pg-node-deploy/panel.conf
sudo chmod 600 /etc/pg-node-deploy/panel.conf
```

Or create it directly on the server:

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
