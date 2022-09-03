# URI Scheme
## Scope
This URI scheme describes the wormhole file transfer application. For other use cases of the wormhole spec and URI scheme has not been defined yet.

The application ID for this protocol is always assumed to be `lothar.com/wormhole/text-or-file-xfer`

## Description

The `wormhole-transfer` URI Scheme is used to encode a wormhole code for file transfer as a URI. This can then be used to generate QR codes, or be opened by the platform URI handler to open a supporting client.

The general format looks like this, and assumes default values for all query fields:
`wormhole-transfer:{code}`

`{code}` is the [URL / percent encoded](https://en.wikipedia.org/wiki/Percent-encoding) wormhole code. The [C0 control percent encode set](https://url.spec.whatwg.org/#c0-control-percent-encode-set) is used to be [compatible with URL parsers](https://url.spec.whatwg.org/#concept-opaque-host-parser). While common codes may not require any encoding, it must be made sure that percent-encoding and decoding is applied to support all possibilities.

It can be extended by appending a [query string](https://en.wikipedia.org/wiki/Query_string). The query string is percent-encoded with the [query percent encode set](https://url.spec.whatwg.org/#query-percent-encode-set).

## Query fields
Applications MUST parse all query fields specified below and fail if they contain unknown fields or unsupported parameter values. Query values are percent-encoded.

* `version`: The version of the URI scheme.  At the moment, only version 0 is specified. Clients must check this for compatibility.
Default: `0`

* `rendezvous`: The rendezvous server and protocol to use, including its port. The versioned endpoint is supposed to be added by the client implementation, eg. `/v1`
Default: `ws://relay.magic-wormhole.io:4000`

* `role`: The type of operation requested. Valid values are:
  * `follower`: The URI *parsing* client is supposed to be prepared to receive a file over the connection once established.
  * `leader`: The URI *parsing* client is supposed to send a file. This functionality can be used if it is easier (from the user's point of view) to read the URI in the opposite direction (for example because QR codes are used and only one device is equipped with a camera).
Default: `follower`

## Examples
To encode the code `4-hurricane-equipment` to send a file the URI would look like this:

`wormhole-transfer:4-hurricane-equipment`

By expanding the default values this would be equivalent to:

`wormhole-transfer:4-hurricane-equipment?version=0&rendezvous=ws%3A%2F%2Frelay.magic-wormhole.io%3A4000&role=follower`

To request the URI parsing side to lead the connection instead (and probably send a file), the URI would look like this:

`wormhole-transfer:4-hurricane-equipment?role=leader`
