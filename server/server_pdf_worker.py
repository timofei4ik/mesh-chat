"""Bounded PDF text extraction in a disposable process, without provider secrets."""
import io
import json
import sys

if sys.platform != 'win32':
    import resource
    resource.setrlimit(resource.RLIMIT_AS, (384 * 1024 * 1024, 384 * 1024 * 1024))
    resource.setrlimit(resource.RLIMIT_CPU, (12, 12))

from pypdf import PdfReader

data = sys.stdin.buffer.read(3 * 1024 * 1024 + 1)
if len(data) > 3 * 1024 * 1024:
    raise ValueError('document_too_large')
reader = PdfReader(io.BytesIO(data), strict=True)
if reader.is_encrypted:
    raise ValueError('encrypted_document')
pages = []
for index, page in enumerate(reader.pages):
    if index >= 12:
        break
    text = (page.extract_text() or '').strip()[:2000]
    if text:
        pages.append({'page': index + 1, 'text': text})
sys.stdout.buffer.write(json.dumps(pages, ensure_ascii=False).encode('utf-8'))
