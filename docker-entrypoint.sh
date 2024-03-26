#!/bin/sh
set -e
nginx -v

echo "running: $@"
exec "$@"