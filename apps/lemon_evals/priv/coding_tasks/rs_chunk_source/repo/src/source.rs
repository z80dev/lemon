#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReadError { Interrupted, Fault(&'static str) }

pub trait ChunkSource {
    fn read_chunk(&mut self, output: &mut [u8]) -> Result<usize, ReadError>;
}

pub struct BytesSource { bytes: Vec<u8>, position: usize }
impl BytesSource {
    pub fn new(bytes: Vec<u8>) -> Self { Self { bytes, position: 0 } }
    pub fn position(&self) -> usize { self.position }
}
impl ChunkSource for BytesSource {
    fn read_chunk(&mut self, output: &mut [u8]) -> Result<usize, ReadError> {
        let count = output.len().min(self.bytes.len() - self.position);
        output[..count].copy_from_slice(&self.bytes[self.position..self.position + count]);
        self.position += count;
        Ok(count)
    }
}
