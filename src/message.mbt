///|
/// The text is not JSON.
pub let parse_error : Int32 = -32700

///|
/// The value is not a valid message.
pub let invalid_request : Int32 = -32600

///|
/// Nobody registered that method.
pub let method_not_found : Int32 = -32601

///|
/// The parameters are not what the method takes.
pub let invalid_params : Int32 = -32602

///|
/// The handler failed in a way the caller is not told about.
pub let internal_error : Int32 = -32603

///|
/// A request's identifier. A number keeps the text it was written in, as core's `Json` does, so an
/// identifier `Double` cannot hold goes back out exactly as it came in.
#derive(Eq, Debug)
pub(all) enum Id {
  Num(Double, repr~ : String?)
  Text(String)
  Null
}

///|
/// An identifier from an integer.
pub fn Id::int(n : Int64) -> Id {
  Num(n.to_double(), repr=None)
}

///|
/// The same text for the same identifier, whichever side wrote it: a map key for matching replies
/// to calls.
pub fn Id::key(self : Id) -> String {
  match self {
    Num(_, repr=Some(repr)) => "n:\{repr}"
    Num(number, repr=None) => "n:\{number}"
    Text(text) => "s:\{text}"
    Null => "null"
  }
}

///|
pub impl ToJson for Id with fn to_json(self) {
  match self {
    Num(number, repr~) => Json::number(number, repr?)
    Text(text) => Json::string(text)
    Null => Json::null()
  }
}

///|
/// The error object of a response.
#derive(Eq, Debug)
pub(all) struct Failure {
  code : Int32
  message : String
  data : Json?
}

///|
pub impl ToJson for Failure with fn to_json(self) {
  let out : Map[String, Json] = {
    "code": Json::number(self.code.to_double()),
    "message": Json::string(self.message),
  }
  if self.data is Some(data) {
    out["data"] = data
  }
  Json(out)
}

///|
/// What goes wrong with a call. `Failed` is the other side's error object, and a handler raises it to
/// answer with one. `limit~` is the bound that was passed and `got~` what came.
#derive(Eq, Debug)
pub(all) suberror Failed {
  Failed(Failure)
  TimedOut(name~ : String, limit~ : Int32)
  Closed(name~ : String)
  TooLong(limit~ : Int32, got~ : Int64)
  Malformed(String)
}

///|
/// Raise an error object: `fail(invalid_params, "no such file")`.
pub fn[T] fail(code : Int32, message : String, data? : Json) -> T raise Failed {
  raise Failed({ code, message, data, })
}

///|
/// One JSON-RPC 2.0 message. A `Refusal` is a response carrying an error.
#derive(Eq, Debug)
pub(all) enum Message {
  Call(id~ : Id, name~ : String, params~ : Json?)
  Notice(name~ : String, params~ : Json?)
  Reply(id~ : Id, result~ : Json)
  Refusal(id~ : Id, failure~ : Failure)
}

///|
pub impl ToJson for Message with fn to_json(self) {
  let out : Map[String, Json] = { "jsonrpc": Json::string("2.0") }
  match self {
    Call(id~, name~, params~) => {
      out["id"] = id.to_json()
      out["method"] = Json::string(name)
      if params is Some(params) {
        out["params"] = params
      }
    }
    Notice(name~, params~) => {
      out["method"] = Json::string(name)
      if params is Some(params) {
        out["params"] = params
      }
    }
    Reply(id~, result~) => {
      out["id"] = id.to_json()
      out["result"] = result
    }
    Refusal(id~, failure~) => {
      out["id"] = id.to_json()
      out["error"] = failure.to_json()
    }
  }
  Json(out)
}

///|
fn id_of(value : Json) -> Id? {
  match value {
    Number(number, repr~) => Some(Num(number, repr~))
    String(text) => Some(Text(text))
    Null => Some(Null)
    _ => None
  }
}

///|
fn failure_of(value : Json) -> Failure? {
  guard value is Object(fields) &&
    fields.get("code") is Some(Number(code, ..)) &&
    fields.get("message") is Some(String(message)) &&
    code == code.to_int().to_double() else {
    return None
  }
  Some({ code: code.to_int(), message, data: fields.get("data"), })
}

///|
fn call_of(fields : Map[String, Json], name : Json) -> Message? {
  guard name is String(name) &&
    !fields.contains("result") &&
    !fields.contains("error") else {
    return None
  }
  let params = fields.get("params")
  match params {
    None | Some(Array(_)) | Some(Object(_)) => ()
    _ => return None
  }
  match fields.get("id") {
    None => Some(Notice(name~, params~))
    Some(id) => id_of(id).map(id => Call(id~, name~, params~))
  }
}

///|
fn response_of(fields : Map[String, Json]) -> Message? {
  guard fields.get("id").bind(id_of) is Some(id) else { return None }
  match (fields.get("result"), fields.get("error")) {
    (Some(result), None) =>
      if id == Null {
        None
      } else {
        Some(Reply(id~, result~))
      }
    (None, Some(error)) =>
      failure_of(error).map(failure => Refusal(id~, failure~))
    _ => None
  }
}

///|
fn message_of(json : Json) -> Message? {
  guard json is Object(fields) && fields.get("jsonrpc") is Some(String("2.0")) else {
    return None
  }
  match fields.get("method") {
    Some(name) => call_of(fields, name)
    None => response_of(fields)
  }
}

///|
/// Decodes by the specification's section 4 and 5: `jsonrpc` is exactly `"2.0"`, `params` is an array
/// or object when present, and a response has `result` or `error` but not both.
pub impl @json.FromJson for Message with fn from_json(json, path) {
  guard message_of(json) is Some(message) else {
    raise @json.JsonDecodeError((path, "not a JSON-RPC 2.0 message"))
  }
  message
}

///|
/// The answer to something that is not a valid message: -32600, with its identifier if one can be
/// read and null otherwise.
pub fn Message::invalid(json : Json) -> Message {
  let id = if json is Object(fields) {
    fields.get("id").bind(id_of).unwrap_or(Null)
  } else {
    Null
  }
  Refusal(id~, failure={
    code: invalid_request,
    message: "Invalid Request",
    data: None,
  })
}

///|
/// The answer to text that is not JSON: -32700, with a null identifier.
pub fn Message::unreadable() -> Message {
  Refusal(id=Null, failure={
    code: parse_error,
    message: "Parse error",
    data: None,
  })
}

///|
pub extend Id with Eq::{not_equal, equal}

///|
pub extend Id with Debug::{to_repr}

///|
pub extend Id with ToJson::{to_json}

///|
pub extend Failure with Eq::{not_equal, equal}

///|
pub extend Failure with Debug::{to_repr}

///|
pub extend Failure with ToJson::{to_json}

///|
pub extend Failed with Eq::{not_equal, equal}

///|
pub extend Failed with Debug::{to_repr}

///|
pub extend Message with Eq::{not_equal, equal}

///|
pub extend Message with Debug::{to_repr}

///|
pub extend Message with ToJson::{to_json}

///|
pub extend Message with @json.FromJson::{from_json}
