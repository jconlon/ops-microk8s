#!/usr/bin/env nu

# Query node uptimes from Prometheus
#
# Fetches uptime for all cluster nodes by querying node_boot_time_seconds
# from the Prometheus API. No SSH required.
#
# Usage:
#   ops cluster node-uptime
#
# Example output:
#   ╭───────┬────────────────╮
#   │ node  │ uptime         │
#   ├───────┼────────────────┤
#   │ carp  │ 102d 14h 47m   │
#   │ mullet│ 1d 13h 16m     │
#   ...
#
def "main cluster node-uptime" [
    --url (-u): string = "https://prometheus.verticon.com"
] {
    let query = 'time() - node_boot_time_seconds * on(instance) group_left(nodename) node_uname_info'

    let results = (
        http get $"($url)/api/v1/query?query=($query | url encode)"
        | get data.result
    )

    $results
    | each { |r|
        let seconds = ($r.value.1 | into float)
        let days    = ($seconds / 86400 | math floor)
        let hours   = (($seconds mod 86400) / 3600 | math floor)
        let mins    = (($seconds mod 3600) / 60 | math floor)
        {
            node:   $r.metric.nodename
            uptime: $"($days)d ($hours)h ($mins)m"
        }
    }
    | sort-by node
}

# Show node uptime and kured reboot-required status for all cluster nodes
#
# Queries Prometheus for uptime and kured's kured_reboot_required metric to
# show which nodes are pending a reboot. "Unknown" means no kured metric was
# scraped for that node (kured pod down or not scraped). No SSH required.
#
# Usage:
#   ops cluster node-status
#
# Example output:
#   ╭───┬────────┬──────────────┬──────────────────╮
#   │ # │  node  │    uptime    │ reboot_required  │
#   ├───┼────────┼──────────────┼──────────────────┤
#   │ 0 │ carp   │ 102d 15h 0m  │ No               │
#   │ 1 │ gold   │ 66d 18h 37m  │ Yes              │
#   ...
#
def "main cluster node-status" [
    --url (-u): string = "https://prometheus.verticon.com"
] {
    let query = 'time() - node_boot_time_seconds * on(instance) group_left(nodename) node_uname_info'

    let uptime_data = (
        http get $"($url)/api/v1/query?query=($query | url encode)"
        | get data.result
        | each { |r|
            let nodename = ($r.metric | get -i nodename)
            if ($nodename | is-not-empty) {
                let seconds = ($r.value.1 | into float)
                let days    = ($seconds / 86400 | math floor)
                let hours   = (($seconds mod 86400) / 3600 | math floor)
                let mins    = (($seconds mod 3600) / 60 | math floor)
                { node: $nodename, uptime: $"($days)d ($hours)h ($mins)m" }
            }
        }
        | filter { |r| $r != null }
        | sort-by node
    )

    # kured exports kured_reboot_required{node} = 1 when its sentinel command
    # (reboot-required flag OR newer kernel installed) fires, 0 otherwise.
    let reboot_query = 'kured_reboot_required'
    let reboot_data = (
        http get $"($url)/api/v1/query?query=($reboot_query | url encode)"
        | get data.result
        | each { |r|
            {
                node: $r.metric.node
                reboot_required: (if ($r.value.1 == "1") { "Yes" } else { "No" })
            }
        }
    )

    $uptime_data | each { |u|
        let matches = ($reboot_data | where node == $u.node)
        let rb = if ($matches | is-empty) { "Unknown" } else { $matches.0.reboot_required }
        { node: $u.node, uptime: $u.uptime, reboot_required: $rb }
    }
}
