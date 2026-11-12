use crate::{ChunkSource, ReadError};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExactError {
    UnexpectedEof { read: usize },
    Source { error: ReadError, read: usize },
}

pub trait ReadExt: ChunkSource {
    fn read_exact(&mut self, output: &mut [u8]) -> Result<(), ExactError> {
        let mut read = 0;
        while read < output.len() {
            match self.read_chunk(&mut output[read..]) {
                Ok(0) => return Err(ExactError::UnexpectedEof { read }),
                Ok(count) => read += count,
                Err(ReadError::Interrupted) => continue,
                Err(error) => return Err(ExactError::Source { error, read }),
            }
        }
        Ok(())
    }
    fn read_to_end(&mut self, output: &mut Vec<u8>) -> Result<usize, ReadError> {
        let start = output.len();
        let mut buffer = [0; 1024];
        loop {
            match self.read_chunk(&mut buffer) {
                Ok(0) => return Ok(output.len() - start),
                Ok(count) => output.extend_from_slice(&buffer[..count]),
                Err(ReadError::Interrupted) => continue,
                Err(error) => return Err(error),
            }
        }
    }
}
impl<T: ChunkSource + ?Sized> ReadExt for T {}
