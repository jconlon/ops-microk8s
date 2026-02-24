#!/usr/bin/env nu

# Connect to the FreshRSS PostgreSQL database via psql
#
# Starts a kubectl port-forward in the background, connects via psql
# using credentials from the cluster secret, and cleans up when done.
#
# Usage:
#   ops freshrss psql
#   ops freshrss psql --port 5434
#
# Parameters:
#   --port (-p): int (optional)
#     Local port for the port-forward.
#     Default: 5433 (avoids conflict with any local PostgreSQL on 5432)
#
# Example:
#   ops freshrss psql
#
def "main freshrss psql" [
    --port (-p): int = 5433
] {
    print $"Starting port-forward to production-postgresql-rw on localhost:($port)..."

    let pf_id = job spawn {
        ^kubectl port-forward -n postgresql-system svc/production-postgresql-rw $"($port):5432"
    }

    sleep 2sec

    let password = (
        ^kubectl get secret freshrss-role-password -n postgresql-system -o $"jsonpath={.data.password}"
        | ^base64 -d
        | str trim
    )

    print "Connecting to freshrss database..."

    with-env { PGPASSWORD: $password } {
        ^psql -h localhost -p $port -U freshrss -d freshrss
    }

    job kill $pf_id
    print "Port-forward stopped."
}
