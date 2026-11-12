pub fn hash(bytes: &[u8]) -> String {
    let mut state = 0xcbf29ce484222325u64;
    for byte in bytes {
        state ^= u64::from(*byte);
        state = state.wrapping_mul(0x100000001b3);
    }
    format!("{state:016x}")
}
pub fn fields(parts: &[String]) -> String {
    let mut state = 0xcbf29ce484222325u64;
    for part in parts {
        for byte in (part.len() as u64)
            .to_le_bytes()
            .iter()
            .chain(part.as_bytes())
        {
            state ^= u64::from(*byte);
            state = state.wrapping_mul(0x100000001b3);
        }
    }
    format!("{state:016x}")
}
