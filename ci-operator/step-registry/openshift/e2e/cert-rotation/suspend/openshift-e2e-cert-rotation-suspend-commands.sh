#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ openshift cert rotation suspend test command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# This file is scp'd to the machine where the nested libvirt cluster is running
# It stops kubelet service, kills all containers on each node, kills all pods,
# disables chronyd service on each node and on the machine itself, sets date ahead 400days
# then starts kubelet on each node and waits for cluster recovery. This simulates
# cert-rotation after 1 year.
# TODO: Run suite of conformance tests after recovery
cat >"${SHARED_DIR}"/time-skew-test.sh <<'EOF'
#!/bin/bash

set -euxo pipefail
sudo systemctl stop chronyd

SKEW=${1:-90d}
OC=${OC:-oc}
SSH_OPTS=${SSH_OPTS:- -o 'ConnectionAttempts=100' -o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' -o LogLevel=ERROR}
SCP=${SCP:-scp ${SSH_OPTS}}
SSH=${SSH:-ssh ${SSH_OPTS}}
SETTLE_TIMEOUT=5m
COMMAND_TIMEOUT=15m

# HA cluster's KUBECONFIG points to a directory - it needs to use first found cluster
if [ -d "$KUBECONFIG" ]; then
  for kubeconfig in $(find ${KUBECONFIG} -type f); do
    export KUBECONFIG=${kubeconfig}
  done
fi

mapfile -d ' ' -t control_nodes < <( ${OC} get nodes --selector='node-role.kubernetes.io/master' --template='{{ range $index, $_ := .items }}{{ range .status.addresses }}{{ if (eq .type "InternalIP") }}{{ if $index }} {{end }}{{ .address }}{{ end }}{{ end }}{{ end }}' )

mapfile -d ' ' -t compute_nodes < <( ${OC} get nodes --selector='!node-role.kubernetes.io/master' --template='{{ range $index, $_ := .items }}{{ range .status.addresses }}{{ if (eq .type "InternalIP") }}{{ if $index }} {{end }}{{ .address }}{{ end }}{{ end }}{{ end }}' )

function run-on-all-nodes {
  for n in ${control_nodes[@]} ${compute_nodes[@]}; do timeout ${COMMAND_TIMEOUT} ${SSH} core@"${n}" sudo 'bash -eEuxo pipefail' <<< ${1}; done
}

function run-on-first-master {
  timeout ${COMMAND_TIMEOUT} ${SSH} "core@${control_nodes[0]}" sudo 'bash -eEuxo pipefail' <<< ${1}
}

function copy-file-from-first-master {
  timeout ${COMMAND_TIMEOUT} ${SCP} "core@${control_nodes[0]}:${1}" "${2}"
}

function wait-for-nodes-to-be-ready {
  run-on-first-master "
    export KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost-recovery.kubeconfig
    until oc get nodes; do sleep 30; done
    for nodename in $(oc get nodes -o name); do
      node_ready=false
      until ${node_ready}; do
        STATUS=$(oc get ${nodename} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
        TIME_DIFF=$(($(date +%s)-$(date -d $(oc get ${nodename} -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastHeartbeatTime}') +%s)))
        if [[ ${DIFF} < 100 && "${STATUS} == "True" ]]; then
          node_ready=true
        fi
        oc get csr | grep Pending | cut -f1 -d' ' | xargs oc adm certificate approve || true
        sleep 30
      done
    done
    oc get csr | grep Pending
    oc get nodes
  "
}

function retry() {
    local check_func=$1
    local max_retries=10
    local retry_delay=30
    local retries=0

    while (( retries < max_retries )); do
        if $check_func; then
            return 0
        fi

        (( retries++ ))
        if (( retries < max_retries )); then
            sleep $retry_delay
        fi
    done
    return 1
}

function pod-restart-workarounds {
  # Workaround for https://issues.redhat.com/browse/OCPBUGS-28735
  # Restart OVN / Multus before proceeding
  retry oc -n openshift-multus delete pod -l app=multus --force --grace-period=0
  retry oc -n openshift-ovn-kubernetes delete pod -l app=ovnkube-node --force --grace-period=0
  retry oc -n openshift-ovn-kubernetes delete pod -l app=ovnkube-control-plane --force --grace-period=0
}

ssh-keyscan -H ${control_nodes[@]} ${compute_nodes[@]} >> ~/.ssh/known_hosts

# Save found node IPs for "gather-cert-rotation" step
echo -n "${control_nodes[@]}" > /srv/control_node_ips
echo -n "${compute_nodes[@]}" > /srv/compute_node_ips

echo "Wrote control_node_ips: $(cat /srv/control_node_ips), compute_node_ips: $(cat /srv/compute_node_ips)"

# Prepull tools image on the nodes. "gather-cert-rotation" step uses it to run sos report
# However, if time is too far in the future the pull will fail with "Trying to pull registry.redhat.io/rhel8/support-tools:latest...
# Error: initializing source ...: tls: failed to verify certificate: x509: certificate has expired or is not yet valid: current time ... is after <now + 6m>"
run-on-all-nodes "podman pull --authfile /var/lib/kubelet/config.json registry.redhat.io/rhel8/support-tools:latest"

# Stop chrony service on all nodes
run-on-all-nodes "systemctl disable chronyd --now"

# Backup lb-ext kubeconfig so that it could be compared to a new one
KUBECONFIG_NODE_DIR="/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs"
KUBECONFIG_LB_EXT="${KUBECONFIG_NODE_DIR}/lb-ext.kubeconfig"
KUBECONFIG_REMOTE="/tmp/lb-ext.kubeconfig"
run-on-first-master "cp ${KUBECONFIG_LB_EXT} ${KUBECONFIG_REMOTE} && chown core:core ${KUBECONFIG_REMOTE}"
copy-file-from-first-master "${KUBECONFIG_REMOTE}" "${KUBECONFIG_REMOTE}"

# Set date for host
sudo timedatectl status
sudo timedatectl set-time ${SKEW}
sudo timedatectl status

# Skew clock on every node
# TODO: Suspend, resume and make it resync time from host instead?
run-on-all-nodes "timedatectl set-time ${SKEW} && timedatectl status"

# Restart kubelet
run-on-all-nodes "systemctl restart kubelet"

# Wait for nodes to become unready and approve CSRs until nodes are ready again
wait-for-nodes-to-be-ready

# Wait for kube-apiserver operator to generate new localhost-recovery kubeconfig
run-on-first-master "while diff -q ${KUBECONFIG_LB_EXT} ${KUBECONFIG_REMOTE}; do sleep 30; done"

# Copy system:admin's lb-ext kubeconfig locally and use it to access the cluster
run-on-first-master "cp ${KUBECONFIG_LB_EXT} ${KUBECONFIG_REMOTE} && chown core:core ${KUBECONFIG_REMOTE}"
copy-file-from-first-master "${KUBECONFIG_REMOTE}" "${KUBECONFIG_REMOTE}"

# Approve certificates for workers, so that all operators would complete
wait-for-nodes-to-be-ready

pod-restart-workarounds

# Wait for operators to stabilize
if
  ! oc adm wait-for-stable-cluster --minimum-stable-period=5m --timeout=60m; then
    oc get nodes
    oc get co | grep -v "True\s\+False\s\+False"
    exit 1
else
  oc get nodes
  oc get co
  oc get clusterversion
fi
exit 0

EOF
chmod +x "${SHARED_DIR}"/time-skew-test.sh
scp "${SSHOPTS[@]}" "${SHARED_DIR}"/time-skew-test.sh "root@${IP}:/usr/local/bin"

timeout \
	--kill-after 10m \
	120m \
	ssh \
	"${SSHOPTS[@]}" \
	"root@${IP}" \
	/usr/local/bin/time-skew-test.sh \
	${SKEW}
