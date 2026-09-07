import io
import unittest
from pypdf import PdfWriter
from pypdf.generic import DictionaryObject, NameObject, DecodedStreamObject
from server.server_ai_tools import extract_pdf, parse_tool_result


class AiDocumentTests(unittest.TestCase):
    def test_pdf_worker_extracts_numbered_pages_and_stops_at_twelve(self):
        writer = PdfWriter()
        for number in range(1, 15):
            page = writer.add_blank_page(width=300, height=300)
            font = DictionaryObject({NameObject('/Type'): NameObject('/Font'),
                                     NameObject('/Subtype'): NameObject('/Type1'),
                                     NameObject('/BaseFont'): NameObject('/Helvetica')})
            page[NameObject('/Resources')] = DictionaryObject({NameObject('/Font'): DictionaryObject({NameObject('/F1'): font})})
            stream = DecodedStreamObject()
            stream.set_data(f'BT /F1 12 Tf 10 100 Td (Invoice page {number}) Tj ET'.encode())
            page[NameObject('/Contents')] = writer._add_object(stream)
        data = io.BytesIO()
        writer.write(data)
        pages = extract_pdf(data.getvalue())
        self.assertEqual(12, len(pages))
        self.assertEqual({'page': 12, 'text': 'Invoice page 12'}, pages[-1])

    def test_invalid_provider_json_is_not_rendered_as_a_result(self):
        for raw in ('not json', '[]', 'null', '{}'):
            with self.assertRaises((ValueError, TypeError)):
                parse_tool_result(raw, [])

    def test_untrusted_citation_values_are_removed(self):
        result = parse_tool_result('{"answer":"No matching sources","source_ids":[{},"missing"],"items":[{"text":"x","source_ids":[{}]}]}', [])
        self.assertEqual([], result['source_ids'])
        self.assertEqual([], result['items'])
