# Starting and stopping the server a script owns.
#
# Sourced by the test and benchmark harnesses. It exists because they used to
# clean up with `pkill -9 -x peregrine`, which matches by name: that takes down
# every peregrine on the machine, including a second copy being compared against
# and whatever somebody else happens to be running. `pkill -9 -f uvicorn` and
# friends are wider still, since -f matches any command line containing the
# word -- a text editor with the file open, or the invoking shell.
#
# Nothing here signals a process it cannot show it started:
#
#   * the server runs in a process group of its own, so the workers a
#     supervisor forks are reached along with it. Signalling the leader alone
#     and then killing it after a timeout is how an orphaned worker survives to
#     hold the port against the next run;
#   * descendants that leave that group -- granian's workers are
#     `multiprocessing` children that start a session of their own -- are
#     collected by walking the process tree *before* anything is signalled,
#     because once the leader dies its children are re-parented and there is
#     nothing left to prove they were ours.
#
# Killing whatever holds the port is deliberately not done. It reads as the
# narrow option and is not: a harness calls `stop` before it starts anything, so
# a port-based cleanup fires while the only listener is a server that has
# nothing to do with this script. `server_require_port_free` says so and stops
# instead.
#
# Usage:
#
#     . "$(dirname "$0")/serverlib.sh"
#     server_require_port_free 8210 || exit 1
#     server_start "$BIN" --port 8210 app:application > server.log 2>&1
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

# Every descendant of $1, plus $1 itself, as a space-separated list.
server_descendants() {
    local frontier=$1 out=$1 next p kids
    while [ -n "$frontier" ]; do
        next=""
        for p in $frontier; do
            kids=$(pgrep -P "$p" 2>/dev/null | tr '\n' ' ')
            next="$next $kids"
        done
        frontier=$(echo "$next" | xargs 2>/dev/null)
        out="$out $frontier"
    done
    echo "$out" | xargs
}

# Stops the server and everything it started. Safe to call when nothing is
# running, and safe to call twice.
server_stop() {
    [ -n "${SERVER_PID:-}" ] || return 0

    # Taken while the tree is still intact, and only ever processes this script
    # is the ancestor of.
    local owned
    owned=$(server_descendants "$SERVER_PID")

    # A negative PID is the process group that PID leads; the list catches
    # anything that left it.
    kill -TERM -- "-$SERVER_PID" 2>/dev/null
    # shellcheck disable=SC2086 -- a deliberate list of pids.
    kill -TERM $owned 2>/dev/null

    local waited=0
    local limit=$((SERVER_STOP_TIMEOUT * 5))
    while kill -0 "$SERVER_PID" 2>/dev/null && [ "$waited" -lt "$limit" ]; do
        sleep 0.2
        waited=$((waited + 1))
    done

    # Whatever is still up has had its grace period. The point is not to leave a
    # worker behind holding the port.
    kill -KILL -- "-$SERVER_PID" 2>/dev/null
    # shellcheck disable=SC2086 -- a deliberate list of pids.
    kill -KILL $owned 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
    SERVER_PID=""
    return 0
}

# True when nothing is listening on the port yet.
#
# A harness that finds the port taken should say so and stop. The alternatives
# are both bad: measuring whatever is already there, or clearing it out of the
# way, which means killing a process this script never started.
server_require_port_free() {
    local port=$1
    command -v ss >/dev/null 2>&1 || return 0
    ss -ltn "sport = :$port" 2>/dev/null | grep -q LISTEN || return 0
    echo "port $port is already in use; stop whatever is on it and run this again" >&2
    return 1
}

# `server_stop` on the way out, however the script ends.
server_trap_cleanup() {
    trap 'server_stop; exit 130' INT TERM
    trap 'server_stop' EXIT
}
