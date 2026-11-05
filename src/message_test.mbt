///|
fn decoded(text : String) -> @moonjrpc.Message? {
  let json = @json.parse(text) catch { _ => return None }
  try @json.from_json(json) catch {
    _ => None
  } noraise {
    message => Some(message)
  }
}

///|
test "each kind of message comes back the same through JSON" {
  let messages : Array[@moonjrpc.Message] = [
    Call(id=@moonjrpc.Id::int(1), name="m", params=None),
    Call(id=Text("a"), name="m", params=Some(Json::array([]))),
    Call(id=Null, name="m", params=Some(Json::object({}))),
    Notice(name="m", params=None),
    Notice(name="m", params=Some(Json::array([Json::number(1)]))),
    Reply(id=Text("a"), result=Json::null()),
    Refusal(id=Null, failure={ code: -1, message: "x", data: None, }),
    Refusal(id=Text("a"), failure={
      code: 1,
      message: "x",
      data: Some(Json::string("y")),
    }),
  ]
  for message in messages {
    assert_eq(decoded(message.to_json().stringify()), Some(message))
  }
}

///|
test "what the specification rules out does not decode" {
  let bad = [
    // Not an object, or the wrong version.
    "1", "[]", "{}", "{\"id\":1,\"method\":\"m\"}", "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"m\"}",
    "{\"jsonrpc\":2,\"id\":1,\"method\":\"m\"}",
    // The method's name is a string; params are structured.
     "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":1}", "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\",\"params\":1}",
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\",\"params\":null}",
    // An identifier is a string, a number or null.
     "{\"jsonrpc\":\"2.0\",\"id\":[],\"method\":\"m\"}", "{\"jsonrpc\":\"2.0\",\"id\":true,\"result\":1}",
    // A response has one of result and error, and an identifier.
     "{\"jsonrpc\":\"2.0\",\"id\":1}", "{\"jsonrpc\":\"2.0\",\"result\":1}", "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":1,\"error\":{\"code\":1,\"message\":\"x\"}}",
    // A result never has a null identifier; only an error can.
     "{\"jsonrpc\":\"2.0\",\"id\":null,\"result\":1}",
    // An error object has an integer code and a string message.
     "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"message\":\"x\"}}", "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":1.5,\"message\":\"x\"}}",
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":1}}", "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":1}",
    // A call is not also a response.
     "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\",\"result\":1}",
  ]
  for text in bad {
    assert_eq(decoded(text), None)
  }
}

///|
test "a null identifier is a call, a missing one a notice" {
  let call =
    #|{"jsonrpc":"2.0","id":null,"method":"m"}
  let notice =
    #|{"jsonrpc":"2.0","method":"m"}
  assert_eq(decoded(call), Some(Call(id=Null, name="m", params=None)))
  assert_eq(decoded(notice), Some(Notice(name="m", params=None)))
}

///|
test "the same identifier has the same key whichever side wrote it" {
  assert_eq(
    @moonjrpc.Id::int(5).key(),
    @moonjrpc.Id::Num(5, repr=Some("5")).key(),
  )
  assert_true(@moonjrpc.Id::int(5).key() != @moonjrpc.Id::Text("5").key())
  assert_true(@moonjrpc.Id::Null.key() != @moonjrpc.Id::Text("null").key())
}

///|
test "invalid keeps a readable identifier and drops the rest" {
  let refused = fn(id) -> @moonjrpc.Message {
    Refusal(id~, failure={
      code: -32600,
      message: "Invalid Request",
      data: None,
    })
  }
  assert_eq(
    @moonjrpc.Message::invalid(Json::object({ "id": Json::string("a") })),
    refused(Text("a")),
  )
  assert_eq(
    @moonjrpc.Message::invalid(Json::object({ "id": Json::array([]) })),
    refused(Null),
  )
  assert_eq(@moonjrpc.Message::invalid(Json::number(1)), refused(Null))
}
