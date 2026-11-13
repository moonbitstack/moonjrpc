///|
/// The method table: what a side does with the calls and notices it receives. Registering a name
/// again replaces it.
struct Methods {
  calls : Map[String, async (Json?) -> Json]
  notices : Map[String, async (Json?) -> Unit]
  on_error : ((String, Error) -> Unit)?
}

///|
/// A table with nothing in it. `on_error` hears the errors a client is not told about: a handler's
/// failure other than `Failed`, which goes out as -32603 with no detail, and any failure of a notice,
/// which has no one to go to.
pub fn Methods::new(on_error? : (String, Error) -> Unit) -> Methods {
  { calls: {}, notices: {}, on_error, }
}

///|
/// Answer calls to `name` with what `run` returns. The parameters arrive as they came.
pub fn Methods::call(
  self : Methods,
  name : String,
  run : async (Json?) -> Json,
) -> Unit {
  self.calls[name] = run
}

///|
/// Run `run` for each notice named `name`. Nothing goes back.
pub fn Methods::notice(
  self : Methods,
  name : String,
  run : async (Json?) -> Unit,
) -> Unit {
  self.notices[name] = run
}

///|
/// A call whose parameters and result go through `FromJson` and `ToJson`. Parameters that do not
/// decode are -32602, with the decoder's reason as the error's `data`.
pub fn[P : @json.FromJson, R : ToJson] Methods::typed(
  self : Methods,
  name : String,
  run : async (P) -> R,
) -> Unit {
  self.call(name, async fn(params) {
    let input : P = @json.from_json(params.unwrap_or(Json::null())) catch {
      JsonDecodeError((path, reason)) =>
        fail(
          invalid_params,
          "Invalid params",
          data=Json::string("\{path}: \{reason}"),
        )
    }
    run(input).to_json()
  })
}

///|
fn Methods::heard(self : Methods, name : String, error : Error) -> Unit {
  if self.on_error is Some(on_error) {
    on_error(name, error)
  }
}

///|
/// What to send back for a message: the response to a call, nothing for the rest. A method nobody
/// registered is -32601 and a raised `Failed` goes out as it is; any other error is -32603 with no
/// detail, because what a handler trips over is not the caller's to read.
pub async fn Methods::answer(self : Methods, message : Message) -> Message? {
  match message {
    Call(id~, name~, params~) => {
      guard self.calls.get(name) is Some(run) else {
        return Some(
          Refusal(id~, failure={
            code: method_not_found,
            message: "Method not found",
            data: None,
          }),
        )
      }
      try run(params) catch {
        Failed(failure) => Some(Refusal(id~, failure~))
        error => {
          self.heard(name, error)
          Some(
            Refusal(id~, failure={
              code: internal_error,
              message: "Internal error",
              data: None,
            }),
          )
        }
      } noraise {
        result => Some(Reply(id~, result~))
      }
    }
    Notice(name~, params~) => {
      if self.notices.get(name) is Some(run) {
        run(params) catch {
          error => self.heard(name, error)
        }
      }
      None
    }
    Reply(_) | Refusal(_) => None
  }
}

///|
async fn Methods::answer_json(self : Methods, json : Json) -> Json? {
  match message_of(json) {
    None => Some(Message::invalid(json).to_json())
    Some(message) => self.answer(message).map(answer => answer.to_json())
  }
}

///|
/// One body in, one body out, by the specification: text that is not JSON is -32700, a value that is
/// not a message is -32600, an array is a batch, and when nothing needs answering there is nothing to
/// send. `batch=false` is for protocols that forbid arrays, as ACP does: an array is then -32600.
pub async fn Methods::body(
  self : Methods,
  text : StringView,
  batch~ : Bool = true,
) -> String? {
  let json = @moonjson.loads(text, @moonjson.strict) catch {
    _ => return Some(@moonjson.dumps(Message::unreadable().to_json()))
  }
  match json {
    Array(items) => {
      guard batch && !items.is_empty() else {
        return Some(@moonjson.dumps(Message::invalid(Json::null()).to_json()))
      }
      let out = []
      for item in items {
        if self.answer_json(item) is Some(answer) {
          out.push(answer)
        }
      }
      if out.is_empty() {
        None
      } else {
        Some(@moonjson.dumps(Json::array(out)))
      }
    }
    one => self.answer_json(one).map(answer => @moonjson.dumps(answer))
  }
}
