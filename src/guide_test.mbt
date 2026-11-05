// What docs/guide.html shows: scripts/check_guide.py checks every line of the page's code and output
// against this file and src/peer/guide_test.mbt.

///|
async test "guide: answer a request" {
  let methods = @moonjrpc.Methods::new()
  methods.typed("sum", (numbers : Array[Int32]) => {
    numbers.fold(init=0, (a, b) => a + b)
  })
  let request =
    #|{"jsonrpc":"2.0","id":1,"method":"sum","params":[1,2,3]}
  let answer = methods.body(request)
  inspect(
    answer.unwrap(),
    content=(
      #|{"jsonrpc":"2.0","id":1,"result":6}
    ),
  )
}

///|
async test "guide: errors" {
  let methods = @moonjrpc.Methods::new()
  methods.call("no", _ => @moonjrpc.fail(7, "said no", data=Json::string("why")))
  let refused =
    #|{"jsonrpc":"2.0","id":1,"method":"no"}
  let unknown =
    #|{"jsonrpc":"2.0","id":2,"method":"nobody"}
  inspect(
    methods.body(refused).unwrap(),
    content=(
      #|{"jsonrpc":"2.0","id":1,"error":{"code":7,"message":"said no","data":"why"}}
    ),
  )
  inspect(
    methods.body(unknown).unwrap(),
    content=(
      #|{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Method not found"}}
    ),
  )
  inspect(
    methods.body("not json").unwrap(),
    content=(
      #|{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}
    ),
  )
}

///|
async test "guide: notices and batches" {
  let methods = @moonjrpc.Methods::new()
  let logged = []
  methods.notice("log", params => logged.push(params))
  let notice =
    #|{"jsonrpc":"2.0","method":"log","params":["hello"]}
  assert_eq(methods.body(notice), None)
  inspect(logged.length(), content="1")
  methods.call("ping", _ => Json::string("pong"))
  let batch =
    #|[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"log"}]
  inspect(
    methods.body(batch).unwrap(),
    content=(
      #|[{"jsonrpc":"2.0","id":1,"result":"pong"}]
    ),
  )
  inspect(
    methods.body(batch, batch=false).unwrap(),
    content=(
      #|{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid Request"}}
    ),
  )
}

///|
test "guide: messages are plain values" {
  let call : @moonjrpc.Message = Call(
    id=@moonjrpc.Id::int(1),
    name="ping",
    params=None,
  )
  inspect(
    call.to_json().stringify(),
    content=(
      #|{"jsonrpc":"2.0","id":1,"method":"ping"}
    ),
  )
}
