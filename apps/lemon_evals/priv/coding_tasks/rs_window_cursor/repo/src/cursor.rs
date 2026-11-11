use std::iter::FusedIterator;

#[derive(Debug, PartialEq, Eq)]
pub enum CursorError { ZeroSize }
#[derive(Debug, PartialEq, Eq)]
pub struct Batch<'a, T> { pub offset: usize, pub items: &'a [T] }
pub struct BatchCursor<'a, T> { data: &'a [T], size: usize, position: usize }
impl<'a, T> BatchCursor<'a, T> {
    pub fn new(data: &'a [T], size: usize) -> Result<Self, CursorError> {
        if size == 0 { return Err(CursorError::ZeroSize); }
        Ok(Self { data, size, position: 0 })
    }
}
impl<'a, T> Iterator for BatchCursor<'a, T> {
    type Item = Batch<'a, T>;
    fn next(&mut self) -> Option<Self::Item> {
        let end = self.position + self.size;
        if end > self.data.len() { return None; }
        let batch = Batch { offset: self.position, items: &self.data[self.position..end] };
        self.position = end;
        Some(batch)
    }
    fn size_hint(&self) -> (usize, Option<usize>) {
        let n = (self.data.len() - self.position) / self.size;
        (n, Some(n))
    }
}
impl<T> ExactSizeIterator for BatchCursor<'_, T> {}
impl<T> FusedIterator for BatchCursor<'_, T> {}
