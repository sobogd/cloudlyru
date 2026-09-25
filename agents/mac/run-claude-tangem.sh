#!/bin/bash
# launchd wrapper for the tangem Claude Code remote-control agent.
export PATH="/Users/sobogd/.nvm/versions/node/v22.23.3/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CLAUDE_CONFIG_DIR="/Users/sobogd/.claude-work"
cd /Users/sobogd/work/tangem || exit 1
exec claude remote-control --name tangem-local --permission-mode bypassPermissions
