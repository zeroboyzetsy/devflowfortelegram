#!/usr/bin/env bash
# ============================================================================
#  post-install.sh — Этап 3: запускается ПОСЛЕ первой загрузки, от ОБЫЧНОГО
#  пользователя (НЕ root). Скрипт сам попросит sudo там, где нужно.
#
#  Делает:
#    * Ставит paru (AUR-хелпер)
#    * AUR-пакеты для UM5606WA: фан-профили (fan_state), курсоры Bibata
#    * Опционально (флаги):
#        --face-unlock     разблокировка лицом через IR-камеру (howdy)
#        --npu             стек AMD XDNA NPU (xrt + xrt-plugin-amdxdna)
#        --ilyamiro        рабочий стол ilyamiro (Quickshell) ОФИЦИАЛЬНЫМ
#                          установщиком imperative-dots (см. предупреждения!)
#        --ilyamiro-manual то же, но ручным копированием, без телеметрии
#    * Предлагает обновление прошивок (fwupd) — BIOS-апдейт чинит фризы тачпада
#    * Быстрая самодиагностика (CPU-драйвер, VA-API, платформенные профили)
#
#  Использование:  ./post-install.sh [--face-unlock] [--npu] [--ilyamiro | --ilyamiro-manual]
# ============================================================================
set -Eeuo pipefail

C_GREEN=$'\e[1;32m'; C_RED=$'\e[1;31m'; C_YELLOW=$'\e[1;33m'; C_BLUE=$'\e[1;34m'; C_OFF=$'\e[0m'
log()  { echo "${C_GREEN}[post]${C_OFF} $*"; }
warn() { echo "${C_YELLOW}[внимание]${C_OFF} $*"; }
die()  { echo "${C_RED}[ошибка]${C_OFF} $*" >&2; exit 1; }
step() { echo; echo "${C_BLUE}==> $*${C_OFF}"; }
trap 'die "Прервано на строке $LINENO (команда: $BASH_COMMAND)"' ERR

[[ $EUID -ne 0 ]] || die "Запускайте от обычного пользователя, НЕ от root."
ping -c1 -W3 archlinux.org &>/dev/null || ping -c1 -W3 1.1.1.1 &>/dev/null || die "Нет интернета."

OPT_FACE=0; OPT_NPU=0; OPT_ILYAMIRO=0; OPT_ILYAMIRO_MANUAL=0
for a in "$@"; do
    case "$a" in
        --face-unlock)     OPT_FACE=1 ;;
        --npu)             OPT_NPU=1 ;;
        --ilyamiro)        OPT_ILYAMIRO=1 ;;
        --ilyamiro-manual) OPT_ILYAMIRO_MANUAL=1 ;;
        *) die "Неизвестный флаг: $a" ;;
    esac
done

# ----------------------------------------------------------------------------
# 1. paru — AUR-хелпер
# ----------------------------------------------------------------------------
step "Установка paru (AUR-хелпер)"
if ! command -v paru &>/dev/null; then
    sudo pacman -S --needed --noconfirm base-devel git
    tmpdir="$(mktemp -d)"
    git clone --depth 1 https://aur.archlinux.org/paru-bin.git "$tmpdir/paru-bin"
    ( cd "$tmpdir/paru-bin" && makepkg -si --noconfirm )
    rm -rf "$tmpdir"
else
    log "paru уже установлен."
fi

# ----------------------------------------------------------------------------
# 2. AUR-пакеты под это железо и внешний вид
# ----------------------------------------------------------------------------
step "AUR: фан-профили UM5606 + курсоры Bibata"

# asus-5606-fan-state-git — управление 4 фирменными фан-профилями прошивки.
# Использование: sudo fan_state set quiet|standard|high|full  (или 0-3), fan_state get
paru -S --needed --noconfirm \
    asus-5606-fan-state-git \
    bibata-cursor-theme-bin

log "Курсор Bibata установлен. Раскомментируйте в ~/.config/hypr/hyprland.conf:"
log '    env = XCURSOR_THEME,Bibata-Modern-Classic'

# ----------------------------------------------------------------------------
# 3. Опция: разблокировка лицом (IR-камера; сканера отпечатков в UM5606WA нет)
# ----------------------------------------------------------------------------
if [[ $OPT_FACE -eq 1 ]]; then
    step "Face-unlock: howdy + linux-enable-ir-emitter"
    paru -S --needed --noconfirm howdy linux-enable-ir-emitter
    warn "Дальнейшая настройка вручную (см. README): sudo linux-enable-ir-emitter configure,"
    warn "затем sudo howdy add и PAM-конфигурация."
fi

# ----------------------------------------------------------------------------
# 4. Опция: NPU (AMD XDNA, Ryzen AI)
# ----------------------------------------------------------------------------
if [[ $OPT_NPU -eq 1 ]]; then
    step "NPU: XRT + плагин amdxdna (эксперименты с Ryzen AI)"
    sudo pacman -S --needed --noconfirm xrt xrt-plugin-amdxdna
    log "Проверка: ls /dev/accel/ (должен появиться accel0 — драйвер amdxdna в ядре 6.14+)."
fi

# ----------------------------------------------------------------------------
# 5. Опция: рабочий стол ilyamiro (тот самый nixos-configuration, но для Arch)
# ----------------------------------------------------------------------------
# Репозиторий ilyamiro/nixos-configuration — конфиг NixOS, напрямую на Arch его
# поставить НЕЛЬЗЯ. Но 90% его содержимого — портируемые дотфайлы (Quickshell/QML
# рабочий стол для Hyprland), и автор ведёт зеркальный репозиторий
# ilyamiro/imperative-dots с официальным установщиком именно для Arch.
if [[ $OPT_ILYAMIRO -eq 1 ]]; then
    step "Дотфайлы ilyamiro — ОФИЦИАЛЬНЫЙ установщик imperative-dots"
    warn "Этот установщик:"
    warn "  • ПЕРЕЗАПИШЕТ конфиги hypr/kitty/rofi и др. (сделает бэкап в ~/.config-backup-<время>)"
    warn "  • Отправляет анонимную телеметрию (UUID, ОС, ядро, RAM, CPU/GPU) на сервер автора"
    warn "  • Заменит тему SDDM astronaut на свою matugen-minimal (вернуть astronaut: см. README)"
    read -rp "Продолжить? Введите yes: " ok
    if [[ "$ok" == "yes" ]]; then
        bash -c "$(curl -fsSL https://raw.githubusercontent.com/ilyamiro/imperative-dots/master/install.sh)"
        echo
        warn "Если хотите вернуть экран входа astronaut вместо matugen-minimal:"
        warn '  echo -e "[Theme]\nCurrent=sddm-astronaut-theme" | sudo tee /etc/sddm.conf.d/10-theme.conf'
    else
        log "Пропущено."
    fi
fi

if [[ $OPT_ILYAMIRO_MANUAL -eq 1 ]]; then
    step "Дотфайлы ilyamiro — ручной порт (без телеметрии, без установщика автора)"
    warn "Конфиги hypr/kitty/cava/matugen/nvim/zsh будут скопированы в ~/.config"
    warn "(существующие каталоги будут сохранены в ~/.config-backup-\$(дата))."
    read -rp "Продолжить? Введите yes: " ok
    if [[ "$ok" == "yes" ]]; then
        # Пакеты, которые использует этот рабочий стол (сверено с install.sh автора):
        # quickshell-git — QML-оболочка (панель, локскрин, лаунчер); matugen-bin — цвета
        # из обоев (Material You); awww — анимированные обои (преемник swww).
        paru -S --needed --noconfirm \
            quickshell-git matugen-bin \
            rofi cava swayosd-git mpvpaper \
            pamixer libnotify socat jq fd ripgrep imagemagick bc \
            inotify-tools zbar yq \
            qt6-multimedia qt6-websockets python-websockets

        backup=~/.config-backup-$(date +%Y%m%d-%H%M%S)
        mkdir -p "$backup"
        git clone --depth 1 https://github.com/ilyamiro/imperative-dots.git ~/.hyprland-dots
        for d in hypr kitty cava matugen nvim zsh; do
            [[ -d ~/.hyprland-dots/.config/$d ]] || continue
            [[ -d ~/.config/$d ]] && mv ~/.config/"$d" "$backup"/
            cp -r ~/.hyprland-dots/.config/"$d" ~/.config/
        done
        mkdir -p ~/.local/share/fonts
        cp -r ~/.hyprland-dots/.local/share/fonts/* ~/.local/share/fonts/ 2>/dev/null || true
        fc-cache -f
        # В скриптах автора обои вызываются как swww — в репах Arch пакет переименован в awww
        find ~/.config/hypr -type f \( -name '*.sh' -o -name '*.conf' \) \
            -exec sed -i -e 's/swww-daemon/awww-daemon/g' -e 's/\bswww\b/awww/g' {} +
        sudo systemctl enable --now swayosd-libinput-backend.service || true
        log "Готово. Бэкап старых конфигов: $backup"
        warn "Перелогиньтесь (Hyprland перечитает конфиг). Панель тут — Quickshell, не waybar."
    else
        log "Пропущено."
    fi
fi

# ----------------------------------------------------------------------------
# 6. Обновление прошивок (BIOS-апдейт чинит периодические фризы тачпада)
# ----------------------------------------------------------------------------
step "Прошивки (fwupd / LVFS)"
read -rp "Проверить обновления прошивок сейчас? [y/N]: " r
if [[ "${r,,}" == "y" ]]; then
    fwupdmgr refresh || true
    fwupdmgr get-updates || true
    warn "Если есть обновление BIOS — ставьте (fwupdmgr update), оно чинит фризы тачпада."
fi

# ----------------------------------------------------------------------------
# 7. Самодиагностика
# ----------------------------------------------------------------------------
step "Самодиагностика"

echo -n "  CPU-драйвер:        "; cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo "н/д"
echo -n "  EPP-профиль:        "; cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo "н/д"
echo -n "  Платформ. профили:  "; cat /sys/firmware/acpi/platform_profile_choices 2>/dev/null || echo "н/д"
echo -n "  Лимит заряда:       "; cat /sys/class/power_supply/BAT*/charge_control_end_threshold 2>/dev/null || echo "н/д"
echo -n "  zram:               "; zramctl --noheadings 2>/dev/null | awk '{print $1, $3}' || echo "н/д"
echo -n "  zswap выключен (N): "; cat /sys/module/zswap/parameters/enabled 2>/dev/null || echo "н/д"
echo -n "  sched-ext:          "; cat /sys/kernel/sched_ext/root/ops 2>/dev/null || echo "(scx_loader стартует при загрузке)"
echo    "  VA-API:             $(vainfo 2>/dev/null | grep -c 'VAProfile' || echo 0) профилей декодирования"
echo -n "  Сжатие btrfs (/):   "; sudo compsize -x / 2>/dev/null | awk 'NR==2 {print $1, "использовано", $3, "из", $4}' || echo "н/д"

step "Готово!"
echo "
  Полезное:
    powerprofilesctl set power-saver|balanced|performance   — профиль питания
    sudo fan_state set quiet|standard|high|full             — фан-профиль прошивки
    hyprctl keyword monitor \"eDP-1, 2880x1800@60, 0x0, 1.5\" — 60 Гц на батарее
    ~/.config/hypr/hyprland.conf                             — ваш конфиг Hyprland

  ОГРАНИЧЕНИЯ ЖЕЛЕЗА (не баги установки, см. README):
    • Встроенный ЦИФРОВОЙ микрофонный массив не работает в Linux —
      используйте «Internal Stereo Microphone» (аналоговый) или гарнитуру.
    • Клавиша Fn+F4 циклически меняет 4 уровня подсветки клавиатуры.
"
