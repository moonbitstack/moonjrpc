---
name: moonjrpc
description: Speak JSON-RPC 2.0 from MoonBit with moonbitstack/moonjrpc. Answer requests with a method table, call both ways over an open stream, and frame messages as lines or Content-Length. Use when writing or debugging a JSON-RPC server, client or peer in MoonBit, or a protocol built on it such as MCP, ACP, A2A or LSP.
---

# moonjrpc

Add the module, then import what you need in `moon.pkg`:

```bash
moon add moonbitstack/moonjrpc
moon add moonbitlang/async
```

```moonbit
import {
  "moonbitstack/moonjrpc",
  "moonbitstack/moonjrpc/peer", // only for two-way calls
  "moonbitlang/async",
}
```

## Pick the shape

- One request, one answer, such as an HTTP POST: `Methods::body`.
- A stream that stays open, where either side may call the other: `@peer.Peer`.

## Answer requests

```moonbit
let methods = @moonjrpc.Methods::new()
methods.typed("sum", (numbers : Array[Int32]) => numbers.fold(init=0, (a, b) => a + b))
methods.call("no", _ => @moonjrpc.fail(7, "said no"))
methods.notice("log", _ => ())

let answer : String? = methods.body(text) // None when there is nothing to send
```

`body` handles the specification's errors: -32700 for text that is not JSON, -32600 for a value that is not a message, -32601 for an unknown method, -32602 when `typed` cannot decode the parameters. Any other error from a handler goes out as -32603 with no detail; pass `Methods::new(on_error=(name, error) => ...)` to hear it.

Pass `batch=false` for a protocol that forbids arrays, as ACP does.

## Call both ways

```moonbit
let peer = @peer.Peer::new(@peer.lines(@stdio.stdin, @stdio.stdout), methods~)
@async.with_task_group(async fn(group) {
  group.spawn_bg(no_wait=true, () => peer.run())
  let roots = peer.call("roots/list")
  peer.notify("log", params=Json::array([roots]))
})
```

`Peer::call` raises one of these:

| Error | Meaning |
|:--|:--|
| `@moonjrpc.Failed(failure)` | The other side answered with an error object |
| `@moonjrpc.TimedOut(name~, limit~)` | No answer in time. The default is 60 seconds; `timeout_ms=None` waits as long as it takes |
| `@moonjrpc.Closed(name~)` | The other side went away |

## Frame messages

- `@peer.lines(reader, writer)`: one message to a line, the stdio transport of MCP and ACP.
- `@peer.content_length(reader, writer)`: the base protocol of LSP.
- Anything else: implement `@peer.Frames`, whose `read` returns the next message's text and `write` sends one.

Both built-in framings raise `TooLong` past `limit`, 64 MiB unless you pass another.

HTTP is not here, because each protocol has its own shape. Build it on `Methods` and `Peer`.

## Rules that catch people out

- Messages are taken in arrival order. A notice finishes before the next message is looked at, so a notice handler that waits on `Peer::call` waits for a reply nobody can read until it returns. Start a task for that call.
- A handler that awaits nothing is an arrow, `params => ...`. Writing `async fn` there fails `moon check --deny-warn` with `unused_async`.
- The message field is named `name`, because `method` is reserved in MoonBit: `Call(id~, name~, params~)`.
- `catch` arms name the package: `@moonjrpc.Failed(failure) => ...`. A bare `Failed(...)` does not match the abstract `Error`.
- In a black-box test of a package that exports `fail`, core's `fail` is hidden. Use `abort`.
- Giving up on a call does not tell the other side. MCP, ACP and LSP each have their own notice for that; send it yourself.
- `params` must be an array or an object when present. A bare number goes out and comes back as -32600.
