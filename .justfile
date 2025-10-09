#!/usr/bin/env -S just --justfile

set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

root_dir := justfile_dir()

mod kube "kubernetes"

[private]
default:
    just -l

[private]
log lvl msg *args:
    gum log -t rfc3339 -s -l "{{ lvl }}" "{{ msg }}" {{ args }}

[private]
template file *args:
    minijinja-cli "{{ file }}" {{ args }} | op inject

[doc('Run Flux Test')]
flux-test:
    docker run --rm -v {{ root_dir }}:/workspace -w /workspace ghcr.io/allenporter/flux-local:v7.10.0 test --all-namespaces --enable-helm --path /workspace/kubernetes/flux/cluster --verbose
