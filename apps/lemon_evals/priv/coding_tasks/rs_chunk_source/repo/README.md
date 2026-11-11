# Resumable chunk sources

Repair `chunk_source`, a dependency-free library for resumable byte reads. Keep the existing modules and the exact public API below, all available at crate root. Sources own their state; callers can resume after successful short reads or errors. No async or lifetime-heavy interface is needed.

```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReadError { Interrupted, Fault(&'static str) }
pub trait ChunkSource {
    fn read_chunk(&mut self, output: &mut [u8]) -> Result<usize, ReadError>;
}
pub struct BytesSource; // fields private
impl BytesSource {
    pub fn new(bytes: Vec<u8>) -> Self;
    pub fn position(&self) -> usize;
}
pub struct LimitSource<S>; // fields private
impl<S: ChunkSource> LimitSource<S> {
    pub fn new(inner: S, limit: usize) -> Self;
    pub fn remaining(&self) -> usize;
    pub fn into_inner(self) -> S;
}
pub struct ChainSource<A, B>; // fields private
impl<A: ChunkSource, B: ChunkSource> ChainSource<A, B> {
    pub fn new(first: A, second: B) -> Self;
    pub fn into_inner(self) -> (A, B);
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExactError {
    UnexpectedEof { read: usize },
    Source { error: ReadError, read: usize },
}
pub trait ReadExt: ChunkSource {
    fn read_exact(&mut self, output: &mut [u8]) -> Result<(), ExactError>;
    fn read_to_end(&mut self, output: &mut Vec<u8>) -> Result<usize, ReadError>;
}
```
Implement `ChunkSource` for all three source types, and blanket-implement `ReadExt` for every `T: ChunkSource + ?Sized`, so extensions work on `&mut dyn ChunkSource` as well as concrete sources. Methods take no ownership of caller buffers.

## Shared read contract
For a nonempty buffer, `Ok(n)` with `n > 0` writes exactly the prefix of length `n`, advances by `n`, and leaves the rest unchanged; short reads are valid. `Ok(0)` means permanent EOF. An error consumes no bytes and changes no buffer bytes; a source may subsequently resume. `Interrupted` is a retryable error. All sources supplied to adapters/extensions obey this contract and never return a count larger than the buffer. A zero-length output always returns `Ok(0)` without reading, changing state, or consulting an inner source; it does not mark EOF.

`BytesSource` copies as many remaining bytes as fit; its position is the number already consumed and stays at the length after EOF.

`LimitSource` exposes at most `limit` bytes from the inner source's current position. Cap the slice passed inward, decrement `remaining()` only by successful byte counts, and do not consume beyond the limit. At a zero limit return EOF without consulting the inner source. If the inner source reaches EOF early, latch EOF and never consult it again, but `remaining()` still reports the unused quota. Errors do not latch EOF or change quota. `into_inner` returns the inner source with its current position.

`ChainSource` reads the first source until it returns EOF for a nonempty request, then reads the second in that same call. Successful reads from the first return immediately, even if short: do not combine sources in one returned chunk. Errors never switch sources. EOF from either source is latched; once the second reaches EOF, later calls do not consult either source. Empty requests neither consult sources nor switch them. `into_inner` recovers both sources with their current positions.

`read_exact` fills the whole output across partial reads, retrying `Interrupted`. On premature EOF return `UnexpectedEof { read }`; on another error return `Source { error, read }`. `read` counts successful bytes from this invocation only. Already written prefixes remain; unwritten suffixes stay unchanged. Empty requests succeed without consulting the source. The source remains resumable after either error.

`read_to_end` appends all remaining bytes to the existing vector, preserving its prefix and retrying `Interrupted`. Return the count appended (not the total vector length). On another error retain bytes appended so far and return that error, leaving the source resumable. Stop at the first EOF. No external crates.

Run `cargo test --offline`.
