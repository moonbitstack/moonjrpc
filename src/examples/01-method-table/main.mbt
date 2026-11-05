///|
async fn main {
  let methods = @moonjsonrpc.Methods::new()
  methods.typed("sum", (numbers : Array[Int32]) => {
    numbers.fold(init=0, (a, b) => a + b)
  })
  methods.call("no", _ => @moonjsonrpc.fail(7, "said no"))
  let call =
    #|{"jsonrpc":"2.0","id":1,"method":"sum","params":[1,2,3]}
  let refused =
    #|{"jsonrpc":"2.0","id":2,"method":"no"}
  let unknown =
    #|{"jsonrpc":"2.0","id":3,"method":"nobody"}
  let bodies = [call, refused, unknown, "not json"]
  for body in bodies {
    println(methods.body(body).unwrap())
  }
}
