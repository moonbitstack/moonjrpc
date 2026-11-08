///|
/// Everything `frames` reads from `input`, given all at once.
async fn read_all_lines(
  input : String,
  limit~ : Int32 = @peer.limit,
) -> Array[String] {
  let (reads, in_writes) = @io.pipe()
  let (_, writes) = @io.pipe()
  let frames = @peer.lines(reads, writes, limit~)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      in_writes.write(input)
      in_writes.close()
    })
    let out = []
    while frames.read() is Some(text) {
      out.push(text)
    }
    out
  })
}

///|
async fn read_all_framed(
  input : Bytes,
  limit~ : Int32 = @peer.limit,
) -> Array[String] {
  let (reads, in_writes) = @io.pipe()
  let (_, writes) = @io.pipe()
  let frames = @peer.content_length(reads, writes, limit~)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      in_writes.write(input)
      in_writes.close()
    })
    let out = []
    while frames.read() is Some(text) {
      out.push(text)
    }
    out
  })
}

///|
async test "lines: blank lines, carriage returns and a last line with no newline" {
  assert_eq(read_all_lines("a\n\n  \r\nb\r\nc"), ["a", "b", "c"])
  assert_eq(read_all_lines(""), [])
  assert_eq(read_all_lines("\n\n"), [])
}

///|
async test "lines: limit, on both sides" {
  assert_eq(read_all_lines("aaaa\n", limit=8), ["aaaa"])
  let got = try read_all_lines("aaaaaaaaaaaaaaaaaaaa\n", limit=8) catch {
    @moonjrpc.TooLong(limit~, got~) => {
      assert_eq(limit, 8)
      assert_true(got > 0L)
      "too long"
    }
    _ => "other"
  } noraise {
    _ => "read"
  }
  assert_eq(got, "too long")
  // No newline ever comes: this is the case that would otherwise take all the memory there is.
  let got = try read_all_lines("aaaaaaaaaaaaaaaaaaaa", limit=8) catch {
    @moonjrpc.TooLong(_) => "too long"
    _ => "other"
  } noraise {
    _ => "read"
  }
  assert_eq(got, "too long")
}

///|
async test "lines: bad bytes inside a JSON string do not turn into valid JSON" {
  let (reads, in_writes) = @io.pipe()
  let (_, writes) = @io.pipe()
  let frames = @peer.lines(reads, writes)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      in_writes.write(b"[\"\xff\"]\n")
      in_writes.close()
    })
    let parsed = try @json.parse(frames.read().unwrap()) catch {
      _ => false
    } noraise {
      _ => true
    }
    assert_false(parsed)
  })
}

///|
async test "lines: writes one line" {
  let (reads, writes) = @io.pipe()
  let (other, _) = @io.pipe()
  let frames = @peer.lines(other, writes)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      frames.write("{}")
      writes.close()
    })
    assert_eq(reads.read_all().text(), "{}\n")
  })
}

///|
async test "lines: bytes that are not UTF-8 come through as something no JSON parser takes" {
  let (reads, in_writes) = @io.pipe()
  let (_, writes) = @io.pipe()
  let frames = @peer.lines(reads, writes)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      in_writes.write(b"\xff\xfe\n")
      in_writes.close()
    })
    let text = frames.read().unwrap()
    let parsed = try @json.parse(text) catch {
      _ => false
    } noraise {
      _ => true
    }
    assert_false(parsed)
  })
}

///|
async test "content_length: several messages, in any case, with other headers" {
  let input = "Content-Length: 2\r\n\r\n{}content-length:3\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n[1]"
  assert_eq(read_all_framed(@utf8.encode(input)), ["{}", "[1]"])
}

///|
async test "content_length: the length counts bytes, not characters" {
  let body = "\"猫\""
  let bytes = @utf8.encode(body)
  assert_eq(bytes.length(), 5)
  let input = @utf8.encode("Content-Length: 5\r\n\r\n\{body}")
  assert_eq(read_all_framed(input), [body])
}

///|
async test "content_length: writes the length in bytes" {
  let (reads, writes) = @io.pipe()
  let (other, _) = @io.pipe()
  let frames = @peer.content_length(other, writes)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      frames.write("\"猫\"")
      writes.close()
    })
    assert_eq(reads.read_all().text(), "Content-Length: 5\r\n\r\n\"猫\"")
  })
}

///|
async test "content_length: nothing at all is the end of the input" {
  assert_eq(read_all_framed(b""), [])
}

///|
async test "content_length: what cannot be read raises Malformed" {
  let cases = [
    ("X: 1\r\n\r\n{}", "no Content-Length"),
    ("Content-Length: x\r\n\r\n{}", "bad Content-Length"),
    ("Content-Length:\r\n\r\n{}", "bad Content-Length"),
    ("Content-Length: -1\r\n\r\n{}", "bad Content-Length"),
    ("Content-Length: 12345678901\r\n\r\n", "bad Content-Length"),
    ("no colon\r\n\r\n{}", "header without a colon"),
    ("Content-Length: 2\r\n", "the input ended inside the headers"),
    ("Content-Length: 99\r\n\r\n{}", "the input ended inside a message"),
  ]
  for case in cases {
    let (input, want) = case
    let got = try read_all_framed(@utf8.encode(input)) catch {
      @moonjrpc.Malformed(reason) => reason
      _ => "other"
    } noraise {
      _ => "read"
    }
    assert_true(got.has_prefix(want))
  }
}

///|
async test "content_length: limit, on both sides" {
  let input = @utf8.encode("Content-Length: 4\r\n\r\n1234")
  assert_eq(read_all_framed(input, limit=64), ["1234"])
  let got = try read_all_framed(input, limit=3) catch {
    @moonjrpc.TooLong(limit~, got~) => {
      assert_eq(limit, 3)
      got
    }
    _ => -1L
  } noraise {
    _ => -2L
  }
  assert_true(got > 0L)
  // The headers fit and the body does not, so only the declared length can trip this.
  let long = @utf8.encode("Content-Length: 40\r\n\r\n\{pattern(40)}")
  let got = try read_all_framed(long, limit=30) catch {
    @moonjrpc.TooLong(got~, ..) => got
    _ => -1L
  } noraise {
    _ => -2L
  }
  assert_eq(got, 40L)
  let unending = @utf8.encode(
    "Content-Length: 1\r\nX: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  )
  let got = try read_all_framed(unending, limit=8) catch {
    @moonjrpc.TooLong(_) => "too long"
    _ => "other"
  } noraise {
    _ => "read"
  }
  assert_eq(got, "too long")
}

///|
/// A piece of text of `n` characters, each one telling where it is.
fn pattern(n : Int32) -> String {
  let out = StringBuilder()
  for i in 0..<n {
    out.write_char((i % 26 + 97).unsafe_to_char())
  }
  out.to_string()
}

///|
async test "lines: a message far longer than the first read, and many short ones after it" {
  let long = pattern(100000)
  let short = pattern(3000)
  let input = StringBuilder()
  input.write_string(long)
  input.write_char('\n')
  for _ in 0..<20 {
    input.write_string(short)
    input.write_char('\n')
  }
  let got = read_all_lines(input.to_string())
  assert_eq(got.length(), 21)
  assert_true(got[0] == long)
  for one in got[1:] {
    assert_true(one == short)
  }
}

///|
async test "content_length: a message far longer than the first read, and many short ones after it" {
  let long = pattern(100000)
  let short = pattern(3000)
  let input = StringBuilder()
  input.write_string("Content-Length: 100000\r\n\r\n")
  input.write_string(long)
  for _ in 0..<20 {
    input.write_string("Content-Length: 3000\r\n\r\n")
    input.write_string(short)
  }
  let got = read_all_framed(@utf8.encode(input.to_string()))
  assert_eq(got.length(), 21)
  assert_true(got[0] == long)
  for one in got[1:] {
    assert_true(one == short)
  }
}

///|
async test "two peers talk over content_length" {
  let (right_reads, left_writes) = @io.pipe()
  let (left_reads, right_writes) = @io.pipe()
  let right = @moonjrpc.Methods::new()
  right.call("猫", _ => Json::string("喵"))
  let a = @peer.Peer::new(@peer.content_length(left_reads, left_writes))
  let b = @peer.Peer::new(
    @peer.content_length(right_reads, right_writes),
    methods=right,
  )
  @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, () => a.run())
    group.spawn_bg(no_wait=true, () => b.run())
    assert_eq(a.call("猫"), Json::string("喵"))
    left_writes.close()
    right_writes.close()
    group.return_immediately(())
  })
}

///|
test "the default limits: 64 MiB to a message, 60 seconds to a call" {
  assert_eq(@peer.limit, 67_108_864)
  assert_eq(@peer.timeout_ms, 60_000)
}
