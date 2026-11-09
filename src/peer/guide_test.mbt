// What docs/guide.html shows: scripts/check_guide.py checks every line of the page's code and output
// against this file and src/guide_test.mbt.

///|
async test "guide: call both ways" {
  let (agent_reads, editor_writes) = @io.pipe()
  let (editor_reads, agent_writes) = @io.pipe()

  let editor_methods = @moonjrpc.Methods::new()
  editor_methods.call("read_file", _ => Json::string("hello"))
  let editor = @peer.Peer::new(
    @peer.lines(editor_reads, editor_writes),
    methods=editor_methods,
  )

  let agent_methods = @moonjrpc.Methods::new()
  let agent : Ref[@peer.Peer?] = Ref(None)
  agent_methods.call("prompt", async fn(_) {
    let text = agent.val.unwrap().call("read_file")
    Json::array([Json::string("the file says"), text])
  })
  agent.val = Some(
    @peer.Peer::new(
      @peer.lines(agent_reads, agent_writes),
      methods=agent_methods,
    ),
  )

  @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, () => editor.run())
    group.spawn_bg(no_wait=true, () => agent.val.unwrap().run())
    let answer = editor.call("prompt")
    inspect(
      answer.stringify(),
      content=(
        #|["the file says","hello"]
      ),
    )
    group.return_immediately(())
  })
  editor_writes.close()
  agent_writes.close()
}

///|
async test "guide: errors from a call" {
  let (agent_reads, editor_writes) = @io.pipe()
  let (editor_reads, agent_writes) = @io.pipe()
  let agent_methods = @moonjrpc.Methods::new()
  agent_methods.call("slow", async fn(_) {
    @async.sleep(50)
    Json::null()
  })
  let editor = @peer.Peer::new(@peer.lines(editor_reads, editor_writes))
  let agent = @peer.Peer::new(
    @peer.lines(agent_reads, agent_writes),
    methods=agent_methods,
  )
  @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, () => editor.run())
    group.spawn_bg(no_wait=true, () => agent.run())
    let said = try editor.call("slow", timeout_ms=Some(10)) catch {
      @moonjrpc.Failed(failure) => "refused: \{failure.message}"
      @moonjrpc.TimedOut(name~, limit~) => "\{name} took over \{limit} ms"
      @moonjrpc.Closed(name~) => "\{name}: the other side went away"
      _ => "something else"
    } noraise {
      _ => "answered"
    }
    inspect(said, content="slow took over 10 ms")
    group.return_immediately(())
  })
  editor_writes.close()
  agent_writes.close()
}

///|
struct Memory {
  incoming : @aqueue.Queue[String]
  outgoing : @aqueue.Queue[String]
}

///|
impl @peer.Frames for Memory with fn read(self) {
  Some(self.incoming.get())
}

///|
impl @peer.Frames for Memory with fn write(self, text) {
  self.outgoing.put(text)
}

///|
async test "guide: a transport of your own" {
  let there : @aqueue.Queue[String] = @aqueue.Queue::Queue(
    kind=@aqueue.Kind::Unbounded,
  )
  let back : @aqueue.Queue[String] = @aqueue.Queue::Queue(
    kind=@aqueue.Kind::Unbounded,
  )
  let methods = @moonjrpc.Methods::new()
  methods.call("ping", _ => Json::string("pong"))
  let client = @peer.Peer::new(({ incoming: back, outgoing: there, } : Memory))
  let server = @peer.Peer::new(
    ({ incoming: there, outgoing: back, } : Memory),
    methods~,
  )
  @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, () => client.run())
    group.spawn_bg(no_wait=true, () => server.run())
    inspect(
      client.call("ping").stringify(),
      content=(
        #|"pong"
      ),
    )
    group.return_immediately(())
  })
}

///|
async test "guide: what framing writes" {
  let (reads, writes) = @io.pipe()
  let (nothing, _) = @io.pipe()
  let frames = @peer.content_length(nothing, writes)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      frames.write("{\"猫\":1}")
      writes.close()
    })
    inspect(
      reads.read_all().text(),
      content="Content-Length: 9\r\n\r\n{\"猫\":1}",
    )
  })
}
