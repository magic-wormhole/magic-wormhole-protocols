# File-Transfer Protocol

The `bin/wormhole` tool uses a Wormhole to establish a connection, then
speaks a file-transfer -specific protocol over that Wormhole to decide how to
transfer the data. This application-layer protocol is described here.

All application-level messages are dictionaries, which are JSON-encoded and
and UTF-8 encoded before being handed to `wormhole.send` (which then encrypts
them before sending through the rendezvous server to the peer).

## Application version

The main key in the `app_version` object is called `abilities`, which is an array of strings. The known values are: `["transfer-v1", "transfer-v2"]`. Unknown values and keys have to be accepted by every client. An ability may specify additional hints to store in the object as well. If the value is empty (`{}`), `{abilities = ["transfer-v1"];}` must be assumed for backwards compatibility. `transfer-v1` should always be supported.

The sender gets to pick a protocol version and capabilities based on the version information of the peer. The receiver distinguishes which protocol is used on the first incoming message. (Therefore, different protocol versions must be distinguishable on the first message.)

**Example value:**

```json
{
  "abilities": ["transfer-v1", "transfer-v2"],
  "transfer-v2": {
    "supported-formats": ["plain", "zst"],
    "transit-abilities": ["direct-tcp-v1", "relay-v1"],
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
        "abilities-v1": [ … ],
        "hints-v1": [ … ]
    }
}
```

The `abilities-v1` and `hints-v1` entries follow the canonical encoding described
in the transit protocol.

The file-transfer application, when actually sending file/directory data,
may close the Wormhole as soon as it has enough information to begin opening
the Transit connection. The final ack of the received data is sent through
the Transit object, as a UTF-8-encoded JSON-encoded dictionary with `ack: ok`
and `sha256: HEXHEX` containing the hash of the received data.

## Transfer v2

Version 2 of the file transfer protocol got invented to add the following features:

- Resumable transfers after a connection interruption
- No need to build a temporary zip file; for both speed and space efficiency reasons. Also zip has a lot of other subtle limitations.
- Allow for multiple transfer from both sides using a single connection

All individual transfers may contain multiple files: This covers both the "single file" use
case as well as the "folder" use case.

This protocol builds upon Dilation (TODO link), and therefore supporting Dilation
is required for implementing Transfer v2.

### Application version

TODO discuss on which encoding style for appversion is better. Independently of
the encoding, the provided information will roughly stay the same.

TODO incorporate the "mode" flag (send vs receive vs interactive)

Setting the `transfer-v2` ability also requires providing a `transfer-v2` dictionary with the following values:
`supported-formats` (see below) <del>and `transit-abilities`, which is the same as `abilities-v1` in the version 1 specification. The transit abilities are exchanged earlier than in version 1 so that the `transit` message may
only contain the hints for abilities both sides support, which avoids wasting effort.</del> transit abilities are
now part of and managed by the Dilation abstraction.

#### Supported formats

Known formats are `plain` and `zst`. The former indicates uncompressed data and
must be supported by all clients; all other formats are optional. TODO
The details about which format to use and with which settings are up to the sender; a low compression level is recommended.

### Overview

Both sides immediately "dilate" the Wormhole connection. They now have a number
of communication channels suitable for bulk data transfer. The Wormhole mailbox
is not explicitly used anymore, but kept open for Dilation to manage the connection.
Subchannel #0 is used for control data, all other channels that are opened
represent an individual transfer operation, independent from the others.

All messages are encoded using [msgpack](https://msgpack.org/) instead of JSON
to allow binary payloads. (All protocol examples in this document will use JSON for readability.)

A transfer is started by the sender side opening a new sub-channel.

- The sender starts by sending an offer. The receiver accepts it and receives the bytes.
- The receiver rejects the offer by sending an error message and closing the sub-channel.
- The sub-channel is closed once all accepted files have been transferred (and checked).

### Control channel messages

Text messages may be sent over the control channel at any time, in both directions.

```
{
  "text-message": "Hello world"
}
```

TODO here is where we want to communicate global error messages and cancellation.

### Sub-channel messages

#### Send offer

A send offer has only one entry, but which may contain a recursive directory
structure. If the top level entry is not a file, receiving clients may display
the offer either as single folder or as a list of files.

File names may be *arbitrary* (but UTF-8 encoded), it is up to the receiver to
sanitize them. Handling of unsupported file names is implementation speficit,
but could for example be realized through escaping or rejection of the offer.

If the sender's file system does not support modification times, `mtime` must be constant (preferably `0`).
`files` must not be empty. If there are multiple files, `directory-name` may be set to mark
this transfer as directory instead of a loose collection of files. If it is not present, `path`
must have a depth of one, i.e. only contain the file name.
The `format` must be one that both sides support.

`type` must be one of `"regular-file"`, `"directory"` and `"symlink"`. Regular
files have an additional `size` field (in bytes) and a transfer `id`. Directories have a
`content` field, which contains a list of direct children. Symlinks have a
`target` path.

```json
{
  "offer-v2": {
    //"transfer-name": "<string, optional>",
    "content": {
      "type": "<string>",
      "name": "<string>",
      "mtime": "<integer>",
      "format": "<string>",
      …
    },
  }
}
```

If a transfer fails mid way, we don't want to re-transmit unnecessary data when
a second attempt is made. The idea is that when a transfer fails, the sender
stores the IDs along with the partially transferred data. On the second attempt,
the sender should reuse the trnasfer IDs so that the sender can tell it already
has part of the data, therefore only requesting what it does not yet have.

Transfer IDs are opaque strings to the receiver, how they are generated is an
implementation detail of the sender. However the following points should be taken
into consideration:

- Sending the same files or folder twice results in the same identifiers
- When making transfer IDs content adressed, they should not leak any information
  about the data to anybody except the receiver.
  - All hashes in use should be salted, the salt should be kept private by the
    sender and rotate regularly.
- The transfer ID should have sufficiently high entropy to avoid collisions.
  - At least 256 bits are recommended
- Due to the purpose of allowing retransfers, no data
- Since the goal is to facilitate retransfers after a failure, no further
  information needs to be stored on success.
- Retransfers after failure are expected to happen more or less immediately. The
  data needs not be kept around longer than a few hours, at most days.
- False negatives lead to additional retransfer of data, while false positives
  result in a transfer failure due to hash mismatch. Therefore, try to keep the
  ID generation as conservative as possible.
  - Simply using fresh random IDs for everything is an acceptable strategy.

#### Receive ack

`files` contains a mapping from transfer ID to offset (bytes).
An offer may be rejected using an `error` message.

```json
{
  "answer": {
    "files": {
      "<string>": "<integer>"
    },
  }
}
```

#### Payload transfer

After receiving the ack, the sender transfers the payload according to the `format`. For each file, the data stream
must start at the offset requested by the receiver. A `payload` message contains only the (compressed) bytes as value.

```json
{
  "payload": {
    "id": "<string>",
    "payload": "<bytes>",
  }
}
```

The payload must not exceed 64kiB per message. The sender keeps track of the received bytes (after
decompression according to the format), and errors out if the sender exceeds the announced amount by more than 5%. Note that due to
file system smear, sending a different amount of bytes than announced is rather common (hence
the 5%). Errors will be caught using checksums later on.

#### Checksums

At the end of the transfer, *both* sides send their checksums. That way, they do not need to communicate any further
to exchange their opinion: they can both calculate themselves whether things went wrong or not and only need to notify
the user. Once the checksums are exchanged, the transfer is complete and the connection is closed.

There is a per file integrity check. `wire-sha256` is the (binary) sha256sum of all transferred payload bytes (i.e. before decompression). `sha256` is the sha256sum of the *entire* file, including bytes before the resumption offset.

```json
{
  "transfer-ack-v2": {
    "wire-sha256": "<bytes>",
    "files": [
      {
        "id": "<string>",
        "size": "<integer>",
        "sha256": "<bytes>",
      }
    ],
  }
}
```

### A note about file system handling

File systems are hard. To achieve consistent and sane behavior across implementations and
systems, applications should pay attention to the following details:

- Symlinks are preserved by default when sending directories
- Hardlinks and reflinks may be resolved/duplicated at any point
- Permissions are not preserved by default (use rsync for that instead).
- The sender's mtime should be preserved, unless it is zero
- Extended file attributes (xattrs) are not preserved
- Files may have been modified between transfers. Checking the modification time
  is necessary, but not sufficient.
- To avoid file system hacking: The receiver must check for malicious file paths
  and invalid/unsupported character sequences. Symlinks *must not* be followed.

### When to resume

On a failed attempt, the receiver may decide to keep the partially transferred data in the
anticipation of the transfer being tried again soon. The receiver can use the `answer` message
to exert some control over which bytes the sender will send again. It is also free to decide
when a transfer should be resumed instead of being started anew. However, not every failure
may be recovered from, forcing a full retransfer:

- 

### Random notes

## Future Extensions

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
