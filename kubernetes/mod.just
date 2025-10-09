set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

kubernetes_dir := justfile_dir() + '/kubernetes'

[private]
default:
    just -l kube

[doc('Get all External Secrets')]
get-all-es:
    kubectl get externalsecrets -A

[doc('Annotate an External Secret to force refresh')]
annotate-es es_name es_namespace:
    kubectl annotate externalsecret -n {{es_namespace}} {{es_name}} force-refresh=$(date +%s) --overwrite

