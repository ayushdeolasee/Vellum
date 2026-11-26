# /// script
# dependencies = ["pikepdf==10.18.2", "Pillow>=10"]
# ///
"""Run with uv run tools/pdf-fixtures/validate.py with Poppler and OpenSSL on PATH."""
import subprocess
import tempfile
import zlib
from pathlib import Path

import pikepdf
from PIL import Image

corpus = Path(__file__).resolve().parents[2] / "Packages/VellumCore/Tests/VellumCoreTests/Fixtures/Pdf"


def open_pdf(name, **kwargs):
    return pikepdf.open(corpus / name, attempt_recovery=False, inherit_page_attributes=False, **kwargs)


def validate():
    with open_pdf("classic-two-column.pdf") as pdf:
        assert not pdf.check_pdf_syntax()
        assert all(entry.type == 1 for entry in pdf.get_xref_table().values())
        assert "/Type" not in pdf.trailer and "/Annots" not in pdf.pages[0]
    text = subprocess.check_output(["pdftotext", "-layout", corpus / "classic-two-column.pdf", "-"])
    rows = [line.split() for line in text.decode().splitlines() if line.strip()]
    assert rows == ["Left column: Café Right column: naïve".split(),
                    "First line of evidence. Second line of evidence.".split()]

    with open_pdf("xref-stream-objstm.pdf") as pdf:
        assert not pdf.check_pdf_syntax()
        assert pdf.trailer.Type == "/XRef"
        offset = int((corpus / "xref-stream-objstm.pdf").read_bytes().split(b"startxref")[-1].split()[0])
        table = pdf.get_xref_table()
        number, = [key for key, entry in table.items() if entry.type == 1 and entry.offset == offset]
        xref = pdf.get_object(number)
        assert xref.Filter == "/FlateDecode" and xref.DecodeParms.Predictor == 12
        row_width = 1 + sum(xref.W)
        rows = zlib.decompress(xref.read_raw_bytes())
        assert xref.DecodeParms.Columns == row_width - 1
        assert len(rows) == xref.Size * row_width and set(rows[::row_width]) == {2}
        for obj in [pdf.Root, pdf.Root.Pages, pdf.pages[0].obj, pdf.pages[0].Resources.Font.Helv]:
            entry = table[obj.objgen]
            assert entry.type == 2 and pdf.get_object(entry.obj_stream_number, 0).Type == "/ObjStm"

    for credentials in [{}, {"password": "wrong"}]:
        try:
            with open_pdf("encrypted-user-pass.pdf", **credentials):
                raise AssertionError("Encrypted fixture opened without the user password")
        except pikepdf.PasswordError:
            pass
    with open_pdf("encrypted-user-pass.pdf", password="vellum") as pdf:
        assert pdf.is_encrypted and pdf.user_password_matched and pdf.encryption.bits == 256
        assert not pdf.check_pdf_syntax() and len(pdf.pages) == 1

    with open_pdf("digitally-signed.pdf") as pdf:
        assert not pdf.check_pdf_syntax()
        form = pdf.Root.AcroForm
        field, = form.Fields
        assert form.SigFlags == 3 and field.FT == "/Sig" and field.V.Type == "/Sig"
        assert field.V.SubFilter == "/adbe.pkcs7.detached"
        start, first_size, second_start, second_size = field.V.ByteRange
        assert start == 0 < first_size < second_start
        data = (corpus / "digitally-signed.pdf").read_bytes()
        assert second_start + second_size == len(data)
        assert data[first_size] == ord("<") and data[second_start - 1] == ord(">")
        cms = bytes(field.V.Contents)
        assert bytes.fromhex(data[first_size + 1:second_start - 1].decode()) == cms
    with tempfile.TemporaryDirectory() as directory:
        content = Path(directory) / "signed-bytes"
        content.write_bytes(data[:first_size] + data[second_start:])
        # Verify the detached signature over both byte ranges. The fixture is self-signed.
        subprocess.run(["openssl", "cms", "-verify", "-binary", "-inform", "DER", "-noverify",
                        "-content", content], input=cms, stdout=subprocess.DEVNULL, check=True)

    with open_pdf("foreign-annotations.pdf") as pdf:
        assert not pdf.check_pdf_syntax()
        annots = pdf.pages[0].Annots
        highlight, empty, free_text, link = annots
        assert not annots.is_indirect and empty is None
        assert highlight.is_indirect and not free_text.is_indirect and link.is_indirect
        assert [a.Subtype for a in (highlight, free_text, link)] == ["/Highlight", "/FreeText", "/Link"]
        assert all("/NM" not in a for a in (highlight, free_text, link))

    with open_pdf("rotated-all-angles.pdf") as pdf:
        assert not pdf.check_pdf_syntax()
        assert list(pdf.Root.Pages.CropBox) == [24, 36, 576, 744]
        assert [page.Rotate for page in pdf.pages] == [0, 90, 180, 270]
    # Centers in the unrotated, top-left-origin cropped raster at one pixel per point.
    marks = [(15, 691, (255, 0, 0)), (530, 685, (0, 255, 0)),
             (22, 21, (0, 0, 255)), (523, 28, (255, 0, 255))]
    with tempfile.TemporaryDirectory() as directory:
        prefix = Path(directory) / "crop"
        subprocess.run(["pdftoppm", "-cropbox", "-r", "72", "-png", corpus / "rotated-all-angles.pdf", prefix],
                       check=True)
        width, height = 552, 708
        for number in range(1, 5):
            with Image.open(f"{prefix}-{number}.png") as image:
                assert image.size == (width, height)
                for x, y, color in marks:
                    assert image.getpixel((x, y)) == color
            marks = [(height - 1 - y, x, color) for x, y, color in marks]
            width, height = height, width


if __name__ == "__main__":
    validate()
    print("Validated all six non-ink PDFs.")
