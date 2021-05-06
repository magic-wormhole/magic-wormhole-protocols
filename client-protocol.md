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
shared key. They derive a "verifier" which is a subkey of the shared key
generated with `wormhole:verifier` as purpose: applications can display
this to users who want additional assurance (by manually comparing the values
from both sides: they ought to be identical). This protects against the threat
where a man in the middle attacker correctly guesses the password.

From this point on, all messages are encrypted using a NaCl `SecretBox` or some
semantic equivalent. The key is derived from the shared key using the following
purpose (as pseudocode-fstring): `f"wormhole:phase:{sha256(side)}{sha256(phase)}"`.
The key derivation function is HKDF-SHA256 using the shared PAKE key as the secret.
A random nonce is used. The nonce and ciphertext are concatenated. Their hex
encoding is the content of the `body` field.

## Version exchange

In the `version` phase, the clients exchange information about themselves in
order to do feature negotiation. Unknown keys and values must be ignored.

The optional `abilities` key allows the two Wormhole instances
to signal their ability to do other things (like "dilate" the wormhole).
It defaults to the empty list. Both sides intersect their abilities with their
peer's ones, in order to determine wich protocol extensions will be used. An
ability might define more keys in the dict to exchange more detailed information
about that feature apart from "I support it". Currently reserved abilities are:
`dilation-v1`, `seeds-v1`.

The version data will also include an `app_versions` key which contains a
dictionary of metadata provided by the application, allowing apps to perform
similar negotiation. Its value is determined by the application-specific protocol,
for example [file transfer](file-transfer-protocol.md).

```json
{
  "abilities": [],
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

Usually the `version` message will be the first one decrypted.
In case an implementation decrypts messages on arrival (before queuing them for proper in-order delivery) it can happen that a non-`version` message arrives first.

If any message cannot be successfully decrypted, the mood is set to "scary",
and the wormhole is closed, the nameplate/mailbox
will be released, and the WebSocket connection will be dropped.

## Application-specific

Now the client connection is fully set up, and the application specific messages
(those with numeric phases) may be exchanged.

## Wormhole Seeds

Once two clients ever connected to each other, they now have a shared secret.
This can be used to establish a new Wormhole connection without involving human
entering codes. If A says "I want to connect to B" and B does the same they'll
find each other and get a secure connection. Some additional data needs to be
exchanged and stored in order to allow for a good user experience.

Support for session resumption is declared using the
`seeds-v1` ability during the `versions` phase. Additionally, a `seeds`
key must be added to the versions message that roughly looks like this:

```json
{
  "abilities": [ "seeds-v1" ],
  "app_versions": {},
  "seeds": {
    "display_names": [<string>],
    "known_seeds": [<string>],
  },
}
```

A client may choose a list of `display_names` in order to be recognizable. Note
that client names may be arbitrary, collide with other sessions or change over
time. Any valid UTF-8 string may be used as name, except for the following
characters: `'`, `"` and `,`.

It is up to the clients to keep track of such a mapping and keep it up to
date, if they want to. It is also up to the clients to name themselves.
We recommend giving at least two values: one with the user's
name and one that also disambiguate multiple devices the user may have (now or in
the future). The list must be sorted in decreasing order of preference.

A seed is derived from the shared session key like this:

```python
# `derive(key, purpose)` is the usual key derivation function
seed = hex(derive(session_key, "wormhole:seed"))
```

The `seed` is the main shared secret between the peers and all other data will
be derived from it:

```python
password = hex(derive(seed, "wormhole:seed:password"))
nameplate = hex(derive(seed, "wormhole:seed:nameplate"))
```

To "grow" a seed (resume a connection), both sides connect to the rendezvous server
using `${nameplate}-${password}` as code. The code is entered automatically without
user interaction. Setting the `seeds-v1` ability in the `versions` phase is not
required anymore.

On normal connections where both sides support the seeds ability, clients may
wish to know whether they already share a seed in common with the peer. For this,
they may specify all their known seeds into the `known_seeds` list, but hashed
with a key derivation function using the raw (i.e. not hex-encoded) session ID
as purpose. By simple set intersection, they will then find out the seeds they
have in common (provided that both sides act faithfully). The process is equivalent
to a simple *private set intersection* protocol, meaning that as long as the
session ID is unique no sensitive contact graph information will be leaked.

### Client implementation notes

- Clients should notify the user about the display names feature, or even provide
  opt-in. For some people, user name or device name are sensitive information.
- It is up to the clients if they want to make pairings explicit or automatic.
- Seeds only work if both sides store the seed. A seed only stored on one side
  will not function. Clients must deal with this scenario.
- An expiration time of 12 months for explicitly stored seeds is recommended.
  Automatically stored seeds (e.g. for session resumption) should be expire after
  1-14 days, depending on the use case.
