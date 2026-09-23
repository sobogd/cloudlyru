# nginx/ — VPS reference config

Everything here is **reference / deploy source** for nginx on the VPS
(`46.225.143.221`, Ubuntu, nginx 1.18). The Mac itself runs no nginx; it only keeps
the reverse-SSH tunnel (`com.agent.mac-tunnel`) so the VPS can reach
`127.0.0.1:18810` (status panel). Live configs live in `/etc/nginx/sites-available/`
(symlinked into `sites-enabled`); treat this folder as the source of truth and copy
to the VPS.

## Files

| Path | Purpose |
| --- | --- |
| `status.iq-factura.conf` | Reference server block for status.iq-factura.com (basic auth) — adjust `<TUNNEL_PORT>`. |

## Deploy (manual, from the Mac)

```bash
scp nginx/status.iq-factura.conf root@46.225.143.221:/tmp/status.conf.new
ssh root@46.225.143.221 'TS=$(date +%Y%m%d-%H%M%S); \
  cp -a /etc/nginx/sites-available/status.iq-factura.com \
        /etc/nginx/sites-available/status.iq-factura.com.bak.$TS; \
  install -m 644 /tmp/status.conf.new /etc/nginx/sites-available/status.iq-factura.com; \
  nginx -t && systemctl reload nginx'
```

Notes:
- The server block keeps auth off for `/sw.js`, `/manifest.json`, `/icon-*.png` so the
  PWA service worker can register behind HTTP basic auth; pages and `/api/*` stay
  protected.
