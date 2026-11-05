///|
/// An agent asks its editor a question in the middle of answering a prompt.
async fn main {
  let (agent_reads, editor_writes) = @io.pipe()
  let (editor_reads, agent_writes) = @io.pipe()

  let editor_methods = @moonjrpc.Methods::new()
  editor_methods.call("read_file", _ => Json::string("hello from the editor"))
  editor_methods.notice("update", params => {
    println("update: \{params.unwrap().stringify()}")
  })
  let editor = @peer.Peer::new(
    @peer.lines(editor_reads, editor_writes),
    methods=editor_methods,
  )

  let agent_methods = @moonjrpc.Methods::new()
  let agent : Ref[@peer.Peer?] = Ref(None)
  agent_methods.call("prompt", async fn(_) {
    let peer = agent.val.unwrap()
    peer.notify("update", params=Json::array([Json::string("reading")]))
    guard peer.call("read_file") is String(text) else { return Json::null() }
    Json::string("the file says: \{text}")
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
    println(editor.call("prompt").stringify())
    editor_writes.close()
    agent_writes.close()
    group.return_immediately(())
  })
}
