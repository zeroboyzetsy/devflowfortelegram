#!/usr/bin/env bash
# ============================================================================
#  chroot-setup.sh — Этап 2: настройка системы внутри arch-chroot
#  Запускается автоматически из install.sh. Вручную: arch-chroot /mnt bash /root/chroot-setup.sh
#
#  Делает:
#    1. Время/локали/hostname/консоль
#    2. pacman.conf: цвет, параллельные загрузки, multilib, репозитории CachyOS
#    3. Пользователь + sudo
#    4. mkinitcpio (amdgpu, microcode, zstd)
#    5. Загрузчик Limine: EFI-бинарь + запись UEFI + limine.conf + pacman-хук
#    6. Полный стек Hyprland-десктопа + PipeWire + всё для железа UM5606WA
#    7. Красивый вход: SDDM + sddm-astronaut-theme
#    8. Глубокий тюнинг: cachyos-settings, ananicy-cpp, sched-ext (scx_lavd),
#       systemd-oomd, journald/coredump-лимиты, makepkg -march=native,
#       udev-правила (Bluetooth MT7925, лимит заряда 80%), blacklist watchdog
#    9. Дефолтные конфиги Hyprland/hypridle/hyprlock/waybar/kitty в /etc/skel
#   10. Включение сервисов
# ============================================================================
set -Eeuo pipefail

C_GREEN=$'\e[1;32m'; C_RED=$'\e[1;31m'; C_BLUE=$'\e[1;34m'; C_OFF=$'\e[0m'
log()  { echo "${C_GREEN}[chroot]${C_OFF} $*"; }
die()  { echo "${C_RED}[ошибка]${C_OFF} $*" >&2; exit 1; }
step() { echo; echo "${C_BLUE}==> $*${C_OFF}"; }
trap 'die "Прервано на строке $LINENO (команда: $BASH_COMMAND)"' ERR

# Переменные, переданные Этапом 1
[[ -f /root/install.env ]] || die "Не найден /root/install.env (запускайте через install.sh)."
# shellcheck disable=SC1091
source /root/install.env

# ----------------------------------------------------------------------------
# 1. Время, локали, hostname, консоль
# ----------------------------------------------------------------------------
step "Время и локали"

ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
sed -i 's/^#ru_RU.UTF-8/ru_RU.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=$LOCALE_MAIN" > /etc/locale.conf

# Консоль TTY: шрифт Terminus с кириллицей
cat > /etc/vconsole.conf <<EOF
KEYMAP=$KEYMAP_CONSOLE
FONT=ter-v24n
EOF

echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

# ----------------------------------------------------------------------------
# 2. pacman.conf целевой системы
# ----------------------------------------------------------------------------
step "Настройка pacman (цвет, параллельные загрузки, multilib, CachyOS)"

# Косметика и скорость
sed -i 's/^#Color/Color/'                                   /etc/pacman.conf
sed -i 's/^#VerbosePkgLists/VerbosePkgLists/'               /etc/pacman.conf
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/'    /etc/pacman.conf
grep -q '^ILoveCandy' /etc/pacman.conf || sed -i '/^Color/a ILoveCandy' /etc/pacman.conf

# Архитектуры оптимизированных пакетов CachyOS (обязательно для ванильного pacman)
sed -i 's/^#\?Architecture.*/Architecture = x86_64 x86_64_v3 x86_64_v4/' /etc/pacman.conf

# multilib (32-битные библиотеки — Steam/Wine)
sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf

# Репозитории CachyOS ВЫШЕ [core] (мирролисты уже установлены пакетами при pacstrap)
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

# Ключ CachyOS в keyring целевой системы (cachyos-keyring уже установлен, это подстраховка)
pacman-key --recv-keys "$CACHYOS_KEY" --keyserver keyserver.ubuntu.com || true
pacman-key --lsign-key "$CACHYOS_KEY" || true

pacman -Syu --noconfirm

# ----------------------------------------------------------------------------
# 3. Дефолтные конфиги рабочего стола в /etc/skel (ДО создания пользователя)
# ----------------------------------------------------------------------------
step "Дефолтные конфиги Hyprland/waybar/kitty в /etc/skel"

mkdir -p /etc/skel/.config/{hypr,waybar,kitty}

# --- Hyprland: аккуратная база под UM5606WA (потом можно заменить дотфайлами ilyamiro)
cat > /etc/skel/.config/hypr/hyprland.conf <<'EOF'
# ~/.config/hypr/hyprland.conf — базовый конфиг под ASUS Zenbook S16 UM5606WA
# Примечание: с Hyprland 0.55 формат hyprlang объявлен устаревшим в пользу Lua
# (hyprland.lua), но .conf ещё поддерживается. Дотфайлы ilyamiro тоже на .conf.

# --- Монитор: OLED 2880x1800@120, масштаб 1.5 => логическое 1920x1200 (делится нацело)
monitor = eDP-1, 2880x1800@120, 0x0, 1.5
# На батарее можно жить на 60 Гц (экономит несколько ватт — 120 Гц держит память GPU
# в высоком состоянии): hyprctl keyword monitor "eDP-1, 2880x1800@60, 0x0, 1.5"

# --- Автозапуск
exec-once = hyprpaper
exec-once = waybar
exec-once = swaync
exec-once = hypridle
exec-once = systemctl --user start hyprpolkitagent
exec-once = nm-applet
exec-once = blueman-applet
exec-once = udiskie
exec-once = wl-paste --type text --watch cliphist store
exec-once = wl-paste --type image --watch cliphist store

# --- Окружение
env = QT_QPA_PLATFORMTHEME,qt6ct
env = XCURSOR_SIZE,24
# env = XCURSOR_THEME,Bibata-Modern-Classic   # раскомментировать после post-install.sh
# VA-API аппаратное декодирование видео на Radeon 890M (VCN):
env = LIBVA_DRIVER_NAME,radeonsi
# mpv: hwdec=vaapi; Firefox: about:config -> media.ffmpeg.vaapi.enabled=true

# --- Ввод: en/ru, переключение Alt+Shift
input {
    kb_layout = us,ru
    kb_options = grp:alt_shift_toggle
    follow_mouse = 1
    touchpad {
        natural_scroll = true
        tap-to-click = true
        disable_while_typing = true
    }
}

gestures {
    workspace_swipe = true
}

# --- Внешний вид
general {
    gaps_in = 4
    gaps_out = 8
    border_size = 2
    col.active_border = rgba(7aa2f7ee) rgba(bb9af7ee) 45deg
    col.inactive_border = rgba(414868aa)
    layout = dwindle
}

decoration {
    rounding = 8
    # Блюр красив, но на 2880x1800 ощутимо ест GPU/батарею — по умолчанию выключен.
    blur {
        enabled = false
    }
    shadow {
        enabled = true
        range = 12
        render_power = 2
    }
}

animations {
    enabled = true
    bezier = smooth, 0.25, 0.1, 0.25, 1.0
    animation = windows, 1, 4, smooth, slide
    animation = workspaces, 1, 4, smooth, slide
    animation = fade, 1, 4, smooth
}

misc {
    # vfr — главный «бесплатный» способ экономии батареи композитором
    vfr = true
    # vrr=2: FreeSync только в полноэкранных приложениях.
    # vrr=1 (всегда) на статичном рабочем столе даёт мерцание OLED на низкой частоте.
    vrr = 2
    disable_hyprland_logo = true
}

# Чёткий XWayland на дробном масштабе
xwayland {
    force_zero_scaling = true
}
env = GDK_SCALE,2

dwindle {
    pseudotile = true
    preserve_split = true
}

# --- Горячие клавиши
$mod = SUPER
bind = $mod, Return, exec, kitty
bind = $mod, Q, killactive
bind = $mod, E, exec, thunar
bind = $mod, R, exec, rofi -show drun
bind = $mod, V, exec, cliphist list | rofi -dmenu -p "буфер" | cliphist decode | wl-copy
bind = $mod, L, exec, hyprlock
bind = $mod, F, fullscreen
bind = $mod, T, togglefloating
bind = $mod, P, pseudo
bind = $mod, J, togglesplit
bind = $mod SHIFT, E, exit

bind = , Print, exec, hyprshot -m region --clipboard-only
bind = SHIFT, Print, exec, hyprshot -m output

# Мультимедийные клавиши
bindel = , XF86AudioRaiseVolume, exec, wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+
bindel = , XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bindl  = , XF86AudioMute,        exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
bindl  = , XF86AudioMicMute,     exec, wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle
bindel = , XF86MonBrightnessUp,   exec, brightnessctl set 5%+
bindel = , XF86MonBrightnessDown, exec, brightnessctl set 5%-
bindl  = , XF86AudioPlay,  exec, playerctl play-pause
bindl  = , XF86AudioNext,  exec, playerctl next
bindl  = , XF86AudioPrev,  exec, playerctl previous

# Фокус/перемещение
bind = $mod, left,  movefocus, l
bind = $mod, right, movefocus, r
bind = $mod, up,    movefocus, u
bind = $mod, down,  movefocus, d
bind = $mod SHIFT, left,  movewindow, l
bind = $mod SHIFT, right, movewindow, r
bind = $mod SHIFT, up,    movewindow, u
bind = $mod SHIFT, down,  movewindow, d

# Рабочие столы 1-9
bind = $mod, 1, workspace, 1
bind = $mod, 2, workspace, 2
bind = $mod, 3, workspace, 3
bind = $mod, 4, workspace, 4
bind = $mod, 5, workspace, 5
bind = $mod, 6, workspace, 6
bind = $mod, 7, workspace, 7
bind = $mod, 8, workspace, 8
bind = $mod, 9, workspace, 9
bind = $mod SHIFT, 1, movetoworkspace, 1
bind = $mod SHIFT, 2, movetoworkspace, 2
bind = $mod SHIFT, 3, movetoworkspace, 3
bind = $mod SHIFT, 4, movetoworkspace, 4
bind = $mod SHIFT, 5, movetoworkspace, 5
bind = $mod SHIFT, 6, movetoworkspace, 6
bind = $mod SHIFT, 7, movetoworkspace, 7
bind = $mod SHIFT, 8, movetoworkspace, 8
bind = $mod SHIFT, 9, movetoworkspace, 9

# Мышью: перенос/ресайз с зажатым Super
bindm = $mod, mouse:272, movewindow
bindm = $mod, mouse:273, resizewindow
EOF

# --- hypridle: OLED-щадящая цепочка (притушить -> заблокировать -> ВЫКЛЮЧИТЬ панель -> сон).
# Для OLED важно: никаких «заставок» — только DPMS off (чёрный = выключенные пиксели).
cat > /etc/skel/.config/hypr/hypridle.conf <<'EOF'
general {
    lock_cmd = pidof hyprlock || hyprlock
    before_sleep_cmd = loginctl lock-session
    after_sleep_cmd = hyprctl dispatch dpms on
}

listener {
    timeout = 120                                # 2 мин: сильно притушить
    on-timeout = brightnessctl -s set 10%
    on-resume = brightnessctl -r
}
listener {
    timeout = 300                                # 5 мин: блокировка
    on-timeout = loginctl lock-session
}
listener {
    timeout = 330                                # 5.5 мин: панель ВЫКЛ (DPMS)
    on-timeout = hyprctl dispatch dpms off
    on-resume = hyprctl dispatch dpms on
}
listener {
    timeout = 1200                               # 20 мин: сон (s2idle)
    on-timeout = systemctl suspend
}
EOF

# --- hyprlock: чистый чёрный фон (выключенные пиксели OLED)
cat > /etc/skel/.config/hypr/hyprlock.conf <<'EOF'
background {
    monitor =
    color = rgba(0, 0, 0, 1.0)
}

input-field {
    monitor =
    size = 300, 50
    outline_thickness = 2
    outer_color = rgb(7aa2f7)
    inner_color = rgb(1a1b26)
    font_color = rgb(c0caf5)
    placeholder_text = <i>Пароль…</i>
    fade_on_empty = true
    position = 0, -40
    halign = center
    valign = center
}

label {
    monitor =
    text = $TIME
    color = rgb(c0caf5)
    font_size = 72
    font_family = JetBrainsMono Nerd Font
    position = 0, 120
    halign = center
    valign = center
}
EOF

# --- hyprpaper (обои; awww установлен как альтернатива для анимированных)
cat > /etc/skel/.config/hypr/hyprpaper.conf <<'EOF'
# Положите свои обои и укажите путь:
# preload = ~/Pictures/wall.png
# wallpaper = eDP-1, ~/Pictures/wall.png
splash = false
EOF

# --- waybar: минималистичная панель
cat > /etc/skel/.config/waybar/config.jsonc <<'EOF'
{
    "layer": "top",
    "position": "top",
    "height": 32,
    "modules-left": ["hyprland/workspaces", "hyprland/window"],
    "modules-center": ["clock"],
    "modules-right": ["hyprland/language", "tray", "pulseaudio", "network", "bluetooth", "cpu", "memory", "backlight", "battery"],

    "hyprland/workspaces": { "format": "{id}" },
    "hyprland/window": { "max-length": 60 },
    "hyprland/language": { "format-en": "EN", "format-ru": "RU" },
    "clock": {
        "format": "{:%H:%M  %d.%m}",
        "tooltip-format": "<tt>{calendar}</tt>"
    },
    "pulseaudio": {
        "format": "{icon} {volume}%",
        "format-muted": "󰝟",
        "format-icons": { "default": ["󰕿", "󰖀", "󰕾"] },
        "on-click": "pavucontrol"
    },
    "network": {
        "format-wifi": "󰤨 {signalStrength}%",
        "format-ethernet": "󰈀",
        "format-disconnected": "󰤭",
        "tooltip-format-wifi": "{essid} ({ipaddr})"
    },
    "bluetooth": {
        "format": "󰂯",
        "format-disabled": "󰂲",
        "format-connected": "󰂱 {num_connections}",
        "on-click": "blueman-manager"
    },
    "cpu": { "format": "󰻠 {usage}%" },
    "memory": { "format": "󰍛 {percentage}%" },
    "backlight": { "format": "󰃞 {percent}%" },
    "battery": {
        "states": { "warning": 25, "critical": 10 },
        "format": "{icon} {capacity}%",
        "format-charging": "󰂄 {capacity}%",
        "format-icons": ["󰁺", "󰁼", "󰁾", "󰂀", "󰁹"]
    }
}
EOF

cat > /etc/skel/.config/waybar/style.css <<'EOF'
* {
    font-family: "JetBrainsMono Nerd Font", "Noto Sans", sans-serif;
    font-size: 13px;
}
window#waybar {
    background: rgba(26, 27, 38, 0.92);
    color: #c0caf5;
}
#workspaces button {
    padding: 0 8px;
    color: #565f89;
}
#workspaces button.active {
    color: #7aa2f7;
    border-bottom: 2px solid #7aa2f7;
}
#clock, #pulseaudio, #network, #bluetooth, #cpu, #memory, #backlight, #battery, #tray, #language, #window {
    padding: 0 10px;
}
#battery.warning  { color: #e0af68; }
#battery.critical { color: #f7768e; }
EOF

# --- kitty
cat > /etc/skel/.config/kitty/kitty.conf <<'EOF'
font_family      JetBrainsMono Nerd Font
font_size        11.5
background_opacity 0.95
confirm_os_window_close 0
enable_audio_bell no
# Tokyo Night
foreground #c0caf5
background #1a1b26
selection_background #33467c
cursor #c0caf5
EOF

# ----------------------------------------------------------------------------
# 4. Пользователь и sudo
# ----------------------------------------------------------------------------
step "Создание пользователя $USERNAME"

if ! id "$USERNAME" &>/dev/null; then
    useradd -m -G wheel,video,input -s /bin/bash "$USERNAME"
fi
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel

echo
log "Пароль для root:"
until passwd; do echo "Повторите."; done
log "Пароль для $USERNAME:"
until passwd "$USERNAME"; do echo "Повторите."; done

# ----------------------------------------------------------------------------
# 5. Установка всех пакетов рабочего стола и железа
# ----------------------------------------------------------------------------
step "Установка Hyprland-десктопа, PipeWire, графики, шрифтов, утилит"

# Чистим остатки прошлых прерванных попыток: если pacman успел выбрать mesa-git
# как «провайдера» исчезнувших пакетов (vulkan-radeon/libva-mesa-driver),
# он конфликтует с обычной mesa и валит транзакцию.
for leftover in mesa-git lib32-mesa-git; do
    if pacman -Qq "$leftover" &>/dev/null; then
        log "Удаляю конфликтующий пакет прошлой попытки: $leftover"
        pacman -Rdd --noconfirm "$leftover"
    fi
done

PKGS=(
    # --- Графика AMD (Radeon 890M, RDNA 3.5).
    # ВАЖНО: vulkan-radeon, lib32-vulkan-radeon и libva-mesa-driver больше НЕ
    # существуют как отдельные пакеты — RADV (Vulkan) и VA-API влиты в mesa/lib32-mesa.
    # Указывать старые имена нельзя: pacman подберёт «провайдера» mesa-git из реп
    # CachyOS, а mesa-git конфликтует с mesa -> транзакция падает.
    mesa lib32-mesa
    libva-utils                            # vainfo — проверка VA-API (сам драйвер внутри mesa)

    # --- Аудио: PipeWire. ВАЖНО для UM5606WA: кодек Realtek ALC294,
    #     sof-firmware НЕ нужен (и по отчётам конфликтует), нужен alsa-ucm-conf.
    pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber
    gst-plugin-pipewire alsa-ucm-conf alsa-utils
    pavucontrol playerctl

    # --- Hyprland и первопартийная экосистема (всё из extra)
    hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk
    hyprpaper awww                          # обои: hyprpaper (статичные) + awww (анимированные, преемник swww)
    hyprlock hypridle hyprpicker hyprsunset hyprpolkitagent hyprshot
    waybar rofi swaync                      # панель, лаунчер (rofi 2.0 — нативный Wayland), уведомления
    wl-clipboard cliphist                   # буфер обмена
    grim slurp satty                        # скриншоты + аннотации

    # --- Сеть и Bluetooth
    networkmanager network-manager-applet
    bluez bluez-utils blueman

    # --- Файлы
    thunar thunar-volman thunar-archive-plugin file-roller
    gvfs gvfs-mtp tumbler udiskie
    7zip unzip zip                          # p7zip больше не существует — пакет называется 7zip

    # --- Терминал и базовые приложения
    kitty
    firefox firefox-i18n-ru
    mpv loupe

    # --- Тема/внешний вид
    qt5ct qt6ct kvantum kvantum-qt5 qt5-wayland qt6-wayland
    nwg-look papirus-icon-theme
    gnome-keyring seahorse
    brightnessctl xdg-user-dirs

    # --- Шрифты
    ttf-jetbrains-mono-nerd ttf-nerd-fonts-symbols ttf-nerd-fonts-symbols-mono
    noto-fonts noto-fonts-cjk noto-fonts-emoji otf-font-awesome

    # --- Вход в систему: SDDM (Qt6) + зависимости темы astronaut
    sddm xorg-server
    qt6-svg qt6-virtualkeyboard qt6-multimedia-ffmpeg qt6-5compat qt6-declarative

    # --- Питание и платформа ASUS (asus-wmi в ядре даёт профили и лимит заряда)
    power-profiles-daemon                   # НЕ ставить TLP вместе с ним!
    fwupd                                   # обновления BIOS/прошивок (LVFS)

    # --- Тюнинг CachyOS
    cachyos-settings                        # sysctl, zram-generator, udev-правила I/O
    ananicy-cpp cachyos-ananicy-rules       # автоприоритеты процессов
    scx-scheds scx-tools                    # sched-ext планировщики (scx_lavd) + scx_loader

    # --- Инструменты наблюдения и обслуживания
    btop htop fastfetch
    amdgpu_top compsize
    pacman-contrib                          # paccache.timer
    powertop
)
pacman -S --needed --noconfirm "${PKGS[@]}"

# ----------------------------------------------------------------------------
# 6. mkinitcpio
# ----------------------------------------------------------------------------
step "mkinitcpio: amdgpu + microcode + zstd"

# MODULES=(amdgpu) — ранний KMS гарантированно; хук microcode (mkinitcpio>=38)
# встраивает amd-ucode прямо в initramfs — отдельная строка в limine.conf не нужна.
sed -i 's/^MODULES=.*/MODULES=(amdgpu)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck)/' /etc/mkinitcpio.conf
sed -i 's/^#COMPRESSION="zstd"/COMPRESSION="zstd"/' /etc/mkinitcpio.conf
mkinitcpio -P

# ----------------------------------------------------------------------------
# 7. Загрузчик Limine
# ----------------------------------------------------------------------------
step "Установка загрузчика Limine"

# Limine читает ТОЛЬКО FAT/ISO9660 — поэтому ESP смонтирован в /boot и ядра лежат там.
mkdir -p /boot/EFI/limine
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/

# Запись в UEFI NVRAM (Limine сам себя не регистрирует).
# Идемпотентно: при повторном запуске скрипта дубликат записи не создаётся.
ESP_PARTNUM="${ESP_DEV##*[a-z]}"     # /dev/nvme0n1p1 -> 1
if efibootmgr | grep -q "Arch Linux (Limine)"; then
    log "Запись UEFI 'Arch Linux (Limine)' уже существует — пропускаю efibootmgr."
else
    efibootmgr --create \
        --disk "$DISK" --part "$ESP_PARTNUM" \
        --label "Arch Linux (Limine)" \
        --loader '\EFI\limine\BOOTX64.EFI' \
        --unicode || {
            log "efibootmgr не смог создать запись — ставлю fallback-загрузчик EFI/BOOT/BOOTX64.EFI"
            install -Dm644 /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI
        }
fi

# Параметры ядра:
#  root/rootflags       — btrfs-сабволюм @
#  quiet                — чистая загрузка
#  nowatchdog           — минус ватт и минус задержки (десктоп не нуждается в watchdog)
#  zswap.enabled=0      — используем zram (cachyos-settings), zswap мешает его учёту
#  amdgpu.dcdebugmask=0x600 — ОТКЛЮЧАЕТ PSR-SU + Panel Replay: лечит зависания
#                             OLED-панели Strix Point. На ядрах >=6.15 можно
#                             попробовать убрать (см. README, раздел PSR).
CMDLINE="root=UUID=$ROOT_UUID rootflags=subvol=/@ rw rootfstype=btrfs quiet nowatchdog zswap.enabled=0 amdgpu.dcdebugmask=0x600"

# limine.conf — НОВЫЙ синтаксис (v8+ .. v12+): опции `имя: значение`, записи `/Имя`.
# Файл лежит на ESP (/boot). Fallback-запись компенсирует отсутствие второго ядра.
cat > /boot/limine.conf <<EOF
timeout: 3
default_entry: 1
interface_branding: Arch Linux - Zenbook S16
interface_branding_colour: 00aaaa
term_font_scale: 2x2
# Хотите обои меню: положите PNG на ESP (/boot/wallpaper.png) и раскомментируйте:
#wallpaper: boot():/wallpaper.png
#wallpaper_style: stretched

/Arch Linux (linux-cachyos)
    protocol: linux
    path: boot():/vmlinuz-linux-cachyos
    cmdline: $CMDLINE
    module_path: boot():/initramfs-linux-cachyos.img

/Arch Linux (fallback initramfs)
    protocol: linux
    path: boot():/vmlinuz-linux-cachyos
    cmdline: root=UUID=$ROOT_UUID rootflags=subvol=/@ rw rootfstype=btrfs
    module_path: boot():/initramfs-linux-cachyos-fallback.img
EOF

# pacman-хук: обновлять EFI-бинарь Limine при обновлении пакета.
# (limine.conf статичен: имена файлов ядра linux-cachyos не меняются между версиями)
mkdir -p /etc/pacman.d/hooks
cat > /etc/pacman.d/hooks/99-limine.hook <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = limine

[Action]
Description = Обновление EFI-бинаря Limine на ESP...
When = PostTransaction
Exec = /usr/bin/cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/
EOF

log "limine.conf:"
sed 's/^/    /' /boot/limine.conf

# ----------------------------------------------------------------------------
# 8. Красивый вход: SDDM + sddm-astronaut-theme
# ----------------------------------------------------------------------------
step "SDDM + тема sddm-astronaut (вариант: $SDDM_THEME_VARIANT)"

THEME_DIR=/usr/share/sddm/themes/sddm-astronaut-theme
if [[ ! -d "$THEME_DIR" ]]; then
    git clone -b master --depth 1 https://github.com/keyitdev/sddm-astronaut-theme.git "$THEME_DIR"
fi
mkdir -p /usr/share/fonts/sddm-astronaut
cp -r "$THEME_DIR"/Fonts/* /usr/share/fonts/sddm-astronaut/ 2>/dev/null || true
fc-cache -f >/dev/null 2>&1 || true

# Выбор встроенного варианта темы (10 штук в Themes/*.conf)
if [[ -f "$THEME_DIR/Themes/${SDDM_THEME_VARIANT}.conf" ]]; then
    sed -i "s|^ConfigFile=.*|ConfigFile=Themes/${SDDM_THEME_VARIANT}.conf|" "$THEME_DIR/metadata.desktop"
else
    log "Вариант '$SDDM_THEME_VARIANT' не найден, остаётся дефолтный astronaut."
fi

# Активация через drop-in'ы (НЕ трогаем /etc/sddm.conf)
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/10-theme.conf <<'EOF'
[Theme]
Current=sddm-astronaut-theme
EOF
cat > /etc/sddm.conf.d/20-virtualkbd.conf <<'EOF'
[General]
InputMethod=qtvirtualkeyboard
EOF
# Wayland-греетер — экспериментальный; по умолчанию SDDM использует X11-греетер
# (xorg-server установлен). Как включить Wayland-греетер — в README.

# ----------------------------------------------------------------------------
# 9. Глубокий тюнинг
# ----------------------------------------------------------------------------
step "Тюнинг: sched-ext, oomd, journald, makepkg, udev, watchdog"

# --- sched-ext: scx_lavd — планировщик с фокусом на отзывчивость/латентность,
#     хорошо подходит ноутбукам. Режим Auto сам переключает power/perf-профили.
#     (zram, swappiness=150, I/O-шедулеры и пр. уже настроены пакетом cachyos-settings)
mkdir -p /etc/scx_loader
cat > /etc/scx_loader/config.toml <<'EOF'
default_sched = "scx_lavd"
default_mode = "Auto"
EOF

# --- systemd-oomd: аккуратный OOM-киллер поверх zram
mkdir -p /etc/systemd/oomd.conf.d /etc/systemd/system/-.slice.d /etc/systemd/system/user@.service.d
cat > /etc/systemd/oomd.conf.d/00-oomd.conf <<'EOF'
[OOM]
SwapUsedLimit=90%
DefaultMemoryPressureLimit=60%
DefaultMemoryPressureDurationSec=20s
EOF
cat > /etc/systemd/system/-.slice.d/10-oomd.conf <<'EOF'
[Slice]
ManagedOOMSwap=kill
EOF
cat > /etc/systemd/system/user@.service.d/10-oomd.conf <<'EOF'
[Service]
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=50%
EOF

# --- journald/coredump: не дать логам съесть SSD
mkdir -p /etc/systemd/journald.conf.d /etc/systemd/coredump.conf.d
cat > /etc/systemd/journald.conf.d/00-size.conf <<'EOF'
[Journal]
SystemMaxUse=200M
MaxRetentionSec=1month
EOF
cat > /etc/systemd/coredump.conf.d/00-size.conf <<'EOF'
[Coredump]
ProcessSizeMax=1G
ExternalSizeMax=1G
MaxUse=1G
KeepFree=2G
EOF

# --- makepkg: собирать AUR-пакеты под свой CPU (-march=native == znver5 на HX 370)
mkdir -p /etc/makepkg.conf.d
cat > /etc/makepkg.conf.d/99-native.conf <<'EOF'
CFLAGS="-march=native -mtune=native -O2 -pipe -fno-plt -fexceptions \
        -Wp,-D_FORTIFY_SOURCE=3 -Wformat -Werror=format-security \
        -fstack-clash-protection -fcf-protection -fno-omit-frame-pointer"
CXXFLAGS="$CFLAGS -Wp,-D_GLIBCXX_ASSERTIONS"
RUSTFLAGS="-C opt-level=3 -C target-cpu=native"
MAKEFLAGS="-j$(nproc)"
NINJAFLAGS="-j$(nproc)"
OPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug lto)
EOF

# --- watchdog: выключен параметром nowatchdog + blacklist модуля чипсетного watchdog AMD
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/nowatchdog.conf <<'EOF'
blacklist sp5100_tco
EOF

# --- udev: Bluetooth MT7925 — запрет USB-autosuspend (лечит таймауты/error -110 после сна).
#     ID 13d3:3608 подтверждён на UM5606-серии; проверьте свой через lsusb | grep 13d3.
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/50-mt7925-bt-no-autosuspend.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="13d3", ATTR{idProduct}=="3608", TEST=="power/control", ATTR{power/control}="on"
EOF

# --- udev: лимит заряда батареи 80% (здоровье АКБ; работает через asus-wmi, без asusctl)
cat > /etc/udev/rules.d/90-battery-threshold.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="power_supply", KERNEL=="BAT?", TEST=="charge_control_end_threshold", ATTR{charge_control_end_threshold}="80"
EOF

# ----------------------------------------------------------------------------
# 10. Сервисы
# ----------------------------------------------------------------------------
step "Включение сервисов"

systemctl enable NetworkManager.service
systemctl enable bluetooth.service
systemctl enable sddm.service
systemctl enable power-profiles-daemon.service
systemctl enable ananicy-cpp.service
systemctl enable scx_loader.service
systemctl enable systemd-oomd.service
systemctl enable paccache.timer          # еженедельная чистка кэша pacman
systemctl enable btrfs-scrub@-.timer     # ежемесячная проверка целостности btrfs (корень)
# fstrim.timer НЕ включаем: btrfs смонтирован с discard=async (см. README)

step "Этап 2 завершён — система готова к первой загрузке"
