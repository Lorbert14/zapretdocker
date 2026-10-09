# Zapret VPN Gateway для umbrelOS

Комбинированное приложение для **Umbrel App Store**: собственный **WireGuard VPN-шлюз** для iPhone и **прозрачный обход DPI (zapret)** для выбранных Docker-контейнеров Umbrel (yt-dlp, cobalt и других сервисов скачивания контента). Стратегии обхода взяты из проекта [SergeyDiGi3/zapret-discord-youtube-linux](https://github.com/Sergeydigl3/zapret-discord-youtube-linux) (nfqws от bol-van/zapret, списки и стратегии Flowseal).

## Возможности

- **WireGuard VPN для iPhone/iOS** — добавление клиента в 2 клика, QR-код прямо в веб-панели (и в логах контейнера `qrencode -t ANSIUTF8`), скачивание `.conf`-файла.
- **Выборочный проброс контейнеров** — трафик выбранных контейнеров Umbrel (YouTube, Discord и т.д.) идёт через nfqws с проверенными стратегиями `dpi-desync` (multisplit, fake QUIC/TLS, ip-id=zero, обман TTL).
- **Веб-панель** на `http://umbrel.local:8095` — статус, управление пирами WireGuard, управление маршрутами контейнеров.
- **Ничего не ломает** — изменение маршрута в контейнере затрагивает только его исходящий внешний трафик; доступ к UI по `umbrel.local:PORT` и внутренние сети Docker продолжают работать напрямую.

## Требования

- **umbrelOS 1.0+** (приложение использует `app_proxy` и сеть `umbrel_main_network`).
- Ядро с поддержкой WireGuard и NFQUEUE (штатное ядро umbrelOS подходит).

---

## Установка

### Способ 1: Кастомный App Store (рекомендуется)

1. Репозиторий со стором должен содержать в корне `umbrel-app-store.yml` и каталог `zapret-vpn-gateway/` со всеми файлами приложения (именно так устроен этот репозиторий).
2. На Umbrel откройте **Настройки → App Store → Community App Stores**.
3. Добавьте URL репозитория (например `https://github.com/Lorbert14/zapretvpn`).
4. Перейдите в магазин, найдите **Zapret VPN Gateway** и нажмите **Install**.

> Репозиторий должен быть **публичным**: umbrelOS загружает community-сторы по HTTPS без аутентификации.
> Если приложение не появилось — обновите магазин (кнопка обновления в App Store) или удалите и добавьте URL заново.

### Способ 2: локальная установка вручную

```bash
ssh umbrel@umbrel.local
mkdir -p ~/umbrel/app-data
cd ~/umbrel/app-data
# скопируйте папку приложения на устройство (scp/git clone) так, чтобы получился путь:
# ~/umbrel/app-data/zapret-vpn-gateway/{umbrel-app.yml, docker-compose.yml, ...}
sudo umbrel apps install zapret-vpn-gateway   # если приложение зарегистрировано в одном из подключённых магазинов
```

Либо собрать и запустить контейнер напрямую (для отладки):

```bash
cd ~/umbrel/app-data/zapret-vpn-gateway
docker compose build
APP_DATA_DIR=~/umbrel/app-data/zapret-vpn-gateway docker compose up -d
```

> При локальном запуске без Umbrel нужно самостоятельно создать сеть: `docker network create umbrel_main_network`.

После установки откройте **http://umbrel.local:8095**.

---

## Подключение iPhone

1. Откройте веб-панель `http://umbrel.local:8095` (или `http://umbrel.local:8095/?token=...`, если задан токен).
2. В блоке **WireGuard клиенты** введите имя (например `iphone`) и нажмите **Добавить клиента**.
3. В появившемся окне отсканируйте QR-код приложением **WireGuard** из App Store (или скачайте `.conf` и импортируйте его: WireGuard → «+» → «Создать из файла или архива»).
4. Включите туннель. Весь трафик iPhone пойдёт через вашу Umbrel с активным обходом DPI.

Клиентский конфиг генерируется автоматически:

```
[Interface]
PrivateKey = <ключ клиента>
Address = 10.11.12.N/32
DNS = 1.1.1.1

[Peer]
PublicKey = <ключ сервера>
AllowedIPs = 0.0.0.0/0
Endpoint = <ваш_адрес>:51820
PersistentKeepalive = 25
```

**Доступ из интернета:** по умолчанию в конфиге endpoint = `umbrel.local` (работает только в домашней Wi-Fi). Для доступа извне:

- пробросьте порт **51820/UDP** на роутере на IP вашей Umbrel;
- укажите в панели (Настройки) свой публичный домен/IP (например `myhome.duckdns.org`).

Обратите внимание: `umbrel.local` внутри VPN-туннеля не резолвится — для доступа к сервисам Umbrel через VPN используйте локальный IP устройства (например `http://192.168.1.10:8095`).

---

## Проброс контейнеров Umbrel через zapret

1. В панели откройте блок **Контейнеры Umbrel → zapret** (кнопка «Обновить список»).
2. У нужного контейнера (например `yt-dlp`, `cobalt`) нажмите **Через zapret**.
3. Демон маршрутизации выполнит внутри контейнера:

   ```bash
   docker exec <container> ip route replace default via <IP_шлюза>
   ```

4. Весь **внешний** трафик контейнера (YouTube, Discord и т.д.) пойдёт через шлюз с nfqws. **Внутренний** трафик (веб-UI по `umbrel.local:PORT`, локальные сети Docker) продолжает идти напрямую.

Что делает демон `route-manager.sh` (через `/var/run/docker.sock`):

- следит за списком выбранных контейнеров и их рестартами (при рестарте контейнера маршрут переприменяется автоматически);
- сохраняет исходный маршрут и восстанавливает его при отключении;
- при остановке приложения возвращает все маршруты в исходное состояние.

Ограничения:

- в контейнере должна быть утилита `ip` (есть в большинстве образов на базе Ubuntu/Debian/Alpine);
- если контейнер запущен без прав root/CAP_NET_ADMIN, изменение маршрута невозможно — в панели появится ошибка.

---

## Настройка (переменные окружения)

Переменные задаются в `docker-compose.yml` (в umbrelOS их можно переопределить при установке из магазина или в файле компоуза):

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `APP_ZAPRET_VPN_WG_PORT` | `51820` | UDP-порт WireGuard (публикуется на хосте) |
| `APP_ZAPRET_VPN_ENDPOINT` | `umbrel.local` (или `DEVICE_DOMAIN_NAME`) | Адрес сервера в конфигах клиентов |
| `APP_ZAPRET_VPN_WG_SUBNET` | `10.11.12.0/24` | Подсеть VPN-клиентов |
| `APP_ZAPRET_VPN_CLIENT_DNS` | `1.1.1.1` | DNS в конфигах клиентов |
| `APP_ZAPRET_VPN_MODE` | `nfqws` | `nfqws` / `tpws` / `both` / `none` |
| `APP_ZAPRET_VPN_STRATEGY` | `general` | `general` (multisplit) или `general_simple` (fake) |
| `APP_ZAPRET_VPN_ZAPRET_ALL` | `0` | `1` — применять dpi-desync ко всему трафику TCP 80/443 (осторожно!) |
| `APP_ZAPRET_VPN_GAMEFILTER` | `0` | `1` — включить gamefilter (порты 1024-65535) |
| `APP_ZAPRET_VPN_DEFAULT_PEER` | `iphone` | Имя клиента, создаваемого при первом запуске (QR печатается в логи) |
| `APP_ZAPRET_VPN_ROUTE_CONTAINERS` | `` | Контейнеры, включаемые через zapret при старте (через запятую) |
| `APP_ZAPRET_VPN_TOKEN` | `` | Необязательный токен для доступа к панели (`?token=...`) |

---

## Как это устроено

```
                     umbrelOS (хост)
                          │
        ┌─────────────────┼──────────────────┐
        │                 │                  │
  [контейнер yt-dlp]  [контейнер cobalt]  [zapret-vpn-gateway]
        │ 10.21.21.x        │                  │ 10.21.21.y (eth0, umbrel_main_network)
        │ default via       │ default via      │ wg0: 10.11.12.1/24 (WireGuard ← iPhone)
        ▼ 10.21.21.y        ▼ 10.21.21.y       │
        └──────────────────►│                  │
                            └─────► NFQUEUE(220) ─► nfqws (dpi-desync)
                                   MASQUERADE ──► интернет
```

1. **entrypoint.sh** — включает `net.ipv4.ip_forward=1`, поднимает WireGuard (`wg-quick`), ставит MASQUERADE, запускает zapret, демон маршрутизации и веб-панель.
2. **zapret.sh** — вешает правила `iptables` (mangle, `NFQUEUE --queue-num 220 --queue-bypass`, mark `0x40000000`, первые 6 пакетов соединения + первые 3 ответных) и запускает `nfqws` с параметрами стратегий Flowseal (multisplit `seqovl`, fake QUIC/TLS, `--ip-id=zero`, фейковые полезные нагрузки из `quic_initial_www_google_com.bin` и др.).
3. **route-manager.sh** — демон, через `/var/run/docker.sock` находит контейнеры, подменяет в них `ip route replace default via <gateway_ip>` и восстанавливает маршруты при выключении/остановке.
4. **server.py** — веб-панель и API (порт 8095): пиры WireGuard, QR (qrencode), маршруты контейнеров, статус.

### Список зон обхода (из стратегии general)

- **TCP 80, 443, 2053, 2083, 2087, 2096, 8443** — multisplit desync по hostlist'ам `list-general.txt`, `list-google.txt` (YouTube, googlevideo, Discord CDN и т.д.), с исключениями из `list-exclude.txt`.
- **UDP 443 (QUIC) и 19294-19344, 50000-50100 (Discord)** — fake QUIC/STUN desync.
- Опционально: весь трафик (`ZAPRET_ALL=1`) и gamefilter.

Списки и бинарники загружаются в образ на этапе сборки (Flowseal @ `ef19845a…`, nfqws/tpws из bol-van/zapret `v72.9`).

---

## Диагностика

```bash
# логи приложения (включая QR-код клиента по умолчанию)
docker logs zapret-vpn-gateway_app_1

# статус zapret
docker exec zapret-vpn-gateway_app_1 /opt/zapret-gateway/zapret.sh status

# список маршрутов контейнеров
docker exec zapret-vpn-gateway_app_1 /opt/zapret-gateway/route-manager.sh status

# проверка правил
docker exec zapret-vpn-gateway_app_1 iptables-legacy -t mangle -L -n -v
```

**Частые проблемы**

- **`wg-quick up wg0` не удался** — проверьте наличие модуля WireGuard в ядре: `sudo modprobe wireguard`.
- **Видео на iPhone не ускоряется** — проверьте, что `nfqws: running` в панели; попробуйте сменить стратегию `general` ↔ `general_simple`, при необходимости включите `ZAPRET_ALL=1`.
- **Контейнер не маршрутизируется** — убедитесь, что в контейнере есть `ip` и что он запущен от root.
- **Нет доступа к панели** — панель на `http://umbrel.local:8095` (через прокси Umbrel). Внутри контейнера она слушает порт 8095.

## Безопасность

- Панель слушает на внутренней сети Umbrel; задайте `APP_ZAPRET_VPN_TOKEN` для дополнительной защиты.
- Приложение получает `NET_ADMIN`, `NET_RAW`, `SYS_MODULE` и read-only доступ к `/var/run/docker.sock` — это необходимо для работы с сетью и маршрутами других контейнеров.
- Ключи сервера и клиентов хранятся в `/data` (persist-том приложения).

## Благодарности

- [bol-van/zapret](https://github.com/bol-van/zapret) — nfqws/tpws
- [Flowseal/zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube) — стратегии и списки
- [SergeyDiGi3/zapret-discord-youtube-linux](https://github.com/Sergeydigl3/zapret-discord-youtube-linux) — Linux-адаптер, параметры NFQUEUE/mark
