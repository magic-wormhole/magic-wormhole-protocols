# Security and privacy considerations

## Code interception attacks

By default, Wormhole codes contain 16 bits of entropy. Failed attempts of
guessing a code will cause both clients to error out. Thus, an attacker
has a one-in-65536 chance of successfully guessing the code, while being
detected in all other cases.

If the attacker successfully guesses the code, they can attempt a
machine-in-the-middle (MitM) attack. For this, they quickly reconnect with
the same code in order to connect with the second peer. With that, they get a
secure channel to each side while being able to read and modify the connection's
content.

Both cases can be mitigated by enabling the verifier feature, in which case
even successful attacks can be detected.

In general, this is a very similar process to ordinary key exchanges like
Diffie-Hellman (or variations), except that MitM attackers additionally have to
guess the code correctly. (Hence the name, "*password authenticated* key
exchange", PAKE.)

### Password entropy

Compared to password strengths we are used to nowadays, 16 bits may seem scarily
small, even knowing that an attacker only has one try to guess the password. But
to put it into perspective:
An attacker gains *on average* only one file for every 2^16 = 65536 attempts.
Since there is no possibility of targetting any individual connection (because
who would re-try sending their file hundreds of times if it keeps failing?),
any gained data would be fairly useless in most of the cases.
Because failed guessing attempts result in failed key exchanges, brute force
attacks are inherently very disruptive of the service, and thus easy to detect.

In short, guessing codes is unlikely to be an attractive target for any attacker.
Of course, there is always the possibility to configure a stronger code in the
clients if desired.

## Denial of Service (DoS) attacks on the Mailbox server

Wormhole codes can be so short because they implicitly contain a common
rendezvous server URL (any two applications that use Magic Wormhole
should be configured to use the same server). As a result, successful
operation depends upon both clients being able to contact that server,
making it a single point of failure (SPOF).

While it is of course possible to incapacitate the rendezvous server using
traditional means of DoS, so much work is not necessary: An attacker may
simply connect to every nameplate with a random code, causing the key exchange
to fail. There is a "list" command in the protocol which makes it easy to
enumerate all nameplates to disrupt them, but even without it the name space is
sufficiently small (by design, as we want short codes) to brute force.

There are several ideas to defend against this, however the only one already
specified in the protocol is the "permission" feature: The rendezvous server
may use it to restrict new connections with some kind of challenge (or for
private servers, authentication). The motivation behind this is to enable
a proof-of-work challenge (using HashCash) when under attack to slow it down.
See the server protocol specification for details.

## Metadata leaks

As usual in cryptography, communication metadata cannot easily be protected. Any
involved server will know the timestamp and size of each message it relays. For
file transfer, this may be an issue in cases where the file size may be
characteristic for its content. (Imagine people using Magic Wormhole to send
some specific movie.)

Thanks to the separation between rendezvous server and relay server, forcing the
client to establish a direct connection will bypass the relay server and thus not
leak such metadata for file transfers.

## IP address leakage and anonymity

As usual on the internet, any involved server will know connection information
including the IP address of any two peers.

Additionally, in order to establish a direct connection, public and local IP
addresses are sent to the peer. This may leak information about the local
network topology, including potentially used VPNs. If you do not trust your
peer with such information, enforcing a relay server connection is advised.
However, keep in mind that it is easy to host a relay server, so it might still
leak your public IP address.

If you do not want to expose your IP address, use [Tor](https://torproject.org/)
to use Magic Wormhole anonymously. In the case
where both sides connect via Tor, the [Transit protocol](./transit.md) has support
for bypassing the relay server by spinning up an ad-hoc onion service and
establishing a direct connection on the Tor network instead. You can think of
this as the Tor network being the relay, instead of the usual dedicated relay
server.
