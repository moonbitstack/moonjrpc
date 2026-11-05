///|
suberror Boom {
  Boom
}

///|
fn methods(peer : Ref[@peer.Peer?]) -> @moonjsonrpc.Methods {
  let methods = @moonjsonrpc.Methods::new()
  let logged = []
  methods.typed("sum", (numbers : Array[Int32]) => {
    numbers.fold(init=0, (a, b) => a + b)
  })
  methods.call("echo", params => params.unwrap_or(Json::null()))
  methods.call("no", _ => {
    @moonjsonrpc.fail(7, "said no", data=Json::string("why"))
  })
  methods.call("boom", _ => raise Boom)
  methods.notice("log", params => logged.push(params.unwrap_or(Json::null())))
  methods.call("logged", _ => Json::array(logged))
  methods.call("ask_back", async fn(_) {
    guard peer.val.unwrap().call("who") is String(who) else {
      return Json::null()
    }
    Json::string("hello \{who}")
  })
  methods
}

///|
/// `lines` and `content-length` serve a peer on standard input and output; `body` answers each line
/// with `Methods::body`, or writes `null` when there is nothing to send.
async fn main {
  let peer : Ref[@peer.Peer?] = Ref(None)
  let table = methods(peer)
  match @env.args()[1] {
    "body" =>
      while @stdio.stdin.read_until("\n") is Some(line) {
        let answer = table.body(line.trim(chars="\r"))
        @stdio.stdout.write(answer.unwrap_or("null") + "\n")
      }
    mode => {
      let frames = if mode == "lines" {
        @peer.lines(@stdio.stdin, @stdio.stdout)
      } else {
        @peer.content_length(@stdio.stdin, @stdio.stdout)
      }
      let one = @peer.Peer::new(frames, methods=table)
      peer.val = Some(one)
      one.run()
    }
  }
}
