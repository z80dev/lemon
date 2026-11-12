use crate::{ChunkSource, ReadError};

pub struct LimitSource<S> { inner: S, remaining: usize, eof: bool }
impl<S: ChunkSource> LimitSource<S> {
    pub fn new(inner: S, limit: usize) -> Self { Self { inner, remaining: limit, eof: false } }
    pub fn remaining(&self) -> usize { self.remaining }
    pub fn into_inner(self) -> S { self.inner }
}
impl<S: ChunkSource> ChunkSource for LimitSource<S> {
    fn read_chunk(&mut self, output: &mut [u8]) -> Result<usize, ReadError> {
        if output.is_empty() || self.remaining == 0 || self.eof { return Ok(0); }
        let cap = output.len().min(self.remaining);
        let count = self.inner.read_chunk(&mut output[..cap])?;
        self.remaining -= count;
        if count == 0 { self.eof = true; }
        Ok(count)
    }
}

pub struct ChainSource<A, B> { first: A, second: B, in_second: bool, eof: bool }
impl<A: ChunkSource, B: ChunkSource> ChainSource<A, B> {
    pub fn new(first: A, second: B) -> Self {
        Self { first, second, in_second: false, eof: false }
    }
    pub fn into_inner(self) -> (A, B) { (self.first, self.second) }
}
impl<A: ChunkSource, B: ChunkSource> ChunkSource for ChainSource<A, B> {
    fn read_chunk(&mut self, output: &mut [u8]) -> Result<usize, ReadError> {
        if output.is_empty() || self.eof { return Ok(0); }
        if !self.in_second {
            let count = self.first.read_chunk(output)?;
            if count != 0 { return Ok(count); }
            self.in_second = true;
        }
        let count = self.second.read_chunk(output)?;
        if count == 0 { self.eof = true; }
        Ok(count)
    }
}
