# Talu lab target descriptor — sourced by the `make lab-*` targets and dev/lab/* scripts.
# This is the remote Rocky9 validation sandbox. Override any value in your shell if needed.
#
#   original handle:  ssh rocky@203.0.113.10

# SSH connection to the lab host.
export LAB_SSH="${LAB_SSH:-rocky@203.0.113.10}"

# Local port the Kubernetes API is forwarded to (dev/lab/tunnel.sh -L LAB_API_PORT:127.0.0.1:6443).
export LAB_API_PORT="${LAB_API_PORT:-6443}"

# Local port the in-cluster zot registry is forwarded to (for `flux push artifact` reconcile testing).
export LAB_ZOT_PORT="${LAB_ZOT_PORT:-5000}"

# The overlay driven onto the lab.
export LAB_ENV="${LAB_ENV:-rocky9-sandbox}"

# Where the repo is rsync'd on the lab host (for host-side ops: bootstrap, cluster create, loopdev).
export LAB_REMOTE_DIR="${LAB_REMOTE_DIR:-talu}"

# Talos-in-Docker cluster name on the lab.
export LAB_CLUSTER="${LAB_CLUSTER:-talu-lab}"

# kubeconfig / talosconfig fetched from the lab live here (gitignored).
export LAB_KUBECONFIG="${LAB_KUBECONFIG:-$PWD/.lab/kubeconfig}"
export LAB_TALOSCONFIG="${LAB_TALOSCONFIG:-$PWD/.lab/talosconfig}"

# Persistent SSH ControlMaster socket, so every lab-* command reuses one connection.
export LAB_SSH_SOCKET="${LAB_SSH_SOCKET:-$PWD/.lab/ssh-control.sock}"
