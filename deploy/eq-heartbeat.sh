#!/usr/bin/env bash
# Dead-man's switch for the box, through Healthchecks.io (2026-09-06).
#
# Every minute (eq-heartbeat.timer) this pings the check's URL. Nothing on the VM can report
# the VM being gone, so an outside service has to notice the silence: Healthchecks posts to
# the officers' Discord channel when the pings stop. On the way, the ping carries the state
# of the units a raider depends on: when one is not active the ping goes to /fail with the
# list as its body, so "the bot is down" is also an alert - without an Alertmanager on the box.
#
# The check URL is a capability (anyone holding it can ping), kept root-only in
# /etc/healthchecks/eq-perses.url, never in the repo.
set -u
URL_FILE=/etc/healthchecks/eq-perses.url
CRITICAL=(nocturnal.service eq-gateway.service prometheus.service perses.service caddy.service ourios.service)

url=$(cat "$URL_FILE" 2>/dev/null) || { echo "no check url in $URL_FILE"; exit 0; }

down=()
for u in "${CRITICAL[@]}"; do
  systemctl is-active --quiet "$u" || down+=("$u $(systemctl is-active "$u")")
done

# --retry covers a hiccup on the way out; -m bounds the whole thing well under the timer period.
if [ ${#down[@]} -eq 0 ]; then
  curl -fsS -m 10 --retry 3 --retry-delay 2 -o /dev/null "$url"
else
  printf '%s\n' "${down[@]}" | curl -fsS -m 10 --retry 3 --retry-delay 2 -o /dev/null --data-binary @- "$url/fail"
fi
