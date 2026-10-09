# Zapret App Store для umbrelOS

Кастомный App Store для umbrelOS с приложением:

- **[zapret-vpn-gateway](zapret-vpn-gateway/)** — WireGuard VPN-шлюз для iPhone + прозрачный обход DPI (zapret/nfqws) для выбранных Docker-контейнеров Umbrel (yt-dlp, cobalt и др.).

## Установка

1. В umbrelOS откройте **Настройки → App Store → Community App Stores**.
2. Добавьте URL этого репозитория: `https://github.com/Lorbert14/zapretvpn`.
3. Откройте магазин **Zapret** и установите **Zapret VPN Gateway**.
4. Веб-панель приложения: `http://umbrel.local:8095`.

> Репозиторий должен быть публичным: umbrelOS не поддерживает аутентификацию при загрузке community-сторов.

Подробная документация — в [README приложения](zapret-vpn-gateway/README.md).
