import CAvian

// Whether this machine can be listened to on a second loopback address.
//
// Linux routes the whole of 127.0.0.0/8 to `lo`, so 127.0.0.2 is there for the
// taking. macOS configures 127.0.0.1 on lo0 and nothing else, and wants to be
// asked:
//
//     sudo ifconfig lo0 alias 127.0.0.2 up
//
// Two tests need a second address, and both prove something no other test can:
// that the address which was *resolved* is the address connected to, and that
// a certificate is checked against the address actually reached. Every other
// test in their files uses 127.0.0.1, which is guessable -- mutation testing
// showed that discarding the resolver's answer and hardcoding the literal
// passed all of them. So these are worth keeping, and worth skipping plainly
// where the machine cannot host them rather than failing as though Garuda
// were at fault.

/// True when a listener can be opened on 127.0.0.2.
let loopbackAliasAvailable: Bool = {
    let fd = "127.0.0.2".withCString { av_listen_tcp($0, 0, 4, 0, 0) }
    guard fd >= 0 else { return false }
    _ = av_close(fd)
    return true
}()

/// What to say when it cannot, which is a machine to configure rather than a
/// bug to file.
let loopbackAliasReason = "needs a second loopback address: sudo ifconfig lo0 alias 127.0.0.2 up"
