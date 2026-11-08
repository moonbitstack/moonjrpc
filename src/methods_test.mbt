///|
/// The methods section 7 of the specification assumes.
fn spec_methods() -> @moonjrpc.Methods {
  let methods = @moonjrpc.Methods::new()
  methods.call("subtract", params => {
    let (minuend, subtrahend) = match params {
      Some(Array([Number(a, ..), Number(b, ..)])) => (a, b)
      Some(
        Object({ "minuend": Number(a, ..), "subtrahend": Number(b, ..), .. })
      ) => (a, b)
      _ => @moonjrpc.fail(@moonjrpc.invalid_params, "Invalid params")
    }
    Json::number(minuend - subtrahend)
  })
  methods.call("sum", params => {
    guard params is Some(Array(items)) else { return Json::null() }
    let mut total = 0.0
    for item in items {
      if item is Number(n, ..) {
        total += n
      }
    }
    Json::number(total)
  })
  methods.call("get_data", _ => {
    Json::array([Json::string("hello"), Json::number(5)])
  })
  methods.notice("update", _ => ())
  methods.notice("foobar", _ => ())
  methods.notice("notify_sum", _ => ())
  methods.notice("notify_hello", _ => ())
  methods
}

///|
async test "every example in the specification" {
  assert_eq(spec_cases.length(), 15)
  let methods = spec_methods()
  for case in spec_cases {
    let (ask, want) = case
    match (methods.body(ask), want) {
      (None, None) => ()
      (Some(got), Some(want)) => assert_eq(@json.parse(got), @json.parse(want))
      _ => abort("the answer to \{ask} does not match")
    }
  }
}

///|
async test "typed: parameters decode, or -32602 with the reason" {
  let methods = @moonjrpc.Methods::new()
  methods.typed("double", (n : Int32) => n * 2)
  let good =
    #|{"jsonrpc":"2.0","id":1,"method":"double","params":[21]}
  let bad =
    #|{"jsonrpc":"2.0","id":2,"method":"double","params":["x"]}
  methods.typed("double", (ns : Array[Int32]) => ns[0] * 2)
  let answer = methods.body(good).unwrap()
  assert_eq(
    @json.parse(answer).stringify(),
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":42}",
  )
  guard @json.parse(methods.body(bad).unwrap())
    is Object(
      {
        "error": Object({ "code": Number(code, ..), "data": String(_), .. }),
        ..
      }
    ) else {
    abort("no reason given")
  }
  assert_eq(code, -32602)
}

///|
async test "a raised Failed goes out as it is, with its data" {
  let methods = @moonjrpc.Methods::new()
  methods.call("no", _ => @moonjrpc.fail(7, "said no", data=Json::string("why")))
  let answer = methods.answer(Call(id=Text("a"), name="no", params=None))
  assert_eq(
    answer,
    Some(
      Refusal(id=Text("a"), failure={
        code: 7,
        message: "said no",
        data: Some(Json::string("why")),
      }),
    ),
  )
}

///|
suberror Secret {
  Secret
}

///|
async test "any other error is -32603 with no detail, and on_error hears it" {
  let heard = []
  let methods = @moonjrpc.Methods::new(on_error=(name, _) => heard.push(name))
  methods.call("boom", _ => raise Secret)
  let answer = methods.answer(Call(id=Text("a"), name="boom", params=None))
  assert_eq(
    answer,
    Some(
      Refusal(id=Text("a"), failure={
        code: -32603,
        message: "Internal error",
        data: None,
      }),
    ),
  )
  assert_eq(heard, ["boom"])
}

///|
async test "a notice never answers, even when it fails, and on_error hears it" {
  let heard = []
  let methods = @moonjrpc.Methods::new(on_error=(name, _) => heard.push(name))
  methods.notice("boom", _ => raise Secret)
  assert_eq(methods.answer(Notice(name="boom", params=None)), None)
  assert_eq(methods.answer(Notice(name="nobody", params=None)), None)
  assert_eq(heard, ["boom"])
}

///|
async test "a call to a notice-only name is -32601, and registering again replaces" {
  let methods = @moonjrpc.Methods::new()
  methods.notice("n", _ => ())
  guard methods.answer(Call(id=Null, name="n", params=None))
    is Some(Refusal(failure~, ..)) else {
    abort("no refusal")
  }
  assert_eq(failure.code, -32601)
  methods.call("c", _ => Json::number(1))
  methods.call("c", _ => Json::number(2))
  assert_eq(
    methods.answer(Call(id=Null, name="c", params=None)),
    Some(Reply(id=Null, result=Json::number(2))),
  )
}

///|
async test "responses are not answered" {
  let methods = @moonjrpc.Methods::new()
  assert_eq(methods.answer(Reply(id=Text("a"), result=Json::null())), None)
  let reply =
    #|{"jsonrpc":"2.0","id":1,"result":1}
  assert_eq(methods.body(reply), None)
}

///|
async test "batch=false: an array is -32600, a single message still goes through" {
  let methods = spec_methods()
  let array =
    #|[{"jsonrpc":"2.0","id":1,"method":"sum","params":[1]}]
  let single =
    #|{"jsonrpc":"2.0","id":1,"method":"sum","params":[1]}
  let refused =
    #|{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid Request"}}
  assert_eq(
    @json.parse(methods.body(array, batch=false).unwrap()),
    @json.parse(refused),
  )
  assert_true(methods.body(array, batch=true).unwrap().has_prefix("["))
  assert_true(methods.body(single, batch=false).unwrap().contains("result"))
}

///|
async test "an identifier comes back exactly as it was written" {
  let methods = @moonjrpc.Methods::new()
  methods.call("c", _ => Json::null())
  for id in ["12345678901234567890", "1.5", "0", "-3", "1.0", "1e2"] {
    let answer = methods.body(
      "{\"jsonrpc\":\"2.0\",\"id\":\{id},\"method\":\"c\"}",
    )
    assert_true(answer.unwrap().contains("\"id\":\{id}"))
  }
}

///|
async test "an invalid message with a readable identifier keeps it" {
  let methods = @moonjrpc.Methods::new()
  let invalid =
    #|{"jsonrpc":"2.0","id":5,"method":3}
  let refused =
    #|{"jsonrpc":"2.0","id":5,"error":{"code":-32600,"message":"Invalid Request"}}
  assert_eq(@json.parse(methods.body(invalid).unwrap()), @json.parse(refused))
}

///|
async test "an empty body is -32700, and a value that is not a message is -32600" {
  let methods = @moonjrpc.Methods::new()
  let unreadable =
    #|{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}
  assert_eq(@json.parse(methods.body("").unwrap()), @json.parse(unreadable))
  let invalid =
    #|{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid Request"}}
  for text in ["null", "3", "\"text\"", "true"] {
    assert_eq(@json.parse(methods.body(text).unwrap()), @json.parse(invalid))
  }
}

///|
async test "a batch of notices alone has nothing to send, and every notice ran" {
  let methods = @moonjrpc.Methods::new()
  let listened = []
  methods.notice("log", params => listened.push(params))
  let notices =
    #|[{"jsonrpc":"2.0","method":"log","params":[1]},{"jsonrpc":"2.0","method":"log","params":[2]}]
  assert_eq(methods.body(notices), None)
  assert_eq(listened.length(), 2)
}

///|
async test "typed with the parameters left out is -32602, not an empty list" {
  let methods = @moonjrpc.Methods::new()
  methods.typed("count", (numbers : Array[Int32]) => numbers.length())
  let bare =
    #|{"jsonrpc":"2.0","id":3,"method":"count"}
  guard @json.parse(methods.body(bare).unwrap())
    is Object({ "error": Object({ "code": Number(code, ..), .. }), .. }) else {
    abort("no error object")
  }
  assert_eq(code, -32602)
}
