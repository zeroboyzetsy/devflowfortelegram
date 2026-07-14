# Arch Linux + Hyprland — автоматический установщик для ASUS Zenbook S16 (UM5606WA)

Полностью автоматизированная установка Arch Linux, заточенная под конкретное железо
**ASUS Zenbook S16 UM5606WA** (AMD Ryzen AI 9 HX 370 «Strix Point», Radeon 890M,
OLED 2880×1800@120 Гц, Wi-Fi 7 MediaTek MT7925), со следующей конфигурацией:

| Компонент | Выбор |
|---|---|
| Загрузчик | **Limine** (UEFI, новый синтаксис `limine.conf`) |
| Файловая система | **btrfs без снапшотов** (сабволюмы `@ @home @log @cache @tmp @pkg`, zstd-сжатие) |
| Ядро | **только `linux-cachyos`** (EEVDF + ThinLTO + AutoFDO/Propeller, sched_ext), из znver4-репозиториев CachyOS |
| Рабочий стол | **Hyprland** 0.55+ (Wayland) |
| Экран входа | **SDDM + sddm-astronaut-theme** (Qt6, анимированные варианты) |
| Питание | amd-pstate-epp + power-profiles-daemon + asus-wmi (профили, лимит заряда 80%) |
| Память | zram (zstd) через `cachyos-settings`, systemd-oomd |
| Планировщики | ananicy-cpp + sched-ext `scx_lavd` (режим Auto) |

Скрипты: `install.sh` (Этап 1, live-ISO) → `chroot-setup.sh` (Этап 2, chroot, вызывается
автоматически) → `post-install.sh` (Этап 3, после первой загрузки, от пользователя).

---

## 0. Перед установкой — ОБЯЗАТЕЛЬНО

1. **Обновите BIOS** (в Windows или через EZ Flash: `F2` при загрузке → `F7` → Tool → EZ Flash 3).
   Старые прошивки имеют баг с периодическими фризами тачпада на 1–2 секунды; это чинится
   именно обновлением BIOS (позже можно обновляться прямо из Linux через `fwupd`).
2. **Бэкап данных** — установщик стирает NVMe-диск целиком (Windows не сохраняется).
3. Скачайте свежий [archiso](https://archlinux.org/download/), запишите на флешку
   (`dd if=archlinux-*.iso of=/dev/sdX bs=4M oflag=sync status=progress`).

## 1. Загрузка live-ISO (важный нюанс OLED-панели)

При загрузке флешки в меню ISO нажмите **`e`** и допишите в конец строки параметров:

```
amdgpu.dcdebugmask=0x600
```

Без него OLED-панель Strix Point может зависнуть ещё в live-окружении (баг PSR-SU/Panel
Replay). Установщик добавит этот параметр в установленную систему автоматически.

## 2. Запуск установки

```bash
# Wi-Fi в live-окружении:
iwctl station wlan0 connect "<имя_сети>"

# Скачать три скрипта (замените URL на свой raw-адрес):
curl -LO https://raw.githubusercontent.com/<user>/<repo>/<branch>/arch-zenbook-s16/install.sh
curl -LO https://raw.githubusercontent.com/<user>/<repo>/<branch>/arch-zenbook-s16/chroot-setup.sh
curl -LO https://raw.githubusercontent.com/<user>/<repo>/<branch>/arch-zenbook-s16/post-install.sh
chmod +x install.sh chroot-setup.sh post-install.sh

# Запуск (все параметры можно переопределить):
HOSTNAME=zenbook USERNAME=ilya TIMEZONE=Europe/Moscow ./install.sh
```

Переменные: `DISK` (по умолчанию — первый NVMe), `HOSTNAME`, `USERNAME`, `TIMEZONE`,
`LOCALE_MAIN` (по умолчанию `ru_RU.UTF-8`), `KEYMAP_CONSOLE`, `ESP_SIZE` (2 GiB),
`BTRFS_COMPRESS`, `SDDM_THEME_VARIANT` (см. §6).

Скрипт попросит ввести слово `ERASE` перед стиранием диска и пароли root/пользователя
на этапе chroot. После перезагрузки войдите через SDDM и запустите `./post-install.sh`.

---

## 3. Что и почему делает установщик

### 3.1 Разметка и btrfs (без снапшотов)

* GPT: `p1` — ESP **2 GiB** (FAT32, монтируется в **`/boot`**), `p2` — btrfs на всё остальное.
  ESP такой большой потому, что **Limine читает только FAT** — ядра и initramfs живут на ESP.
* Сабволюмы: `@` (корень), `@home`, `@log`, `@cache`, `@tmp`, `@pkg` (кэш pacman).
  Снапшоты **не используются** (по требованию): snapper/timeshift не ставятся, хуков нет.
  Разделение на сабволюмы всё равно полезно: логи/кэш можно чистить и монтировать отдельно.
* Опции монтирования: `noatime` (нет записи времени доступа — меньше износ SSD),
  **`compress-force=zstd:1`** (прозрачное сжатие: на быстром NVMe уровень 1 почти бесплатен
  по CPU и часто *ускоряет* чтение; хотите плотнее — `BTRFS_COMPRESS=compress=zstd:3`),
  `ssd`, `space_cache=v2`, `discard=async` — последние три являются умолчаниями современных
  ядер и прописаны явно для наглядности.
* `fstrim.timer` **не включён**: TRIM уже выполняется на лету через `discard=async`.
  Включён `btrfs-scrub@-.timer` — ежемесячная проверка контрольных сумм.
* Для каталогов с образами ВМ/БД (если появятся) отключайте CoW вручную:
  `chattr +C /путь/к/пустому/каталогу` (заодно отключает сжатие и чексуммы для новых файлов).

### 3.2 Ядро CachyOS и его репозитории

* Подключаются репозитории **`cachyos-znver4`** + `[cachyos]` **выше** `[core]`.
  Zen 5 (Strix Point) использует znver4-tier — отдельных znver5-репозиториев не существует,
  Zen 4/5 делят одни пакеты, собранные под x86-64-v4/znver4. Это до ~10% производительности
  на ряде нагрузок просто за счёт пересобранных пакетов.
* Ванильному pacman прописывается `Architecture = x86_64 x86_64_v3 x86_64_v4` — иначе он
  отвергнет оптимизированные пакеты. Форк pacman от CachyOS не ставится (наш вариант проще
  и не трогает базовый инструментарий).
* Ставится **только `linux-cachyos`** (+`-headers`): EEVDF-планировщик, Clang ThinLTO,
  AutoFDO/Propeller-профилирование, 1000 Гц, полная поддержка **sched_ext**.
  Ключ GPG репозиториев: `F3B607488DB35A47`.
* **Риск единственного ядра**: fallback-ядра нет (по требованию). Подстраховки:
  (а) вторая запись Limine с fallback-initramfs, (б) chroot с live-флешки чинит всё остальное.
  Если хотите страховку — `pacman -S linux-lts` и добавьте запись в `/boot/limine.conf`.
* Дополнительно из реп CachyOS: `cachyos-settings`, `ananicy-cpp`+`cachyos-ananicy-rules`,
  `scx-scheds`+`scx-tools` (см. §3.5).

### 3.3 Загрузчик Limine

* `BOOTX64.EFI` копируется в `ESP/EFI/limine/`, запись в NVRAM создаёт `efibootmgr`
  (Limine сам себя не регистрирует). Если NVRAM-запись не создалась — ставится
  fallback-путь `EFI/BOOT/BOOTX64.EFI`.
* `/boot/limine.conf` — новый синтаксис (v8+…v12+): опции `имя: значение`, записи `/Имя`,
  `protocol: linux`, `path: boot():/vmlinuz-linux-cachyos`, `cmdline: …`, `module_path: …`.
  Микрокод AMD **не** указывается отдельной строкой: хук `microcode` mkinitcpio (v38+)
  встраивает его в initramfs.
* Обновление EFI-бинаря при апдейте пакета `limine` — pacman-хук `99-limine.hook`.
  Сам `limine.conf` статичен: имена `vmlinuz-linux-cachyos` не меняются между версиями ядра.
* Красивое меню: `interface_branding`, крупный шрифт `term_font_scale: 2x2` для HiDPI;
  можно добавить обои — положите PNG на ESP и раскомментируйте `wallpaper:` в конфиге.
* Альтернатива на будущее: пакеты `limine-entry-tool` + `limine-mkinitcpio-hook`
  (есть в репах CachyOS) автогенерируют записи при установке/удалении ядер. Не включены,
  чтобы не иметь двух «хозяев» одного `limine.conf`.

### 3.4 Параметры ядра (cmdline) — каждый объяснён

```
root=UUID=… rootflags=subvol=/@ rw rootfstype=btrfs quiet nowatchdog zswap.enabled=0 amdgpu.dcdebugmask=0x600
```

| Параметр | Зачем |
|---|---|
| `quiet` | чистая загрузка без простыни логов |
| `nowatchdog` | десктопу watchdog не нужен: меньше прерываний/энергопотребления (плюс blacklist модуля `sp5100_tco`) |
| `zswap.enabled=0` | swap живёт в zram; zswap ломал бы его статистику/эффективность |
| `amdgpu.dcdebugmask=0x600` | **ключевой для UM5606WA**: отключает PSR-SU + Panel Replay — лечит зависания/фризы OLED (в т.ч. после сна). На ядрах ≥6.15 PSR-SU для проблемных панелей отключают по умолчанию — можно попробовать убрать параметр (см. §8) |
| `amd_pstate=active` — **не нужен** | драйвер amd-pstate-epp активен по умолчанию с ядра 6.5; проверка: `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver` → `amd-pstate-epp` |
| `mitigations=off` — **не рекомендуем** | Zen 5 аппаратно не подвержен Inception/SRSO; замеры Phoronix показывают ~0% выигрыша — вы теряете защиту Spectre v1/v2 даром |

### 3.5 Глубокий тюнинг производительности и батареи

* **CPU/питание**: `power-profiles-daemon` (0.21+ учитывает батарею: `balanced` даёт EPP
  `balance_performance` от сети и `balance_power` от батареи). Профили железа ASUS
  (quiet/balanced/performance) работают через ядрёный `asus-wmi` — **asusctl не обязателен**
  (это Zenbook, не ROG; всё нужное уже в ядре). **TLP не ставить** — конфликтует с PPD.
* **Фан-профили прошивки** (standard/quiet/high/full): AUR-пакет `asus-5606-fan-state-git`,
  команда `sudo fan_state set quiet` (ставится Этапом 3).
* **Лимит заряда 80%** — udev-правило пишет в `charge_control_end_threshold` (здоровье АКБ;
  поменять цифру: `/etc/udev/rules.d/90-battery-threshold.rules`).
* **zram** (сжатый swap в RAM): настраивается пакетом `cachyos-settings`
  (`zram-size = ram`, zstd, swappiness → 150, отключение zswap по udev). Хотите классические
  арчевики-значения — создайте `/etc/systemd/zram-generator.conf` с `zram-size = ram / 2`
  (файл в `/etc` переопределит вендорский).
* **systemd-oomd** — при исчерпании swap/давлении памяти убивает виновника, а не вешает систему.
* **ananicy-cpp** + правила CachyOS — автоматические приоритеты (nice/ionice) процессов.
* **sched-ext `scx_lavd`** через `scx_loader` (режим Auto) — планировщик с фокусом на
  латентность, заметно отзывчивее под нагрузкой; выключить: `systemctl disable --now scx_loader`.
* **journald ≤200 MB, месяц хранения; coredump ≤1 GB** — логи не съедают SSD.
* **makepkg**: `-march=native` (= znver5), `!debug`, LTO, `-j$(nproc)` — AUR-пакеты
  собираются под ваш CPU.
* **pacman**: `ParallelDownloads=10`, `Color`, `ILoveCandy`, `VerbosePkgLists`, multilib,
  еженедельный `paccache.timer`.
* **VA-API** (аппаратное видео на VCN): `libva-mesa-driver`, `LIBVA_DRIVER_NAME=radeonsi`
  уже в конфиге Hyprland; mpv: `hwdec=vaapi`; Firefox: `media.ffmpeg.vaapi.enabled=true`.
  VDPAU не ставится — mesa 25.3 удалила его для radeonsi, VA-API — единственный путь.
* **Hyprland**: масштаб 1.5 (логическое 1920×1200 — целочисленно делит 2880×1800),
  `vfr = true` (главная экономия батареи композитором), `vrr = 2` (FreeSync только в
  полноэкранных приложениях; `vrr = 1` на статичном столе даёт OLED-мерцание),
  `xwayland:force_zero_scaling` (нет мыла в XWayland), блюр выключен (дорог на 2880×1800).

### 3.6 Железо UM5606WA — что работает и как

| Железо | Статус | Примечание |
|---|---|---|
| Wi-Fi 7 MT7925 | ✅ из коробки | драйвер `mt7925e`, прошивка в `linux-firmware-mediatek` |
| Bluetooth MT7925 | ✅ | udev-правило отключает USB-autosuspend (лечит таймауты `-110` после сна) |
| Динамики (4 шт., ALC294) | ✅ на ядрах ≥6.13 | это **не** Cirrus-конфигурация; `sof-firmware` не нужен и не ставится, нужен `alsa-ucm-conf` |
| Микрофон цифровой (DMIC-массив) | ❌ не работает | ограничение Linux (ACP PDM); используйте «Internal Stereo Microphone» (аналоговый) или гарнитуру |
| Клавиатурная подсветка | ✅ (≥6.13) | Fn+F4 циклит 4 уровня |
| Suspend (s2idle) | ✅ (≥6.14) | S3 отключён прошивкой; расход во сне ~1 Вт (~30%/сутки) |
| Веб-камера + IR | ✅ | обычная UVC; face-unlock: `./post-install.sh --face-unlock` (howdy) |
| Сканер отпечатков | — | его физически нет (только IR-камера) |
| NPU (Ryzen AI, XDNA) | ⚙️ | драйвер `amdxdna` в ядре 6.14+; юзерспейс: `./post-install.sh --npu` (xrt + xrt-plugin-amdxdna) — только для экспериментов |
| OLED 120 Гц | ✅ | см. PSR-параметр §3.4 и OLED-гигиену §7 |

---

## 4. Про https://github.com/ilyamiro/nixos-configuration — можно ли поставить?

**Напрямую — нет.** Это конфигурация **NixOS** (`configuration.nix` + home-manager);
модули NixOS исполняются только менеджером Nix на самой NixOS, на Arch они бессмысленны.
Сам автор в README предупреждает даже пользователей NixOS: «Do NOT install it on NixOS…».

**Но по сути — да, и официальным способом.** 90% этого репозитория — не Nix, а портируемые
дотфайлы: Quickshell (QML) рабочий стол для Hyprland (панель, локскрин, лаунчер,
уведомления), конфиги kitty/rofi/cava/matugen. Автор поддерживает зеркальный репозиторий
**[ilyamiro/imperative-dots](https://github.com/ilyamiro/imperative-dots)** — те же дотфайлы
с установщиком **именно для Arch/CachyOS**. Наш `post-install.sh` даёт два пути:

* `./post-install.sh --ilyamiro` — официальный установщик автора.
  Знайте: он делает бэкап `~/.config`, **отправляет анонимную телеметрию** (UUID, ОС, ядро,
  RAM, CPU/GPU) и **заменяет тему SDDM** astronaut на свою `matugen-minimal`. Вернуть astronaut:

  ```bash
  echo -e "[Theme]\nCurrent=sddm-astronaut-theme" | sudo tee /etc/sddm.conf.d/10-theme.conf
  ```

* `./post-install.sh --ilyamiro-manual` — ручной порт без телеметрии: клонирование
  `imperative-dots`, копирование `.config/{hypr,kitty,cava,matugen,nvim,zsh}` (с бэкапом),
  установка пакетов (`quickshell-git`, `matugen-bin`, `rofi`, `swayosd-git`, `mpvpaper`…)
  и замена `swww → awww` в скриптах (пакет `swww` архивирован, в репах Arch его преемник `awww`).

Третий, теоретический путь — standalone home-manager на Arch — **не рекомендуется**:
в `home.nix` захардкожены имя пользователя `ilyamiro`, `/home/ilyamiro` и абсолютные пути
`/etc/nixos/...` в каждом симлинке; пришлось бы патчить всё дерево.

Примечание: автор анонсировал v2.0 — компоситор-независимую Quickshell-конфигурацию
(в т.ч. под Niri и MangoWM); текущая стабильная ветка для Arch — v1.x.

## 5. Hyprland vs MangoWC (Mango) — почему Hyprland

Вы просили совет между Hyprland и «mangodw» (имеется в виду MangoWC, ныне переименован в
**Mango/MangoWM**). Рекомендация — **Hyprland**, и вот почему (состояние на середину 2026):

| | Hyprland | Mango (MangoWC) |
|---|---|---|
| Зрелость | 0.55.x, 36k+ звёзд, собственный стек Aquamarine | 0.15.x (pre-1.0), 3k звёзд, dwl+wlroots+scenefx |
| Пакеты | весь стек в официальном `extra` | только AUR (`mangowm`) |
| Документация | огромная вики + тысячи гайдов | тонкая, частично коммьюнити |
| Экосистема | hyprlock/hypridle/portal/плагины/4 крупных фреймворка дотфайлов | generic wlroots-инструменты |
| Риски | переход конфига на Lua (0.55+; .conf пока работает) | «lingering GPU compatibility issues» в собственных доках |

Mango — интересный лёгкий композитор (и ilyamiro v2.0 планирует его поддержку — сможете
попробовать позже второй сессией), но как ежедневная система с «красивым» столом Hyprland
сейчас объективно сильнее. На AMD оба работают без драйверных плясок.

## 6. Экран входа: SDDM + astronaut

Тема [sddm-astronaut-theme](https://github.com/Keyitdev/sddm-astronaut-theme) (Qt6):
анимированные фоны, виртуальная клавиатура. Вариант выбирается при установке переменной
`SDDM_THEME_VARIANT` или потом одной командой:

```bash
sudo sed -i 's|^ConfigFile=.*|ConfigFile=Themes/pixel_sakura.conf|' \
    /usr/share/sddm/themes/sddm-astronaut-theme/metadata.desktop
```

Варианты: `astronaut`, `black_hole`, `cyberpunk`, `hyprland_kath`, `jake_the_dog`,
`japanese_aesthetic`, `pixel_sakura`, `pixel_sakura_static`, `post-apocalyptic_hacker`,
`purple_leaves` (анимированные — с видеофоном, чуть-чуть CPU на экране входа).

Предпросмотр без выхода из сессии: `sddm-greeter-qt6 --test-mode --theme /usr/share/sddm/themes/sddm-astronaut-theme`.

Греетер по умолчанию работает на X11 (наиболее обкатанный вариант; `xorg-server` установлен).
Экспериментальный Wayland-греетер: создайте `/etc/sddm.conf.d/30-wayland.conf` с
`[General] DisplayServer=wayland` — потребуется компоситор для греетера (weston или kwin).

## 7. OLED: как не выжечь панель

Пиксель-шифтеров под Linux нет (ASUS OLED Care — только Windows), поэтому гигиена поведенческая,
и она уже настроена: цепочка hypridle «2 мин — притушить → 5 мин — блокировка (чёрный
hyprlock) → 5.5 мин — **DPMS off** (никаких заставок!) → 20 мин — сон». Плюс рекомендации:
тёмные темы (выключенный пиксель OLED = ноль износа и ноль ватт), не держать 100% яркости
на статичных окнах, иногда менять обои. На батарее полезно переходить на 60 Гц:
`hyprctl keyword monitor "eDP-1, 2880x1800@60, 0x0, 1.5"` (120 Гц держит память GPU в
высоком энергосостоянии и стоит несколько ватт).

## 8. Troubleshooting

* **Фризы/зависания экрана, зависание при выходе из сна** — проверьте, что в cmdline есть
  `amdgpu.dcdebugmask=0x600` (`cat /proc/cmdline`). Хотите проверить, нужен ли он ещё вашей
  связке BIOS+ядро: уберите параметр из `/boot/limine.conf`, перезагрузитесь; вернулись
  фризы — верните параметр (он стоит немного батареи, т.к. держит дисплейный конвейер активным).
* **Bluetooth умер после сна с `error -110`** — полностью выключите ноутбук, отключите
  зарядку, подержите кнопку питания 20–30 с (сброс EC). Udev-правило против autosuspend уже
  стоит; проверьте свой USB-ID: `lsusb | grep 13d3` (правило написано под `13d3:3608`).
* **Нет звука/звук «жестяной»** — убедитесь, что `sof-firmware` НЕ установлен
  (`pacman -Q sof-firmware` → должен отсутствовать), а `alsa-ucm-conf` установлен; ядро ≥6.13.
* **Микрофон не видит голос** — выберите источник «Internal Stereo Microphone» в pavucontrol;
  цифровой DMIC-массив в Linux не работает (ограничение платформы, не установки).
* **Редкие сбросы GPU при видео** (`ring vcn_unified_0 timeout` в dmesg) — известный баг VCN
  на Strix Point, к 2026 почти изжит; обновляйте ядро/linux-firmware, обычно композитор
  переживает сброс без падения сессии.
* **Подсветка клавиатуры «дышит» и не управляется** — известный EC-глюк; лечится сбросом EC
  (см. пункт про Bluetooth) или обновлением BIOS.
* **Система не грузится после неудачного обновления** (единственное ядро!) — загрузите
  archiso с `amdgpu.dcdebugmask=0x600`, затем:

  ```bash
  mount -o subvol=@ /dev/nvme0n1p2 /mnt && mount /dev/nvme0n1p1 /mnt/boot
  arch-chroot /mnt
  pacman -Syu linux-cachyos linux-cachyos-headers && mkinitcpio -P
  ```

* **Откат интенсивности сжатия btrfs** — поменяйте опцию в `/etc/fstab`
  (`compress-force=zstd:1` ↔ `compress=zstd:3`), `systemctl daemon-reload`, перемонтирование/
  перезагрузка; старые файлы пережмутся только при перезаписи (`btrfs filesystem defrag -rczstd /`).
* **Проверить, что всё работает**: `./post-install.sh` в конце печатает самодиагностику
  (scaling_driver=amd-pstate-epp, zram, VA-API-профили, лимит заряда, sched-ext).

## 9. Что сознательно НЕ сделано (и почему)

* **Снапшоты btrfs** — по требованию. (Если передумаете: `pacman -S snapper snap-pac`,
  плюс `limine-snapper-sync` из реп CachyOS для загрузочных записей снапшотов.)
* **Второе ядро** — по требованию («без лишних ядер»); риск и обходные пути описаны в §3.2 и §8.
* **LUKS-шифрование** — по вашему выбору при опросе.
* **TLP** — конфликтует с power-profiles-daemon; PPD на современном AMD предпочтителен.
* **asusctl / rog-control-center** — на Zenbook почти всё их полезное (профили платформы,
  лимит заряда) уже делает ядрёный asus-wmi; RGB-подсветки, за которой asusctl нужен на ROG,
  здесь нет. Захотите — репозиторий `[g14]` описан на asus-linux.org.
* **`mitigations=off`** — задокументировано в §3.4, не включено: на Zen 5 выигрыша ~0%.
* **uwsm** (session manager) — лишний слой для одного компоситора; SDDM запускает Hyprland напрямую.
* **mesa-vdpau** — VDPAU удалён из mesa 25.3 для radeonsi; VA-API — единственный путь.
