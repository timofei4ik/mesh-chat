def normalize_server_url(url):

    url = (
        url
        or ""
    ).strip()

    if not url:
        return ""

    if url.startswith("https://"):

        return "wss://" + url[len("https://"):]

    if url.startswith("http://"):

        return "ws://" + url[len("http://"):]

    if url.startswith(
        (
            "ws://",
            "wss://"
        )
    ):

        return url

    return "ws://" + url
