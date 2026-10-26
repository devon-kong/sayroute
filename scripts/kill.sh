#!/bin/bash
# Kill running SayRoute instance
if pkill -x "SayRoute" 2>/dev/null; then
  echo "🛑 SayRoute stopped"
else
  echo "ℹ️  SayRoute is not running"
fi
