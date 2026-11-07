#!/bin/sh
# Starts WatchSwifty as the unprivileged user `vapor`. Started as root (the default), it first makes sure the data
# folder belongs to `vapor`: bind mounts such as `/home/docker/watchswifty:/data` usually belong to another user.
set -e

data_dir=$(dirname "${DATABASE_PATH:-/data/watchswifty.sqlite}")

if [ "$(id -u)" = "0" ]; then
    mkdir -p "$data_dir"
    if ! setpriv --reuid=vapor --regid=vapor --init-groups test -w "$data_dir"; then
        echo "WatchSwifty: $data_dir gehört nicht dem App-Benutzer (vapor, UID $(id -u vapor)) – Besitzer wird angepasst."
        chown -R vapor:vapor "$data_dir" \
            || echo "WatchSwifty: chown fehlgeschlagen – auf dem Host ausführen: chown -R $(id -u vapor):$(id -g vapor) <Datenordner>" >&2
    fi
    export HOME=/app
    exec setpriv --reuid=vapor --regid=vapor --init-groups /app/App "$@"
fi

exec /app/App "$@"
