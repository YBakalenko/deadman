#!/bin/sh
# Сквозная проверка в контейнере Alpine (busybox ash, как на роутере):
#   docker run --rm -v "$PWD":/src:ro alpine:3 sh /src/tests/smoke.sh
# Ставит в /tmp/dm из исходников, поднимает приём сигнала на lighttpd,
# проверяет ключ, тревогу и восстановление. Telegram подменён недоступным
# адресом — сообщения оседают в очереди, по ней и сверяемся.
set -eu
apk add --no-cache lighttpd curl >/dev/null

export DEADMAN_PREFIX=/tmp/dm DEADMAN_SKIP_OPKG=1 DEADMAN_NONINTERACTIVE=1
export LIGHTTPD_BIN=/usr/sbin/lighttpd
export DM_NAME="Тест" DM_TG_TOKEN="x" DM_TG_CHAT_ID="1" DM_LISTEN_PORT=18089
export DM_BEAT_TIMEOUT_MIN=15 DM_REMIND_MIN=0
P=$DEADMAN_PREFIX
D=$P/bin/deadman
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok   $*"; }

cp -r /src /tmp/src
sh /tmp/src/install.sh >/tmp/install.log 2>&1 || { cat /tmp/install.log; fail "установка"; }
ok "установка и настройка без вопросов"

# Telegram — в никуда, проверка интернета — на себя.
sed -i "s|^INET_HOSTS=.*|INET_HOSTS='127.0.0.1'|" "$P/etc/deadman/deadman.conf"
echo "TG_API='http://127.0.0.1:9'" >>"$P/etc/deadman/deadman.conf"
echo "LISTEN_ADDR='127.0.0.1'" >>"$P/etc/deadman/deadman.conf"
$D restart >/dev/null
sleep 1

tok=$(cat "$P/etc/deadman/beat.token")
[ ${#tok} -eq 32 ] || fail "ключ сигнала: длина ${#tok}"
ok "ключ сигнала из 32 знаков"

code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:18089/beat/wrong")
[ "$code" = 404 ] || fail "чужой ключ: $code"
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:18089/")
[ "$code" != 200 ] || fail "корень отдаёт 200"
ok "чужой ключ и корень — не 200"

rm -f "$P/var/lib/deadman/last_beat"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d '{"alerts":[{"labels":{"alertname":"Watchdog"}}]}' "http://127.0.0.1:18089/beat/$tok")
[ "$code" = 200 ] || fail "сигнал POST: $code"
[ -s "$P/var/lib/deadman/last_beat" ] || fail "сигнал не записан"
ok "сигнал POST с телом Alertmanager принят"

$D stop >/dev/null
st=$P/var/lib/deadman
outbox() { cat "$st"/outbox/* 2>/dev/null || true; }

now=$(date +%s)
echo $((now - 7200)) >"$st/started"
echo $((now - 3600)) >"$st/last_beat"
$D check
outbox | grep -q "🔴 Тест: нет сигнала «жив» 60 мин" || { outbox; fail "нет тревоги о пропавшем сигнале"; }
ok "тревога: сигнала нет час"

n1=$(ls "$st/outbox" | wc -l)
$D check
[ "$(ls "$st/outbox" | wc -l)" = "$n1" ] || fail "тревога повторилась без напоминания"
ok "повтор без REMIND_MIN не шлётся"

date +%s >"$st/last_beat"
$D check
outbox | grep -q "🟢 Тест: сигнал «жив» снова приходит" || { outbox; fail "нет сообщения о восстановлении"; }
ok "восстановление"

rm -rf "$st/outbox" "$st"/st.*
echo "$now" >"$st/started"; rm -f "$st/last_beat"
echo "$((now - 600))" >"$st/started"
$D check
[ -z "$(outbox)" ] || fail "тревога раньше таймаута"
ok "без сигнала 10 мин из 15 — тихо"

echo "INET_HOSTS='192.0.2.1'" >>"$P/etc/deadman/deadman.conf"
echo $((now - 7200)) >"$st/started"
$D check
[ -z "$(outbox)" ] && [ -f "$st/offline" ] || fail "без интернета у роутера проверки не отложены"
ok "без интернета у роутера — тишина"
sed -i '$d' "$P/etc/deadman/deadman.conf"
$D check
[ -z "$(outbox)" ] || { outbox; fail "ложная тревога сразу после возврата интернета"; }
ok "после возврата интернета отсчёт заново"

printf "CHECK_URLS='http://127.0.0.1:1/'\nURL_FAILS=2\n" >>"$P/etc/deadman/deadman.conf"
date +%s >"$st/last_beat"
$D check
[ -z "$(outbox)" ] || fail "тревога по адресу после первой неудачи"
$D check
outbox | grep -q "http://127.0.0.1:1/ не отвечает (код 000, 2 проверок подряд)" || { outbox; fail "нет тревоги по адресу"; }
ok "адрес не отвечает дважды — тревога"

# KeenDNS «This Keenetic device» ходит через петлю: приём на домашнем адресе
# обязан отвечать и на 127.0.0.1 (иначе снаружи 502).
lan=$(ip -4 addr show eth0 | awk '/inet /{split($2,a,"/"); print a[1]; exit}')
sed -i "s|^LISTEN_ADDR=.*|LISTEN_ADDR='$lan'|" "$P/etc/deadman/deadman.conf"
$D restart >/dev/null
sleep 1
for a in "$lan" 127.0.0.1; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://$a:18089/beat/wrong")
  [ "$code" = 404 ] || fail "приём на $a: $code"
done
$D stop >/dev/null
ok "приём на домашнем адресе отвечает и через петлю"

$D status >/dev/null || fail "status"
$D uninstall --purge >/dev/null
[ ! -e "$P/bin/deadman" ] && [ ! -e "$P/etc/deadman" ] || fail "uninstall --purge"
ok "удаление"
echo "ALL OK"
