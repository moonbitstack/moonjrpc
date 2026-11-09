///|
/// Two peers joined by a pair of pipes, both reading, for as long as `body` runs.
async fn joined(
  left : @moonjrpc.Methods,
  right : @moonjrpc.Methods,
  body : async (@peer.Peer, @peer.Peer) -> Unit,
  timeout_ms~ : Int32? = Some(2000),
) -> Unit {
  let (right_reads, left_writes) = @io.pipe()
  let (left_reads, right_writes) = @io.pipe()
  let a = @peer.Peer::new(
    @peer.lines(left_reads, left_writes),
    methods=left,
    timeout_ms~,
  )
  let b = @peer.Peer::new(
    @peer.lines(right_reads, right_writes),
    methods=right,
    timeout_ms~,
  )
  @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, () => a.run())
    group.spawn_bg(no_wait=true, () => b.run())
    body(a, b)
    group.return_immediately(())
  })
  left_writes.close()
  right_writes.close()
}

///|
fn methods() -> @moonjrpc.Methods {
  @moonjrpc.Methods::new()
}

///|
async test "a call gets its result, and a bare number for params goes out invalid" {
  let right = methods()
  right.call("double", params => {
    guard params is Some(Array([Number(n, ..)])) else { return Json::null() }
    Json::number(n * 2)
  })
  joined(methods(), right, async fn(a, _) {
    assert_eq(
      a.call("double", params=Json::array([Json::number(21)])),
      Json::number(42),
    )
    let refused = try a.call("double", params=Json::number(21)) catch {
      @moonjrpc.Failed(failure) => failure.code
      _ => 0
    } noraise {
      _ => 0
    }
    assert_eq(refused, -32600)
  })
}

///|
async test "both sides call in the same conversation, one inside the other" {
  let left = methods()
  let right = methods()
  left.call("who", _ => Json::string("left"))
  let peer : Ref[@peer.Peer?] = Ref(None)
  right.call("hello", async fn(_) {
    guard peer.val.unwrap().call("who") is String(who) else {
      return Json::null()
    }
    Json::string("hello \{who}")
  })
  joined(left, right, async fn(a, b) {
    peer.val = Some(b)
    assert_eq(a.call("hello"), Json::string("hello left"))
  })
}

///|
async test "the other side's error object raises Failed, an unknown method too" {
  let right = methods()
  right.call("no", _ => @moonjrpc.fail(7, "said no", data=Json::string("why")))
  joined(methods(), right, async fn(a, _) {
    let code = try a.call("no") catch {
      @moonjrpc.Failed(failure) => {
        assert_eq(failure.data, Some(Json::string("why")))
        failure.code
      }
      _ => 0
    } noraise {
      _ => 0
    }
    assert_eq(code, 7)
    let code = try a.call("nobody") catch {
      @moonjrpc.Failed(failure) => failure.code
      _ => 0
    } noraise {
      _ => 0
    }
    assert_eq(code, -32601)
  })
}

///|
async test "a slow answer raises TimedOut, comes in late unnoticed, and the next call works" {
  let right = methods()
  right.call("slow", async fn(_) {
    @async.sleep(100)
    Json::number(1)
  })
  right.call("quick", _ => Json::number(2))
  joined(methods(), right, async fn(a, _) {
    let timed_out = try a.call("slow", timeout_ms=Some(10)) catch {
      @moonjrpc.TimedOut(name~, limit~) => {
        assert_eq(name, "slow")
        limit
      }
      _ => 0
    } noraise {
      _ => 0
    }
    assert_eq(timed_out, 10)
    @async.sleep(150)
    assert_eq(a.call("quick"), Json::number(2))
  })
}

///|
async test "a call woken in the round the peers stop writes before the pipes close" {
  let gate : @aqueue.Queue[Unit] = @aqueue.Queue::Queue(
    kind=@aqueue.Kind::Unbounded,
  )
  let right = methods()
  right.call("slow", async fn(_) {
    gate.get()
    Json::null()
  })
  joined(methods(), right, async fn(a, _) {
    let answered = try {
      ignore(a.call("slow", timeout_ms=Some(10)))
      true
    } catch {
      _ => false
    }
    assert_false(answered)
    gate.put(())
  })
}

///|
async test "no limit waits past the default" {
  let right = methods()
  right.call("slow", async fn(_) {
    @async.sleep(60)
    Json::number(1)
  })
  joined(
    methods(),
    right,
    async fn(a, _) {
      assert_eq(a.call("slow", timeout_ms=None), Json::number(1))
    },
    timeout_ms=Some(10),
  )
}

///|
async test "answers that come out of order reach the right callers" {
  let right = methods()
  let release : @aqueue.Queue[Unit] = @aqueue.Queue::Queue(
    kind=@aqueue.Kind::Unbounded,
  )
  right.call("first", async fn(_) {
    release.get()
    Json::string("first")
  })
  right.call("second", async fn(_) {
    release.put(())
    Json::string("second")
  })
  joined(methods(), right, async fn(a, _) {
    @async.with_task_group(async fn(group) {
      let first = group.spawn(() => a.call("first"))
      assert_eq(a.call("second"), Json::string("second"))
      assert_eq(first.wait(), Json::string("first"))
    })
  })
}

///|
async test "updates sent before an answer are handled before the caller sees it" {
  let left = methods()
  let right = methods()
  let seen = []
  left.notice("update", async fn(params) {
    // Slower than the answer that follows it, so only the ordering can make this pass.
    @async.sleep(5)
    seen.push(params.unwrap())
  })
  let peer : Ref[@peer.Peer?] = Ref(None)
  right.call("prompt", async fn(_) {
    for i in 0..<3 {
      peer.val
      .unwrap()
      .notify("update", params=Json::array([Json::number(i.to_double())]))
    }
    Json::string("done")
  })
  joined(left, right, async fn(a, b) {
    peer.val = Some(b)
    assert_eq(a.call("prompt"), Json::string("done"))
    assert_eq(seen.length(), 3)
    assert_eq(seen[2], Json::array([Json::number(2)]))
  })
}

///|
async test "a notice finishes before the call after it starts" {
  let right = methods()
  let log = []
  right.notice("change", async fn(_) {
    @async.sleep(10)
    log.push("change")
  })
  right.call("read", _ => {
    log.push("read")
    Json::null()
  })
  joined(methods(), right, async fn(a, _) {
    a.notify("change")
    ignore(a.call("read"))
    assert_eq(log, ["change", "read"])
  })
}

///|
async test "a call still running is waited for after the input closes" {
  let (reads, in_writes) = @io.pipe()
  let (out_reads, writes) = @io.pipe()
  let right = methods()
  right.call("slow", async fn(_) {
    @async.sleep(20)
    Json::string("answered")
  })
  let server = @peer.Peer::new(@peer.lines(reads, writes), methods=right)
  let call =
    #|{"jsonrpc":"2.0","id":1,"method":"slow"}
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      server.run()
      writes.close()
    })
    in_writes.write("\{call}\n")
    in_writes.close()
    assert_true(out_reads.read_all().text().contains("answered"))
  })
}

///|
async test "the other side going away raises Closed in whoever is waiting, and later calls too" {
  let (reads, in_writes) = @io.pipe()
  let (out_reads, writes) = @io.pipe()
  let a = @peer.Peer::new(@peer.lines(reads, writes), timeout_ms=None)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(() => a.run())
    group.spawn_bg(() => ignore(out_reads.read_all()))
    let waiting = group.spawn(async fn() {
      try a.call("never") catch {
        @moonjrpc.Closed(name~) => name
        _ => "other"
      } noraise {
        _ => "answered"
      }
    })
    @async.pause()
    in_writes.close()
    assert_eq(waiting.wait(), "never")
    let later = try a.call("later") catch {
      @moonjrpc.Closed(name~) => name
      _ => "other"
    } noraise {
      _ => "answered"
    }
    assert_eq(later, "later")
    let told = try a.notify("later") catch {
      @moonjrpc.Closed(name~) => name
      _ => "other"
    } noraise {
      _ => "told"
    }
    assert_eq(told, "later")
    writes.close()
  })
}

///|
/// Feed `input` to a peer and return what it writes back, one reply to a line.
async fn exchange(
  input : Array[String],
  methods~ : @moonjrpc.Methods = methods(),
  batch~ : Bool = true,
) -> Array[Json] {
  let (reads, in_writes) = @io.pipe()
  let (out_reads, writes) = @io.pipe()
  let server = @peer.Peer::new(@peer.lines(reads, writes), methods~, batch~)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      server.run()
      writes.close()
    })
    group.spawn_bg(async fn() {
      for line in input {
        in_writes.write("\{line}\n")
      }
      in_writes.close()
    })
    let out = []
    for line in out_reads.read_all().text().split("\n") {
      if !line.is_empty() {
        out.push(@json.parse(line))
      }
    }
    out
  })
}

///|
async test "text that is not JSON is -32700 and the conversation goes on" {
  let right = methods()
  right.call("c", _ => Json::string("ok"))
  let call =
    #|{"jsonrpc":"2.0","id":1,"method":"c"}
  let got = exchange(["not json", call], methods=right)
  assert_eq(got.length(), 2)
  assert_true(got[0].stringify().contains("-32700"))
  assert_true(got[1].stringify().contains("\"ok\""))
}

///|
async test "a value that is not a message is -32600 with its identifier" {
  let invalid =
    #|{"jsonrpc":"2.0","id":9,"method":3}
  let got = exchange([invalid])
  assert_true(got[0].stringify().contains("-32600"))
  assert_true(got[0].stringify().contains("\"id\":9"))
}

///|
async test "an identifier comes back exactly as it was written" {
  let right = methods()
  right.call("c", _ => Json::null())
  let (reads, in_writes) = @io.pipe()
  let (out_reads, writes) = @io.pipe()
  let server = @peer.Peer::new(@peer.lines(reads, writes), methods=right)
  let call =
    #|{"jsonrpc":"2.0","id":1.0,"method":"c"}
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      server.run()
      writes.close()
    })
    in_writes.write("\{call}\n")
    in_writes.close()
    assert_true(out_reads.read_all().text().contains("\"id\":1.0"))
  })
}

///|
async test "a handler waiting on a call of its own hears Closed when the input closes" {
  let right = methods()
  let peer : Ref[@peer.Peer?] = Ref(None)
  right.call("c", async fn(_) {
    peer.val.unwrap().call("who", timeout_ms=None) catch {
      @moonjrpc.Closed(name~) => Json::string("closed on \{name}")
      _ => Json::string("other")
    }
  })
  let (reads, in_writes) = @io.pipe()
  let (out_reads, writes) = @io.pipe()
  let server = @peer.Peer::new(@peer.lines(reads, writes), methods=right)
  peer.val = Some(server)
  let call =
    #|{"jsonrpc":"2.0","id":1,"method":"c"}
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      server.run()
      writes.close()
    })
    in_writes.write("\{call}\n")
    // The handler is waiting once its own call has come out.
    let sent = @peer.lines(out_reads, in_writes)
    assert_true(sent.read().unwrap().contains("\"who\""))
    in_writes.close()
    assert_true(sent.read().unwrap().contains("closed on who"))
  })
}

///|
async test "a batch is answered in one array" {
  let right = methods()
  right.call("c", _ => Json::string("ok"))
  right.notice("n", _ => ())
  let batch =
    #|[{"jsonrpc":"2.0","id":1,"method":"c"},{"jsonrpc":"2.0","method":"n"},{"jsonrpc":"2.0","id":2,"method":"c"},1]
  let got = exchange([batch], methods=right)
  assert_eq(got.length(), 1)
  guard got[0] is Array(answers) else { abort("no array") }
  assert_eq(answers.length(), 3)
}

///|
async test "batch=false refuses an array, and an empty one is always refused" {
  let right = methods()
  right.call("c", _ => Json::string("ok"))
  let batch =
    #|[{"jsonrpc":"2.0","id":1,"method":"c"}]
  let got = exchange([batch], methods=right, batch=false)
  assert_true(got[0].stringify().contains("-32600"))
  let got = exchange(["[]"], methods=right)
  assert_true(got[0].stringify().contains("-32600"))
}

///|
async test "replies in a batch reach their callers" {
  let (reads, in_writes) = @io.pipe()
  let (out_reads, writes) = @io.pipe()
  let a = @peer.Peer::new(@peer.lines(reads, writes))
  let replies =
    #|[{"jsonrpc":"2.0","id":1,"result":"a"},{"jsonrpc":"2.0","id":2,"result":"b"}]
  @async.with_task_group(async fn(group) {
    group.spawn_bg(() => a.run())
    let first = group.spawn(() => a.call("one"))
    let second = group.spawn(() => a.call("two"))
    // Both calls are out once their two lines have been read.
    let sent = @peer.lines(out_reads, in_writes)
    ignore(sent.read())
    ignore(sent.read())
    in_writes.write("\{replies}\n")
    assert_eq(first.wait(), Json::string("a"))
    assert_eq(second.wait(), Json::string("b"))
    in_writes.close()
    writes.close()
  })
}

///|
async test "cancelling run ends it and tells whoever is waiting" {
  let (reads, in_writes) = @io.pipe()
  let (out_reads, writes) = @io.pipe()
  let a = @peer.Peer::new(@peer.lines(reads, writes), timeout_ms=None)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(() => ignore(out_reads.read_all()))
    let running = group.spawn(allow_failure=true, () => a.run())
    let waiting = group.spawn(async fn() {
      try a.call("never") catch {
        @moonjrpc.Closed(_) => "closed"
        _ => "other"
      } noraise {
        _ => "answered"
      }
    })
    @async.pause()
    running.cancel()
    assert_eq(waiting.wait(), "closed")
    in_writes.close()
    writes.close()
  })
}
