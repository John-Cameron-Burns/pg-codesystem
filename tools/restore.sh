#!/bin/sh
# Restores a custom-format or directory-format pg_dump (pg_dump -Fc) of a database that uses codesystem.
#
#    tools/restore.sh db.dump newdb          (newdb is created for you)
#
# Why not plain pg_restore: a code column is restored from text ("isic_rev4:4711") and reading it needs the code system's
# definition, which is in the codesystem_* tables. Those tables must therefore be restored BEFORE the data of every table
# that has a code in it, and pg_restore does not know that. Restoring in the wrong order stops with
# "the code system of this column is not defined here", so a mistake is loud, never silent.
set -eu
[ $# -eq 2 ] || { echo "usage: $0 dumpfile newdb" >&2; exit 2; }
dump=$1; db=$2
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pg_restore -l "$dump" > "$tmp/all.list"
grep -E ' TABLE DATA [^ ]+ codesystem_(system|revision|level|code) ' "$tmp/all.list" > "$tmp/registry.list" || {
   echo "$dump has no codesystem_* table data: nothing here needs this script, use pg_restore" >&2; exit 1; }
grep -v -x -F -f "$tmp/registry.list" "$tmp/all.list" > "$tmp/rest.list"
createdb "$db"
pg_restore --exit-on-error -d "$db" --section=pre-data  "$dump"
pg_restore --exit-on-error -d "$db" --section=data -L "$tmp/registry.list" "$dump"
pg_restore --exit-on-error -d "$db" --section=data -L "$tmp/rest.list"     "$dump"
pg_restore --exit-on-error -d "$db" --section=post-data "$dump"
