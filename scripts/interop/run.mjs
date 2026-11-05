// Real JSON-RPC implementations against src/examples/03-interop:
//   vscode-jsonrpc, the one VS Code's language servers use, over Content-Length framing;
//   json-rpc-2.0 over one message to a line, then the same bodies through both, compared.
//
//     node scripts/interop/run.mjs <path to the 03-interop executable>
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { JSONRPCServer, JSONRPCServerAndClient, JSONRPCClient } from "json-rpc-2.0";
import * as rpc from "vscode-jsonrpc/node";

const program = process.argv[2];

function start(mode) {
  const child = spawn(program, [mode], { stdio: ["pipe", "pipe", "inherit"] });
  child.on("error", (error) => {
    console.error(error);
    process.exit(1);
  });
  return child;
}

async function closed(child) {
  child.stdin.end();
  return new Promise((resolve) => child.on("close", resolve));
}

async function refused(call, code) {
  try {
    await call();
  } catch (error) {
    assert.equal(error.code, code);
    return error;
  }
  assert.fail(`no error ${code}`);
}

async function withVscode() {
  const child = start("content-length");
  const connection = rpc.createMessageConnection(
    new rpc.StreamMessageReader(child.stdout),
    new rpc.StreamMessageWriter(child.stdin),
  );
  connection.onRequest("who", () => "vscode-jsonrpc");
  connection.listen();

  assert.equal(await connection.sendRequest("sum", 1, 2, 3), 6);
  assert.deepEqual(await connection.sendRequest("echo", { cat: "猫", n: 1 }), { cat: "猫", n: 1 });
  assert.equal(await connection.sendRequest("ask_back"), "hello vscode-jsonrpc");

  const no = await refused(() => connection.sendRequest("no"), 7);
  assert.equal(no.message, "said no");
  assert.equal(no.data, "why");
  await refused(() => connection.sendRequest("nobody"), -32601);
  await refused(() => connection.sendRequest("boom"), -32603);
  await refused(() => connection.sendRequest("sum", "x"), -32602);

  // Notices are handled in the order they were sent, ahead of a call sent after them.
  for (const i of [1, 2, 3]) {
    await connection.sendNotification("log", i);
  }
  await connection.sendNotification("nobody");
  assert.deepEqual(await connection.sendRequest("logged"), [[1], [2], [3]]);

  // Far past the 4096 bytes the reader starts with, and past what one read returns.
  const large = "猫".repeat(200000);
  assert.equal(await connection.sendRequest("echo", large).then((a) => a[0]), large);

  connection.dispose();
  assert.equal(await closed(child), 0);
  console.log("vscode-jsonrpc: every call both ways");
}

async function withLines() {
  const child = start("lines");
  const both = new JSONRPCServerAndClient(
    new JSONRPCServer(),
    new JSONRPCClient((message) => {
      child.stdin.write(JSON.stringify(message) + "\n");
    }),
  );
  both.addMethod("who", () => "json-rpc-2.0");
  createInterface({ input: child.stdout }).on("line", (line) => both.receiveAndSend(JSON.parse(line)));

  assert.equal(await both.request("sum", [1, 2, 3]), 6);
  assert.equal(await both.request("ask_back"), "hello json-rpc-2.0");
  await refused(() => both.request("no"), 7);
  await refused(() => both.request("nobody"), -32601);
  both.rejectAllPendingRequests("done");
  assert.equal(await closed(child), 0);
  console.log("json-rpc-2.0: every call both ways");
}

const bodies = [
  { jsonrpc: "2.0", id: 1, method: "sum", params: [1, 2] },
  { jsonrpc: "2.0", id: "a", method: "sum", params: [1, 2] },
  { jsonrpc: "2.0", id: null, method: "sum", params: [1, 2] },
  { jsonrpc: "2.0", method: "log", params: [1] },
  { jsonrpc: "2.0", method: "nobody" },
  { jsonrpc: "2.0", id: 1, method: "nobody" },
  { jsonrpc: "2.0", id: 1, method: "echo", params: { a: 1 } },
  { jsonrpc: "2.0", id: 1, method: "echo" },
  { jsonrpc: "1.0", id: 1, method: "echo" },
  { id: 1, method: "echo" },
  { jsonrpc: "2.0", id: 1, method: 3 },
  { jsonrpc: "2.0", method: 3 },
  { jsonrpc: "2.0", id: 1 },
  { jsonrpc: "2.0", id: 1, method: "no" },
  1,
  "x",
  null,
];

async function compareBodies() {
  const server = new JSONRPCServer();
  server.addMethod("sum", (numbers) => numbers.reduce((a, b) => a + b, 0));
  server.addMethod("echo", (params) => params ?? null);
  server.addMethod("log", () => {});
  server.addMethod("no", () => {
    throw new (class extends Error {
      code = 7;
    })("said no");
  });
  server.mapErrorToJSONRPCErrorResponse = (id, error) => ({
    jsonrpc: "2.0",
    id,
    error: { code: error.code ?? -32603, message: error.message, data: "why" },
  });

  const child = start("body");
  const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
  const differing = [];
  for (const body of bodies) {
    child.stdin.write(`${JSON.stringify(body)}\n`);
    const ours = JSON.parse((await lines.next()).value);
    const theirs = await server.receive(body).then(
      (answer) => answer ?? null,
      () => "threw",
    );
    try {
      assert.deepEqual(ours, theirs);
    } catch {
      differing.push({ body, ours, theirs });
    }
  }
  await closed(child);
  console.log(`json-rpc-2.0: ${bodies.length} bodies compared, ${differing.length} differ`);
  for (const one of differing) {
    console.log(JSON.stringify(one));
  }
  // A method that is not a string: the specification's own example answers -32600, and they answer
  // -32601 or nothing. A null body: they throw. A new difference fails here until someone looks at it.
  assert.deepEqual(
    differing.map((one) => JSON.stringify(one.body)),
    ['{"jsonrpc":"2.0","id":1,"method":3}', '{"jsonrpc":"2.0","method":3}', "null"],
  );
}

await withVscode();
await withLines();
await compareBodies();
