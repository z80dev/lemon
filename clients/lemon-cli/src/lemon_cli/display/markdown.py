from rich.markdown import Markdown as RichMarkdown


def render_markdown(text: str) -> RichMarkdown:
    return RichMarkdown(text)
