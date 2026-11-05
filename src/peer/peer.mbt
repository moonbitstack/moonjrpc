///|
/// How long `Peer::call` waits: 60 seconds, the MCP TypeScript SDK's `DEFAULT_REQUEST_TIMEOUT_MSEC`.
pub let timeout_ms : Int32 = 60000

///|
/// One end of a conversation in which either side may call the other. Messages are taken in the order
/// they arrive: a notice finishes before the next message is looked at, a call starts in its turn and
/// runs on in a task of its own, and a reply wakes its caller in its turn. So the updates a side sends
/// before answering are handled before its caller sees the answer.
///
/// A notice handler that waits on `Peer::call` waits for a reply that cannot be looked at until the
/// handler returns. Start a task for that instead.
pub struct Peer {
  frames : &Frames
  methods : @moonjsonrpc.Methods
  timeout_ms : Int32?
  batch : Bool
  lock : @async.Mutex
  waiting : Map[String, (String, @aqueue.Queue[@moonjsonrpc.Message])]
  mut next : Int64
  mut closed : Bool
}

///|
/// `timeout_ms=None` waits as long as it takes. `batch=false` answers an array with -32600, for
/// protocols that forbid batches.
pub fn Peer::new(
  frames : &Frames,
  methods~ : @moonjsonrpc.Methods = @moonjsonrpc.Methods::new(),
  timeout_ms~ : Int32? = Some(timeout_ms),
  batch~ : Bool = true,
) -> Peer {
  {
    frames,
    methods,
    timeout_ms,
    batch,
    lock: @async.Mutex::Mutex(),
    waiting: {},
    next: 0,
    closed: false,
  }
}

///|
async fn Peer::write(self : Peer, text : String) -> Unit {
  self.lock.acquire()
  defer self.lock.release()
  self.frames.write(text)
}

///|
async fn Peer::send(self : Peer, message : @moonjsonrpc.Message) -> Unit {
  self.write(message.to_json().stringify())
}

///|
/// Send a call and wait for its answer. The other side's error object raises `Failed`; no answer in
/// time raises `TimedOut`, and the side going away raises `Closed`. Telling the other side the call
/// was given up on is for the protocol to do: MCP, ACP and LSP each have their own notice for it.
pub async fn Peer::call(
  self : Peer,
  name : String,
  params? : Json,
  timeout_ms~ : Int32? = self.timeout_ms,
) -> Json {
  if self.closed {
    raise @moonjsonrpc.Closed(name~)
  }
  self.next += 1
  let id = @moonjsonrpc.Id::int(self.next)
  let queue : @aqueue.Queue[@moonjsonrpc.Message] = @aqueue.Queue::Queue(
    kind=@aqueue.Kind::Unbounded,
  )
  self.waiting[id.key()] = (name, queue)
  defer self.waiting.remove(id.key())
  self.send(@moonjsonrpc.Message::Call(id~, name~, params~))
  let answer = match timeout_ms {
    None => queue.get()
    Some(limit) =>
      match @async.with_timeout_opt(limit, () => queue.get()) {
        Some(answer) => answer
        None => raise @moonjsonrpc.TimedOut(name~, limit~)
      }
  }
  match answer {
    Reply(result~, ..) => result
    Refusal(failure~, ..) => raise @moonjsonrpc.Failed(failure)
    _ => raise @moonjsonrpc.Closed(name~)
  }
}

///|
pub async fn Peer::notify(self : Peer, name : String, params? : Json) -> Unit {
  if self.closed {
    raise @moonjsonrpc.Closed(name~)
  }
  self.send(@moonjsonrpc.Message::Notice(name~, params~))
}

///|
/// Hand a reply to its caller. One nobody is waiting for is dropped: the wait may have given up.
fn Peer::settle(
  self : Peer,
  id : @moonjsonrpc.Id,
  answer : @moonjsonrpc.Message,
) -> Unit {
  if self.waiting.get(id.key()) is Some((_, queue)) {
    ignore(queue.try_put(answer) catch { _ => false })
  }
}

///|
/// Everything still waiting learns the other side is gone.
fn Peer::shut(self : Peer) -> Unit {
  self.closed = true
  for _, waiting in self.waiting {
    let (name, queue) = waiting
    queue.close(error=@moonjsonrpc.Closed(name~))
  }
}

///|
/// A batch: replies go to their callers, the rest are answered together in one array.
fn Peer::take_batch(
  self : Peer,
  group : @async.TaskGroup[Unit],
  items : Array[Json],
) -> Unit {
  guard self.batch && !items.is_empty() else {
    self.answer_later(group, @moonjsonrpc.Message::invalid(Json::null()))
    return
  }
  let rest : Array[Json] = []
  for item in items {
    let message : @moonjsonrpc.Message? = try @json.from_json(item) catch {
      _ => None
    } noraise {
      message => Some(message)
    }
    match message {
      Some(Reply(id~, ..) as answer) | Some(Refusal(id~, ..) as answer) =>
        self.settle(id, answer)
      _ => rest.push(item)
    }
  }
  if rest.is_empty() {
    return
  }
  group.spawn_bg(allow_failure=true, async fn() {
    if self.methods.body(Json::array(rest).stringify()) is Some(text) {
      self.write(text)
    }
  })
}

///|
/// Reading never waits on writing: two sides that each wait for the other to read would stop for good
/// once the buffers between them fill.
fn Peer::answer_later(
  self : Peer,
  group : @async.TaskGroup[Unit],
  message : @moonjsonrpc.Message,
) -> Unit {
  group.spawn_bg(allow_failure=true, () => self.send(message))
}

///|
async fn Peer::take(
  self : Peer,
  group : @async.TaskGroup[Unit],
  json : Json,
) -> Unit {
  let message : @moonjsonrpc.Message = @json.from_json(json) catch {
    _ => {
      self.answer_later(group, @moonjsonrpc.Message::invalid(json))
      return
    }
  }
  match message {
    Reply(id~, ..) | Refusal(id~, ..) => self.settle(id, message)
    Notice(_) => ignore(self.methods.answer(message))
    Call(_) =>
      group.spawn_bg(allow_failure=true, async fn() {
        if self.methods.answer(message) is Some(answer) {
          self.send(answer)
        }
      })
  }
}

///|
/// Read until the other side closes. Calls still running are waited for, so a client that writes its
/// requests and closes its end still gets its answers; cancel this task to stop sooner.
pub async fn Peer::run(self : Peer) -> Unit {
  defer self.shut()
  @async.with_task_group(async fn(group) {
    while self.frames.read() is Some(text) {
      let json = @json.parse(text, preserve_number_repr=true) catch {
        _ => {
          self.answer_later(group, @moonjsonrpc.Message::unreadable())
          continue
        }
      }
      match json {
        Array(items) => self.take_batch(group, items)
        one => self.take(group, one)
      }
    }
    self.shut()
  })
}
