#!/bin/sh
#
# AWG Manager Tunnel Access for Keenetic + Entware
# Russian interface
#
# Purpose:
#   Give AWG Manager :2222 access through a selected Keenetic WireGuard
#   interface and provide a reliable rollback to the exact saved state.
#
# Requirements:
#   - KeeneticOS with ndmc
#   - Entware
#   - AWG Manager with /opt/etc/awg-manager/settings.json
#
# Run as root.
#

PATH="/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin:$PATH"

AWG_SETTINGS="/opt/etc/awg-manager/settings.json"
AWG_INIT="/opt/etc/init.d/S99awg-manager"
BACKUP_ROOT="/opt/etc/awg-manager/.tunnel-access-backup"
STATE_FILE="$BACKUP_ROOT/state.tsv"
FULL_SETTINGS="$BACKUP_ROOT/settings.json"
LOCK_FILE="/tmp/awg-manager-tunnel-access.lock"

say() { printf '%s\n' "$*"; }
die() { say "ОШИБКА: $*" >&2; exit 1; }

cleanup() { rm -f "$LOCK_FILE"; }
trap cleanup EXIT INT TERM

[ "$(id -u 2>/dev/null)" = "0" ] || die "скрипт нужно запускать от root"
[ -f "$AWG_SETTINGS" ] || die "не найден $AWG_SETTINGS"
[ -x "$AWG_INIT" ] || die "не найден $AWG_INIT"

if [ -e "$LOCK_FILE" ]; then
    die "скрипт уже выполняется"
fi
: > "$LOCK_FILE"

ndmc_cmd() {
    ndmc -c "$1" 2>/dev/null
}

# Extract a value from: "key": value / key: value
json_string() {
    key="$1"
    file="$2"
    sed -n 's/^[[:space:]]*"'"$key"'":[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n 1
}

json_number() {
    key="$1"
    file="$2"
    sed -n 's/^[[:space:]]*"'"$key"'":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$file" | head -n 1
}

get_server_port() {
    p=$(json_number port "$AWG_SETTINGS")
    [ -n "$p" ] && printf '%s\n' "$p" || printf '2222\n'
}

# Read WireGuard interfaces from Keenetic CLI.
# We intentionally use CLI names Wireguard0, Wireguard1, ... rather than
# Linux names nwg0, nwg1, ... .
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
    say "Доступные WireGuard:"
    say ""
    n=1
    while IFS="$(printf '\t')" read -r name ip desc sec state link; do
        printf '%s) %s\n' "$n" "$name"
        printf '   IP: %s\n' "$ip"
        printf '   Описание: %s\n' "$desc"
        printf '   Security: %s\n' "$sec"
        printf '   State: %s / Link: %s\n' "$state" "$link"
        n=$((n + 1))
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

ensure_backup() {
    mkdir -p "$BACKUP_ROOT" || die "не удалось создать $BACKUP_ROOT"

    # Create the original snapshot only once. This is the rollback point.
    if [ ! -f "$FULL_SETTINGS" ]; then
        cp -p "$AWG_SETTINGS" "$FULL_SETTINGS" || die "не удалось сохранить settings.json"
    fi

    # Store the original security level per interface only once.
    if [ ! -f "$STATE_FILE" ]; then
        : > "$STATE_FILE"
    fi

    if ! grep -q "^$SEL_NAME	" "$STATE_FILE" 2>/dev/null; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$SEL_NAME" "$SEL_IP" "$SEL_SEC" "$SEL_LINUX" "$SEL_DESC" \
            "$(date '+%Y-%m-%d %H:%M:%S')" >> "$STATE_FILE"
    fi
}

add_interface_to_awg() {
    linux="$1"

    # Already present?
    if grep -q '"'"$linux"'"' "$AWG_SETTINGS"; then
        return 0
    fi

    # The usual AWG Manager JSON layout is:
    # "interfaces": [
    #   "br0"
    # ]
    #
    # Insert before the closing ] of the interfaces array only.
    tmp="/tmp/awg-settings.$$"
    awk -v add="$linux" '
        BEGIN { in_if=0; done=0 }
        /"interfaces"[[:space:]]*:[[:space:]]*\[/ {
            in_if=1
            print
            next
        }
        in_if && /^[[:space:]]*\][[:space:]]*,?[[:space:]]*$/ && !done {
            # If the previous element exists, add a comma to it.
            if (last ~ /"[^"]+"/) {
                sub(/[[:space:]]*,?[[:space:]]*$/, ",", last)
                print last
            }
            printf "      \"%s\"\n", add
            print
            done=1
            in_if=0
            next
        }
        in_if {
            if (last != "") print last
            last=$0
            next
        }
        { print }
        END {
            if (in_if && !done) {
                if (last != "") print last
                printf "      \"%s\"\n", add
                print "    ]"
            }
        }
    ' "$AWG_SETTINGS" > "$tmp" || {
        rm -f "$tmp"
        die "не удалось изменить settings.json"
    }

    # Validate that the requested interface was inserted.
    grep -q '"'"$linux"'"' "$tmp" || {
        rm -f "$tmp"
        die "не удалось добавить $linux в interfaces"
    }

    mv "$tmp" "$AWG_SETTINGS" || die "не удалось сохранить settings.json"
}

set_security_private() {
    iface="$1"
    ndmc_cmd "interface $iface security-level private" >/dev/null || \
        die "не удалось установить security-level private для $iface"
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

check_port() {
    ipaddr="$1"
    port="$2"
    netstat -lnpt 2>/dev/null | grep -q "${ipaddr}:${port}[[:space:]]" && return 0
    return 1
}

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

    say "[1/4] Добавляю $SEL_LINUX в AWG Manager..."
    add_interface_to_awg "$SEL_LINUX"

    say "[2/4] Устанавливаю $SEL_NAME = private..."
    set_security_private "$SEL_NAME"

    say "[3/4] Сохраняю конфигурацию Keenetic..."
    save_keenetic

    say "[4/4] Перезапускаю AWG Manager..."
    restart_awg

    port="$(get_server_port)"
    say ""
    say "Проверка:"
    if check_port "$SEL_IP" "$port"; then
        say "OK: AWG Manager слушает $SEL_IP:$port"
    else
        say "ПРЕДУПРЕЖДЕНИЕ: $SEL_IP:$port пока не обнаружен в LISTEN."
        say "Проверь: netstat -lnpt | grep $port"
    fi

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

    # Restore exact original AWG settings.
    if [ -f "$FULL_SETTINGS" ]; then
        cp -p "$FULL_SETTINGS" "$AWG_SETTINGS" || die "не удалось восстановить settings.json"
        say "[+] settings.json восстановлен"
    fi

    # Restore exact original security levels.
    if [ -f "$STATE_FILE" ]; then
        while IFS="$(printf '\t')" read -r iface ip oldsec linux desc timestamp; do
            [ -n "$iface" ] || continue
            [ -n "$oldsec" ] || continue

            say "[+] $iface -> security-level $oldsec"
            ndmc_cmd "interface $iface security-level $oldsec" >/dev/null || \
                say "    ПРЕДУПРЕЖДЕНИЕ: не удалось восстановить $iface"
        done < "$STATE_FILE"
    fi

    say "[+] Сохраняю конфигурацию Keenetic..."
    save_keenetic

    say "[+] Перезапускаю AWG Manager..."
    restart_awg

    say ""
    say "Откат завершён."
    say "Резервная копия НЕ удалена:"
    say "  $BACKUP_ROOT"
}

show_status() {
    port="$(get_server_port)"
    say ""
    say "=== Текущее состояние ==="
    say ""
    show_wg_list

    say ""
    say "AWG Manager:"
    say "  Порт: $port"

    if netstat -lnpt 2>/dev/null | grep -q ":$port[[:space:]]"; then
        netstat -lnpt 2>/dev/null | grep ":$port[[:space:]]"
    else
        say "  LISTEN на порту $port не найден"
    fi

    say ""
    if [ -f "$STATE_FILE" ]; then
        say "Точка отката существует:"
        say "  $BACKUP_ROOT"
        say ""
        say "Изменённые интерфейсы:"
        cat "$STATE_FILE"
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
