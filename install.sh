#!/usr/bin/env bash
# ============================================================================
#  install.sh — Этап 1: автоматический установщик Arch Linux
#  Целевое железо: ASUS Zenbook S16 UM5606WA (Ryzen AI 9 HX 370 «Strix Point»,
#                  Radeon 890M, OLED 2880x1800@120, Wi-Fi/BT MediaTek MT7925)
#
#  Что делает этот скрипт (запускается из live-окружения archiso):
#    1. Проверяет UEFI, интернет, синхронизирует часы
#    2. Полностью СТИРАЕТ выбранный NVMe-диск (с явным подтверждением!)
#    3. Размечает GPT: ESP 2 GiB (FAT32, /boot) + btrfs на всё остальное
#    4. Создаёт btrfs-сабволюмы БЕЗ снапшотов: @ @home @log @cache @tmp @pkg
#    5. Подключает репозитории CachyOS (znver4 — оптимизация под Zen 5)
#    6. pacstrap с ядром linux-cachyos (единственное ядро в системе)
#    7. Генерирует fstab и запускает Этап 2 (chroot-setup.sh) внутри chroot
#
#  ВАЖНО: сам live-ISO на этом ноутбуке нужно грузить с параметром ядра
#         amdgpu.dcdebugmask=0x600  (в меню ISO нажать «e» и дописать),
#         иначе возможны зависания OLED-панели ещё до установки.
#
#  Использование:
#    1) Загрузиться с archiso, подключить Wi-Fi:  iwctl station wlan0 connect <SSID>
#    2) curl -LO <raw-url>/install.sh <raw-url>/chroot-setup.sh <raw-url>/post-install.sh
#    3) chmod +x install.sh && ./install.sh
#
#  Все параметры можно переопределить переменными окружения:
#    DISK=/dev/nvme0n1 HOSTNAME=zenbook USERNAME=ilya ./install.sh
# ============================================================================
set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Конфигурация (переопределяется переменными окружения)
# ----------------------------------------------------------------------------
DISK="${DISK:-}"                                  # пусто = автоопределение NVMe
HOSTNAME="${HOSTNAME:-zenbook-s16}"
USERNAME="${USERNAME:-user}"
TIMEZONE="${TIMEZONE:-Europe/Moscow}"
LOCALE_MAIN="${LOCALE_MAIN:-ru_RU.UTF-8}"         # основной язык системы
KEYMAP_CONSOLE="${KEYMAP_CONSOLE:-us}"            # раскладка TTY-консоли (не Hyprland)
ESP_SIZE="${ESP_SIZE:-2GiB}"                      # ESP = /boot: тут живут ядра (Limine читает только FAT)
BTRFS_COMPRESS="${BTRFS_COMPRESS:-compress-force=zstd:1}"  # альтернатива: compress=zstd:3 (лучше сжатие, медленнее)
SDDM_THEME_VARIANT="${SDDM_THEME_VARIANT:-astronaut}"      # astronaut | pixel_sakura | black_hole | cyberpunk |
                                                           # hyprland_kath | jake_the_dog | japanese_aesthetic |
                                                           # pixel_sakura_static | post-apocalyptic_hacker | purple_leaves
CACHYOS_KEY="F3B607488DB35A47"                    # официальный GPG-ключ репозиториев CachyOS

# ----------------------------------------------------------------------------
# Вспомогательные функции
# ----------------------------------------------------------------------------
C_GREEN=$'\e[1;32m'; C_RED=$'\e[1;31m'; C_YELLOW=$'\e[1;33m'; C_BLUE=$'\e[1;34m'; C_OFF=$'\e[0m'
log()  { echo "${C_GREEN}[install]${C_OFF} $*"; }
warn() { echo "${C_YELLOW}[внимание]${C_OFF} $*"; }
die()  { echo "${C_RED}[ошибка]${C_OFF} $*" >&2; exit 1; }
step() { echo; echo "${C_BLUE}==> $*${C_OFF}"; }

trap 'die "Скрипт прерван на строке $LINENO (команда: $BASH_COMMAND)"' ERR

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# ----------------------------------------------------------------------------
# 0. Предварительные проверки
# ----------------------------------------------------------------------------
step "Проверки окружения"

[[ $EUID -eq 0 ]] || die "Запускайте от root (в archiso вы уже root)."
[[ -f "$SCRIPT_DIR/chroot-setup.sh" ]] || die "Рядом с install.sh должен лежать chroot-setup.sh."

# UEFI 64-bit обязателен для Limine на этом ноутбуке
[[ -d /sys/firmware/efi/efivars ]] || die "Система загружена НЕ в UEFI-режиме. Проверьте настройки BIOS."
fw_size="$(cat /sys/firmware/efi/fw_platform_size 2>/dev/null || echo 64)"
[[ "$fw_size" == "64" ]] || die "Обнаружен ${fw_size}-битный UEFI — требуется 64-битный."
log "UEFI 64-bit: OK"

# Предупреждение, если ISO загружен без анти-фриз параметра для OLED
if ! grep -q 'amdgpu.dcdebugmask' /proc/cmdline; then
    warn "ISO загружен БЕЗ amdgpu.dcdebugmask=0x600 — на UM5606WA возможны фризы экрана."
    warn "Если экран зависнет — перезагрузитесь и добавьте параметр в меню ISO (клавиша «e»)."
fi

# Интернет
if ! ping -c1 -W3 archlinux.org &>/dev/null && ! ping -c1 -W3 1.1.1.1 &>/dev/null; then
    die "Нет интернета. Wi-Fi: iwctl station wlan0 connect \"<SSID>\""
fi
log "Интернет: OK"

timedatectl set-ntp true
log "Синхронизация времени (NTP): включена"

# ----------------------------------------------------------------------------
# 1. Выбор диска
# ----------------------------------------------------------------------------
step "Выбор целевого диска"

if [[ -z "$DISK" ]]; then
    # Автоопределение: первый NVMe-диск (в UM5606WA единственный SSD — NVMe)
    DISK="$(lsblk -dpno NAME,TYPE | awk '$2=="disk" && $1 ~ /nvme/ {print $1; exit}')"
    [[ -n "$DISK" ]] || die "NVMe-диск не найден. Укажите вручную: DISK=/dev/sdX ./install.sh"
fi
[[ -b "$DISK" ]] || die "$DISK не является блочным устройством."

echo
lsblk -o NAME,SIZE,MODEL,TYPE,MOUNTPOINTS "$DISK"
echo
warn "ВСЕ ДАННЫЕ НА ДИСКЕ $DISK БУДУТ БЕЗВОЗВРАТНО УНИЧТОЖЕНЫ (включая Windows)."
read -rp "Чтобы продолжить, введите слово ERASE: " confirm
[[ "$confirm" == "ERASE" ]] || die "Отменено пользователем."

# Суффикс номеров разделов: nvme0n1 -> nvme0n1p1, sda -> sda1
PART=""
[[ "$DISK" == *[0-9] ]] && PART="p"
ESP_DEV="${DISK}${PART}1"
ROOT_DEV="${DISK}${PART}2"

# ----------------------------------------------------------------------------
# 2. Разметка и файловые системы
# ----------------------------------------------------------------------------
step "Разметка $DISK (GPT: ESP $ESP_SIZE + btrfs)"

# Отмонтировать всё, что могло остаться от прошлых попыток
umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true

wipefs -af "$DISK"
sgdisk --zap-all "$DISK"
sgdisk -n "1:0:+${ESP_SIZE}" -t 1:ef00 -c 1:"EFI system partition" "$DISK"
sgdisk -n "2:0:0"            -t 2:8300 -c 2:"Arch Linux btrfs"     "$DISK"
partprobe "$DISK"
sleep 2

log "Создание файловых систем"
mkfs.fat -F32 -n ESP "$ESP_DEV"
mkfs.btrfs -f -L archroot "$ROOT_DEV"

# --- btrfs-сабволюмы (снапшоты НЕ используются — snapper/timeshift не ставим).
# Отдельные сабволюмы для логов/кэша/тмп — чтобы их можно было монтировать
# со своими опциями и они не «раздували» будущие бэкапы корня.
log "Создание btrfs-сабволюмов: @ @home @log @cache @tmp @pkg"
mount "$ROOT_DEV" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@tmp
btrfs subvolume create /mnt/@pkg
umount /mnt

# --- Монтирование с оптимизированными опциями.
# noatime            — не писать время доступа (меньше записей на SSD)
# compress-force=zstd:1 — прозрачное сжатие, минимальная нагрузка на CPU, быстрее NVMe
# ssd, space_cache=v2, discard=async — значения по умолчанию современных ядер,
#                      указаны явно для наглядности и стабильности поведения
BTRFS_OPTS="noatime,${BTRFS_COMPRESS},ssd,space_cache=v2,discard=async"

mount -o "${BTRFS_OPTS},subvol=@" "$ROOT_DEV" /mnt
mkdir -p /mnt/{boot,home,var/log,var/cache,var/tmp}
mount -o "${BTRFS_OPTS},subvol=@home"  "$ROOT_DEV" /mnt/home
mount -o "${BTRFS_OPTS},subvol=@log"   "$ROOT_DEV" /mnt/var/log
mount -o "${BTRFS_OPTS},subvol=@cache" "$ROOT_DEV" /mnt/var/cache
mount -o "${BTRFS_OPTS},subvol=@tmp"   "$ROOT_DEV" /mnt/var/tmp
mkdir -p /mnt/var/cache/pacman/pkg
mount -o "${BTRFS_OPTS},subvol=@pkg"   "$ROOT_DEV" /mnt/var/cache/pacman/pkg
# ESP монтируется в /boot: Limine читает ТОЛЬКО FAT, поэтому ядра живут здесь
mount -o "noatime,fmask=0137,dmask=0027" "$ESP_DEV" /mnt/boot

log "Точки монтирования:"
findmnt -R /mnt | sed 's/^/    /'

# ----------------------------------------------------------------------------
# 3. Репозитории CachyOS в live-окружении (для pacstrap с linux-cachyos)
# ----------------------------------------------------------------------------
step "Подключение репозиториев CachyOS (znver4 — оптимизация под Zen 5)"

# Ключ CachyOS
pacman-key --recv-keys "$CACHYOS_KEY" --keyserver keyserver.ubuntu.com
pacman-key --lsign-key "$CACHYOS_KEY"

# Ванильный pacman понимает только Architecture=auto(=x86_64); чтобы принять
# пакеты x86_64_v3/x86_64_v4 из оптимизированных реп, перечисляем архитектуры явно.
sed -i 's/^#\?Architecture.*/Architecture = x86_64 x86_64_v3 x86_64_v4/' /etc/pacman.conf

# Мирролисты CachyOS для live-окружения (копия официальных; в установленной
# системе их заменят пакеты cachyos-mirrorlist / cachyos-v4-mirrorlist).
# Хитрость совместимости: ванильный pacman подставляет вместо ПОДСТРОКИ «$arch»
# первое значение из Architecture, поэтому «$arch_v4» превращается в «x86_64_v4» —
# ровно то, что нужно. Поэтому x86_64 обязан стоять ПЕРВЫМ в строке Architecture.
mkdir -p /etc/pacman.d
cat > /etc/pacman.d/cachyos-mirrorlist <<'EOF'
Server = https://cdn77.cachyos.org/repo/$arch/$repo
Server = https://us.cachyos.org/repo/$arch/$repo
EOF
cat > /etc/pacman.d/cachyos-v4-mirrorlist <<'EOF'
Server = https://cdn77.cachyos.org/repo/$arch_v4/$repo
Server = https://us.cachyos.org/repo/$arch_v4/$repo
EOF

# Репозитории CachyOS должны стоять ВЫШЕ [core]: вставляем перед ним.
# Zen 5 (Strix Point) использует znver4-репы — отдельных znver5-реп не существует,
# Zen 4 и Zen 5 делят один tier (пакеты собраны под x86-64-v4/znver4).
if ! grep -q '^\[cachyos-znver4\]' /etc/pacman.conf; then
    sed -i '/^\[core\]/i \
[cachyos-znver4]\
Include = /etc/pacman.d/cachyos-v4-mirrorlist\
\
[cachyos-core-znver4]\
Include = /etc/pacman.d/cachyos-v4-mirrorlist\
\
[cachyos-extra-znver4]\
Include = /etc/pacman.d/cachyos-v4-mirrorlist\
\
[cachyos]\
Include = /etc/pacman.d/cachyos-mirrorlist\
' /etc/pacman.conf
fi

pacman -Syy

# ----------------------------------------------------------------------------
# 4. Установка базовой системы (pacstrap)
# ----------------------------------------------------------------------------
step "pacstrap: базовая система + ядро linux-cachyos (единственное ядро)"

# Ядро ставится сразу из znver4-репозитория CachyOS.
# ВНИМАНИЕ: по требованию пользователя резервного ядра (linux/linux-lts) НЕТ —
# зато в Limine будет fallback-initramfs запись (см. chroot-setup.sh).
pacstrap -K /mnt \
    base base-devel \
    linux-cachyos linux-cachyos-headers \
    linux-firmware amd-ucode \
    btrfs-progs \
    cachyos-keyring cachyos-mirrorlist cachyos-v4-mirrorlist \
    limine efibootmgr \
    networkmanager \
    terminus-font \
    git curl wget \
    nano vim \
    man-db man-pages \
    bash-completion

# ----------------------------------------------------------------------------
# 5. fstab
# ----------------------------------------------------------------------------
step "Генерация fstab"
genfstab -U /mnt >> /mnt/etc/fstab
log "fstab:"
grep -v '^#' /mnt/etc/fstab | sed 's/^/    /'

# ----------------------------------------------------------------------------
# 6. Передача управления Этапу 2 (внутри chroot)
# ----------------------------------------------------------------------------
step "Запуск Этапа 2: chroot-setup.sh"

ROOT_UUID="$(blkid -s UUID -o value "$ROOT_DEV")"

# Переменные для chroot-этапа
cat > /mnt/root/install.env <<EOF
DISK='$DISK'
ESP_DEV='$ESP_DEV'
ROOT_DEV='$ROOT_DEV'
ROOT_UUID='$ROOT_UUID'
HOSTNAME='$HOSTNAME'
USERNAME='$USERNAME'
TIMEZONE='$TIMEZONE'
LOCALE_MAIN='$LOCALE_MAIN'
KEYMAP_CONSOLE='$KEYMAP_CONSOLE'
SDDM_THEME_VARIANT='$SDDM_THEME_VARIANT'
CACHYOS_KEY='$CACHYOS_KEY'
EOF

install -Dm755 "$SCRIPT_DIR/chroot-setup.sh" /mnt/root/chroot-setup.sh
arch-chroot /mnt bash /root/chroot-setup.sh

# post-install.sh кладём в домашний каталог пользователя (он уже создан Этапом 2)
if [[ -d "/mnt/home/$USERNAME" && -f "$SCRIPT_DIR/post-install.sh" ]]; then
    install -Dm755 "$SCRIPT_DIR/post-install.sh" "/mnt/home/$USERNAME/post-install.sh"
    arch-chroot /mnt chown "$USERNAME:$USERNAME" "/home/$USERNAME/post-install.sh"
fi

# Уборка
rm -f /mnt/root/install.env /mnt/root/chroot-setup.sh

step "УСТАНОВКА ЗАВЕРШЕНА"
echo "
  Дальнейшие шаги:
    1. ${C_GREEN}umount -R /mnt && reboot${C_OFF}  (вынуть флешку при перезагрузке)
    2. Войти через красивый экран SDDM (тема: sddm-astronaut / $SDDM_THEME_VARIANT)
    3. В терминале (kitty, Super+Enter) запустить: ${C_GREEN}./post-install.sh${C_OFF}
       — он поставит paru (AUR), фан-профили, курсоры и предложит
         дотфайлы ilyamiro (Quickshell-рабочий стол).

  Заметки по железу — в README.md (микрофон, PSR/OLED, Bluetooth).
"
read -rp "Перезагрузить сейчас? [y/N]: " r
if [[ "${r,,}" == "y" ]]; then
    umount -R /mnt
    reboot
fi
