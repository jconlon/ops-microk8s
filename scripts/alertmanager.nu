#!/usr/bin/env nu

# Poll Alertmanager for active alerts and send desktop notifications via notify-send.
#
# Tracks previously-notified alerts by fingerprint in a local state file
# (~/.cache/ops-microk8s/alertmanager-notified.json) so a still-firing alert
# doesn't re-notify on every poll — only newly-firing and newly-resolved
# alerts trigger a notification. The Watchdog heartbeat alert (always firing
# by design) is filtered out.
#
# Intended to run on mullet's desktop session via a systemd --user timer
# (scripts/systemd/alertmanager-notify.timer) — notify-send needs the user's
# D-Bus session bus, which a system-level unit (User=) does not have without
# extra plumbing, unlike a --user unit which inherits it automatically.
#
# Usage:
#   ops alertmanager notify
#
def "main alertmanager notify" [
    --url (-u): string = "https://alertmanager.verticon.com"
] {
    let state_dir = ($env.HOME | path join ".cache" "ops-microk8s")
    let state_file = ($state_dir | path join "alertmanager-notified.json")
    mkdir $state_dir

    let previous = if ($state_file | path exists) {
        open $state_file
    } else {
        []
    }

    let alerts = (
        try {
            http get $"($url)/api/v2/alerts?active=true&silenced=false&inhibited=false"
        } catch { |e|
            print $"Failed to reach Alertmanager at ($url): ($e.msg)"
            exit 1
        }
        | where {|a| ($a.labels.alertname? | default "") != "Watchdog" }
        | each {|a| {
            fingerprint: $a.fingerprint
            alertname: ($a.labels.alertname? | default "unknown")
            node: ($a.labels.node? | default "")
            severity: ($a.labels.severity? | default "warning")
            summary: ($a.annotations.summary? | default $a.labels.alertname)
        }}
    )

    let previous_fps = (if ($previous | is-empty) { [] } else { $previous | get fingerprint })
    let current_fps = (if ($alerts | is-empty) { [] } else { $alerts | get fingerprint })

    # Newly-firing alerts
    for a in ($alerts | where {|a| not ($a.fingerprint in $previous_fps) }) {
        let urgency = if $a.severity == "critical" { "critical" } else { "normal" }
        let title = if ($a.node | is-empty) {
            $"🔥 ($a.alertname)"
        } else {
            $"🔥 ($a.alertname) — ($a.node)"
        }
        ^notify-send --urgency $urgency --app-name "Alertmanager" $title $a.summary
    }

    # Newly-resolved alerts (were tracked last run, no longer active now)
    for a in ($previous | where {|a| not ($a.fingerprint in $current_fps) }) {
        let title = if ($a.node | is-empty) {
            $"✅ ($a.alertname) resolved"
        } else {
            $"✅ ($a.alertname) resolved — ($a.node)"
        }
        ^notify-send --urgency low --app-name "Alertmanager" $title ""
    }

    $alerts | save --force $state_file
}
