#!/usr/bin/env nu

# Loki log analysis commands via logcli
#
# All commands query Loki at http://192.168.0.220 (pre-set via LOKI_ADDR in devbox).
# Syslog entries are stored under {filename="/var/log/syslog"} — the hostname
# embedded in each line is used to filter by node.
#
# Usage:
#   ops loki node-events puffer
#   ops loki shutdown-events puffer --since 7d
#   ops loki idrac puffer --since 24h
#   ops loki reboot-history
#   ops loki tail puffer

const LOKI = "http://192.168.0.220"

# Parse logcli --output=jsonl lines into a nushell table
# logcli jsonl format: {"timestamp":"...","labels":{...},"line":"..."}
def parse-loki-jsonl [] {
    lines
    | filter { |l| ($l | str trim | is-not-empty) }
    | each { |l| $l | from json }
    | each { |r|
        {
            time:    ($r.timestamp | into datetime)
            labels:  $r.labels
            message: $r.line
        }
    }
}

# Strip the leading syslog timestamp + hostname prefix from a log line,
# leaving just the process and message body.
def clean-syslog-line [node: string] {
    str replace -r $"^\\S+\\s+($node)\\s+" ""
}

# Run a logcli query and return a parsed nushell table
def loki-query [query: string, since: string, limit: int] {
    (^logcli query $query --addr $LOKI --since $since --limit $limit --output jsonl --quiet)
    | parse-loki-jsonl
    | sort-by time
}

# Query syslog events for a node over a time window
#
# Returns a table of timestamped syslog lines from the given node.
# Use --filter to narrow to a keyword (server-side, efficient).
#
# Usage:
#   ops loki node-events puffer
#   ops loki node-events puffer --since 7d --filter "kernel"
#   ops loki node-events puffer --since 2h --limit 200
#
def "main loki node-events" [
    node: string = "puffer"       # cluster node name
    --since (-s): string = "24h"  # how far back: 1h, 24h, 7d, 30d
    --limit (-n): int = 100       # max lines returned
    --filter (-f): string = ""    # optional keyword (server-side filter)
] {
    let query = if ($filter | is-empty) {
        $"{filename=\"/var/log/syslog\"} |= \" ($node) \""
    } else {
        $"{filename=\"/var/log/syslog\"} |= \" ($node) \" |= \"($filter)\""
    }

    loki-query $query $since $limit
    | select time message
    | update message { clean-syslog-line $node }
}

# Query for shutdown, reboot, and power events on a node
#
# Searches syslog for Power key, Powering off, shutdown, reboot signals,
# and kernel startup markers that indicate the node restarted.
# Cross-references iDRAC events if available.
#
# Usage:
#   ops loki shutdown-events puffer
#   ops loki shutdown-events puffer --since 30d
#
def "main loki shutdown-events" [
    node: string = "puffer"       # cluster node name
    --since (-s): string = "7d"   # how far back
    --limit (-n): int = 100       # max lines returned
] {
    # Power/shutdown signals in syslog
    let power_query = ("{filename=\"/var/log/syslog\"} |= \" " + $node + " \" |~ \"(?i)(power key|powering off|shutdown|reboot|Reached target.*Power-Off|Starting.*Power-Off|systemd-logind.*Power|ACPI.*power)\"")

    # Kernel boot markers (appear at node startup)
    let boot_query = ("{filename=\"/var/log/syslog\"} |= \" " + $node + " \" |~ \"(kernel:.*Linux version|Reached target.*Network is Online|systemd.*Startup finished)\"")

    let power_events = (
        loki-query $power_query $since $limit
        | select time message
        | update message { clean-syslog-line $node }
        | insert event "power/shutdown"
    )

    let boot_events = (
        loki-query $boot_query $since $limit
        | select time message
        | update message { clean-syslog-line $node }
        | insert event "boot"
    )

    $power_events
    | append $boot_events
    | sort-by time
}

# Query iDRAC hardware events for a Dell R320 node
#
# iDRAC syslog arrives via rsyslog on port 514 and is written to
# /var/log/syslog on each node. Valid nodes: gold, squid, puffer, carp.
#
# Usage:
#   ops loki idrac puffer
#   ops loki idrac puffer --since 30d
#
def "main loki idrac" [
    node: string = "puffer"       # Dell R320 node (gold, squid, puffer, carp)
    --since (-s): string = "7d"   # how far back
    --limit (-n): int = 100       # max lines
] {
    let dell_nodes = [gold squid puffer carp]
    if not ($node in $dell_nodes) {
        error make { msg: $"($node) is not a Dell R320 node. iDRAC is only on: ($dell_nodes | str join ', ')" }
    }

    let query = $"{filename=\"/var/log/syslog\"} |= \" ($node) \" |= \"iDRAC\""

    loki-query $query $since $limit
    | select time message
    | update message { clean-syslog-line $node }
}

# Show recent boot times for all nodes (from Prometheus node_boot_time_seconds)
#
# Uses Prometheus rather than Loki for current boot time.
# Also queries Loki to count shutdown events per node in the given window
# to surface nodes with repeated restarts.
#
# Usage:
#   ops loki reboot-history
#   ops loki reboot-history --since 30d --prom https://prometheus.verticon.com
#
def "main loki reboot-history" [
    --since (-s): string = "7d"                                # Loki window for shutdown event count
    --prom (-p): string = "https://prometheus.verticon.com"    # Prometheus URL
] {
    let prom_query = 'time() - node_boot_time_seconds * on(instance) group_left(nodename) node_uname_info'

    let boot_times = (
        http get $"($prom)/api/v1/query?query=($prom_query | url encode)"
        | get data.result
        | each { |r|
            let nodename = ($r.metric | get -i nodename)
            if ($nodename | is-not-empty) {
                # r.value.1 is uptime in seconds (time() - node_boot_time_seconds)
                let uptime_s   = ($r.value.1 | into float)
                let days       = ($uptime_s / 86400 | math floor)
                let hours      = (($uptime_s mod 86400) / 3600 | math floor)
                let mins       = (($uptime_s mod 3600) / 60 | math floor)
                # Derive boot epoch from current time minus uptime
                let now_s      = ((date now | into int) / 1_000_000_000)
                let boot_epoch = ($now_s - $uptime_s)
                let last_boot  = ($boot_epoch * 1_000_000_000 | into int | into datetime)
                {
                    node:      $nodename
                    last_boot: $last_boot
                    uptime:    $"($days)d ($hours)h ($mins)m"
                }
            }
        }
        | filter { |r| $r != null }
        | sort-by node
    )

    # Count shutdown/power events per node from Loki in the given window
    let nodes = [mullet trout tuna whale gold squid puffer carp]
    let shutdown_counts = (
        $nodes | each { |node|
            let query = ("{filename=\"/var/log/syslog\"} |= \" " + $node + " \" |~ \"(?i)(powering off|Power key pressed|Reached target.*Power-Off)\"")
            let count = (do { ^logcli query $query --addr $LOKI --since $since --limit 500 --output jsonl --quiet } | complete | get stdout | lines | filter { |l| $l | str trim | is-not-empty } | length)
            { node: $node, shutdown_events: $count }
        }
    )

    $boot_times | each { |b|
        let sc = ($shutdown_counts | where node == $b.node | first)
        $b | insert shutdown_events_since ($sc.shutdown_events)
    }
}

# Live tail logs for a node (press Ctrl+C to stop)
#
# Usage:
#   ops loki tail puffer
#   ops loki tail puffer --filter "iDRAC"
#
def "main loki tail" [
    node: string = "puffer"     # cluster node name
    --filter (-f): string = ""  # optional keyword filter
] {
    let query = if ($filter | is-empty) {
        $"{filename=\"/var/log/syslog\"} |= \" ($node) \""
    } else {
        $"{filename=\"/var/log/syslog\"} |= \" ($node) \" |= \"($filter)\""
    }

    print $"(ansi green)Tailing ($node) syslog — Ctrl+C to stop(ansi reset)"
    ^logcli query $query --addr $LOKI --tail --output raw --quiet
}
