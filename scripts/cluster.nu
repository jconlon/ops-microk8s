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
# Combines Prometheus uptime data with kured pod log inspection to show
# which nodes are pending a reboot. No SSH required.
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

    let kured_pods = (
        ^kubectl get pods -n kube-system -l app.kubernetes.io/name=kured -o json
        | from json
        | get items
        | each { |p| { pod: $p.metadata.name, node: $p.spec.nodeName } }
    )

    let reboot_data = (
        $kured_pods | each { |p|
            let log = (do { ^kubectl logs -n kube-system $p.pod --tail=5 } | complete | get stdout | lines | str join " ")
            let required = if ($log | str contains "Reboot required") and not ($log | str contains "not required") {
                "Yes"
            } else if ($log | str contains "Reboot not required") {
                "No"
            } else {
                "Unknown"
            }
            { node: $p.node, reboot_required: $required }
        }
    )

    $uptime_data | each { |u|
        let matches = ($reboot_data | where node == $u.node)
        let rb = if ($matches | is-empty) { "Unknown" } else { $matches.0.reboot_required }
        { node: $u.node, uptime: $u.uptime, reboot_required: $rb }
    }
}
