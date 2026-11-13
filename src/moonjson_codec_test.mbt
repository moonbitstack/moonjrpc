///|
/// The text codec is strict RFC 8259, read and written by `moonjson` from our own JSON family. A
/// trailing comma is a parse error, not a silently accepted value, so the answer is -32700.
async test "the text codec refuses a trailing comma with -32700" {
  let methods = @moonjrpc.Methods::new()
  let refuse =
    #|{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}
  let got = @json.parse(
    methods.body("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"c\",}").unwrap(),
  )
  assert_eq(got, @json.parse(refuse))
}

///|
/// A line comment is not JSON, so the strict reader answers -32700 rather than skipping it.
async test "the text codec refuses a comment with -32700" {
  let methods = @moonjrpc.Methods::new()
  let refuse =
    #|{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}
  let got = @json.parse(
    methods
    .body("// not json\n{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"c\"}")
    .unwrap(),
  )
  assert_eq(got, @json.parse(refuse))
}

///|
/// Whitespace around a value is RFC 8259 and is accepted; the call still answers.
async test "the text codec accepts a value padded with whitespace" {
  let methods = @moonjrpc.Methods::new()
  methods.call("c", _ => Json::null())
  let answer = methods.body(
    "  {\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"c\"}  ",
  )
  assert_true(answer.unwrap().contains("\"result\""))
}

///|
/// A number identifier keeps the text it was written in, past 2^53, because the codec carries the
/// original digits: a reply matches the call it answers.
async test "a numeric identifier past 2^53 keeps its text" {
  let methods = @moonjrpc.Methods::new()
  methods.call("c", _ => Json::null())
  let id = "9007199254740993"
  let answer = methods
    .body("{\"jsonrpc\":\"2.0\",\"id\":\{id},\"method\":\"c\"}")
    .unwrap()
  assert_true(answer.contains("\"id\":\{id}"))
}
