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

# Run a shell script on a node's host via a kubectl debug pod and return its output
#
# `kubectl debug node/<n>` does not attach by default: it creates a pod and
# returns at once. So this creates the pod, waits for it to finish, reads its
# logs and deletes it. The host filesystem is at /host inside the pod. Mind
# the /var/run symlink trap: /host/var/run points at the container's /run,
# so use /host/run instead.
def node-debug-run [node: string, script: string, --timeout: string = "120s"] {
    let created = (^kubectl debug $"node/($node)" --image=alpine:latest --profile=legacy -- sh -c $script | complete)
    if $created.exit_code != 0 {
        error make { msg: $"kubectl debug failed on ($node): ($created.stderr | str trim)" }
    }
    let pod = ($created.stdout ++ $created.stderr | parse -r 'pod (?<name>\S+) with' | get -i name.0)
    if ($pod | is-empty) {
        error make { msg: $"could not find the debug pod name in: ($created.stdout ++ $created.stderr)" }
    }
    let waited = (^kubectl wait $"pod/($pod)" --for=jsonpath={.status.phase}=Succeeded $"--timeout=($timeout)" | complete)
    let out = (^kubectl logs $pod | complete)
    ^kubectl delete pod $pod --wait=false | complete | ignore
    if $waited.exit_code != 0 {
        error make { msg: $"debug pod ($pod) did not finish: ($waited.stderr | str trim)\n($out.stdout)" }
    }
    $out.stdout
}

# Verify the ACPI power key mitigations on puffer (issue #59)
#
# Checks logind.conf ignores the power key (short and long press) and the udev
# rule that suppresses the power button is present. Exits 1 if any check fails.
#
# Usage:
#   ops cluster puffer-powerkey
#
def "main cluster puffer-powerkey" [
    --node: string = "puffer"   # node to check (the mitigations were only applied to puffer)
] {
    let script = '
        grep -q "^HandlePowerKey=ignore" /host/etc/systemd/logind.conf \
          && echo "PASS  HandlePowerKey=ignore" \
          || echo "FAIL  HandlePowerKey=ignore missing"
        grep -q "^HandlePowerKeyLongPress=ignore" /host/etc/systemd/logind.conf \
          && echo "PASS  HandlePowerKeyLongPress=ignore" \
          || echo "FAIL  HandlePowerKeyLongPress=ignore missing"
        test -f /host/etc/udev/rules.d/99-ignore-power-button.udev \
          && echo "PASS  udev power button suppression rule" \
          || echo "FAIL  udev rule missing"
    '
    print $"Checking ($node) power key mitigations..."
    let out = (node-debug-run $node $script)
    print ($out | str trim)
    if ($out =~ 'FAIL') { exit 1 }
}

# Show pods that are not healthy, across all namespaces
#
# Lists pods that aren't Running or Succeeded, pods with a container stuck
# waiting (CrashLoopBackOff, ImagePullBackOff, ...) and Running pods whose
# containers aren't all ready. Prints a message when there are none.
#
# Usage:
#   ops cluster pods-unhealthy
#
def "main cluster pods-unhealthy" [] {
    let pods = (
        ^kubectl get pods -A -o json | from json | get items
        | each { |p|
            let cs   = ($p.status | get -i containerStatuses | default [])
            let ics  = ($p.status | get -i initContainerStatuses | default [])
            let main_reasons = ($cs | each { |c| $c.state | get -i waiting.reason } | compact)
            let init_reasons = ($ics | each { |c|
                let w = ($c.state | get -i waiting.reason)
                let t = ($c.state | get -i terminated)
                if ($w | is-not-empty) and $w != "PodInitializing" { $"Init:($w)" } else if ($t | is-not-empty) and $t.exitCode != 0 { $"Init:($t.reason? | default 'Error')" }
            } | compact)
            let ready = ($cs | where ready == true | length)
            let status = if ($p.metadata | get -i deletionTimestamp | is-not-empty) {
                "Terminating"
            } else if ($init_reasons | is-not-empty) {
                $init_reasons.0
            } else if ($main_reasons | is-not-empty) {
                $main_reasons.0
            } else {
                $p.status.phase
            }
            {
                namespace: $p.metadata.namespace
                name:      $p.metadata.name
                ready:     $"($ready)/($cs | length)"
                status:    $status
                restarts:  ($cs | each { |c| $c.restartCount } | append 0 | math sum)
                node:      ($p.spec | get -i nodeName | default "")
                all_ready: ($ready == ($cs | length))
            }
        }
        | where { |r| ($r.status not-in [Running Succeeded]) or ($r.status == "Running" and not $r.all_ready) }
        | reject all_ready
    )
    if ($pods | is-empty) {
        print "No unhealthy pods"
    } else {
        $pods
    }
}
