# moonjrpc

JSON-RPC 2.0 for MoonBit: messages, a method table, two-way calls and framing.

```bash
moon add moonbitstack/moonjrpc
```

## Answer calls

A method table takes one body and gives back one body, with the errors the specification asks for. Use it where a request and its answer are one exchange, such as an HTTP POST.

```moonbit
let methods = @moonjrpc.Methods::new()
methods.typed("sum", (numbers : Array[Int]) => numbers.fold(init=0, (a, b) => a + b))
methods.call("no", _ => @moonjrpc.fail(7, "said no"))
methods.notice("log", params => logged.push(params))

let answer = methods.body(request_body) // None when there is nothing to send
```

| Input | Answer |
|:--|:--|
| Not JSON | -32700 |
| Not a message | -32600, with its identifier if one can be read |
| A method nobody registered | -32601 |
| Parameters `typed` cannot decode | -32602, with the reason in `data` |
| `fail(code, message, data=...)` | That error object |
| Any other error from a handler | -32603 with no detail; `Methods::new(on_error=...)` hears it |
| An array | A batch; `batch=false` refuses it with -32600 |

## Call both ways

`@peer` is for transports that stay open, where either side may call the other.

```moonbit
let peer = @peer.Peer::new(@peer.lines(@stdio.stdin, @stdio.stdout), methods~)
@async.with_task_group(async fn(group) {
  group.spawn_bg(no_wait=true, () => peer.run())
  let root = peer.call("roots/list")
  peer.notify("log", params=root)
})
```

| Error from `Peer::call` | Meaning |
|:--|:--|
| `Failed(failure)` | The other side answered with an error object |
| `TimedOut(name~, limit~)` | No answer in time. The default is 60 seconds; `timeout_ms=None` waits as long as it takes |
| `Closed(name~)` | The other side went away |

Messages are taken in the order they arrive. A notice finishes before the next message is looked at; a call starts in its turn and runs on in its own task; a reply wakes its caller in its turn. So updates sent before an answer are handled before the caller sees it, and a change sent before a call is in place when the call starts. A notice handler that waits on `Peer::call` waits for a reply that cannot be looked at until it returns, so it should start a task for that.

Telling the other side a call was given up on is left to the protocol: MCP, ACP and LSP each have their own notice for it.

## Bring your own transport

`lines` is one message to a line, the stdio transport of MCP and ACP. `content_length` is the base protocol of LSP. Anything else implements `Frames`:

```moonbit
pub(open) trait Frames {
  async fn read(Self) -> String?
  async fn write(Self, String) -> Unit
}
```

The HTTP shape is not here, because each protocol has its own: MCP answers on the POST's SSE stream, ACP on a GET stream, A2A in the POST's body. They build it on `Methods` and `Peer`.

## Conformance

- Every example in section 7 of the specification, regenerated from the page by `scripts/vectors/gen_spec_vectors.py`.
- `scripts/interop/run.mjs`, in CI: `vscode-jsonrpc` over `content_length` and `json-rpc-2.0` over `lines`, calling both ways.
- The same 17 bodies through `json-rpc-2.0` and `Methods::body`. Three differ, and the check fails if that changes: a method that is not a string, where the specification's own example answers -32600 and theirs answers -32601 or nothing, and a null body, where theirs throws.

## License

Apache-2.0.
