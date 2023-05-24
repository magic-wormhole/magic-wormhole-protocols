# The Magic Wormhole protocols

This site contains all the documentation and specification of protocols related
to Magic Wormhole, which are not specific to a single client or implementation.
It assumes the reader is already familiar with the general Magic Wormhole concept.

The most important component is the **Mailbox server**. There are two aspects
to it: The [**server protocol**](./server-protocol.md) describes how two peers
find each other and how they then can exchange low-bandwidth messages.
Once the two peers are connected over the server, the
[**client protocol**](./client-protocol.md) describes how they establish a
secure way of exchanging messages.

Using the established low-bandwidth secure channel, both sides then negotiate a
secure high-bandwidth channel, called [**transit**](./transit.md). The transit
protocol describes how both sides establish a direct connection, how a special
relay server may be used as fallback, and the cryptography used to make that
connection secure.

Applications make use of the above protocols to provide their functionality.
Currently, only one application level protocol is documented here:
[**file transfer**](./file-transfer-protocol.md). Additionally, a custom
[**uri scheme**](./uri-scheme.md) has been standardised for file transfer. This
makes it possible for applications to replace the traditional code exchange
with sharing a link or QR code.

Security threat models and privacy considerations are discussed in
[**security**](./security.md)
