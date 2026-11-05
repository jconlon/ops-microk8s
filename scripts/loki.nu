#!/usr/bin/env nu

# Loki log analysis commands via logcli
#
# All commands query Loki at http://192.168.0.220 (pre-set via LOKI_ADDR in devbox).
#
# Log streams these commands read (all shipped by Promtail on every node):
#   {job="syslog", filename="/var/log/syslog", node="<n>"}
#       rsyslog output. Also has a /var/log/kern.log stream under the same
#       job, which repeats every kernel line, so pin filename when counting.
#   {job="journal", node="<n>"}
#       systemd journal. This is the only stream with logind's final
#       "The system will reboot now!" line: rsyslog stops before it's written.
#   {filename=~"/var/log/pods/kube-system_kured-..."}
#       kured pod logs (drain / trigger reboot / uncordon). These streams have
#       no node label; the node name is in the message text.
#
# The node label only exists from 2026-05-12 on (the Promtail pipeline_stages
# fix). node-events, idrac and tail still filter on the hostname inside the
# syslog line, so they also work on older data. shutdown-events and
# reboot-history use the node label and return nothing before that date.
#
# Usage:
#   ops loki node-events puffer
#   ops loki shutdown-events puffer --since 7d
#   ops loki idrac puffer --since 24h
#   ops loki reboot-history
#   ops loki tail puffer

const LOKI = "http://192.168.0.220"

# ── Event patterns ───────────────────────────────────────────────────────────
# Used inside LogQL backtick strings (|~ `...`), so regex backslashes are
# literal and need no extra escaping.
#
# Lines that mark a node actually going down, matched against the journal
# stream. They're tied to the exact systemd-logind / systemd[1] messages so
# that normal boot-time lines don't match. The old loose patterns (bare
# "shutdown", "reboot", "ACPI.*power") flagged about 40 such lines per reboot:
#   - containerd loading its "io.containerd.internal.v1.shutdown" plugin
#     (every MicroK8s restart, including the daily 04:00 ones)
#   - "kernel: ACPI: button: Power Button [PWRB]": the button being found at boot
#   - "cron: Running @reboot jobs", and the secureboot-db / ua-reboot-cmds unit names
#   - "systemd[<user pid>]: Reached target shutdown.target": a desktop
#     session logging out, not the machine
# What a normal reboot logs (journal), in order:
#   The system will reboot now!                (logind; one per shutdown)
#   System is rebooting.                       (logind)
#   Reached target reboot.target               (systemd[1], often not shipped)
# A physical or iDRAC power-button press logs "Power key pressed ..." first.
const SHUTDOWN_RE = 'The system will (reboot|power off|halt) now|System is (rebooting|powering down|halting)|Power key pressed|Reached target (reboot|poweroff|halt|kexec)\.target'

# Exactly one line per initiated shutdown or reboot, used for counting.
const SHUTDOWN_COUNT_RE = 'The system will (reboot|power off|halt) now'

# Boot markers, matched against {job="syslog", filename="/var/log/syslog"}.
# "kernel: Linux version ..." is the first kernel line of every boot, so it
# appears exactly once per boot and is used for counting. "systemd[1]: Startup
# finished" marks the end of boot (it's also shown in the timeline).
const BOOT_COUNT_RE = 'kernel: Linux version'
const BOOT_RE = 'kernel: Linux version|systemd\[1\]: Startup finished'

# Parse logcli --output=jsonl lines into a nushell table
# logcli jsonl format: {"timestamp":"...","labels":{...},"line":"..."}
#
# Loki's timestamp for a syslog or pod-log line is when Promtail read it, which
# can lag the real event by minutes. For example, kured's "Triggering reboot"
# at 02:18:54 was ingested at 02:21:58, after the node came back. Those lines
# start with their own ISO-8601 timestamp (the rsyslog prefix or the CRI
# prefix), so `time` is taken from there. Journal lines have no prefix, but
# Promtail's journal target already stamps them with the journal's own event
# time, so the Loki timestamp is used for those as-is.
def parse-loki-jsonl [] {
    lines
    | filter { |l| ($l | str trim | is-not-empty) }
    | each { |l| $l | from json }
    | each { |r|
        let ingested = ($r.timestamp | into datetime)
        let prefix = ($r.line | parse -r '^(?<ts>\d{4}-\d{2}-\d{2}T\S+)')
        let time = if ($prefix | is-empty) {
            $ingested
        } else {
            try { $prefix.0.ts | into datetime } catch { $ingested }
        }
        {
            time:    $time
            labels:  $r.labels
            message: $r.line
        }
    }
}

# Count matching lines per node across all nodes in one logcli call.
# Returns [{node, value}]. A node with no matches is missing from the result,
# so callers default it to 0.
#
# --include-label node makes logcli keep the node label on every line. Without
# it, logcli drops labels shared by all results, so if only one node matched
# its name would disappear.
#
# Loki holds some lines twice: Promtail re-ships them with a new ingestion
# timestamp but identical content (this happened to puffer's 2026-10-11 boot).
# A raw count (or LogQL count_over_time) would over-count, and then report a
# false "unclean" boot, so duplicates are dropped on (node, event time, message)
# first. That's why this uses logcli instead of a Loki metric query.
def count-by-node [query: string, since: string] {
    (^logcli query $query --addr $LOKI --since $since --limit 5000 --output jsonl --quiet --include-label node)
    | parse-loki-jsonl
    | each { |r| { node: ($r.labels | get -i node), time: $r.time, message: $r.message } }
    | uniq-by node time message
    | group-by node
    | transpose node rows
    | each { |g| { node: $g.node, value: ($g.rows | length) } }
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

# Timeline of reboot, shutdown and boot events for one node
#
# Returns a table (time, event, message) in time order, with three kinds of event:
#   kured     kured draining / triggering a reboot / uncordoning this node
#   shutdown  systemd-logind / systemd[1] taking the node down
#             (reboot, power off, halt, power key press). From the journal.
#   boot      kernel banner + "systemd[1]: Startup finished". From syslog.
#
# What to expect: a normal kured reboot reads like this (mullet, 2026-11-04):
#   02:18:52  kured     Draining node mullet
#   02:18:54  kured     Triggering reboot for node mullet
#   02:18:54  shutdown  The system will reboot now!
#   02:18:54  shutdown  System is rebooting.
#   02:20:11  boot      kernel: Linux version 6.8.0-147-generic ...
#   02:23:15  kured     Uncordoning node mullet
#   02:23:44  boot      systemd[1]: Startup finished in ... (userspace can take ~4 min)
#
# Reading other patterns:
#   shutdown + boot, no kured   someone ran `reboot` / `shutdown` by hand
#   "Power key pressed" first   physical or iDRAC power button (see issue #59)
#   boot with no shutdown       power loss, kernel panic or hard reset; check
#                               `ops loki idrac` on the Dell nodes
#   empty table                 no reboot in the window, or the window is
#                               before 2026-05-12 (no node label yet)
#
# To see why kured decided to reboot (flag file vs. newer kernel), look at the
# node's apt/dpkg history; kured only logs that a reboot was required.
#
# Usage:
#   ops loki shutdown-events puffer
#   ops loki shutdown-events puffer --since 30d
#
def "main loki shutdown-events" [
    node: string = "puffer"       # cluster node name
    --since (-s): string = "7d"   # how far back
    --limit (-n): int = 100       # max lines returned per event kind
] {
    let shutdown_query = $"{job=\"journal\", node=\"($node)\"} |~ `($SHUTDOWN_RE)`"
    let boot_query     = $"{job=\"syslog\", filename=\"/var/log/syslog\", node=\"($node)\"} |~ `($BOOT_RE)`"
    # Each node's own kured pod logs its drain / reboot / uncordon, but those
    # pod-log streams have no node label, so match the node name in the message.
    # The trailing \" (end of kured's msg="...") stops a node name from matching
    # a longer name that starts with it.
    let kured_query    = $"{filename=~\"/var/log/pods/kube-system_kured-.*\"} |~ `\(Triggering reboot for|Draining|Uncordoning\) node ($node)\"`"

    let shutdown_events = (
        loki-query $shutdown_query $since $limit
        | select time message
        | insert event "shutdown"
    )

    let boot_events = (
        loki-query $boot_query $since $limit
        | select time message
        | update message { clean-syslog-line $node }
        | insert event "boot"
    )

    # Pod-log lines are CRI format: '<ts> stderr F time="..." level=info msg="..."';
    # keep only the msg text.
    let kured_events = (
        loki-query $kured_query $since $limit
        | select time message
        | update message { |r|
            let m = ($r.message | parse -r 'msg="(?<msg>[^"]*)"')
            if ($m | is-empty) { $r.message } else { $m.0.msg }
        }
        | insert event "kured"
    )

    $kured_events
    | append $shutdown_events
    | append $boot_events
    | uniq-by time event message   # drop Loki's duplicate copies (see count-by-node)
    | sort-by time
    | select time event message
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

# Boot times for all nodes, plus boot/shutdown counts from Loki
#
# Columns:
#   last_boot, uptime  current boot, from Prometheus (node_boot_time_seconds)
#   boots              boots in the --since window (kernel banners in syslog)
#   clean_shutdowns    orderly reboots / power-offs in the window (logind's
#                      "The system will reboot now!" in the journal); kured
#                      reboots and manual `reboot` both count here
#   unclean            boots - clean_shutdowns (never below 0): boots with no
#                      orderly shutdown before them
#
# What to expect: boots == clean_shutdowns and unclean 0 on every node; that
# was the case for all 8 nodes over 30d on 2026-11-04. boots 0 just means no
# reboot in the window (e.g. whale, up 55d).
# If unclean > 0, run `ops loki shutdown-events <node> --since <same window>`
# and look for a boot with no shutdown line before it. It can also be a false
# positive when:
#   - the node went down just before the window started (shutdown outside,
#     boot inside), so try a slightly larger --since
#   - the journal stream wasn't shipping for that node at the time
#
# Counts come from Loki, not Prometheus: Prometheus keeps only 15d of data
# (storage.tsdb.retention.time), so it can't see every boot in a 30d window
# (it reported 1 for mullet against a real 3).
# Two logcli queries in total, about 3s for 30d.
#
# Usage:
#   ops loki reboot-history
#   ops loki reboot-history --since 30d --prom https://prometheus.verticon.com
#
def "main loki reboot-history" [
    --since (-s): string = "7d"                                # Loki window for boot/shutdown counts
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

    # One query each across all nodes (the old version ran one slow logcli call per node)
    let boots     = (count-by-node $"{job=\"syslog\", filename=\"/var/log/syslog\"} |~ `($BOOT_COUNT_RE)`" $since)
    let shutdowns = (count-by-node $"{job=\"journal\"} |~ `($SHUTDOWN_COUNT_RE)`" $since)

    $boot_times | each { |b|
        let nb = ($boots | where node == $b.node | get -i value.0 | default 0)
        let ns = ($shutdowns | where node == $b.node | get -i value.0 | default 0)
        $b | insert boots $nb | insert clean_shutdowns $ns | insert unclean ([($nb - $ns) 0] | math max)
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
