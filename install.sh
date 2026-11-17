#!/bin/sh
# ============================================================================
# Установка keen-deadman на Keenetic с Entware.
#
#   opkg update && opkg install curl
#   curl -fsSLO https://raw.githubusercontent.com/YOUR_GITHUB_USER/keen-deadman/main/install.sh
#   sh install.sh
#
# Повторный запуск обновляет программу и сохраняет настройки. Запуск из
# распакованного репозитория ставит файлы рядом со скриптом, без скачивания.
# ============================================================================
set -eu

# ⚠️ После публикации репозитория впишите сюда своё имя на GitHub.
REPO_OWNER="${DEADMAN_REPO:-YOUR_GITHUB_USER/keen-deadman}"
BRANCH="${DEADMAN_BRANCH:-main}"

P="${DEADMAN_PREFIX:-/opt}"
SKIP_OPKG="${DEADMAN_SKIP_OPKG:-0}"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mОшибка:\033[0m %s\n' "$*" >&2; exit 1; }

# ---- 1. Окружение ----------------------------------------------------------
if [ "$SKIP_OPKG" != 1 ]; then
  [ -x "$P/bin/opkg" ] || die "не найден Entware ($P/bin/opkg). Сначала установите Entware на роутер."
  [ "$(id -u)" = 0 ] || die "запустите от root"
fi

# ---- 2. Пакеты -------------------------------------------------------------
if [ "$SKIP_OPKG" != 1 ]; then
  say "Обновляю список пакетов"
  "$P/bin/opkg" update >/dev/null || warn "opkg update завершился с ошибкой — пробую ставить из имеющегося списка"
  for pkg in curl ca-bundle lighttpd lighttpd-mod-cgi; do
    if "$P/bin/opkg" list-installed | grep -q "^$pkg "; then
      say "Пакет $pkg уже стоит"
    else
      say "Ставлю $pkg"
      "$P/bin/opkg" install "$pkg" || die "не удалось поставить $pkg"
    fi
  done
  # Штатный экземпляр lighttpd Entware не нужен: у нас свой, на своём порту.
  # Если он не был включён до нас, выключаем автозапуск, чтобы не занял :80/:8081.
  if [ -x "$P/etc/init.d/S80lighttpd" ] && ! pidof lighttpd >/dev/null 2>&1; then
    chmod -x "$P/etc/init.d/S80lighttpd"
    warn "Автозапуск штатного lighttpd Entware выключен (вернуть: chmod +x $P/etc/init.d/S80lighttpd)"
  fi
fi

# ---- 3. Файлы --------------------------------------------------------------
here=$(cd "$(dirname "$0")" && pwd)
if [ -f "$here/bin/deadman" ] && [ -f "$here/share/www/beat" ]; then
  SRC="$here"
  say "Ставлю из $SRC"
else
  tmp="/tmp/keen-deadman.$$"
  rm -rf "$tmp"; mkdir -p "$tmp"
  url="https://github.com/$REPO_OWNER/archive/refs/heads/$BRANCH.tar.gz"
  say "Скачиваю $url"
  curl -fsSL "$url" -o "$tmp/src.tar.gz" || die "не скачался архив — проверьте REPO_OWNER в install.sh"
  tar -xzf "$tmp/src.tar.gz" -C "$tmp" || die "не распаковался архив"
  SRC=$(find "$tmp" -maxdepth 2 -type f -name install.sh -exec dirname {} \; | head -n 1)
  [ -n "$SRC" ] && [ -f "$SRC/bin/deadman" ] || die "в архиве нет bin/deadman"
fi

running=0
if [ -x "$P/bin/deadman" ] && [ -f "$P/var/run/deadman.pid" ]; then
  DEADMAN_PREFIX="$P" "$P/bin/deadman" stop >/dev/null 2>&1 || true
  running=1
fi

mkdir -p "$P/bin" "$P/share/deadman/www" "$P/etc/init.d" "$P/etc/deadman" "$P/var/lib/deadman" "$P/var/run" "$P/var/log"
cp "$SRC/bin/deadman" "$P/bin/deadman"
cp "$SRC/share/www/beat" "$P/share/deadman/www/beat"
cp "$SRC/share/lighttpd.conf.in" "$P/share/deadman/lighttpd.conf.in"
cp "$SRC/etc/init.d/S99deadman" "$P/etc/init.d/S99deadman"
chmod 755 "$P/bin/deadman" "$P/share/deadman/www/beat" "$P/etc/init.d/S99deadman"
chmod 700 "$P/etc/deadman"
echo "$REPO_OWNER/$BRANCH" >"$P/share/deadman/repo"
[ -n "${tmp:-}" ] && rm -rf "$tmp"
say "Установлено: $P/bin/deadman ($("$P/bin/deadman" version))"

# ---- 4. Настройка ----------------------------------------------------------
if [ -f "$P/etc/deadman/deadman.conf" ]; then
  say "Настройки сохранены с прошлой установки"
  if [ "$running" = 1 ] || [ "${DEADMAN_NONINTERACTIVE:-0}" != 1 ]; then
    DEADMAN_PREFIX="$P" "$P/bin/deadman" start
  fi
else
  DEADMAN_PREFIX="$P" "$P/bin/deadman" setup
fi

cat <<EOF

Готово. Дальше:
  1. Опубликуйте приёмник наружу через KeenDNS (README, раздел «KeenDNS»).
  2. Пропишите адрес из «deadman url» у наблюдаемого сервера.
  3. Через несколько минут: deadman status — «Последний сигнал» должен быть свежим.
Команды: deadman help
EOF
