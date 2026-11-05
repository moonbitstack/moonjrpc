///|
/// How one message's text travels: a line, a WebSocket frame, an HTTP body. Implement this to carry
/// JSON-RPC over anything.
pub(open) trait Frames {
  /// The next message's text, or `None` once the other side has closed.
  async fn read(Self) -> String?
  async fn write(Self, String) -> Unit
}

///|
/// The longest message `lines` and `content_length` take: 64 MiB. vscode-jsonrpc and the MCP SDKs
/// set no bound, gRPC's default is 4 MiB; no common value exists, so this takes the safe side without
/// refusing what a large tool result needs.
pub let limit : Int32 = 67108864

///|
/// Bytes read and not yet handed out. `Reader` buffers too, but gives no way to stop at a bound.
priv struct Held {
  reader : &@io.Reader
  limit : Int32
  mut store : FixedArray[Byte]
  mut start : Int32
  mut end : Int32
  /// Everything before this has been searched, so a long message is not searched again per read.
  mut searched : Int32
}

///|
fn Held::new(reader : &@io.Reader, limit : Int32) -> Held {
  {
    reader,
    limit,
    store: FixedArray::make(4096, b'\x00'),
    start: 0,
    end: 0,
    searched: 0,
  }
}

///|
fn Held::length(self : Held) -> Int32 {
  self.end - self.start
}

///|
/// Read more. False at the end of the input.
async fn Held::fill(self : Held) -> Bool {
  if self.end == self.store.length() {
    let length = self.length()
    let store = if length * 2 > self.store.length() {
      FixedArray::make(self.store.length() * 2, b'\x00')
    } else {
      self.store
    }
    FixedArray::blit_to(self.store, store, len=length, src_offset=self.start)
    self.store = store
    self.searched -= self.start
    self.start = 0
    self.end = length
  }
  let got = self.reader.read(
    self.store,
    offset=self.end,
    max_len=self.store.length() - self.end,
  )
  self.end += got
  got > 0
}

///|
/// How far `mark` is from the next byte to hand out.
fn Held::find(self : Held, mark : Bytes) -> Int32? {
  let last = self.end - mark.length()
  let mut at = @cmp.maximum(self.start, self.searched)
  while at <= last {
    let mut same = true
    for i in 0..<mark.length() {
      if self.store[at + i] != mark[i] {
        same = false
        break
      }
    }
    if same {
      return Some(at - self.start)
    }
    at += 1
  }
  self.searched = at
  None
}

///|
/// Take the next `n` bytes and drop `skip` more.
fn Held::take(self : Held, n : Int32, skip : Int32) -> Bytes {
  let out = Bytes::makei(n, i => self.store[self.start + i])
  self.start += n + skip
  self.searched = self.start
  out
}

///|
fn Held::too_long(self : Held, got : Int32) -> Unit raise @moonjsonrpc.Failed {
  if got > self.limit {
    raise @moonjsonrpc.TooLong(limit=self.limit, got=got.to_int64())
  }
}

///|
/// Text that is not valid UTF-8 gets the same answer as text that is not JSON, so it comes through as
/// something no JSON parser takes.
fn text_of(bytes : Bytes) -> String {
  @utf8.decode(bytes) catch {
    _ => "\u{FFFD}"
  }
}

///|
priv struct Lines {
  held : Held
  writer : &@io.Writer
}

///|
impl Frames for Lines with fn read(self) {
  let held = self.held
  while true {
    match held.find(b"\n") {
      Some(at) => {
        held.too_long(at)
        let text = text_of(held.take(at, 1)).trim(chars=" \t\r").to_owned()
        if !text.is_empty() {
          return Some(text)
        }
      }
      None => {
        held.too_long(held.length())
        if !held.fill() {
          let text = text_of(held.take(held.length(), 0))
            .trim(chars=" \t\r")
            .to_owned()
          return if text.is_empty() { None } else { Some(text) }
        }
      }
    }
  }
  None
}

///|
impl Frames for Lines with fn write(self, text) {
  self.writer.write("\{text}\n")
}

///|
/// One message to a line: the stdio transport of MCP and ACP. Blank lines are skipped, a last line
/// with no newline still counts, and a line over `limit` bytes raises `TooLong`.
pub fn lines(
  reader : &@io.Reader,
  writer : &@io.Writer,
  limit~ : Int32 = limit,
) -> &Frames {
  ({ held: Held::new(reader, limit), writer, } : Lines)
}

///|
priv struct ContentLength {
  held : Held
  writer : &@io.Writer
}

///|
/// The `Content-Length` of a header block. The name is matched in any case; the other headers, such
/// as `Content-Type`, do not change how the body is read.
fn length_of(headers : Bytes) -> Int64 raise @moonjsonrpc.Failed {
  for line in text_of(headers).split("\r\n") {
    guard line.find(":") is Some(at) else {
      raise @moonjsonrpc.Malformed("header without a colon: \{line}")
    }
    if line[:at].to_lower() == "content-length" {
      let digits = line[at + 1:].trim(chars=" \t")
      guard !digits.is_empty() && digits.length() <= 10 else {
        raise @moonjsonrpc.Malformed("bad Content-Length: \{line}")
      }
      let mut length = 0L
      for digit in digits {
        guard digit is ('0'..<='9') else {
          raise @moonjsonrpc.Malformed("bad Content-Length: \{line}")
        }
        length = length * 10 + (digit.to_int() - '0'.to_int()).to_int64()
      }
      return length
    }
  }
  raise @moonjsonrpc.Malformed("no Content-Length")
}

///|
impl Frames for ContentLength with fn read(self) {
  let held = self.held
  let mark = b"\r\n\r\n"
  let end = while true {
    match held.find(mark) {
      Some(at) => break at
      None => {
        held.too_long(held.length())
        if !held.fill() {
          if held.length() == 0 {
            return None
          }
          raise @moonjsonrpc.Malformed("the input ended inside the headers")
        }
      }
    }
  } nobreak {
    return None
  }
  held.too_long(end)
  let length = length_of(held.take(end, mark.length()))
  if length > held.limit.to_int64() {
    raise @moonjsonrpc.TooLong(limit=held.limit, got=length)
  }
  let length = length.to_int()
  while held.length() < length {
    if !held.fill() {
      raise @moonjsonrpc.Malformed("the input ended inside a message")
    }
  }
  Some(text_of(held.take(length, 0)))
}

///|
impl Frames for ContentLength with fn write(self, text) {
  let body = @utf8.encode(text)
  self.writer.write("Content-Length: \{body.length()}\r\n\r\n")
  self.writer.write(body)
}

///|
/// A `Content-Length` header, a blank line, the body: the base protocol of LSP. A message over `limit`
/// bytes raises `TooLong`.
pub fn content_length(
  reader : &@io.Reader,
  writer : &@io.Writer,
  limit~ : Int32 = limit,
) -> &Frames {
  ({ held: Held::new(reader, limit), writer, } : ContentLength)
}
