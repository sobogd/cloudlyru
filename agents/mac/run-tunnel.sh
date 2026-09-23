#!/bin/bash
# =============================================================================
# run-tunnel.sh — resilient reverse SSH tunnel for the remote Mac.
#
# Managed by launchd (com.agent.mac-tunnel, KeepAlive). It forwards:
#   VPS 127.0.0.1:18810 -> mac 127.0.0.1:18810  (mac status server)
#   VPS 127.0.0.1:18812 -> mac 127.0.0.1:1234   (llama.cpp, local LLM for CloudlyRu)
#   VPS 127.0.0.1:18818 -> mac 127.0.0.1:1238   (whisper.cpp, speech recognition for iq-translate)
#   VPS 127.0.0.1:18820 -> mac 127.0.0.1:18820  (pi bridge: harness inside a project folder, cloudlyru repo)
#   VPS 127.0.0.1:18822 -> mac 127.0.0.1:1235   (TranslateGemma-4B, translation engine for iq-translate)
#
# 18818 exists for the same reason: the iq-translate backend runs ON the VPS, its
# voice endpoint has to reach the speech engine that lives on this Mac.
#
# 18822 is the translation half of that same backend once it moved to its own
# engine: 18812 still serves the general 4B model used for search and the
# language pairs TranslateGemma does not cover, while 18822 leads to the
# translation model on 1235.
#
# 18812 and 18820 exist because the CloudlyRu backend runs ON the VPS and has to
# reach the model and the pi bridge that live on this Mac. All of these bind to
# loopback on both ends: only the VPS itself can talk to them, nothing is exposed
# to the internet, and none needs TLS or an auth layer.
#
# Порт 18820 отдаётся мосту agents/pi-bridge: раздел «Проекты» в приложении даёт агенту pi
# папку проекта, и сервер приложения (src/projects) ходит к мосту по этому же принципу —
# loopback на обоих концах, без TLS и авторизации на плече: снаружи порт не виден никому,
# а доступ к разделу закрыт сессией приложения.
#
# Why a wrapper: the Mac's Wi-Fi link is flaky (packet loss to the router,
# short radio blips that reset TCP). A plain `ssh -N` dies on any blip longer
# than its ServerAlive budget and every death means 502 on the public domains
# until launchd respawns it. So on every (re)start we:
#   1) wait for the WAN path to the VPS to come back before connecting
#      (prevents a spawn-die-spawn spiral while the network is settling);
#   2) clear stale sshd listeners for our ports on the VPS (an abruptly-dropped
#      reverse-forward leaves a stale listener there that blocks rebinding);
#   3) connect with a generous ServerAlive budget (5 s x 12 = ~60 s of silence
#      tolerated) so short blips are absorbed — the ssh pauses and resumes
#      instead of dying, and no reconnect is needed at all.
# launchd KeepAlive restarts us whenever the ssh exits.
# =============================================================================
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
SSH=/usr/bin/ssh
VPS=46.225.143.221

# 1) Wait until the WAN path is up (up to ~40-80 s) so we do not connect into
#    a dead window. If it never comes up, exit and let launchd's ThrottleInterval
#    pace the next attempt.
up=0
for i in $(seq 1 20); do
  if ping -c 1 -W 2000 "$VPS" >/dev/null 2>&1; then
    up=1
    break
  fi
  sleep 2
done
if [ "$up" != 1 ]; then
  exit 1
fi

# 2) Clear stale sshd listeners for our forwarded ports on the VPS.
#    (Kills ONLY the sshd sessions bound to our five ports — never the main sshd
#    or other sessions, because this cleanup connection itself is to :22.)
#    Every forwarded port must be listed in the grep below: a stale listener that
#    is left out keeps its port busy, the new bind fails, ExitOnForwardFailure
#    kills the ssh, launchd respawns it — and that is an endless restart loop.
"$SSH" -o BatchMode=yes -o ConnectTimeout=10 \
  root@"$VPS" \
  'p=$(ss -ltnp 2>/dev/null | grep -E ":18808|:18810|:18812|:18814|:18816|:18818|:18820|:18822" | grep -oE "pid=[0-9]+" | cut -d= -f2 | sort -u); [ -n "$p" ] && kill $p 2>/dev/null; true' \
  >/dev/null 2>&1
sleep 1

# 3) Establish the tunnel. exit -> launchd restarts us -> wait + cleanup + connect.
exec "$SSH" -N \
  -R 127.0.0.1:18810:127.0.0.1:18810 \
  -R 127.0.0.1:18812:127.0.0.1:1234 \
  -R 127.0.0.1:18818:127.0.0.1:1238 \
  -R 127.0.0.1:18820:127.0.0.1:18820 \
  -R 127.0.0.1:18822:127.0.0.1:1235 \
  root@"$VPS" \
  -o ServerAliveInterval=5 \
  -o ServerAliveCountMax=12 \
  -o TCPKeepAlive=yes \
  -o ExitOnForwardFailure=yes \
  -o BatchMode=yes \
  -o ConnectTimeout=15
