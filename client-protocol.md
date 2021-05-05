# Client-to-Client Protocol

Wormhole clients do not talk directly to each other (at least at first): they
only connect directly to the Rendezvous Server. They ask this server to
convey messages to the other client (via the `add` command and the `message`
response).
The goal of this protocol is to establish an authenticated and encrypted
communication channel over which data messages can be exchanged. It is not
suited for larger data transfers. Instead, the channel should be used to coordinate
the negotiation of a better suited communication channel. This is what the
[transit protocol](transit.md) is for (the actual negotiation is done by the
application-specific protocol, for example [file transfer](file-transfer-protocol.md).

This document explains the format of these client-to-client messages. Each
such message contains a "phase" string, and a hex-encoded binary "body":

```json
{
  "phase": <string or number>,
  "body": "<hex bytes>",
}
```

From now on, all mentioned JSON messages will be from within the `body` field.

Any phase which is purely numeric (`^\d+$`) is reserved for encrypted
application data. The Rendezvous server may deliver these messages multiple
times, or out-of-order, but the wormhole client will deliver the
corresponding decrypted data to the application in strict numeric order. All
other (non-numeric) phases are reserved for the Wormhole client itself.
Clients will ignore any phase they do not recognize.
The order of the wormhole phases are: `pake`, `version`, numerical.

## Pake

Immediately upon opening the mailbox, clients send the `pake` phase, which
contains the binary SPAKE2 message (the one computed as `X+M*pw` or
`Y+N*pw`):

```json
{
  "pake_v1": <hex-encoded pake message>,
}
```

Upon receiving their peer's `pake` phase, clients compute and remember the
shared key. They derive a "verifier", which is a subkey of the shared key
generated with `wormhole:verifier` as purpose): applications can display
this to users who want additional assurance (by manually comparing the values
from both sides: they ought to be identical). This protects against the threat
where a man in the middle attacker correctly guesses the password.

From this point on, all messages are encrypted using a NaCl `SecretBox` or some
semantic equivalent. The key is derived from the shared key using the following
purpose (as pseudocode-fstring): `f"wormhole:phase:{sha256(side)}{sha256(phase)}"`.
The key derivation function is HKDF-SHA256, using the shared PAKE key as the secret.
A random nonce is used, and nonce and ciphertext are concatenated. Their hex
encoding is the content of the `body` field.

## Version exchange

In the `version` phase, the clients exchange information about themselves in
order to do feature negotiation. 

This allows the two Wormhole instances
to signal their ability to do other things (like "dilate" the wormhole). The
version data will also include an `app_versions` key which contains a
dictionary of metadata provided by the application, allowing apps to perform
similar negotiation. At the moment, no keys other than `app_versions` are
specified.

```json
{
  "app_versions": {},
}
```

As this is the first encrypted message, it also serves as a test to check if
the encryption worked or failed (i.e. if the user typed the password correctly
and no attackers are involved).
The client knows the supposed shared key, but has not yet seen
evidence that the peer knows it too. When the first peer message arrives, it will
be decrypted: we use authenticated encryption (`nacl.SecretBox`), so if this
decryption succeeds, then we're confident that *somebody* used the same
wormhole code as us. This event pushes the client mood from "lonely" to
"happy".

If any message cannot be successfully decrypted, the mood is set to "scary",
and the wormhole is closed, the nameplate/mailbox
will be released, and the WebSocket connection will be dropped.

## Application-specific

Now the client connection is fully set up, and the application specific messages
(those with numeric phases) may be exchanged.
