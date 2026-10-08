#!/bin/bash
# =============================================================================
# run-harness.sh — local llm-harness (mtplx agent) for the Mac.
#
# Managed by launchd (com.agent.harness, KeepAlive). Serves loopback only:
#   127.0.0.1:9000  gRPC (Ask/Stop/Resume/SetSettings/Compact/Status/GetMessages)
#   127.0.0.1:9001  SSE /events
# Both ports are consumed by the agent bridge (agents/bridge) on the same Mac,
# which re-exposes the harness over its own HTTP/SSE on 127.0.0.1:18820;
# the reverse SSH tunnel forwards that port to the VPS.
# =============================================================================
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cd /Users/sobogd/work/llm-harness
exec .venv/bin/python -m llm_harness \
  --cwd /Users/sobogd/work/llm-harness