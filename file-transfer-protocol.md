# File-Transfer Protocol

The `bin/wormhole` tool uses a Wormhole to establish a connection, then
speaks a file-transfer -specific protocol over that Wormhole to decide how to
transfer the data. This application-layer protocol is described here.

All application-level messages are dictionaries, which are JSON-encoded and
and UTF-8 encoded before being handed to `wormhole.send` (which then encrypts
them before sending through the rendezvous server to the peer).

## Application version

The main key in the `app_version` object is called `abilities`, which is an array of strings. The known values are: `["transfer-v1", "transfer-v2"]`. Unknown values and keys have to be accepted by every client. An ability may specify additional hints to store in the object as well. If the value is empty (`{}`), `{abilities = ["transfer-v1"];}` must be assumed for backwards compatibility. `transfer-v1` SHOULD always be supported.

The sender gets to pick a protocol version and capabilities based on the version information of the peer. The receiver distinguishes which protocol is used on the first incoming message.

**Example value:**

```json
{
    abilities: ["transfer-v1", "transfer-v2"],
    transfer-v2-hints: {
        supported-formats: ["tar.zst"]
    }
}
```

## Transfer v1

The initial version, supports sending files, directories and text messages. Directories are sent by zipping them on the sender side and un-zipping them on the receiver side.

### Sender

`wormhole send` has two main modes: file/directory (which requires a
non-wormhole Transit connection), or text (which does not).

If the sender is doing files or directories, its first message contains just
a `transit` key, whose value is a dictionary with `abilities-v1` and
`hints-v1` keys. These are given to the Transit object, described below.

Then it sends a message with an `offer` key. The offer contains exactly one of:

* `message`: the text message, for text-mode
* `file`: for file-mode, a dict with:
    * `filename`
    * `filesize`
* `directory`: for directory-mode, a dict with:
    * `mode`: the compression mode, currently always `zipfile/deflated`
    * `dirname`
    * `zipsize`: integer, size of the transmitted data in bytes
    * `numbytes`: integer, estimated total size of the uncompressed directory
    * `numfiles`: integer, number of files+directories being sent

The sender runs a loop where it waits for similar dictionary-shaped messages
from the recipient, and processes them. It reacts to the following keys:

* `error`: use the value to throw a TransferError and terminates
* `transit`: use the value to build the Transit instance
* `answer`:
    * if `message_ack: "ok"` is in the value (we're in text-mode), then exit with success
    * if `file_ack: "ok"` in the value (and we're in file/directory mode), then
      wait for Transit to connect, then send the file through Transit, then wait
      for an ack (via Transit), then exit

~~The sender can handle all of these keys in the same message, or spaced out over multiple ones.~~ **This is strongly discouraged!** *Probably no implementation supports receiving multiple messages in one, and no one sends multiple at once.* ~~It will ignore any keys it doesn't recognize, and will completely ignore messages that don't contain any recognized key.~~ *As all capabilities are explained during version negotiation, every sender knows what keys are supported by the other side. No unsupported values should be transferred.* The only constraint is that the message containing `message_ack` or `file_ack` is the last one: it will stop looking for wormhole messages at that point (the
wormhole connection may be closed after the ack).

### Recipient

`wormhole receive` is used for both file/directory-mode and text-mode: it
learns which is being used from the `offer` message.

The recipient enters a loop where it processes the following keys from each
received message:

* `error`: if present in any message, the recipient raises TransferError
(with the value) and exits immediately (before processing any other keys)
* `transit`: the value is used to build the Transit instance
* `offer`: parse the offer:
    * `message`: accept the message and terminate
    * `file`: connect a Transit instance, wait for it to deliver the indicated
    number of bytes, then write them to the target filename
    * `directory`: as with `file`, but unzip the bytes into the target directory

### Transit

See [transit](./transit.md) for some general documentation. The transit protocol does not specify how the data for finding each other is transferred. This is the job of the application level protocol (thus, here):

The file-transfer application uses `transit` messages to convey these
abilities and hints from one Transit object to the other. After updating the
Transit objects, it then asks the Transit object to connect, whereupon
Transit will try to connect to all the hints that it can, and will use the
first one that succeeds.

The `transit` message mentioned above is encoded following this schema:

```json
{
    "transit": {
        "abilities-v1": [
            {
                "kind": "<string, one of {direct-tcp-v1, relay-v1, tor-tcp-v1}>"
            }
        ],
        "hints-v1": [
            {
                "type": "'direct-tcp-v1' or 'tor-tcp-v1'",
                "hostname": "<string>",
                "port": "<tcp port>",
                "priority": "<number, usually [0..1], optional>"
            },
            {
                "type": "relay-v1",
                "hints": [
                    {
                        "hostname": "<string>",
                        "port": "<tcp port>",
                        "priority": "<number, usually [0..1], optional>"
                    }
                ]
            }
        ]
    }
}
```

The file-transfer application, when actually sending file/directory data,
may close the Wormhole as soon as it has enough information to begin opening
the Transit connection. The final ack of the received data is sent through
the Transit object, as a UTF-8-encoded JSON-encoded dictionary with `ack: ok`
and `sha256: HEXHEX` containing the hash of the received data.

## Transfer v2 (proposal)

A v2 of the file transfer protocol got invented to add the following features:

- Resumable transfers after a connection interruption
- No need to build a temporary zip file; for both speed and space efficiency reasons. Also zip has a lot of other subtle limitations.

The feature of sending text messages (without a transit connection), on the other hand, got removed.

### Basic protocol

The sender sends an offer, which contains a list of all the files, their size, modification time, and a transfer identifier that can be used to resume connections. The attempt to send the same files twice should use with the same identifier. How it is generated is an implementation detail, the suggested method is to either store it locally or to use the hash of the absolute path of the folder being sent.

The receiver responses either with either a `"transfer rejected"` error of with an acknowledgement. The acknowledgement may contain a list of byte offsets, one for each file, which will tell the sender from where to resume the transfer.

Both do the negotiation to open a transit relay. The process to doing so is slightly different from the one in the first version. The set of supported abilities is already delivered during the file offer/ack. Thus, the `transit` message only contains the hints for methods both sides support. Both side try to connect to every hint of the other side, the sender will then confirm the first one that succeeded.

The sender then sends the requested bytes over the relay using one of the supported formats. Afterwards, it sends a message with checksums. The receiver then closes the connections, optionally with sending an error message on a checksum mismatch.

#### Supported formats

At the moment, the only supported format is `tar.zst`. The files are sent bundled as a tar ball, compressed with zstd. The details are up to the sender; a low compression level is recommended. Only the files requested by the sender must be sent, and only the bytes starting from the requested offset must be contained.

### The structs in detail

#### Send offer

File paths must be normalized and relative to the root of the sent folder. If the sender's file system does not support modification times, `mtime` must be constant (preferably `0`). Sending a file is the same as sending a directory with a single file. `directory-name` is the name of the directory being sent. It must be present unless `files` contains exactly one item. `files` must not be empty.

```json
{
    "offer-v2": {
        "directory-name": "<string, optional>",
        "files": [
            {
                "path": "<string>",
                "size": "<integer>",
                "mtime": "<integer>"
            }
        ],
        "transit-abilities": "<list, subset of ['direct-tcp-v1', 'relay-v1', 'tor-tcp-v1']>"
    };
}
```

#### Receive ack

`files` contains a mapping from file (index) to offset (bytes). If omitted, all files must be sent.

```json
{
    "answer-v2": {
        "files": {
            "<integer>": "<integer>"
        },
        "transit-abilities": "<list of ability strings>"
    }
}
```

#### Transit hints

Note that the hints for abilities added in the future might follow a different schema. The discriminant is `type`.

```json
{
    "transit-v2": [
        {
            "type": "<ability string>",
            "hostname": "<string>",
            "port": "<tcp port>",
            "priority": "<number, usually [0..1], optional, default 0.5>"
        },
    ]
}
```

#### Checksums

`tar-file-sha256` is the lowerhex-encoded sha256sum of all transferred bytes of the tar file.

TODO maybe some per file integrity check?

```json
{
    "transfer-ack-v2": {
        "tar-file-sha256": "<string>"
    }
}
```

## Future Extensions

Transit will be extended to provide other connection techniques:

* WebSocket: usable by web browsers, not too hard to use by normal computers,
  requires direct (or relayed) TCP connection
* WebRTC: usable by web browsers, hard-but-technically-possible to use by
  normal computers, provides NAT hole-punching for "free"
* (web browsers cannot make direct TCP connections, so interop between
  browsers and CLI clients will either require adding WebSocket to CLI, or a
  relay that is capable of speaking/bridging both)
* I2P: like Tor, but not capable of proxying to normal TCP hints.
* ICE-mediated STUN/STUNT: NAT hole-punching, assisted somewhat by a server
  that can tell you your external IP address and port. Maybe implemented as a
  uTP stream (which is UDP based, and thus easier to get through NAT).

The file-transfer protocol will be extended too:

* "command mode": establish the connection, *then* figure out what we want to
  use it for, allowing multiple files to be exchanged, in either direction.
  This is to support a GUI that lets you open the wormhole, then drop files
  into it on either end.
* some Transit messages being sent early, so ports and Onion services can be
  spun up earlier, to reduce overall waiting time
* transit messages being sent in multiple phases: maybe the transit
  connection can progress while waiting for the user to confirm the transfer

The hope is that by sending everything in dictionaries and multiple messages,
there will be enough wiggle room to make these extensions in a
backwards-compatible way. For example, to add "command mode" while allowing
the fancy new (as yet unwritten) GUI client to interoperate with
old-fashioned one-file-only CLI clients, we need the GUI tool to send an "I'm
capable of command mode" in the VERSION message, and look for it in the
received VERSION. If it isn't present, it will either expect to see an offer
(if the other side is sending), or nothing (if it is waiting to receive), and
can explain the situation to the user accordingly. It might show a locked set
of bars over the wormhole graphic to mean "cannot send", or a "waiting to
send them a file" overlay for send-only.
