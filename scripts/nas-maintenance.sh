#!/usr/bin/env bash
set -Eeuo pipefail

# Stop/start every workload backed by the Synology NAS so it can be safely powered off.
#
#   stop   - suspend owning HelmReleases, scale workloads to 0, wait for iSCSI detach
#   start  - restore original replica counts and resume HelmReleases
#   status - show NAS-backed workloads and Synology VolumeAttachments

# lib/common.sh needs bash 4+; macOS ships 3.2 as /bin/bash, so re-exec under Homebrew bash
if ((BASH_VERSINFO[0] < 4)); then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [[ -x "${candidate}" ]] && exec "${candidate}" "${0}" "$@"
    done
    echo "bash 4+ is required (brew install bash)" >&2
    exit 1
fi

source "$(dirname "${0}")/lib/common.sh"

export ROOT_DIR="$(git rev-parse --show-toplevel)"
export KUBECONFIG="${KUBECONFIG:-${ROOT_DIR}/kubeconfig}"

readonly CSI_DRIVER="csi.san.synology.com"
readonly REPLICAS_ANNOTATION="homelab.nas-maintenance/replicas"
readonly DETACH_TIMEOUT="${DETACH_TIMEOUT:-300}"

# Print "<namespace> <kind> <name>" for each Deployment/StatefulSet whose pods mount a Synology PVC
function find_nas_workloads() {
    local -r storage_classes=$(kubectl get storageclass -o json |
        jq -c --arg driver "${CSI_DRIVER}" '[.items[] | select(.provisioner == $driver) | .metadata.name]')

    local -r claims=$(kubectl get pvc --all-namespaces -o json |
        jq -c --argjson sc "${storage_classes}" \
            '[.items[] | select(.spec.storageClassName as $s | $sc | index($s)) | "\(.metadata.namespace)/\(.metadata.name)"]')

    local -r replicasets=$(kubectl get replicasets --all-namespaces -o json |
        jq -c '[.items[] | {key: "\(.metadata.namespace)/\(.metadata.name)", value: (.metadata.ownerReferences[0].name // "")}] | from_entries')

    kubectl get pods --all-namespaces -o json |
        jq -r --argjson claims "${claims}" --argjson rs "${replicasets}" '
            .items[]
            | . as $pod
            | select([.spec.volumes[]?.persistentVolumeClaim.claimName // empty
                      | "\($pod.metadata.namespace)/\(.)"] | any(. as $c | $claims | index($c)))
            | .metadata.ownerReferences[0] as $owner
            | if $owner.kind == "ReplicaSet" then
                "\(.metadata.namespace) deployment \($rs["\(.metadata.namespace)/\($owner.name)"])"
              elif $owner.kind == "StatefulSet" then
                "\(.metadata.namespace) statefulset \($owner.name)"
              else
                "\(.metadata.namespace) unsupported \(.metadata.name)"
              end' |
        sort -u
}

# Print "<namespace> <kind> <name>" for each workload previously scaled down by this script
function find_stopped_workloads() {
    kubectl get deployments,statefulsets --all-namespaces -o json |
        jq -r --arg ann "${REPLICAS_ANNOTATION}" '
            .items[]
            | select(.metadata.annotations[$ann] != null)
            | "\(.metadata.namespace) \(.kind | ascii_downcase) \(.metadata.name)"'
}

# Print the Flux HelmRelease managing a workload, if any
function helmrelease_for() {
    local -r namespace="${1}" kind="${2}" name="${3}"
    kubectl -n "${namespace}" get "${kind}" "${name}" -o json |
        jq -r '.metadata.labels["helm.toolkit.fluxcd.io/name"] // empty'
}

function synology_attachments() {
    kubectl get volumeattachments -o json |
        jq -r --arg driver "${CSI_DRIVER}" \
            '.items[] | select(.spec.attacher == $driver) | "\(.metadata.name) pv=\(.spec.source.persistentVolumeName) node=\(.spec.nodeName)"'
}

function stop() {
    local workloads
    workloads=$(find_nas_workloads)

    if [[ -z "${workloads}" ]]; then
        log info "No running workloads mount Synology volumes"
    fi

    if grep -q " unsupported " <<<"${workloads}"; then
        log error "Found NAS-backed pods not owned by a Deployment/StatefulSet, stop them manually" \
            "pods=$(grep " unsupported " <<<"${workloads}" | awk '{print $1"/"$3}' | xargs)"
    fi

    while read -r namespace kind name; do
        [[ -z "${namespace}" ]] && continue

        local hr replicas
        hr=$(helmrelease_for "${namespace}" "${kind}" "${name}")
        replicas=$(kubectl -n "${namespace}" get "${kind}" "${name}" -o jsonpath='{.spec.replicas}')

        if [[ -n "${hr}" ]]; then
            log info "Suspending HelmRelease" "namespace=${namespace}" "helmrelease=${hr}"
            flux -n "${namespace}" suspend helmrelease "${hr}"
        else
            log warn "No HelmRelease found, Flux may scale this back up" "namespace=${namespace}" "${kind}=${name}"
        fi

        log info "Scaling to 0" "namespace=${namespace}" "${kind}=${name}" "replicas=${replicas}"
        kubectl -n "${namespace}" annotate "${kind}" "${name}" --overwrite "${REPLICAS_ANNOTATION}=${replicas}"
        kubectl -n "${namespace}" scale "${kind}" "${name}" --replicas=0
    done <<<"${workloads}"

    log info "Waiting for Synology volumes to detach" "timeout=${DETACH_TIMEOUT}s"
    local -r deadline=$((SECONDS + DETACH_TIMEOUT))
    while [[ -n "$(synology_attachments)" ]]; do
        if ((SECONDS >= deadline)); then
            synology_attachments
            log error "Timed out waiting for Synology volumes to detach"
        fi
        sleep 5
    done

    log info "All Synology volumes detached, the NAS is safe to shut down"
}

function start() {
    local workloads
    workloads=$(find_stopped_workloads)

    if [[ -z "${workloads}" ]]; then
        log info "No workloads were stopped by this script"
        return
    fi

    while read -r namespace kind name; do
        local hr replicas
        hr=$(helmrelease_for "${namespace}" "${kind}" "${name}")
        replicas=$(kubectl -n "${namespace}" get "${kind}" "${name}" -o json |
            jq -r --arg ann "${REPLICAS_ANNOTATION}" '.metadata.annotations[$ann]')

        log info "Scaling up" "namespace=${namespace}" "${kind}=${name}" "replicas=${replicas}"
        kubectl -n "${namespace}" scale "${kind}" "${name}" --replicas="${replicas}"
        kubectl -n "${namespace}" annotate "${kind}" "${name}" "${REPLICAS_ANNOTATION}-"

        if [[ -n "${hr}" ]]; then
            log info "Resuming HelmRelease" "namespace=${namespace}" "helmrelease=${hr}"
            flux -n "${namespace}" resume helmrelease "${hr}"
        fi
    done <<<"${workloads}"

    while read -r namespace kind name; do
        log info "Waiting for rollout" "namespace=${namespace}" "${kind}=${name}"
        kubectl -n "${namespace}" rollout status "${kind}" "${name}" --timeout=5m
    done <<<"${workloads}"

    log info "All NAS-backed workloads are running"
}

function status() {
    log info "Running workloads on Synology volumes"
    find_nas_workloads
    log info "Workloads stopped for NAS maintenance"
    find_stopped_workloads
    log info "Synology VolumeAttachments"
    synology_attachments
}

function main() {
    check_cli flux jq kubectl

    case "${1:-}" in
        stop) stop ;;
        start) start ;;
        status) status ;;
        *) log error "Usage: ${0} {stop|start|status}" ;;
    esac
}

main "$@"
