# AWG Manager Tunnel Access

Доступ к **AWG Manager** через выбранный WireGuard-туннель на Keenetic.  
Автоматический поиск `WireguardX` и `nwgX` и выбор нужного туннеля.  
Настройка доступа к AWG Manager через `:2222`.  
Создание backup и полный откат всех изменений.

## Установка

Требуется **Keenetic + Entware + AWG Manager**.

```sh
wget -O /opt/tmp/awg-manager-tunnel-access.sh https://raw.githubusercontent.com/genaRijoff/awgm_tun_wgX/main/awg-manager-tunnel-access.sh
chmod +x /opt/tmp/awg-manager-tunnel-access.sh
/opt/tmp/awg-manager-tunnel-access.sh
```

## Меню

```text
1. Настроить доступ через туннель
2. Вернуть ВСЁ как было
3. Показать текущую конфигурацию
0. Выход
```

После настройки AWG Manager доступен по адресу:

```text
http://<IP WireGuard>:2222
```
