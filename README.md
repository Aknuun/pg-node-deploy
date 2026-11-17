# pg-node-deploy

نصب کاملاً خودکار **PasarGuard Node (pg-node)** + هسته سفارشی **Xray** و **افزودن خودکار نود به پنل PasarGuard**.

> Ubuntu / Debian — نیاز به دسترسی root

---

## قابلیت‌ها

- **اولین سؤال**: نصب مستقیم شروع شود یا وارد **محیط CLI** شوی؟ با زدن `n` منویی باز می‌شود که همان‌جا می‌توانی فیلتر DNS را روشن/خاموش کنی، zram و سواپ و BBR و نوع کر را عوض کنی، نودهای نصب‌شده را ببینی یا یک نود را حذف کنی، و بعد نصب را شروع کنی
- نصب خودکار `pg-node` + هسته سفارشی Xray و نصب `nload`
- افزودن خودکار نود به پنل با نام `<IP>-<4حرف-اول-هاست>-<دیتاسنتر>` (مثلاً `178.104.242.27-nure-hetzner`) و چند instance روی یک سرور
- نگه‌داشتن پورت/API Key/گواهی در نصب مجدد، و انتخاب پورت آزاد در نصب تازه
- **هسته پیش‌فرض استوک Xray است** (بدون رشد رم)؛ اگر هسته اختصاصی این پروژه را خواستی، در سؤال «هسته سفارشی» بله بزن یا `INSTALL_CUSTOM_CORE=1` بده (آن هسته مصرف حجم را دقیق کنترل می‌کند و با تمام‌شدن حجم، کانفیگ سریع قطع می‌شود)
- پرسش **zram** (سواپ فشرده در رم) با پیش‌فرض خیر؛ اگر ماژول نبود خودش `linux-modules-extra` را نصب می‌کند
- بعد از نصب یک **health check** می‌زند: پورت gRPC/API، پروسه xray، بالا بودن کانتینر، فایل env، رم آزاد، سواپ و lost-retransmit
- **محدودکردن لاگ‌ها**: سقف journald (200M) و logrotate برای لاگ‌های نود/xray، تا دیسک پر نشود
- فلگ‌های خط فرمان: `--yes` (بدون پرسش)، `--repair`، `--uninstall`، `--help`، `--version`
- نمایش پیشرفت مرحله‌ها با نوار رنگی، باکس خلاصه در پایان، و رابط **فارسی** وقتی `LANG_CODE=fa` (یا زبان سیستم fa باشد)
- تنظیم دستی اندازه سواپ با `SWAP_SIZE_MB=4096`
- در ابتدای نصب (بعد از نام نود) می‌پرسد که **فایل سواپ** متناسب با رم سرور ساخته شود یا نه — با زدن اینتر (پیش‌فرض) ساخته می‌شود (برابر رم، حداقل ۲ و حداکثر ۸ گیگ) و در `/etc/fstab` ثبت می‌گردد؛ برای رد کردن `ENABLE_SWAP=0`
- در ابتدای نصب (همراه بقیه سؤال‌ها) می‌پرسد که **BBR + fq** فعال شود یا نه — با زدن اینتر (پیش‌فرض) فعال می‌شود و در مرحله ۳ اعمال می‌گردد؛ برای رد کردن `ENABLE_BBR=0`

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
- نام جدید → instance جدا ساخته می‌شود و نام نود در پنل `<IP>-<4حرف>-<دیتاسنتر>-<نام>` می‌شود.
- در اجرای غیرتعاملی (بدون ترمینال) به‌صورت پیش‌فرض روی `pg-node` نصب می‌کند؛ برای instance دلخواه `NODE_INSTANCE` را ست کن.
- override دستی دیتاسنتر: `DATACENTER=hetzner` یا داخل `panel.conf` بگذار `DATACENTER=hetzner` (پیش‌فرض: تشخیص خودکار از روی IP با ip-api.com).

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

- نام نود در پنل (`IP-4حرف-دیتاسنتر`):
  - instance پیش‌فرض `pg-node` → `<IP>-<4حرف-اول-هاست>-<دیتاسنتر>` (مثلاً `178.104.242.27-nure-hetzner`)
  - instance دلخواه `fin3` → `<IP>-<4حرف>-<دیتاسنتر>-fin3` (برای یکتا موندن روی یک سرور)
  - دیتاسنتر خودکار از روی IP تشخیص داده می‌شود (hetzner, ovh, digitalocean, vultr, ...)، اگر غلط بود `DATACENTER=...` بده.
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

- Panel node name: `<IP>-<first4-hostname>-<datacenter>` (e.g. `178.104.242.27-nure-hetzner`; custom instance appends `-<instance>`).
- If `pg-node` is already installed, it asks for Enter (reinstall) or a new instance name.
- Uses random free ports when 62050/62051 are busy (fresh installs only).
- Reinstalling an existing instance stops its services first and keeps the existing ports, API key and certificate, so the panel entry stays valid.
- **Default core is the stock Xray** (no memory creep); the project's custom core (accurate volume tracking, cuts the config as soon as the quota is exhausted) is opt-in via the "custom core" question or `INSTALL_CUSTOM_CORE=1`.
- Also asks up front about **zram** (compressed swap in RAM), default **no**; it installs `linux-modules-extra` when the module is missing.
- Ends with a **health check**: gRPC/API ports, xray process, container up, env file, free RAM, swap use and lost retransmits.
- **Caps logs**: journald limit (200M) + logrotate for node/xray logs so the disk cannot fill.
- CLI flags: `--yes` (no questions), `--repair`, `--uninstall`, `--help`, `--version`.
- Coloured per-step progress bar, a summary box at the end, and a **Persian UI** when `LANG_CODE=fa` (or the system locale is fa).
- Manual swap size with `SWAP_SIZE_MB=4096`.
- The **first question** is \"start the install directly?\" — answering `n` opens a small **CLI menu** where you can toggle the filtered DNS, zram, swap, BBR and the xray core type (applied immediately where it makes sense), list installed nodes, remove one, and then start the install
- It asks up front (right after the node name) whether to create a **swap file sized to the server's RAM** — **Enter = yes** (equal to RAM, min 2G, max 8G, saved in `/etc/fstab`); `ENABLE_SWAP=0` skips it
- It asks up front (with the other setup questions) whether to enable **BBR + fq** (kernel tuning for lossy/high-latency links) — **Enter = yes**, applied in Step 3; `ENABLE_BBR=0` skips it.
- Interactive run asks, besides the node name: block adult content with a filtered (Family) DNS? (default **yes**) and install the custom Xray core? (default **no**). `BLOCK_PORN=0` removes a previously applied filtered DNS and restores the server default (systemd-resolved stub, 127.0.0.53); `INSTALL_CUSTOM_CORE=0` installs the official XTLS release instead of the custom core.

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
