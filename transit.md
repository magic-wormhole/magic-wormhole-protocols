# Transit Protocol

The Wormhole API does not currently provide for large-volume data transfer
(this feature will be added to a future version, under the name "Dilated
Wormhole"). For now, bulk data is sent through a "Transit" object, which does
not use the Rendezvous Server. Instead, it tries to establish a direct TCP
connection from sender to recipient (or vice versa). If that fails, both
sides connect to a "Transit Relay", a very simple server that just glues two
TCP (or WebSocket) streams together when asked.

The Transit protocol is responsible for establishing an encrypted
bidirectional record stream between two programs. It must be given a "transit
key" and a set of "hints" which help locate the other end (which are both
delivered by Wormhole).

The protocol tries hard to create a **direct** connection between the two
ends, but if that fails, it uses a centralized relay server to ferry data
between two separate TCP streams (one to each client). Direct connection
hints are used for the first, and relay hints are used for the second.

The current implementation starts with the following:

* detect all of the host's IP addresses
* listen on a random TCP port
* offers the (address,port) pairs as hints

The other side will attempt to connect to each of those ports, as well as
listening on its own socket. After a few seconds without success, they will
both connect to a relay server.

## Transports

The Transit relay supports two kinds of transports: plain TCP streams and WebSockets.

No matter which transport is selected, the same stream of binary data is sent over it.
That is: first the relay handshake, then the transit handshake and then some number of length-prefixed encrypted records.

More transports may be added in the future.

### TCP Transport

TCP already provides a stream-oriented protocol, so its handling is straightforward with no extra processing.
The framing is described in sections below (line-ending based during the handshakes and length-prefixed encrypted records after that).

### WebSockets Transport

The WebSockets protocol is message-based.
Messages arrive in-order and can be any size up to 4GiB (we recommend using much smaller sizes than this).
Although the WebSockets protocol handles framing of these messages, when using WebSockets via the Transit relay clients must still regard the payload data as a stream of bytes as outlined above.
That is, the framing (line-based and then length-prefixed) is still sent inside the WebSockets messages.

All sent and received messages MUST use the WebSockets "binary" scheme.
Some WebSockets libraries already provide abstractions to treat incoming messages as a stream.
Stated differently: a single WebSocket message may contain only part of a logical Transit protocol message or it may contain several logical protocol messages; buffering these will be necessary.
This allows the same protocol parsing to be used for TCP and for WebSockets: simply process all payload bytes in order.

Handling WebSockets in this manner (i.e. instead of ensuring WebSocket messages correspond to individual Transit protocol messages) also allows the Transit relay to be extremely simply, not having to "translate" message framing between the TCP and WebSockets protocols.
This allows straightforward interoperation between TCP and WebSockets clients with minimal buffering in the Transit server.


## Roles

The Transit protocol has pre-defined "Leader" and "Follower" roles (unlike
Wormhole, which is symmetric/nobody-goes-first), which are called "Sender" and "Receiver"
for historical reasons. Each connection must have exactly one Sender and exactly one Receiver.
If the application using transfer does not provide this distinction, some deterministic
way for distributing the roles must be used. This could be done by comparing each
participant's `side` in the Wormhole.

The connection itself is bidirectional: either side can send or receive
records. However the connection establishment mechanism needs to know who is
in charge, and the encryption layer needs a way to produce separate keys for
each side.

This may be relaxed in the future, much as Wormhole was.

## Abilities

Each Transit object has a set of "abilities". These are outbound connection
mechanisms that the client is capable of using. The following abilities are
specified in this document:

* `direct-tcp-v1` indicates that it can make direct outbound TCP connections to a
  requested host and port number.
* `relay-v1` indicates it can connect to the Transit Relay and speak the
  matching protocol.
* `tor-tcp-v1` allows both sides finding eath other over Tor

Together with each ability, the Transit object can create a
list of "hints", which tell the respective handshake how to find the other side.
Each ability declares its own set of hints; hints have a `type` that is equal
to the name of the ability they hint for.

For example, if our peer can use `direct-tcp-v1`, then our Transit object
will deduce our local IP addresses (unless forbidden, i.e. we're using Tor),
listen on a TCP port, then send a list of `direct-tcp-v1` hints pointing at
all of them. If our peer can use `relay-v1`, then we'll connect to our relay
server and give the peer a hint to the same.

`tor-tcp-v1` hints indicate an Onion service, which cannot be reached without
Tor. `direct-tcp-v1` hints can be reached with direct TCP connections (unless
forbidden) or by proxying through Tor. Onion services take about 30 seconds
to spin up, but bypass NAT, allowing two clients behind NAT boxes to connect
without a transit relay (really, the entire Tor network is acting as a
relay).

## Handshake (`direct-tcp-v1`, `tor-tcp-v1`)

The transit key is used to derive several secondary keys. Two of them are
used as a "handshake", to distinguish correct Transit connections from other
programs that happen to connect to the Transit sockets by mistake or malice.

The handshake is also responsible for choosing exactly one TCP connection to
use, even though multiple outbound and inbound connections are being
attempted.

The SENDER-HANDSHAKE is the string `transit sender %s ready\n\n`, with the
`%s` replaced by a hex-encoded 32-byte HKDF derivative of the transit key,
using a "context string" of `transit_sender`. The RECEIVER-HANDSHAKE is the
same but with `receiver` instead of `sender` (both for the string and the
HKDF context).

The handshake protocol is like this:

* immediately upon connection establishment, the Sender writes
  SENDER-HANDSHAKE to the socket (regardless of whether the Sender initiated
  the TCP connection, or was listening on a socket and accepted the
  connection)
* likewise the Receiver immediately writes RECEIVER-HANDSHAKE to either kind
  of socket
* if the Sender sees anything other than RECEIVER-HANDSHAKE as the first
  bytes on the wire, it hangs up
* likewise with the Receiver and SENDER-HANDSHAKE
* if the Sender sees that this is the first connection to get
  RECEIVER-HANDSHAKE, it sends `go\n`. If some other connection got there
  first, it hangs up (or sends `nevermind\n` and then hangs up, but this is
  mostly for debugging, and implementations should not depend upon it). After
  sending `go`, it switches to encrypted-record mode.
* if the Receiver sees `go\n`, it switches to encrypted-record mode. If the
  receiver sees anything else, or a disconnected socket, it disconnects.

To tolerate the inevitable race conditions created by multiple contending
sockets, only the Sender gets to decide which one wins: the first one to make
it past negotiation. Hopefully this is correlated with the fastest connection
pathway. The protocol ignores any socket that is not somewhat affiliated with
the matching Transit instance.

Hints will frequently point to local IP addresses (local to the other end)
which might be in use by unrelated nearby computers. The handshake helps to
ignore these spurious connections. It is still possible for an attacker to
cause the connection to fail, by intercepting both connections (to learn the
two handshakes), then making new connections to play back the recorded
handshakes, but this level of attacker could simply drop the user's packets
directly.

Any participant in a Transit connection (i.e. the party on the other end of
your wormhole) can cause their peer to make a TCP connection (and send the
handshake string) to any IP address and port of their choosing. The handshake
protocol is intended to make this no more than a minor nuisance.

## Relay Handshake (`relay-v1`)

The **Transit Relay** is a host which offers TURN-like services for
magic-wormhole instances. Clients connect to the relay and do a handshake
to determine which connection wants to be connected to which. The connection
is independent of the transport protocol (currently supported are TCP and
WebSockets), and the relay will also connect two clients using different protocols
together.

When connecting to a relay, the Transit client first writes RELAY-HANDSHAKE
to the socket, which is `please relay $channel for $side\n`, where `$channel`
is the hex-encoded 32-byte HKDF derivative of the transit key,
using `transit_relay_token` as the context, and `$side` is a random per session
identifier. The `side` is used to deduplicate a client opening multiple
connections to the same relay server: without, it may result in a loopback
to itself and a dead-lock of the protocol.
The client then waits for `ok\n`.

The relay waits for a second connection that uses the same token. When this
happens, the relay sends `ok\n` to both, then wires the connections together,
so that everything received after the token on one is written out (after the
ok) on the other. When either connection is lost, the other will be closed
(the relay does not support "half-close").

When clients use a relay connection, they perform the usual sender/receiver
handshake just after the `ok\n` is received: until that point they pretend
the connection doesn't even exist.

Direct connections are better, since they are faster and less expensive for
the relay operator. If there are any potentially-viable direct connection
hints available, the Transit instance will wait a few seconds before
attempting to use the relay. If it has no viable direct hints, it will start
using the relay right away. This prefers direct connections, but doesn't
introduce completely unnecessary stalls.

The Transit client can attempt connections to multiple relays, and uses the
first one that passes negotiation. Each side combines a locally-configured
hostname/port (usually "baked in" to the application, and hosted by the
application author) with additional hostname/port pairs that come from the
peer. This way either side can suggest the relays to use. The connection hints
provided by the Transit instance include the locally-configured relay, along
with the dynamically-determined direct hints. Both should be delivered to the
peer.


## Canonical abilities encodings

The transit protocol relies on an existing secured (but possibly low-bandwidth)
communication channel to exchange the abilities and hints. Thus, it has no
influence over how they are encoded. However, we make a suggestion using JSON
messages for other protocols to use.

Abilities are encoded as a list, each item having a `type` tag. An ability may
not appear more than once in the list.

```json
[
  {
    "type": "<string, one of {direct-tcp-v1, relay-v1, tor-tcp-v1}>"
  }
]
```

Example for the full abilities set:

```json
[
  { "type": "direct-tcp-v1" },
  { "type": "relay-v1" },
  { "type": "tor-tcp-v1" }
]
```

## Canonical hint encodings

Hints are encoded as list of objects. Every object contains a `type` field,
which further determines its encoding.

### `direct-tcp-v1`, `tor-tcp-v1`

```json
{
  "type": "direct-tcp-v1" or "tor-tcp-v1",
  "hostname": <string>,
  "port": <u16>,
  "priority": <float; optional>
}
```

`hostname` must be compliant with the `host` part of an URL, i.e. it may be an
IP address or a domain. Furthermore, IPv6 link-local addresses are not supported.

### `relay-v1`

```json
{
  "type": "relay-v1",
  "name": "<string, optional>",
  "hints": [
    {
      "type": "direct-tcp-v1" or "tor-tcp-v1",
      "hostname": "<string>",
      "port": "<tcp port>",
      "priority": "<number, usually [0..1], optional>"
    },
    {
      "type": "websocket-v1",
      "url": "<url>",
      "priority": "<number, usually [0..1], optional>"
    },
    …
  ],
}
```

A relay server may be reachable at multiple different endpoints and using
different protocols. All hinted endpoints for a relay server must point to the
same location, and the relay server must be able to connect any two of these
endpoints. If this is not the case, the relay server must be advertized using
multiple distinct hints instead (one per endpoint). Furthermore, a relay server
may be given a human readable name for UI purposes. We recommend using a primary
domain name for that purpose.

Hints have a `type` field, of which the currently known values are
`direct-tcp-v1` `tor-tcp-v1` and `websocket-v1`. The former two are
encoded the same way as the respective direct connection hints, hence
the name -- however `tor-tcp-v1` may have a `"hostname"` that is a
`.onion` domain (see RFC 7686). Hints of unknown type must be ignored.

A hint of type `websocket-v1` has an `url` field instead, which points to the
WebSocket. Both relay servers and clients should support `wss://` and `ws://`
URL schemes. If a relay server supports both, they should be advertised using
two hints.

Full example value:

```json
{
  "type": "relay-v1",
  "name": "example.org",
  "hints": [
    {
      "type": "direct-tcp-v1",
      "hostname": "relay.example.org",
      "port": 1234,
      "priority": 0.5
    },
    {
      "type": "websocket-v1",
      "url": "wss://relay.example.org:8000",
      "priority": 1
    }
  ],
}
```

## Encryption

If desired\*, transit provides an encrypted **record-pipe**, which means the two
sides can and receive whole records, rather than unframed bytes. This is a side-effect of the
encryption (which uses the NaCl "secretbox" function). The encryption adds 44
bytes of overhead to each record (4-byte length, 24-byte nonce, 32-byte MAC),
so you might want to avoid bite-sized records for efficiency reasons.

The maximum theoretical
record size is 2^32 bytes (4GiB). The whole record must be held in memory at
the same time, plus its ciphertext, so very large ciphertexts are not
recommended. Transit implementations must implement a mechanism to set an upper
bound to the message size, which protocols using transit may use. That value should
default to 64MiB, which is a common default for WebSockets or HTTP communication.

Transit provides **confidentiality**, **integrity**, and **ordering** of
records. Passive attackers can only do the following:

* learn the size and transmission time of each record
* learn the sending and destination IP addresses

In addition, an active attacker (e.g. a malicious relay) is able to:

* delay delivery of individual records, while maintaining ordering (if they
  delay record #4, they must delay #5 and later as well)
* terminate the connection at any time

If either side receives a corrupted or out-of-order record, they drop the
connection. Attackers cannot modify the contents of a record, or change the
order of the records, without being detected and the connection being
dropped. If a record is lost (e.g. the receiver observes records #1,#2,#4,
but not #3), the connection is dropped when the unexpected sequence number is
received.

\* Most applications will likely want to use this. However, if applications prefer
doing their own crypto (e.g. because they tunnel SSH or TLS over transit), then
they can use the "raw" TCP stream built by Wormhole without the encrypted record pipes.

### Nonces

Each message contains a 24 bytes long nonce. The first nonce is all zeroes and is
incremented little endian for each record. As sender and receiver use different keys,
both sides have their own nonce.

For each received record, the nonce must be checked to be equal to the expected value,
which has to be tracked. Thus, there are 4 nonces in total, two per direction which are
kept in sync.

## On finding a direct connection

Because it is easy to get things wrong. This section only applies to the
`direct-tcp-v1` hint. The following section is closely tied to the operating
system's sockets API, and the the verbs *bind*, *listen*, *accept* and *connect*
will be used accordingly. Note that this is more a guide than a specification,
since it handles implementation details that should all mostly be compatible
with each other (and when not, failure is not critical).

### The easy way

Each side binds a new TCP socket, enumerates all local non-loopback IP addresses
and exchanges port+IPs with the peer. Then, both sides listen on their socket
while simultaneously trying to connect to the peer. As described above, once a
handshake is successful, all other attempts are aborted and the resources closed.

### Punching holes through firewalls

To go through firewalls, a different approach must be used instead: first, both
sides again need to bind a socket and exchange hints. This time however, the
`SO_REUSEADDR` option must be set. Then, both sides try to connect to each of
the peer's IPs. For every connection attempt, they bind a new socket on the same
port again. Also you read that right, there are no `listen` or `accept` calls
involved.

This works only with firewalls that silently filter packets and which don't send
back any RST packets. Unfortunately, this is the default behavior of the kernel
when no firewall is active (or the firewall allowed) the packets. This means
that the firewall hole punching method does *not* work when *no* firewall is
active (Fun fact: if one side has a firewall and the other side doesn't then
connection attempts will work or fail depending on which side sent their packets
first—I'm really glad for you that you didn't have to debug this …). Thus,
**this method can only be an addition to the "easy" way** specified above. Sadly,
this means that the number of hints – and thus, attempted connections – is
doubled. If you manage to listen and accept on the same port so that only one
set of hints needs to be sent out, please contact `piegames` with your findings.
Also read [this paper](https://bford.info/pub/net/p2pnat/) (Python code
[here](https://github.com/dwoz/python-nat-hole-punching/)) for more details on
the subject.

### Traversing NAT

To additionally traverse through a potential NAT, clients need to query their
external IP address from a STUN server\*. Because of how NATs work, the socket
must again be bound with `SO_REUSEADDR` and its port must be used for the hint.
Clients may `shutdown` the connection to the STUN server, but the socket must
be kept open. No enhanced NAT detection or other advanced STUN features need to
be used: we only care about the external IP address and if it fails we can always
simply fall back to the relay. Generally, a failure to do STUN should be silent
and the query should time out rather quickly.

Recall that NATs are mainly a hack around an outgrown address space and that IPv6
users usually have a globally routed public address, for which simply firewall
hole punching is sufficient. For this reason, you only need to do an IPv4 query
and you always want to prefer IPv6 connections.

\* Since you should always host your own for production use (and also most of
the public ones don't support TCP), we provide <tcp://stun.magic-wormhole.io:3478>
as part of the Magic Wormhole infrastructure (please only use for Magic Wormhole
clients).

### Choosing the best connection

When multiple connection attempts go through, it is up to the leader side to
select the one to use and to cancel the other ones. A naive implementation might
simply use the first one that got established, in the assumption that it will be
the best (it probably had the best round trip time, modulo some jitter). But next
to that, there are other criteria that might be taken in on the rating:

1. Prefer direct connections over relay ones
2. Prefer local connections over those that route through the internet
3. Prefer IPv6 over IPv4
4. (the optional `priority` field on the hints should be ignored for now, as it
  is under-specified to the point of being useless.)
5. (Similar to point 4., an interface letting the user specify this might be
  provided.)

The first two points are easy to implement: after a connection established, wait
some time more to see if a "better" connection shows up. The waiting time should
be roughly derived from the time that was needed for the first one, but with some
upper bound to not annoy users.

The third point is a bit fuzzier: the line quickly becomes blurry when VPNs and
corporate network setups are involved. For IPv4, simply check whether the connection
was made over the external IP address or if it uses a prefix commonly used for
local networks. For IPv6, an easy heuristic is to say that a connection where
both sides' IP addresses have a longer prefix in common is preferable.

### Potential pitfalls and other considerations

- The socket options that must be set are really subtle, for example read
  [this excellent StackOverflow answer](https://stackoverflow.com/a/14388707/6094756)
  for more details. In short, you need to check whether the operating system
  supports reusing ports and which options must be set—on some systems,
  `SO_REUSEADDR` suffices, others provide `SO_REUSEPORT`. If the system doesn't
  support it, fall back on the "easy" way and/or relay servers.
- To prevent port hijacking, make sure that the port may not be reused by other
  processes. Some systems provide special exclusivity options, while others enable
  them by default.
- From the first moment a socket is bound to a port, that socket must be kept
  open. Simply binding and not using it is okay. If you just bind one to get a
  free port and then close it immediately, another application may (accidentally)
  hijack the port until you want to use it again.
- Generally, all implementations should bind only IPv6 sockets (`AF_INET6`). The
  kernel will take care of translating the packets to IPv4 if required. That way,
  no special support is required to handle both stacks. Conversely, only binding
  to `127.0.0.1` means that the application will only support IPv4.

## Future Extensions

* WebRTC: usable by web browsers, hard-but-technically-possible to use by
  normal computers, provides NAT hole-punching for "free"
* (web browsers cannot make direct TCP connections, so interop between
  browsers and CLI clients will either require adding WebSocket to CLI, or a
  relay that is capable of speaking/bridging both)
* I2P: like Tor, but not capable of proxying to normal TCP hints.
* ICE-mediated STUN/STUNT: NAT hole-punching, assisted somewhat by a server
  that can tell you your external IP address and port. Maybe implemented as a
  uTP stream (which is UDP based, and thus easier to get through NAT).
