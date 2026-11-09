// The bridge the site imports in the browser. Everything the pages show comes through here, from the
// library compiled to JavaScript: strings in, strings out, promises for the async parts.

///|
priv suberror Boom {
  Boom
}

///|
/// The table the playground answers with.
fn playground() -> @moonjrpc.Methods {
  let methods = @moonjrpc.Methods::new()
  methods.typed("sum", (numbers : Array[Int32]) => {
    numbers.fold(init=0, (a, b) => a + b)
  })
  methods.call("subtract", params => {
    match params {
      Some(Array([Number(a, ..), Number(b, ..)])) => Json::number(a - b)
      Some(
        Object({ "minuend": Number(a, ..), "subtrahend": Number(b, ..), .. })
      ) => Json::number(a - b)
      _ => @moonjrpc.fail(@moonjrpc.invalid_params, "Invalid params")
    }
  })
  methods.call("echo", params => params.unwrap_or(Json::null()))
  methods.call("no", _ => @moonjrpc.fail(7, "said no", data=Json::string("why")))
  methods.call("boom", _ => raise Boom)
  methods.notice("log", _ => ())
  methods
}

///|
let table : @moonjrpc.Methods = playground()

///|
/// `Methods::body`: the answer, or an empty string when there is nothing to send.
pub fn answer(text : String, batch : Bool) -> @js_async.Promise[String] {
  @js_async.Promise::from_async(async fn() {
    table.body(text, batch~).unwrap_or("")
  })
}

///|
/// The bytes `lines` or `content_length` puts on the wire for `text`.
pub fn framed(kind : String, text : String) -> @js_async.Promise[String] {
  @js_async.Promise::from_async(async fn() {
    let (reads, writes) = @io.pipe()
    let (nothing, _) = @io.pipe()
    let frames = if kind == "lines" {
      @peer.lines(nothing, writes)
    } else {
      @peer.content_length(nothing, writes)
    }
    @async.with_task_group(async fn(group) {
      group.spawn_bg(async fn() {
        frames.write(text)
        writes.close()
      })
      reads.read_all().text()
    })
  })
}

///|
/// A transport that keeps a copy of everything written, which is all the diagrams need. It is also
/// the shape of any transport of your own.
priv struct Recorded {
  inner : &@peer.Frames
  who : String
  log : Array[Json]
}

///|
impl @peer.Frames for Recorded with fn read(self) {
  self.inner.read()
}

///|
impl @peer.Frames for Recorded with fn write(self, text) {
  self.log.push({ "from": Json::string(self.who), "text": Json::string(text) })
  self.inner.write(text)
}

///|
/// Two peers over a pair of pipes, for as long as `body` runs.
priv struct Pair {
  log : Array[Json]
  left : @moonjrpc.Methods
  right : @moonjrpc.Methods
  left_peer : Ref[@peer.Peer?]
  right_peer : Ref[@peer.Peer?]
}

///|
fn Pair::new() -> Pair {
  {
    log: [],
    left: @moonjrpc.Methods::new(),
    right: @moonjrpc.Methods::new(),
    left_peer: Ref(None),
    right_peer: Ref(None),
  }
}

///|
fn Pair::note(self : Pair, who : String, text : String) -> Unit {
  self.log.push({ "from": Json::string(who), "note": Json::string(text) })
}

///|
fn Pair::agent(self : Pair) -> @peer.Peer {
  self.right_peer.val.unwrap()
}

///|
async fn Pair::run(
  self : Pair,
  body : async (@peer.Peer) -> Unit,
  timeout_ms~ : Int32? = Some(2000),
) -> Unit {
  let (right_reads, left_writes) = @io.pipe()
  let (left_reads, right_writes) = @io.pipe()
  let left_frames : Recorded = {
    inner: @peer.lines(left_reads, left_writes),
    who: "editor",
    log: self.log,
  }
  let right_frames : Recorded = {
    inner: @peer.lines(right_reads, right_writes),
    who: "agent",
    log: self.log,
  }
  let left = @peer.Peer::new(left_frames, methods=self.left, timeout_ms~)
  let right = @peer.Peer::new(right_frames, methods=self.right, timeout_ms~)
  self.left_peer.val = Some(left)
  self.right_peer.val = Some(right)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, () => left.run())
    group.spawn_bg(no_wait=true, () => right.run())
    body(left)
    group.return_immediately(())
  })
  left_writes.close()
  right_writes.close()
}

///|
/// What a raised error looks like to the person reading the diagram.
fn caught(error : Error) -> String {
  match error {
    @moonjrpc.Failed(failure) =>
      "raised Failed: \{failure.code} \{failure.message}"
    @moonjrpc.TimedOut(name~, limit~) =>
      "raised TimedOut: \{name} after \{limit} ms"
    @moonjrpc.Closed(name~) => "raised Closed: \{name}"
    _ => "raised another error"
  }
}

///|
async fn plain_call(pair : Pair) -> Unit {
  pair.right.typed("sum", (numbers : Array[Int32]) => {
    numbers.fold(init=0, (a, b) => a + b)
  })
  pair.run(async fn(editor) {
    let params = Json::array([Json::number(2), Json::number(3)])
    let got = editor.call("sum", params~)
    pair.note("editor", "the call returned \{got.stringify()}")
  })
}

///|
async fn asks_back(pair : Pair) -> Unit {
  pair.left.call("read_file", _ => Json::string("hello from the editor"))
  pair.right.call("prompt", async fn(_) {
    pair.note("agent", "needs a file, so it asks in the middle of the call")
    guard pair.agent().call("read_file") is String(text) else {
      return Json::null()
    }
    Json::string("the file says: \{text}")
  })
  pair.run(async fn(editor) {
    let got = editor.call("prompt")
    pair.note("editor", "the call returned \{got.stringify()}")
  })
}

///|
async fn updates_first(pair : Pair) -> Unit {
  pair.left.notice("update", async fn(params) {
    // Slower than the answer that follows, so only the ordering can make the diagram come out right.
    @async.sleep(15)
    let shown = params.map(p => p.stringify()).unwrap_or("")
    pair.note("editor", "handled update \{shown}")
  })
  pair.right.call("prompt", async fn(_) {
    for i in 1..<=3 {
      pair
      .agent()
      .notify("update", params=Json::array([Json::number(i.to_double())]))
    }
    Json::string("done")
  })
  pair.run(async fn(editor) {
    let got = editor.call("prompt")
    pair.note("editor", "the call returned \{got.stringify()}, after all three")
  })
}

///|
async fn out_of_order(pair : Pair) -> Unit {
  pair.right.call("slow", async fn(_) {
    @async.sleep(40)
    Json::string("slow answer")
  })
  pair.right.call("quick", _ => Json::string("quick answer"))
  pair.run(async fn(editor) {
    @async.with_task_group(async fn(group) {
      group.spawn_bg(async fn() {
        let got = editor.call("slow")
        pair.note("editor", "slow returned \{got.stringify()}")
      })
      let got = editor.call("quick")
      pair.note("editor", "quick returned \{got.stringify()}")
    })
  })
}

///|
async fn refused(pair : Pair) -> Unit {
  pair.right.call("no", _ => {
    @moonjrpc.fail(7, "said no", data=Json::string("why"))
  })
  pair.right.call("boom", _ => raise Boom)
  pair.right.typed("sum", (numbers : Array[Int32]) => {
    numbers.fold(init=0, (a, b) => a + b)
  })
  pair.run(async fn(editor) {
    let bad = Json::array([Json::string("x")])
    let cases : Array[(String, Json?)] = [
      ("no", None),
      ("nobody", None),
      ("boom", None),
      ("sum", Some(bad)),
    ]
    for case in cases {
      let (name, params) = case
      try editor.call(name, params?) catch {
        error => pair.note("editor", caught(error))
      } noraise {
        _ => ()
      }
    }
  })
}

///|
async fn timed_out(pair : Pair) -> Unit {
  pair.right.call("slow", async fn(_) {
    @async.sleep(60)
    Json::string("too late")
  })
  pair.right.call("quick", _ => Json::string("quick answer"))
  pair.run(async fn(editor) {
    try editor.call("slow", timeout_ms=Some(20)) catch {
      error => pair.note("editor", caught(error))
    } noraise {
      _ => ()
    }
    @async.sleep(90)
    pair.note("editor", "the late answer was dropped; nothing was waiting")
    let got = editor.call("quick")
    pair.note("editor", "the next call returned \{got.stringify()}")
  })
}

///|
/// One conversation between two real peers, as a JSON array of what each side wrote and what it did.
pub fn conversation(name : String) -> @js_async.Promise[String] {
  @js_async.Promise::from_async(async fn() {
    let pair = Pair::new()
    match name {
      "call" => plain_call(pair)
      "asks-back" => asks_back(pair)
      "updates" => updates_first(pair)
      "out-of-order" => out_of_order(pair)
      "refused" => refused(pair)
      "timeout" => timed_out(pair)
      _ => pair.note("editor", "no such conversation: \{name}")
    }
    Json::array(pair.log).stringify()
  })
}
