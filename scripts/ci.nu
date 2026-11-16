#!/usr/bin/env nu

# CI pipeline commands (Argo Workflows + Harbor)
#
# Usage:
#   ops ci build-e2e

const CI_NS = "argo-workflows"
const CI_GH_REPO = "jconlon/ops-microk8s"
const HARBOR = "https://registry.verticon.com"

# Basic auth for Harbor, taken from the harbor-credentials dockerconfigjson
# secret already in the cluster, so no password goes on the command line.
def harbor-auth [] {
    ^kubectl get secret harbor-credentials -n $CI_NS -o json
    | from json
    | get data
    | get ".dockerconfigjson"
    | decode base64 | decode | from json
    | get auths | get "registry.verticon.com" | get auth
}

# Poll a Workflow's phase every 15s until it succeeds, fails or times out
def wait-for-workflow [wf: string, timeout: duration] {
    let deadline = ((date now) + $timeout)
    loop {
        let phase = (^kubectl get workflow $wf -n $CI_NS -o jsonpath={.status.phase} | complete | get stdout | str trim)
        if $phase == "Succeeded" { return }
        if $phase in [Failed Error] {
            print $"FAIL  workflow phase: ($phase)"
            ^argo logs -n $CI_NS $wf | complete | get stdout | print
            error make { msg: $"workflow ($wf) ended in phase ($phase)" }
        }
        if (date now) > $deadline {
            error make { msg: $"timed out after ($timeout) \(phase: ($phase | default 'Unknown')\)" }
        }
        sleep 15sec
    }
}

# Delete the Workflow, close the test PR and delete the spec branch.
# Every step ignores errors, so it's safe to run after a partial failure.
def build-e2e-cleanup [wf: string, branch: string] {
    if ($wf | is-not-empty) {
        print $">>> Cleaning up workflow ($wf)..."
        ^kubectl delete workflow $wf -n $CI_NS --ignore-not-found | complete | ignore
    }
    let prs = (^gh pr list --repo $CI_GH_REPO --head $branch --json number | complete)
    if $prs.exit_code == 0 {
        for pr in ($prs.stdout | from json) {
            print $">>> Closing PR #($pr.number)..."
            ^gh pr close ($pr.number | into string) --repo $CI_GH_REPO | complete | ignore
        }
    }
    print $">>> Deleting spec branch ($branch)..."
    ^gh api -X DELETE $"repos/($CI_GH_REPO)/git/refs/heads/($branch)" | complete | ignore
}

# End-to-end CI pipeline validation
#
# Builds a minimal Alpine image with the image-build-push ClusterWorkflowTemplate,
# checks the result in Harbor and the PR the create-pr step opens, then cleans up.
# Run by hand after changing the CI pipeline. It's not part of the routine
# chainsaw suite because Kaniko has to pull its executor image, clone the repo,
# build and push, which takes 3–10 min.
#
# Prerequisites:
#   - harbor-credentials secret in the argo-workflows namespace (issue #62)
#   - image-build-push ClusterWorkflowTemplate deployed and synced (issue #63)
#   - 'library' project in Harbor (default, always present)
#   - 'cache' project in Harbor with robot$argo-workflows push/pull (issue #63)
#   - robot$argo-workflows has Artifact:Delete on 'library' (issue #62)
#
# Steps:
#   1. Submit         build tests/e2e-build/Dockerfile (FROM alpine:latest) and push
#                     registry.verticon.com/library/kaniko-e2e-test:<epoch tag>;
#                     the create-pr step updates tests/e2e-build/test-manifest.yaml
#                     on branch image-update/<tag> and opens a PR
#   2. Wait           poll the workflow phase every 15s (default limit 15m);
#                     dump the workflow logs on failure
#   3. Verify image   Harbor API: the artifact exists; print its digest
#   4. Verify cache   Harbor API: the 'cache' project has repositories. WARN, not
#                     FAIL, when empty: Kaniko only caches RUN layers, so a bare
#                     FROM produces no cache entries
#   5. Delete image   remove the test artifact (WARN if the robot can't delete)
#   6. Verify PR      a PR exists for the spec branch
#   7. Cleanup        always runs, pass or fail: delete the Workflow, close the PR,
#                     delete the branch. (Ctrl+C skips it: nushell has no trap.
#                     Clean up by hand with kubectl / gh if you interrupt it.)
#
# Usage:
#   ops ci build-e2e
#   ops ci build-e2e --timeout 20min
#
def "main ci build-e2e" [
    --timeout: duration = 15min   # how long to wait for the workflow
] {
    let project = "library"
    let repo    = "kaniko-e2e-test"
    let tag     = $"e2e-(date now | format date '%s')"
    let image   = $"registry.verticon.com/($project)/($repo):($tag)"
    let branch  = $"image-update/($tag)"
    let artifact_url = $"($HARBOR)/api/v2.0/projects/($project)/repositories/($repo)/artifacts/($tag)"

    # Step 1
    print $">>> Submitting kaniko build: ($image)"
    let wf = (
        ^argo submit -n $CI_NS
            --from clusterworkflowtemplate/image-build-push
            -p $"repo-url=https://github.com/($CI_GH_REPO)"
            -p $"image=($image)"
            -p context=tests/e2e-build
            -p $"spec-repo-url=https://github.com/($CI_GH_REPO)"
            -p spec-manifest=tests/e2e-build/test-manifest.yaml
            -o name
        | str trim
    )
    print $"    workflow: ($wf)"

    let result = try {
        # Step 2
        print $">>> Waiting for completion \(timeout: ($timeout)\)..."
        wait-for-workflow $wf $timeout
        print "PASS  workflow succeeded"

        # Step 3
        print ">>> Verifying image in Harbor..."
        let headers = [Authorization $"Basic (harbor-auth)"]
        let digest = (http get -H $headers $artifact_url | get digest | str substring 0..18)
        print $"PASS  image present in Harbor: ($digest)"

        # Step 4
        print ">>> Verifying Kaniko layer cache populated in Harbor..."
        let cache_count = (try {
            http get -H $headers $"($HARBOR)/api/v2.0/projects/cache/repositories?page_size=100" | length
        } catch { 0 })
        if $cache_count > 0 {
            print $"PASS  Kaniko cache populated: ($cache_count) repositor(if $cache_count == 1 { 'y' } else { 'ies' }) in registry.verticon.com/cache"
        } else {
            print "WARN  no cache repositories found — cache project may be empty on first build or --cache-repo not reachable"
        }

        # Step 5
        print ">>> Removing artifact from Harbor..."
        let status = (http delete -H $headers --full --allow-errors $artifact_url | get status)
        if $status in [200 202] {
            print "PASS  artifact deleted"
        } else {
            print $"WARN  artifact deletion returned HTTP ($status) — robot account may lack delete permission; clean up manually in Harbor"
        }

        # Step 6
        print $">>> Verifying PR created for branch ($branch)..."
        let prs = (^gh pr list --repo $CI_GH_REPO --head $branch --json number | from json)
        if ($prs | is-empty) {
            error make { msg: $"no PR found for branch ($branch)" }
        }
        print $"PASS  PR #($prs.0.number) created: ($branch)"
        { ok: true }
    } catch { |e|
        { ok: false, msg: $e.msg }
    }

    # Step 7
    build-e2e-cleanup $wf $branch

    if not $result.ok {
        print $"FAIL  ($result.msg)"
        exit 1
    }
    print ">>> Done."
}
