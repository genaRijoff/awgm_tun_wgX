#!/bin/sh
#
# AWG Manager Tunnel Access for Keenetic + Entware
# Russian interface
#
# Purpose:
#   Give AWG Manager access through a selected Keenetic WireGuard
#   interface and provide a reliable rollback to the exact saved state.
#
# Requirements:
#   - KeeneticOS with ndmc
#   - Entware
#   - jq (opkg install jq)
#   - AWG Manager with /opt/etc/awg-manager/settings.json
#
# JSON layout this script edits (verified on schemaVersion 32):
#   .server.interfaces  -> array, e.g. ["br0"]
#   .server.port        -> number
#   .server.interface   -> NOT touched by this script (single primary iface)
#
# Run as root.
#

PATH="/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin:$PATH"

AWG_SETTINGS="/opt/etc/awg-manager/settings.json"
AWG_INIT="/opt/etc/init.d/S99awg-manager"
AWG_PKG="awg-manager"
# HTTP, а не HTTPS: официальная инструкция AWG Manager использует именно
# http://repo.hoaxisr.ru/install.sh, так как busybox wget на многих
# прошивках Keenetic не умеет TLS. Это только текст подсказки при ошибке
# (скрипт больше не выполняет установку сам), поэтому безопасно.
AWG_INSTALL_URL="http://repo.hoaxisr.ru/install.sh"
BACKUP_ROOT="/opt/etc/awg-manager/.tunnel-access-backup"
STATE_FILE="$BACKUP_ROOT/state.tsv"
FULL_SETTINGS="$BACKUP_ROOT/settings.json"
LOCK_FILE="/tmp/awg-manager-tunnel-access.lock"

say() { printf '%s\n' "$*"; }
die() { say "ОШИБКА: $*" >&2; exit 1; }

cleanup() { rm -f "$LOCK_FILE"; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

[ "$(id -u 2>/dev/null)" = "0" ] || die "скрипт нужно запускать от root"
command -v opkg >/dev/null 2>&1 || die "не найден opkg (нужен Entware)"
command -v jq >/dev/null 2>&1 || die "не найден jq (opkg install jq)"
command -v ndmc >/dev/null 2>&1 || die "не найден ndmc"

# Stale-lock aware locking: store PID, verify liveness on collision.
if [ -e "$LOCK_FILE" ]; then
    old_pid="$(cat "$LOCK_FILE" 2>/dev/null)"
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        die "скрипт уже выполняется (pid $old_pid)"
    else
        say "Найден протухший lock-файл (pid $old_pid не активен) — снимаю."
        rm -f "$LOCK_FILE"
    fi
fi
printf '%s\n' "$$" > "$LOCK_FILE"

# Этот скрипт не устанавливает и не обновляет AWG Manager — это отдельная
# задача. Здесь только проверка, что пакет установлен и рабочий.
if ! opkg list-installed 2>/dev/null | grep -q "^$AWG_PKG - "; then
    die "AWG Manager не установлен. Установка: wget -qO- $AWG_INSTALL_URL | sh"
fi

[ -f "$AWG_SETTINGS" ] || die "не найден $AWG_SETTINGS"
[ -x "$AWG_INIT" ] || die "не найден $AWG_INIT"

jq empty "$AWG_SETTINGS" 2>/dev/null || die "$AWG_SETTINGS повреждён (невалидный JSON)"

ndmc_cmd() {
    ndmc -c "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# jq helpers — all reads/writes of settings.json go through these
# ---------------------------------------------------------------------------

get_server_port() {
    p="$(jq -r '.server.port // empty' "$AWG_SETTINGS" 2>/dev/null)"
    case "$p" in
        ''|*[!0-9]*) printf '2222\n' ;;
        *) printf '%s\n' "$p" ;;
    esac
}

# Returns 0 (true) if iface is already present in .server.interfaces
interface_present() {
    iface="$1"
    jq -e --arg i "$iface" '.server.interfaces | index($i) != null' \
        "$AWG_SETTINGS" >/dev/null 2>&1
}

# Atomically add an interface to .server.interfaces (no-op if present).
add_interface_to_awg() {
    linux="$1"

    if interface_present "$linux"; then
        return 0
    fi

    tmp="/tmp/awg-settings.$$.json"
    jq --arg i "$linux" \
       '.server.interfaces = ((.server.interfaces // []) + [$i] | unique)' \
       "$AWG_SETTINGS" > "$tmp" 2>/dev/null

    [ -s "$tmp" ] || { rm -f "$tmp"; die "jq вернул пустой результат при добавлении $linux"; }
    jq empty "$tmp" 2>/dev/null || { rm -f "$tmp"; die "jq сгенерировал невалидный JSON"; }

    if ! jq -e --arg i "$linux" '.server.interfaces | index($i) != null' "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        die "не удалось добавить $linux в .server.interfaces"
    fi

    mv "$tmp" "$AWG_SETTINGS" || die "не удалось сохранить settings.json"
}

# Atomically remove an interface from .server.interfaces (no-op if absent).
remove_interface_from_awg() {
    linux="$1"

    interface_present "$linux" || return 0

    tmp="/tmp/awg-settings.$$.json"
    jq --arg i "$linux" \
       '.server.interfaces = ((.server.interfaces // []) - [$i])' \
       "$AWG_SETTINGS" > "$tmp" 2>/dev/null

    [ -s "$tmp" ] || { rm -f "$tmp"; die "jq вернул пустой результат при удалении $linux"; }
    jq empty "$tmp" 2>/dev/null || { rm -f "$tmp"; die "jq сгенерировал невалидный JSON"; }

    mv "$tmp" "$AWG_SETTINGS" || die "не удалось сохранить settings.json"
}

# ---------------------------------------------------------------------------
# WireGuard interface discovery (Keenetic CLI side)
# ---------------------------------------------------------------------------

list_wg_interfaces() {
    i=0
    while [ "$i" -lt 64 ]; do
        out="$(ndmc_cmd "show interface Wireguard$i")"
        echo "$out" | grep -q 'type: Wireguard' || {
            i=$((i + 1))
            continue
        }

        ip="$(echo "$out" | sed -n 's/^[[:space:]]*address:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -n 1)"
        desc="$(echo "$out" | sed -n 's/^[[:space:]]*description:[[:space:]]*\(.*\)$/\1/p' | head -n 1)"
        sec="$(echo "$out" | sed -n 's/^[[:space:]]*security-level:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -n 1)"
        state="$(echo "$out" | sed -n 's/^[[:space:]]*state:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -n 1)"
        link="$(echo "$out" | sed -n 's/^[[:space:]]*link:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -n 1)"

        [ -n "$ip" ] || ip="-"
        [ -n "$desc" ] || desc="-"
        [ -n "$sec" ] || sec="-"
        [ -n "$state" ] || state="-"
        [ -n "$link" ] || link="-"

        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "Wireguard$i" "$ip" "$desc" "$sec" "$state" "$link"

        i=$((i + 1))
    done
}

get_linux_name() {
    # Keenetic WireguardN normally maps to nwgN. We verify it exists.
    n="${1#Wireguard}"
    if ip link show "nwg$n" >/dev/null 2>&1; then
        printf 'nwg%s\n' "$n"
    else
        printf '%s\n' "-"
    fi
}

show_wg_list() {
    TMP="/tmp/awg-wg-list.$$"
    list_wg_interfaces > "$TMP"
    if [ ! -s "$TMP" ]; then
        rm -f "$TMP"
        say "WireGuard-интерфейсы не найдены."
        return 1
    fi

    say ""
    say "WireGuard:"
    while IFS="$(printf '\t')" read -r name ip desc sec state link; do
        printf '  %-11s %-15s %-9s %s (%s/%s)\n' "$name" "$ip" "$sec" "$desc" "$state" "$link"
    done < "$TMP"
    rm -f "$TMP"
}

select_wg() {
    TMP="/tmp/awg-wg-list.$$"
    list_wg_interfaces > "$TMP"
    [ -s "$TMP" ] || {
        rm -f "$TMP"
        return 1
    }

    say ""
    say "Выберите WireGuard:"
    say ""
    n=1
    while IFS="$(printf '\t')" read -r name ip desc sec state link; do
        printf '%s) %s — %s — %s\n' "$n" "$name" "$ip" "$desc"
        n=$((n + 1))
    done < "$TMP"

    printf "Выбор [1-%s, 0=отмена]: " "$((n - 1))"
    read choice

    case "$choice" in
        0|"") rm -f "$TMP"; return 1 ;;
    esac

    case "$choice" in
        *[!0-9]*) rm -f "$TMP"; return 1 ;;
    esac

    selected="$(sed -n "${choice}p" "$TMP")"
    rm -f "$TMP"
    [ -n "$selected" ] || return 1

    OLD_IFS="$IFS"
    IFS="$(printf '\t')"
    set -- $selected
    IFS="$OLD_IFS"

    SEL_NAME="$1"
    SEL_IP="$2"
    SEL_DESC="$3"
    SEL_SEC="$4"
    SEL_STATE="$5"
    SEL_LINK="$6"
    SEL_LINUX="$(get_linux_name "$SEL_NAME")"
    return 0
}

# ---------------------------------------------------------------------------
# Backup / restore
# ---------------------------------------------------------------------------

ensure_backup() {
    mkdir -p "$BACKUP_ROOT" || die "не удалось создать $BACKUP_ROOT"

    # Create the original snapshot only once. This is the rollback point.
    if [ ! -f "$FULL_SETTINGS" ]; then
        extra="$(jq -r '.server.interfaces // [] | map(select(. != "br0")) | .[]' "$AWG_SETTINGS" 2>/dev/null)"
        if [ -n "$extra" ]; then
            say ""
            say "ВНИМАНИЕ: в settings.json уже есть интерфейсы, кроме br0:"
            printf '%s\n' "$extra" | while IFS= read -r e; do say "  - $e"; done
            say "Это состояние будет сохранено как точка отката (\"исходное\")."
            say "Если это не так — сначала поправь settings.json/security-level вручную."
            printf "Продолжить и считать текущее состояние исходным? [y/N]: "
            read confirm_extra
            case "$confirm_extra" in
                y|Y|д|Д) ;;
                *) die "Отменено пользователем." ;;
            esac
        fi
        cp -p "$AWG_SETTINGS" "$FULL_SETTINGS" || die "не удалось сохранить settings.json"
    fi

    [ -f "$STATE_FILE" ] || : > "$STATE_FILE"

    if ! grep -q "^$SEL_NAME	" "$STATE_FILE" 2>/dev/null; then
        # Append atomically: write to tmp, then replace.
        tmp="/tmp/awg-state.$$.tsv"
        cp -p "$STATE_FILE" "$tmp" 2>/dev/null || : > "$tmp"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$SEL_NAME" "$SEL_IP" "$SEL_SEC" "$SEL_LINUX" "$SEL_DESC" \
            "$(date '+%Y-%m-%d %H:%M:%S')" >> "$tmp"
        mv "$tmp" "$STATE_FILE" || die "не удалось обновить $STATE_FILE"
    fi
}

set_security_level() {
    iface="$1"
    level="$2"
    ndmc_cmd "interface $iface security-level $level" >/dev/null || \
        die "не удалось установить security-level $level для $iface"
}

save_keenetic() {
    ndmc_cmd "system configuration save" >/dev/null || \
        die "не удалось сохранить конфигурацию Keenetic"
}

restart_awg() {
    "$AWG_INIT" restart >/dev/null 2>&1 || {
        say "ПРЕДУПРЕЖДЕНИЕ: AWG Manager не подтвердил перезапуск."
        return 1
    }
    return 0
}

port_is_listening() {
    ipaddr="$1"
    port="$2"
    netstat -lnpt 2>/dev/null | grep -q "${ipaddr}:${port}[[:space:]]"
}

# Ждёт до $max_wait секунд, пока AWG Manager не начнёт слушать порт.
# После рестарта демону нужно время на инициализацию — мгновенная
# однократная проверка часто ловит ложное "не найдено".
wait_for_port() {
    ipaddr="$1"
    port="$2"
    max_wait=10

    if ! command -v netstat >/dev/null 2>&1; then
        say "ПРЕДУПРЕЖДЕНИЕ: netstat недоступен, проверка порта пропущена."
        return 2
    fi

    say "Проверка порта..."
    elapsed=0
    while [ "$elapsed" -lt "$max_wait" ]; do
        if port_is_listening "$ipaddr" "$port"; then
            return 0
        fi
        elapsed=$((elapsed + 1))
        say "  $elapsed секунд..."
        sleep 1
    done

    port_is_listening "$ipaddr" "$port" && return 0
    return 1
}

# ---------------------------------------------------------------------------
# Main actions
# ---------------------------------------------------------------------------

configure_access() {
    select_wg || return 0

    [ "$SEL_IP" != "-" ] || {
        say "У выбранного интерфейса нет IPv4-адреса."
        return 1
    }

    [ "$SEL_LINUX" != "-" ] || {
        say "Не найден Linux-интерфейс $SEL_NAME -> ожидается nwgN."
        return 1
    }

    say ""
    say "Выбран:"
    say "  Интерфейс: $SEL_NAME"
    say "  IP:        $SEL_IP"
    say "  Описание:  $SEL_DESC"
    say "  Было:      security-level $SEL_SEC"
    say "  Linux:     $SEL_LINUX"
    say ""

    printf "Продолжить? [y/N]: "
    read answer
    case "$answer" in
        y|Y|д|Д) ;;
        *) say "Отменено."; return 0 ;;
    esac

    ensure_backup

    # Backup current settings too, for diagnostics.
    cp -p "$AWG_SETTINGS" "$BACKUP_ROOT/settings.before.$SEL_NAME.json" 2>/dev/null

    say "[1/4] Добавляю $SEL_LINUX в AWG Manager (.server.interfaces)..."
    add_interface_to_awg "$SEL_LINUX"

    say "[2/4] Устанавливаю $SEL_NAME = private..."
    set_security_level "$SEL_NAME" "private"

    say "[3/4] Сохраняю конфигурацию Keenetic..."
    save_keenetic

    say "[4/4] Перезапускаю AWG Manager..."
    restart_awg

    port="$(get_server_port)"
    say ""
    wait_for_port "$SEL_IP" "$port"
    case "$?" in
        0) say "OK: AWG Manager слушает $SEL_IP:$port" ;;
        1) say "ПРЕДУПРЕЖДЕНИЕ: $SEL_IP:$port не обнаружен в LISTEN за 10 секунд."
           say "Проверь: netstat -lnpt | grep $port" ;;
        2) : ;; # already warned inside wait_for_port
    esac

    say ""
    say "Адрес AWG Manager:"
    say "  http://$SEL_IP:$port"
    say ""
    say "Точка отката сохранена в:"
    say "  $FULL_SETTINGS"
    say "  $STATE_FILE"
}

restore_all() {
    if [ ! -f "$FULL_SETTINGS" ] && [ ! -f "$STATE_FILE" ]; then
        say ""
        say "Сохранённого состояния нет."
        return 0
    fi

    say ""
    say "Будут восстановлены изменения этого скрипта."
    say "Исходный settings.json: $FULL_SETTINGS"
    say ""

    printf "ТОЧНО вернуть всё как было? [y/N]: "
    read answer
    case "$answer" in
        y|Y|д|Д) ;;
        *) say "Отменено."; return 0 ;;
    esac

    fail_count=0

    # Restore exact original AWG settings.
    if [ -f "$FULL_SETTINGS" ]; then
        jq empty "$FULL_SETTINGS" 2>/dev/null || die "резервный settings.json повреждён, откат остановлен"
        cp -p "$FULL_SETTINGS" "$AWG_SETTINGS" || die "не удалось восстановить settings.json"
        say "[+] settings.json восстановлен"
    fi

    # Restore exact original security levels.
    if [ -f "$STATE_FILE" ]; then
        while IFS="$(printf '\t')" read -r iface ip oldsec linux desc timestamp; do
            [ -n "$iface" ] || continue
            [ -n "$oldsec" ] || continue

            say "[+] $iface -> security-level $oldsec"
            if ! ndmc_cmd "interface $iface security-level $oldsec" >/dev/null; then
                say "    ПРЕДУПРЕЖДЕНИЕ: не удалось восстановить $iface"
                fail_count=$((fail_count + 1))
            fi
        done < "$STATE_FILE"
    fi

    say "[+] Сохраняю конфигурацию Keenetic..."
    save_keenetic

    say "[+] Перезапускаю AWG Manager..."
    restart_awg

    say ""
    if [ "$fail_count" -gt 0 ]; then
        say "Откат завершён С ОШИБКАМИ ($fail_count интерфейс(ов) не восстановлены)."
        say "Проверь вручную: ndmc -c \"show interface WireguardN\""
        say "Резервная копия НЕ удалена (нужна для повторной попытки):"
        say "  $BACKUP_ROOT"
    else
        say "Откат завершён."
        # Полный успех: точка отката больше не актуальна для будущих
        # запусков — снимаем её, чтобы следующий configure_access() снял
        # свежий снапшот текущего (уже восстановленного) состояния, а не
        # унаследовал точку отката от самого первого запуска скрипта.
        rm -f "$FULL_SETTINGS" "$STATE_FILE"
        rm -f "$BACKUP_ROOT"/settings.before.*.json 2>/dev/null
        say "Точка отката снята — при следующей настройке будет создана заново."
    fi
}

show_status() {
    port="$(get_server_port)"

    say ""
    say "=== Состояние ==="
    show_wg_list

    say ""
    say "AWG Manager: порт $port, interfaces $(jq -c '.server.interfaces' "$AWG_SETTINGS" 2>/dev/null)"

    if command -v netstat >/dev/null 2>&1; then
        listen="$(netstat -lnpt 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {print $4}')"
        if [ -n "$listen" ]; then
            say "  LISTEN: $(printf '%s' "$listen" | tr '\n' ' ')"
        else
            say "  LISTEN на порту $port не найден"
        fi
    else
        say "  (netstat недоступен)"
    fi

    say ""
    if [ -f "$STATE_FILE" ]; then
        say "Точка отката: $BACKUP_ROOT"
        say "Изменённые интерфейсы:"
        while IFS="$(printf '\t')" read -r iface ip oldsec linux desc ts; do
            [ -n "$iface" ] || continue
            printf '  %-11s было: %-8s %s (%s)\n' "$iface" "$oldsec" "$linux" "$ts"
        done < "$STATE_FILE"
    else
        say "Точка отката отсутствует."
    fi
}

menu() {
    while :; do
        say ""
        say "========================================"
        say " AWG Manager — доступ через WireGuard"
        say "========================================"
        say ""
        say "1. Настроить доступ через туннель"
        say "2. Вернуть ВСЁ как было"
        say "3. Показать текущую конфигурацию"
        say "0. Выход"
        say ""

        printf "Выберите [0-3]: "
        read choice

        case "$choice" in
            1) configure_access ;;
            2) restore_all ;;
            3) show_status ;;
            0) exit 0 ;;
            *) say "Неверный выбор." ;;
        esac
    done
}

menu
