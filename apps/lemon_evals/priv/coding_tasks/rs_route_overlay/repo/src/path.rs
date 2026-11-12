use crate::RouteError;
pub(crate) fn canonical(path: &str) -> Result<String, RouteError> {
    if !path.starts_with('/') { return Err(RouteError::InvalidPath(path.into())); }
    Ok(path.trim_end_matches('/').to_string())
}
