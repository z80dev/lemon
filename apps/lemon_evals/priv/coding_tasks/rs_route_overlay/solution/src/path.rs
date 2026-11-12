use crate::RouteError;
pub(crate) fn canonical(path: &str) -> Result<String, RouteError> {
    if !path.starts_with('/') || path.contains(['?', '#', '\0']) || path.split('/').any(|part| part == "..") {
        return Err(RouteError::InvalidPath(path.into()));
    }
    let parts: Vec<_> = path.split('/').filter(|part| !part.is_empty() && *part != ".").collect();
    Ok(format!("/{}",parts.join("/")))
}
