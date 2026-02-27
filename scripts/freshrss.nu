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
# Query FreshRSS entries tagged 'publish' and output a markdown link list
#
# Starts a kubectl port-forward in the background, runs the publish query,
# and prints results as a markdown list of links with tags.
#
# Usage:
#   ops freshrss publish-links
#   ops freshrss publish-links --port 5434
#
# Parameters:
#   --port (-p): int (optional)
#     Local port for the port-forward. Default: 5433
#
def "main freshrss publish-links" [
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

    let sql = "SELECT e.title, e.link, string_agg(DISTINCT t_all.name, ', ' ORDER BY t_all.name) AS tags
FROM public.freshrss_admin_entry AS e
JOIN public.freshrss_admin_entrytag AS et_publish ON et_publish.id_entry = e.id
JOIN public.freshrss_admin_tag AS t_publish ON t_publish.id = et_publish.id_tag AND t_publish.name = 'publish'
JOIN public.freshrss_admin_entrytag AS et_all ON et_all.id_entry = e.id
JOIN public.freshrss_admin_tag AS t_all ON t_all.id = et_all.id_tag
GROUP BY e.title, e.link
ORDER BY e.title;"

    let markdown = (
        with-env { PGPASSWORD: $password } {
            ^psql -h localhost -p $port -U freshrss -d freshrss -t -A -c $sql
        }
        | lines
        | filter { |l| ($l | str trim) != "" }
        | each { |l|
            let parts = ($l | split row "|")
            let title = ($parts | get 0)
            let link  = ($parts | get 1)
            let tags  = ($parts | get 2)
            $"- [($title)]\(($link)\) — ($tags)"
        }
        | str join "\n"
    )

    job kill $pf_id
    print "Port-forward stopped.\n"

    print $markdown
}

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
