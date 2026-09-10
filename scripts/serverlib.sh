# Starting and stopping the server a script owns.
#
# Sourced by the test and benchmark harnesses. It exists because they used to
# clean up with `pkill -9 -x peregrine`, which matches by name: that takes down
# every peregrine on the machine, including a second copy being compared against
# and whatever somebody else happens to be running. `pkill -9 -f uvicorn` and
# friends are wider still, since -f matches any command line containing the
# word -- a text editor with the file open, or the invoking shell.
#
# Two things matter here:
#
#   * only the process this script started is signalled;
#   * it is signalled as a process group, so the workers a supervisor forked go
#     with it. Signalling the leader alone and then killing it after a timeout
#     is how an orphaned worker survives to hold the port against the next run.
#
# Usage:
#
#     . "$(dirname "$0")/serverlib.sh"
#     server_start "$BIN" --port 8000 app:application > server.log 2>&1
#     ...
#     server_stop
#
# Redirections belong on the `server_start` call, as above; the background job
# inherits them. After it returns, $SERVER_PID is the process group leader,
# which is also what to hand anything that walks the process tree.

SERVER_PID=""

# Seconds to wait for a graceful stop before insisting.
SERVER_STOP_TIMEOUT=${SERVER_STOP_TIMEOUT:-10}

server_start() {
    # Job control gives the background job a process group of its own, with the
    # child as leader -- the portable half of what `setsid` does, and unlike
    # `setsid` it is in every shell that runs these scripts.
    set -m
    "$@" &
    SERVER_PID=$!
    set +m
}

# Anything still listening on a port this script owns, once the group is gone.
#
# A server that puts itself in a session of its own cannot be reached by
# signalling the process group -- granian's workers are `multiprocessing`
# children that do exactly that -- and matching by name is what this file exists
# to avoid. The port is the narrowest handle left: the script has already
# claimed it, so whatever is still holding it is both the thing that escaped and
# the thing that would break the next run.
server_reap_port() {
    local port=$1
    command -v fuser >/dev/null 2>&1 || return 0
    fuser -k -TERM "$port/tcp" >/dev/null 2>&1 || return 0
    sleep 0.5
    fuser -k -KILL "$port/tcp" >/dev/null 2>&1 || true
}

# Stops the server and everything it forked. Safe to call when nothing is
# running, and safe to call twice.
#
# With a port argument, anything still holding that port afterwards is reaped
# too; pass it when the server being started is not ours.
server_stop() {
    local port=${1:-}
    if [ -z "${SERVER_PID:-}" ]; then
        [ -n "$port" ] && server_reap_port "$port"
        return 0
    fi

    # A negative PID is the process group that PID leads.
    kill -TERM -- "-$SERVER_PID" 2>/dev/null

    local waited=0
    local limit=$((SERVER_STOP_TIMEOUT * 5))
    while kill -0 "$SERVER_PID" 2>/dev/null && [ "$waited" -lt "$limit" ]; do
        sleep 0.2
        waited=$((waited + 1))
    done

    # Whatever is still up has had its grace period. The group again, because
    # the point is not to leave a worker behind holding the port.
    kill -KILL -- "-$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
    SERVER_PID=""

    [ -n "$port" ] && server_reap_port "$port"
    return 0
}

# `server_stop` on the way out, however the script ends.
server_trap_cleanup() {
    trap 'server_stop; exit 130' INT TERM
    trap 'server_stop' EXIT
}
