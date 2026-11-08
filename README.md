# moonjrpc

JSON-RPC 2.0 for MoonBit: messages, a method table, two-way calls and framing.

<p>
  <a href="https://moonbitstack.github.io/moonjrpc/"><b>Site</b></a> &middot;
  <a href="https://moonbitstack.github.io/moonjrpc/guide.html">Guide</a> &middot;
  <a href="https://moonbitstack.github.io/moonjrpc/play.html">Playground</a> &middot;
  <a href="https://moonbitstack.github.io/moonjrpc/api.html">API</a> &middot;
  <a href="https://mooncakes.io/docs/moonbitstack/moonjrpc">mooncakes</a>
</p>

```bash
moon add moonbitstack/moonjrpc
```

## Answer calls

A method table takes one body and gives back one body, with the errors the specification asks for. Use it where a request and its answer are one exchange, such as an HTTP POST.

```moonbit
let methods = @moonjrpc.Methods::new()
methods.typed("sum", (numbers : Array[Int32]) => {
  numbers.fold(init=0, (a, b) => a + b)
})
let request =
  #|{"jsonrpc":"2.0","id":1,"method":"sum","params":[1,2,3]}
let answer = methods.body(request)
let want = #|{"jsonrpc":"2.0","id":1,"result":6}
assert_eq(answer, Some(want))
```

The answer is `None` when there is nothing to send, which is what a notice gets. A handler that waits for something is written `async fn(params) { ... }`; one that does not is an arrow, as above.

`fail` answers with an error object of your choosing; the rest come from the library.

```moonbit
methods.call("no", _ => @moonjrpc.fail(7, "said no", data=Json::string("why")))
let refused =
  #|{"jsonrpc":"2.0","id":1,"method":"no"}
let said = methods.body(refused)
let error = #|{"jsonrpc":"2.0","id":1,"error":{"code":7,"message":"said no","data":"why"}}
assert_eq(said, Some(error))
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
let (here_reads, there_writes) = @io.pipe()
let (there_reads, here_writes) = @io.pipe()
let here = @peer.Peer::new(@peer.lines(here_reads, here_writes), methods~)
let there = @peer.Peer::new(@peer.lines(there_reads, there_writes), methods~)

@async.with_task_group(async fn(group) {
  group.spawn_bg(no_wait=true, () => here.run())
  group.spawn_bg(no_wait=true, () => there.run())
  let roots = there.call("sum", params=Json::array([Json::number(1.0), Json::number(2.0)]))
  assert_eq(roots.stringify(), "3")
  here_writes.close()
  there_writes.close()
  group.return_immediately(())
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

## Limits

- `@peer.timeout_ms`, 60 seconds, is how long a call waits when no other limit is given.
- `@peer.limit`, 64 MiB, is the longest message `lines` and `content_length` take unless another is passed.
- A batch is answered in one array that leaves the notices out; an empty one is refused with -32600.

## Skill

An [Agent Skill](https://mooncakes.io/skills) for this library is released with each version, at the same version number:

```bash
moonx moonbit-community/skills download moonbitstack/moonjrpc --extract ./moonjrpc-skill
```

The source is `docs/skills/moonjrpc/SKILL.md`, which also ships inside the module.

## Conformance

- Every example in section 7 of the specification, regenerated from the page by `scripts/vectors/gen_spec_vectors.py`.
- `scripts/interop/run.mjs`, in CI: `vscode-jsonrpc` over `content_length` and `json-rpc-2.0` over `lines`, calling both ways.
- The same 17 bodies through `json-rpc-2.0` and `Methods::body`. Three differ, and the check fails if that changes: a method that is not a string, where the specification's own example answers -32600 and theirs answers -32601 or nothing, and a null body, where theirs throws.

## License

Apache-2.0.
